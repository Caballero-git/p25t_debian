#!/bin/bash
# Runs INSIDE the new Debian root filesystem (chroot), called by build_debian.sh.
# Configures it for the Teclast P25T. Argument: the user name.
set -euo pipefail
U="$1"

echo "--- hostname, hosts"
echo p25t > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1	localhost
127.0.1.1	p25t
::1		localhost ip6-localhost ip6-loopback
EOF

echo "--- fstab"
mkdir -p /boot/firmware
cat > /etc/fstab <<'EOF'
# Teclast P25T - SD card
LABEL=p25troot  /               ext4  defaults,noatime,errors=remount-ro  0 1
LABEL=P25TBOOT  /boot/firmware  vfat  defaults,noatime,nofail,flush        0 2
EOF

echo "--- apt sources"
# Main archive: Universidad de Zaragoza mirror instead of the generic
# deb.debian.org redirector - noticeably quicker from here, confirmed to
# carry arm64 (not every mirror does; e.g. ftp.cica.es only has
# amd64/i386/all, checked 2026-09-28 - unusable for this tablet).
# security.debian.org is left as-is on purpose: it's not a redirector
# to random mirrors like deb.debian.org, it's Debian's own dedicated
# security CDN, and ordinary mirrors generally don't carry
# debian-security at all.
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: https://softlibre.unizar.es/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

echo "--- user $U"
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm,video,input,plugdev,dialout,audio "$U"
passwd -l root >/dev/null

echo "--- time zone"
if [ -s /root/host-timezone ]; then
    TZ_NAME=$(cat /root/host-timezone)
    if [ -e "/usr/share/zoneinfo/$TZ_NAME" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
        echo "$TZ_NAME" > /etc/timezone
        echo "time zone $TZ_NAME"
    fi
fi

echo "--- console font (large, for the 800x1280 screen)"
sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/; s/^FONTSIZE=.*/FONTSIZE="10x20"/' /etc/default/console-setup
# 10x20 (or 11x22) suits the 800x1280 panel; 16x32 is far too big.

echo "--- USB gadget: serial console (ACM) + network (NCM)"
cat > /usr/local/sbin/p25t-gadget <<'EOF'
#!/bin/sh
# Set up the USB-C port as a composite USB device: serial console + network.
G=/sys/kernel/config/usb_gadget/p25t
# Host mode (usbhost DTB, see set-usb-role.sh): the port is a USB host and
# there is no device controller (UDC). Without this check the loop below
# waits 20 s for one and fails, and the boot waits with it (2026-10-05).
M=$(tr -d '\0' < /proc/device-tree/usb@fcc00000/dr_mode 2>/dev/null)
[ "$M" = host ] && { echo "USB-C port in host mode: no gadget"; exit 0; }
[ -d $G ] && exit 0
mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0100 > $G/bcdDevice
echo 0x0200 > $G/bcdUSB
mkdir -p $G/strings/0x409
echo "p25t0001"          > $G/strings/0x409/serialnumber
echo "Teclast"           > $G/strings/0x409/manufacturer
echo "P25T Debian"       > $G/strings/0x409/product
mkdir -p $G/configs/c.1/strings/0x409
echo "ACM+NCM" > $G/configs/c.1/strings/0x409/configuration
echo 250 > $G/configs/c.1/MaxPower
mkdir -p $G/functions/acm.usb0 $G/functions/ncm.usb0
# fixed addresses, so the PC always sees the same network device
echo 02:25:54:00:00:01 > $G/functions/ncm.usb0/dev_addr
echo 02:25:54:00:00:02 > $G/functions/ncm.usb0/host_addr
ln -s $G/functions/acm.usb0 $G/configs/c.1/
ln -s $G/functions/ncm.usb0 $G/configs/c.1/
UDC=""
for i in $(seq 1 20); do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done
[ -n "$UDC" ] || { echo "no UDC"; exit 1; }
echo "$UDC" > $G/UDC
echo "gadget bound to $UDC"
EOF
chmod 755 /usr/local/sbin/p25t-gadget
cat > /etc/systemd/system/p25t-gadget.service <<'EOF'
[Unit]
Description=P25T USB gadget (serial console + network)
After=sys-kernel-config.mount
Requires=sys-kernel-config.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/p25t-gadget

[Install]
WantedBy=multi-user.target
EOF

echo "--- network on usb0: 192.168.7.2, gives the PC an address by DHCP"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/50-usb0.network <<'EOF'
[Match]
Name=usb*

[Network]
Address=192.168.7.2/24
DHCPServer=yes
ConfigureWithoutCarrier=yes

[DHCPServer]
PoolOffset=10
PoolSize=10
EmitDNS=no
EmitRouter=no
EOF

echo "--- boot log onto the card (for boots without a USB cable)"
cat > /usr/local/sbin/p25t-bootlog <<'EOF'
#!/bin/sh
# Write a status report onto the card: /boot/firmware/logs/boot-N-debian.txt
D=/boot/firmware/logs
[ -d $D ] || exit 0
N=$(cat $D/bootcount 2>/dev/null || echo 0)
{
    echo "=== $(date)  uptime $(cut -d' ' -f1 /proc/uptime) s"
    echo "=== failed units"; systemctl --failed --no-legend
    echo "=== gadget"; systemctl status --no-pager -n 20 p25t-gadget.service
    for u in /sys/class/udc/*; do echo "$u state: $(cat $u/state)"; done
    echo "=== network"; ip addr
    echo "=== logins"; who
    echo "=== warnings and errors this boot"; journalctl -b -p warning --no-pager
    echo "=== dmesg"; dmesg
} > $D/boot-$N-debian.txt 2>&1
sync
EOF
chmod 755 /usr/local/sbin/p25t-bootlog
cat > /etc/systemd/system/p25t-bootlog.service <<'EOF'
[Unit]
Description=P25T status report onto the SD card

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/p25t-bootlog
EOF
cat > /etc/systemd/system/p25t-bootlog.timer <<'EOF'
[Unit]
Description=P25T status report onto the SD card, 1 min after boot and every 4 min

[Timer]
OnBootSec=60
OnUnitActiveSec=240

[Install]
WantedBy=timers.target
EOF

echo "--- enable services"
# Only getty@tty1 is enabled; logind starts tty2-tty6 on demand
# (NAutoVTs=6), as on any Debian.
systemctl enable systemd-networkd.service systemd-resolved.service \
    ssh.service p25t-gadget.service p25t-bootlog.timer \
    getty@tty1.service
# No login on the USB gadget serial port. When no USB host reads ttyGS0
# (no cable, or host mode), systemd's terminal reset before agetty
# blocks for ever while holding the /dev/console lock; every other
# getty then waits on that lock (blinking cursor, no VT logins) and a
# reboot hangs in PID 1. See "Console: one getty on a dead tty" in
# docs/findings.org. SSH (Wi-Fi or usb0) replaces this console.
systemctl mask serial-getty@ttyGS0.service

echo "--- clean up"
apt-get clean
rm -f /var/lib/apt/lists/*_Packages /var/lib/apt/lists/*_Release /var/lib/apt/lists/*_InRelease
echo "setup done"
