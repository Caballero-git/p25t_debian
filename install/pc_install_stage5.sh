#!/bin/bash
# Stage 5 installed from the PC straight onto the SD card (no USB link to the tablet needed).
# Same content as wifi_install.sh on the tablet: new kernel + device tree, modules,
# AIC8800 Wi-Fi driver and firmware, network settings, your Wi-Fi network.
#
# Usage (SD card in the PC; asks for sudo itself):
#     bash /home/jose/p25t-backup/stage5/pc_install_stage5.sh
#
# Rollback if the new kernel does not boot: on P25TBOOT copy Image.stage4 over Image
# and rk3566-teclast-p25t.dtb.stage4 over rk3566-teclast-p25t.dtb.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/p25t-wifi.tar.gz"
KR=7.3.0-rc4-p25t
say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

say "1/7 Checking the package"
( cd "$HERE" && sha256sum -c p25t-wifi.tar.gz.sha256 ) || die "package damaged"
WORK=$(mktemp -d)
tar -xzf "$PKG" -C "$WORK"
( cd "$WORK/boot" && sha256sum -c SHA256SUMS ) || die "package content damaged"

say "2/7 Finding the P25T card"
BOOTPART=$(blkid -L P25TBOOT || true)
ROOTPART=$(blkid -L p25troot || true)
[ -n "$BOOTPART" ] && [ -n "$ROOTPART" ] || die "card not found (need partitions P25TBOOT and p25troot)"
DISK=/dev/$(lsblk -no PKNAME "$BOOTPART" | head -n 1)
[ "/dev/$(lsblk -no PKNAME "$ROOTPART" | head -n 1)" = "$DISK" ] || die "the two partitions are on different disks"
DNAME=$(basename "$DISK")
if findmnt -no SOURCE / | grep -q "^$DISK"; then die "$DISK holds the PC's own system"; fi
[ "$(cat /sys/block/"$DNAME"/removable)" = "1" ] || [ "$(lsblk -dno TRAN "$DISK")" = "usb" ] || die "$DISK is not removable/USB"
echo "card $DISK: boot $BOOTPART, root $ROOTPART"
for p in "$BOOTPART" "$ROOTPART"; do umount "$p" 2>/dev/null || true; done
B=$(mktemp -d); R=$(mktemp -d)
mount "$BOOTPART" "$B"
mount "$ROOTPART" "$R"
trap 'sync; umount "$B" "$R" 2>/dev/null || true' EXIT
[ -x "$R/usr/lib/systemd/systemd" ] && [ -f "$B/boot-debian" ] || die "this does not look like the P25T Debian card"

say "3/7 Kernel and device tree (old ones kept as *.stage4)"
[ -f "$B/Image.stage4" ] || cp "$B/Image" "$B/Image.stage4"
[ -f "$B/rk3566-teclast-p25t.dtb.stage4" ] || cp "$B/rk3566-teclast-p25t.dtb" "$B/rk3566-teclast-p25t.dtb.stage4"
cp "$WORK/boot/Image" "$B/Image"
cp "$WORK/boot/rk3566-teclast-p25t.dtb" "$B/rk3566-teclast-p25t.dtb"
sync
( cd "$B" && sha256sum -c "$WORK/boot/SHA256SUMS" ) || die "copy to the card failed"
grep -v -E "  (Image|rk3566-teclast-p25t.dtb)$" "$B/CARD-SHA256SUMS" > "$B/CARD-SHA256SUMS.new"
( cd "$B" && sha256sum Image rk3566-teclast-p25t.dtb >> CARD-SHA256SUMS.new )
mv "$B/CARD-SHA256SUMS.new" "$B/CARD-SHA256SUMS"
sync
( cd "$B" && sha256sum -c CARD-SHA256SUMS ) || die "card check failed"

say "4/7 Modules, Wi-Fi driver and firmware onto the Debian partition"
cp -a "$WORK/root/usr/." "$R/usr/"
cp -a "$WORK/root/etc/." "$R/etc/"
depmod -b "$R" "$KR"
grep -q "aic8800_fdrv.ko:" "$R/usr/lib/modules/$KR/modules.dep" || die "depmod did not register the driver"
echo "driver registered for kernel $KR"

say "5/7 Network: Wi-Fi preferred, USB route to the PC kept as backup"
F="$R/etc/systemd/network/50-usb0.network"
[ -f "$F.stage4" ] || cp "$F" "$F.stage4"
cat > "$F" <<'EOF'
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
cat > "$R/etc/systemd/network/60-wlan.network" <<'EOF'
[Match]
Name=wlan*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
EOF
echo "network files written"

say "6/7 Your Wi-Fi network (the password is stored only as a hash, on the card)"
W="$R/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
mkdir -p "$(dirname "$W")"
read -r -p "Wi-Fi name (SSID): " SSID
while true; do
    read -r -s -p "Wi-Fi password: " PASS; echo
    [ ${#PASS} -ge 8 ] && [ ${#PASS} -le 63 ] && break
    echo "A WPA password has 8 to 63 characters - try again."
done
PSK=$(SSID="$SSID" PASS="$PASS" python3 -c 'import hashlib, os; print(hashlib.pbkdf2_hmac("sha1", os.environ["PASS"].encode(), os.environ["SSID"].encode(), 4096, 32).hex())')
unset PASS
SSID_ESC=$(printf '%s' "$SSID" | sed 's/\\/\\\\/g; s/"/\\"/g')
{
    echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    echo "country=ES"
    echo "network={"
    echo "	ssid=\"$SSID_ESC\""
    echo "	psk=$PSK"
    echo "}"
} > "$W"
chmod 600 "$W"
U="$R/usr/lib/systemd/system/wpa_supplicant@.service"
[ -f "$U" ] || die "wpa_supplicant@.service missing in Debian"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/wpa_supplicant@.service "$R/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"
echo "saved network '$SSID'; wpa_supplicant@wlan0 enabled"

say "7/7 Flushing and unmounting"
rm -rf "$WORK"
sync
umount "$B" "$R"
trap - EXIT
rmdir "$B" "$R"
echo "ALL OK - eject the card in the file manager (if it shows up again), put it in the tablet and power on."
