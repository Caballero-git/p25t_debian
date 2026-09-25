#!/bin/bash
# Share the PC's internet connection with the P25T over the USB cable (NAT).
# Temporary: everything it changes is undone with "off" or by rebooting the PC.
#
# Usage (tablet connected by USB and booted into Debian):
#     bash ~/p25t-backup/stage4/pc_share_internet.sh on
#     bash ~/p25t-backup/stage4/pc_share_internet.sh off
#     bash ~/p25t-backup/stage4/pc_share_internet.sh status
#
# What "on" does:
#   - gives the PC's tablet-side network device the extra address 192.168.7.1
#     (the tablet uses it as its gateway)
#   - turns on IPv4 forwarding
#   - NAT (masquerade) for 192.168.7.0/24 out of the PC's internet device
#   - if the ufw firewall is active: allows forwarding tablet -> internet only
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

MODE=${1:-status}
TAB_MAC=02:25:54:00:00:02          # the PC-side address the tablet's gadget announces
NET=192.168.7.0/24
GW=192.168.7.1/24
STATE=/run/p25t-share.state

TABIF=$(ip -br link | awk -v m="$TAB_MAC" 'tolower($3) == m {print $1}')
OUTIF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

show() {
    echo "tablet link device : ${TABIF:-NOT FOUND (is the tablet connected and booted?)}"
    echo "internet device    : ${OUTIF:-NOT FOUND}"
    [ -n "$TABIF" ] && ip -br addr show dev "$TABIF"
    echo "ip_forward         : $(cat /proc/sys/net/ipv4/ip_forward)"
    echo "NAT rule present   : $(iptables -t nat -C POSTROUTING -s $NET ! -d $NET -j MASQUERADE 2>/dev/null && echo yes || echo no)"
}

case "$MODE" in
on)
    [ -n "$TABIF" ] || { show; exit 1; }
    [ -n "$OUTIF" ] && [ "$OUTIF" != "$TABIF" ] || { echo "No internet device found on the PC."; exit 1; }
    [ -f $STATE ] || cat /proc/sys/net/ipv4/ip_forward > $STATE
    ip addr add $GW dev "$TABIF" 2>/dev/null || true
    sysctl -q -w net.ipv4.ip_forward=1
    iptables -t nat -C POSTROUTING -s $NET ! -d $NET -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -s $NET ! -d $NET -j MASQUERADE
    iptables -C FORWARD -i "$TABIF" -o "$OUTIF" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$TABIF" -o "$OUTIF" -j ACCEPT
    iptables -C FORWARD -i "$OUTIF" -o "$TABIF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$OUTIF" -o "$TABIF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw route allow in on "$TABIF" out on "$OUTIF" > /dev/null
        echo "ufw: forwarding $TABIF -> $OUTIF allowed"
    fi
    echo "SHARING ON"
    show
    ;;
off)
    if [ -n "$TABIF" ]; then
        ip addr del $GW dev "$TABIF" 2>/dev/null || true
        iptables -D FORWARD -i "$TABIF" -o "$OUTIF" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$OUTIF" -o "$TABIF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
            ufw route delete allow in on "$TABIF" out on "$OUTIF" > /dev/null 2>&1 || true
        fi
    fi
    iptables -t nat -D POSTROUTING -s $NET ! -d $NET -j MASQUERADE 2>/dev/null || true
    if [ -f $STATE ]; then
        sysctl -q -w net.ipv4.ip_forward="$(cat $STATE)"
        rm -f $STATE
    fi
    echo "SHARING OFF"
    show
    ;;
*)
    show
    ;;
esac
