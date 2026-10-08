#!/bin/bash
# test_46.sh - rear camera after patch 0030 + udev rule: no pokes at all
#
# Checks the permanent setup (2026-10-07):
#  - RK817 LDO2 at 1.2 V from the DT (patch 0030) - READ-ONLY, no RK817 write
#  - VICAP power/control = on from /etc/udev/rules.d/99-p25t-vicap.rules
# then two captures in a row with the plain driver:
#  1. colour bars, 3 frames          -> cam46_bars.raw
#  2. scene, 20 frames, keep last 2  -> cam46_scene.raw  (point it at something lit)
# Stops before capturing if either setting is missing (a second capture
# without the udev rule freezes the tablet).
#
# From the PC (repo's tests folder):
#   ssh -t p25t 'cd tests && sudo bash test_46.sh 2>&1' | tee result_46.txt

set -u
say() { echo "$@"; sync; }
say "=== rear camera, permanent setup (test_46) ==="
date; uname -v
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
stop() { say "STOP: $*"; exit 1; }
bus_of() {
    local a
    for a in /sys/bus/i2c/devices/i2c-*; do
        case "$(readlink -f "$a")" in */"$1".i2c/*) echo "${a##*/i2c-}"; return ;; esac
    done
}
B0=$(bus_of fdd40000); [ -n "$B0" ] || stop "i2c0 (fdd40000) not found"
CE=$(i2cget -f -y "$B0" 0x20 0xce b 2>/dev/null)
say "RK817 LDO2: 0xCE = $CE -> $(( 600 + (CE & 0x7f) * 25 )) mV (read only)"
[ $(( CE & 0x7f )) -eq $(( 0x18 )) ] || stop "LDO2 is not at 1.2 V - is the 0030 DTB active?"
grep -l "vdda_0v9" /sys/class/regulator/*/name 2>/dev/null | head -1 | while read -r n; do
    d=${n%/name}; say "regulator $(cat "$n"): $(cat "$d/microvolts" 2>/dev/null) uV, $(cat "$d/state" 2>/dev/null)"
done
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
say "VICAP $VDEV: power/control $(cat "$VDEV/power/control"), runtime_status $(cat "$VDEV/power/runtime_status")"
[ "$(cat "$VDEV/power/control")" = on ] || stop "VICAP power/control is not 'on' - is the udev rule installed?"

W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null
FR=$((W * H * 2))

say "1. colour bars, 3 frames ($(date +%T))"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=1
rm -f cam46_bars.raw
timeout 10 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam46_bars.raw >/dev/null 2>&1
RC=$?; sync
say "   exit $RC (124 = timeout); cam46_bars.raw: $(stat -c %s cam46_bars.raw 2>/dev/null || echo none) bytes ($((FR * 3)) expected)"
sleep 2; say "   alive"

say "2. scene, 20 frames ($(date +%T))"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0 --set-ctrl=exposure=1992 --set-ctrl=analogue_gain=1024
rm -f cam46_all.raw cam46_scene.raw
timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=20 --stream-to=cam46_all.raw >/dev/null 2>&1
RC=$?; sync
say "   exit $RC (124 = timeout); cam46_all.raw: $(stat -c %s cam46_all.raw 2>/dev/null || echo none) bytes ($((FR * 20)) expected)"
tail -c $((FR * 2)) cam46_all.raw > cam46_scene.raw && rm -f cam46_all.raw
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam46_bars.raw cam46_scene.raw 2>/dev/null
sleep 2; say "   alive"
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
say "=== done ==="
