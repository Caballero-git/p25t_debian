#!/bin/bash
# Read-only probe of the running Android on the P25T: which display-related
# information can plain adb (no root) read? Nothing on the tablet is modified.
#
# Usage (tablet in Android, "adb devices" shows it as "device"):
#     bash ~/p25t-backup/Firmware/probe_android.sh
#
# Output: ~/p25t-backup/Firmware/probe-<date-time>/ (report.txt + bugreport zip)
set -u
OUT=~/p25t-backup/Firmware/probe-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
cd "$OUT" || exit 1

SER=$(adb devices | awk '$2 == "device" {print $1; exit}')
if [ -z "$SER" ]; then
    echo "No tablet in state 'device' in 'adb devices'. Stopping."
    adb devices
    exit 1
fi
A="adb -s $SER"

# run LABEL COMMAND... : run one read-only command on the tablet, log output
run() {
    label=$1
    shift
    {
        echo "===== $label"
        echo "\$ $*"
        $A shell "$@" 2>&1 | head -c 20000
        echo
    } >> report.txt
}

echo "1/2 Quick probes (a few seconds) ..."
run "who am I" id
run "SELinux mode" getenforce
run "slot" getprop ro.boot.slot_suffix
run "build" getprop ro.build.fingerprint
run "proc device-tree listing" ls /proc/device-tree/
run "sysfs devicetree listing" ls /sys/firmware/devicetree/base/
run "model property" cat /proc/device-tree/model
run "panel compatible" cat /proc/device-tree/dsi@fe060000/panel@0/compatible
run "panel node listing" ls /proc/device-tree/dsi@fe060000/panel@0/
run "fdt blob size" "wc -c /sys/firmware/fdt"
run "kernel cmdline" cat /proc/cmdline
run "dmesg (display lines)" "dmesg | grep -iE 'dsi|panel|vop|drm|backlight|lcd'"
run "drm connectors" "ls /sys/class/drm/"
run "drm DSI modes" "cat /sys/class/drm/card0-DSI-1/modes"
run "backlight" "ls /sys/class/backlight/"
run "display (dumpsys, first lines)" "dumpsys display | head -60"
echo "   written: $OUT/report.txt ($(wc -l < report.txt) lines)"

echo "2/2 Android bug report (read-only, takes 1-3 minutes, please wait) ..."
adb -s "$SER" bugreport bugreport.zip > bugreport-log.txt 2>&1
ls -l bugreport.zip 2>/dev/null || { echo "   bug report not created, see bugreport-log.txt"; tail -3 bugreport-log.txt; }

find . -maxdepth 1 -type f -exec sha256sum {} + > SHA256SUMS
echo "DONE. Folder: $OUT"
