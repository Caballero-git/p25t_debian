#!/bin/bash
# Stage 5 on the TABLET: kernel with module support + AIC8800 Wi-Fi driver/firmware,
# device tree with the SDIO Wi-Fi nodes, and a Wi-Fi network configuration.
#
# Usage (tablet SSH session, in the folder where p25t-wifi.tar.gz was unpacked):
#     sudo bash wifi_install.sh
#
# Rollback if the new kernel does not boot: put the card in the PC and, on P25TBOOT,
# copy Image.stage4 over Image and rk3566-teclast-p25t.dtb.stage4 over
# rk3566-teclast-p25t.dtb.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo."; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
KR=7.3.0-rc4-p25t
B=/boot/firmware
LOG=/home/jose/stage5-log.txt
exec > >(tee "$LOG") 2>&1
say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

say "1/6 Checking the package"
( cd "$HERE/boot" && sha256sum -c SHA256SUMS ) || die "package damaged"
[ -f "$HERE/root/usr/lib/modules/$KR/extra/aic8800_fdrv.ko" ] || die "driver missing in package"
mountpoint -q $B || die "$B (P25TBOOT) is not mounted"

say "2/6 Kernel and device tree onto the card (old ones kept as *.stage4)"
[ -f $B/Image.stage4 ] || cp $B/Image $B/Image.stage4
[ -f $B/rk3566-teclast-p25t.dtb.stage4 ] || cp $B/rk3566-teclast-p25t.dtb $B/rk3566-teclast-p25t.dtb.stage4
cp "$HERE/boot/Image" $B/Image
cp "$HERE/boot/rk3566-teclast-p25t.dtb" $B/rk3566-teclast-p25t.dtb
sync
( cd $B && sha256sum -c "$HERE/boot/SHA256SUMS" ) || die "copy to the card failed"
grep -v -E "  (Image|rk3566-teclast-p25t.dtb)$" $B/CARD-SHA256SUMS > $B/CARD-SHA256SUMS.new
( cd $B && sha256sum Image rk3566-teclast-p25t.dtb >> CARD-SHA256SUMS.new )
mv $B/CARD-SHA256SUMS.new $B/CARD-SHA256SUMS
sync
( cd $B && sha256sum -c CARD-SHA256SUMS ) || die "card check failed"

say "3/6 Modules and Wi-Fi firmware"
# the package keeps everything under usr/ and etc/ (Debian trixie: /lib is a link to usr/lib)
cp -a "$HERE/root/usr/." /usr/
cp -a "$HERE/root/etc/." /etc/
depmod "$KR"
modinfo -k "$KR" aic8800_fdrv | grep -E "^(filename|vermagic)" || die "depmod did not register the driver"
ls /lib/firmware/aic8800_fw/SDIO/aic8800/ | head -5

say "4/6 Network: Wi-Fi preferred, USB route to the PC kept as backup"
F=/etc/systemd/network/50-usb0.network
cp -n $F $F.stage4
cat > $F <<'EOF'
[Match]
Name=usb*

[Network]
Address=192.168.7.2/24
DNS=1.1.1.1
DNS=9.9.9.9
DHCPServer=yes
ConfigureWithoutCarrier=yes

[Route]
Gateway=192.168.7.1
Metric=2000

[DHCPServer]
PoolOffset=10
PoolSize=10
EmitDNS=no
EmitRouter=no
EOF
cat > /etc/systemd/network/60-wlan.network <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
EOF
echo "network files written"

say "5/6 Your Wi-Fi network (the password is stored only as a hash on the tablet)"
W=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
if [ -f $W ] && grep -q "network=" $W; then
    echo "$W already has a network - keeping it"
else
    read -r -p "Wi-Fi name (SSID): " SSID
    PSKBLOCK=""
    until [ -n "$PSKBLOCK" ]; do
        read -r -s -p "Wi-Fi password: " PASS; echo
        PSKBLOCK=$(wpa_passphrase "$SSID" "$PASS" 2>&1 | grep -v "#psk=") || true
        echo "$PSKBLOCK" | grep -q "psk=" || { echo "$PSKBLOCK"; PSKBLOCK=""; }
    done
    unset PASS
    {
        echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
        echo "update_config=1"
        echo "country=ES"
        echo "$PSKBLOCK"
    } > $W
    chmod 600 $W
    echo "saved $W for network '$SSID'"
fi
systemctl enable wpa_supplicant@wlan0.service

say "6/6 Done"
echo "STAGE 5 INSTALLED - now reboot the tablet:  sudo reboot"
echo "After the reboot (about 1 minute), check Wi-Fi with:  networkctl status wlan0"
