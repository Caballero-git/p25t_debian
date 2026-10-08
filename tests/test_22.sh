#!/bin/bash
# test_22.sh - rear camera, step 1: did everything probe? (read-only)
#
# Kernel with patches 0028 (GC5035 driver) and 0029 (camera DT + LDO9).
# Success = the GC5035 driver reads the chip ID ("GC5035 detected") and
# the media graph shows sensor -> CSI-2 receiver -> VICAP. No image yet.
#
#   sudo bash test_22.sh | tee result_22.txt
# Needs v4l-utils for media-ctl / v4l2-ctl:  sudo apt install v4l-utils
# (without it the rest still runs).

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo (dmesg, debugfs)"; exit 1; }
echo "=== rear camera probe (test_22) ==="
date; uname -v

echo; echo "--- camera supplies ---"
for r in /sys/class/regulator/regulator.*; do
    n=$(cat "$r/name" 2>/dev/null)
    case "$n" in vcc2v8_dvp|vcc1v8_dvp|vcc_camera)
        echo "$n: state=$(cat "$r/state" 2>/dev/null) uV=$(cat "$r/microvolts" 2>/dev/null || echo -)" ;;
    esac
done

echo; echo "--- kernel log: camera path ---"
dmesg | grep -i -E "gc5035|rkcif|vicap|mipi-csi|csi2|csi@|fdfb0000|fdfe0000|fe870000|csi-dphy|i2c@fe5b0000|2-0037|v4l2|media" | head -40

echo; echo "--- sensor on i2c2 ---"
S=/sys/bus/i2c/devices/2-0037
if [ -e "$S" ]; then
    echo "device: $(cat $S/name 2>/dev/null)  driver: $(basename "$(readlink $S/driver 2>/dev/null)" 2>/dev/null)"
    echo "runtime PM: $(cat $S/power/runtime_status 2>/dev/null)"
else
    echo "no device 2-0037 (i2c2 numbering differs?):"; ls /sys/bus/i2c/devices/
fi

echo; echo "--- deferred probes ---"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
cat /sys/kernel/debug/devices_deferred 2>/dev/null || echo "(debugfs not readable)"

echo; echo "--- camera clock ---"
grep -E "clk_cif_out|pclk_csi2host1|clk_mipicsiphy|aclk_vicap|dclk_vicap" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -8

echo; echo "--- device nodes ---"
ls -l /dev/media* /dev/video* /dev/v4l-subdev* 2>/dev/null || echo "none"

echo; echo "--- media graph ---"
if command -v media-ctl >/dev/null; then
    for m in /dev/media*; do
        [ -e "$m" ] || continue
        echo "## $m"; media-ctl -d "$m" -p 2>&1 | head -80
    done
    echo; v4l2-ctl --list-devices 2>&1 | head -20
else
    echo "media-ctl not installed (sudo apt install v4l-utils)"
fi

echo; echo "=== done ==="
