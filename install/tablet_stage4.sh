#!/bin/bash
# Stage 4 on the TABLET: internet through the PC, correct clock, locales, updates.
# Run AFTER "pc_share_internet.sh on" on the PC.
#
# Usage (in the tablet's SSH session):
#     sudo bash tablet_stage4.sh
#
# Log: /home/jose/stage4-log.txt (and a copy on the card: /boot/firmware/logs/)
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo."; exit 1; }

LOG=/home/jose/stage4-log.txt
exec > >(tee "$LOG") 2>&1
say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; cp "$LOG" /boot/firmware/logs/ 2>/dev/null; sync; exit 1; }

say "1/6 Route to the internet through the PC (192.168.7.1)"
F=/etc/systemd/network/50-usb0.network
cp -n "$F" "$F.stage3"
cat > "$F" <<'EOF'
[Match]
Name=usb*

[Network]
Address=192.168.7.2/24
Gateway=192.168.7.1
DNS=1.1.1.1
DNS=9.9.9.9
DHCPServer=yes
ConfigureWithoutCarrier=yes

[DHCPServer]
PoolOffset=10
PoolSize=10
EmitDNS=no
EmitRouter=no
EOF
networkctl reload
networkctl reconfigure usb0
sleep 3
ip route | grep default || die "no default route"
ping -c 3 -W 3 192.168.7.1 > /dev/null || die "the PC (192.168.7.1) does not answer - is sharing ON on the PC?"
echo "PC reachable"
ping -c 3 -W 5 1.1.1.1 > /dev/null || die "no internet behind the PC (ping 1.1.1.1 failed)"
echo "internet reachable"
getent hosts deb.debian.org > /dev/null || die "name lookup (DNS) does not work"
echo "DNS works"

say "2/6 Clock (the tablet has no battery-backed clock yet)"
echo "before: $(date)"
systemctl restart systemd-timesyncd
for i in $(seq 1 30); do
    [ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ] && break
    sleep 2
done
if [ "$(timedatectl show -p NTPSynchronized --value)" != "yes" ]; then
    echo "NTP did not answer; taking the time from deb.debian.org instead"
    D=$(curl -sI http://deb.debian.org/debian/ | awk -F': ' 'tolower($1) == "date" {print $2}' | tr -d '\r')
    [ -n "$D" ] && date -s "$D" > /dev/null
fi
echo "after:  $(date)"

say "3/6 Package lists"
apt-get update || die "apt-get update failed"

say "4/6 Locales en_GB.UTF-8 and es_ES.UTF-8 (the ones your PC sends)"
DEBIAN_FRONTEND=noninteractive apt-get install -y locales || die "installing locales failed"
sed -i 's/^# *\(en_GB.UTF-8 UTF-8\)/\1/; s/^# *\(es_ES.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_GB.UTF-8
sed -i 's/^#AcceptEnv/AcceptEnv/' /etc/ssh/sshd_config
systemctl reload ssh
echo "locales ready; SSH accepts your PC's language settings again"

say "5/6 Updates"
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade || die "upgrade failed"

say "6/6 Summary"
echo "date:      $(date)"
echo "debian:    $(cat /etc/debian_version)"
echo "disk:      $(df -h / | awk 'NR == 2 {print $3 " used, " $4 " free"}')"
echo "failed:    $(systemctl --failed --no-legend | wc -l) unit(s)"
cp "$LOG" /boot/firmware/logs/ 2>/dev/null
sync
echo "STAGE 4 OK - log out (exit) and ssh in again to use the new locales."
