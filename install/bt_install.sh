#!/bin/bash
# Bluetooth on the P25T: new kernel modules (HIDP, UHID, RFCOMM), device tree with
# UART1 + BT_REG_ON, BlueZ, and a service that attaches the AIC8800 Bluetooth.
#
# Usage (tablet SSH session, in the folder where p25t-bt.tar.gz was unpacked):
#     sudo bash bt_install.sh
#
# Rollback if the tablet does not boot: on P25TBOOT (card in the PC) copy
# Image.stage5 over Image and rk3566-teclast-p25t.dtb.stage5 over rk3566-teclast-p25t.dtb.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo."; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
KR=7.3.0-rc4-p25t
B=/boot/firmware
LOG=/home/jose/bt-install-log.txt
exec > >(tee "$LOG") 2>&1
say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

say "1/5 Checking the package"
( cd "$HERE/boot" && sha256sum -c SHA256SUMS ) || die "package damaged"
mountpoint -q $B || die "$B (P25TBOOT) is not mounted"
[ "$(uname -r)" = "$KR" ] || die "running kernel is $(uname -r), expected $KR"

say "2/5 BlueZ (Bluetooth tools) from Debian"
apt-get update -qq || die "apt-get update failed (is Wi-Fi up?)"
DEBIAN_FRONTEND=noninteractive apt-get install -y bluez || die "installing bluez failed"
command -v btattach >/dev/null || die "btattach missing"

say "3/5 Kernel and device tree onto the card (old ones kept as *.stage5)"
[ -f $B/Image.stage5 ] || cp $B/Image $B/Image.stage5
[ -f $B/rk3566-teclast-p25t.dtb.stage5 ] || cp $B/rk3566-teclast-p25t.dtb $B/rk3566-teclast-p25t.dtb.stage5
cp "$HERE/boot/Image" $B/Image
cp "$HERE/boot/rk3566-teclast-p25t.dtb" $B/rk3566-teclast-p25t.dtb
sync
( cd $B && sha256sum -c "$HERE/boot/SHA256SUMS" ) || die "copy to the card failed"
grep -v -E "  (Image|rk3566-teclast-p25t.dtb)$" $B/CARD-SHA256SUMS > $B/CARD-SHA256SUMS.new
( cd $B && sha256sum Image rk3566-teclast-p25t.dtb >> CARD-SHA256SUMS.new )
mv $B/CARD-SHA256SUMS.new $B/CARD-SHA256SUMS
sync
( cd $B && sha256sum -c CARD-SHA256SUMS ) || die "card check failed"

say "4/5 Kernel modules (incl. the Wi-Fi driver rebuilt for this kernel) and the Bluetooth service"
cp -a "$HERE/root/usr/." /usr/
cp -a "$HERE/root/etc/." /etc/
depmod "$KR"
for m in hidp uhid rfcomm hci_uart aic8800_fdrv; do
    modinfo -k "$KR" -F filename $m >/dev/null || die "module $m not registered"
done
echo "modules registered: hidp uhid rfcomm hci_uart aic8800_fdrv"
systemctl enable bluetooth.service p25t-bluetooth.service

say "5/5 Done"
echo "BLUETOOTH INSTALLED - now reboot the tablet:  sudo reboot"
echo "After the reboot, check with:  systemctl status p25t-bluetooth --no-pager ; bluetoothctl show"
