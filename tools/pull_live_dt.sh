#!/bin/bash
# Copy the LIVE device tree from the running Android on the P25T (read-only).
# This is the tree the panel actually works with, including any changes the
# stock bootloader made at boot. Nothing on the tablet is modified.
#
# Usage (tablet in Android, adb connected - "adb devices" shows it as "device"):
#     bash ~/p25t-backup/Firmware/pull_live_dt.sh
#
# Output folder: ~/p25t-backup/Firmware/dt-live-<date-time>/
set -u
OUT=~/p25t-backup/Firmware/dt-live-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
cd "$OUT" || exit 1

echo "1/5 Checking adb connection ..."
SER=$(adb devices | awk '$2 == "device" {print $1; exit}')
if [ -z "$SER" ]; then
    echo "No tablet in state 'device' in 'adb devices'. Stopping."
    adb devices
    exit 1
fi
echo "   using $SER"
A="adb -s $SER"

echo "2/5 Copying /sys/firmware/devicetree/base (read-only) ..."
$A pull /sys/firmware/devicetree/base tree > pull-log.txt 2>&1
tail -3 pull-log.txt
ROOT=tree
[ -d tree/base ] && ROOT=tree/base
if [ ! -f "$ROOT/compatible" ]; then
    echo "The copy has no top-level 'compatible' file - Android refused access."
    echo "Send Claude the file $OUT/pull-log.txt"
    exit 1
fi

echo "3/5 Converting to a readable .dts ..."
dtc -I fs -O dts -o live.dts "$ROOT" 2> dtc-warnings.txt
ls -l live.dts

echo "4/5 Extra read-only information ..."
$A shell getprop > getprop.txt 2>&1
$A shell cat /proc/cmdline > cmdline.txt 2>&1
$A shell dmesg > dmesg-android.txt 2>&1
$A shell ls -l /dev/block/by-name/ > by-name.txt 2>&1
wc -l getprop.txt cmdline.txt dmesg-android.txt by-name.txt

echo "5/5 Checksums ..."
find . -maxdepth 1 -type f -exec sha256sum {} + > SHA256SUMS
echo "DONE. Folder: $OUT"
