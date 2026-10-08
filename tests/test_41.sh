#!/bin/bash
# test_41.sh - rear camera with RK817 LDO2 at Android's 1.2 V
#
# test_40 (2026-10-07): RK817 LDO2 ("vdda_0v9") is at 900 mV in our boot;
# Android keeps it at 1200 mV, always-on. Everything else matches (LDO5 is
# the SD-card rail, 1.8-3.3 V by design). Our reading of tests 22-39: the
# camera core (DVDD) hangs on LDO2 - it works on the slow 24 MHz clock
# but freezes as soon as it switches to its PLL (0xfc = 0x8e).
# RK817 write approved by Jose on 2026-10-07 ("Ok, yes go on").
#
#   sudo bash test_41.sh check     read-only: chip id, LDO2 now (default)
#   sudo bash test_41.sh apply     LDO2 -> 1.2 V (ONE RK817 write, 0xCE <- 0x18,
#                                  read back), then two captures with the
#                                  unchanged driver (its own 0xfc = 0x8e):
#                                  colour bars -> cam41_bars.raw,
#                                  scene       -> cam41_scene.raw
#   sudo bash test_41.sh restore   LDO2 back to 0.9 V (0xCE <- 0x0c)
# Stops at the first surprise. A full power-off also resets LDO2.
#
#   cd ~/tests
#   sudo bash test_41.sh apply 2>&1 | tee result_41.txt

set -u
MODE=${1:-check}
PMIC=0x20
echo "=== rear camera, RK817 LDO2 1.2 V (test_41, mode: $MODE) ==="
date; uname -v
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
case "$MODE" in check|apply|restore) ;; *) echo "ABORT: mode must be check, apply or restore"; exit 1 ;; esac
command -v i2cget >/dev/null || { echo "ABORT: i2c-tools missing"; exit 1; }
stop() { echo "STOP: $* (nothing further written)"; exit 1; }
bus_of() {
    local a
    for a in /sys/bus/i2c/devices/i2c-*; do
        case "$(readlink -f "$a")" in */"$1".i2c/*) echo "${a##*/i2c-}"; return ;; esac
    done
}
compat_has() { tr '\0' '\n' < "$1/of_node/compatible" 2>/dev/null | grep -qx "$2"; }
B0=$(bus_of fdd40000); [ -n "$B0" ] || stop "i2c0 (fdd40000) not found"
compat_has "/sys/bus/i2c/devices/$B0-0020" rockchip,rk817 || stop "$B0-0020 is not the rk817 node"
rd() { i2cget -f -y "$B0" $PMIC "$1" b 2>/dev/null; }
msb=$(rd 0xed); lsb=$(rd 0xee)
[ $(( (msb << 8 | lsb) & 0xfff0 )) -eq $(( 0x8170 )) ] || stop "chip id $msb $lsb is not RK817"
EN=$(rd 0xb2); CE=$(rd 0xce)
[ -n "$EN" ] && [ -n "$CE" ] || stop "cannot read 0xB2/0xCE"
echo "RK817 on bus $B0, chip id $msb $lsb"
echo "LDO2: $([ $(( (EN >> 1) & 1 )) -eq 1 ] && echo on || echo OFF), 0xCE = $CE -> $(( 600 + (CE & 0x7f) * 25 )) mV"

setldo2() {   # $1 = expected now, $2 = new value
    [ $(( EN & 0x02 )) -ne 0 ] || stop "LDO2 is off - not as expected"
    if [ $(( CE )) -eq $(( $2 )) ]; then echo "LDO2 already at $2 - no write needed"; return; fi
    [ $(( CE )) -eq $(( $1 )) ] || stop "0xCE = $CE, expected $1 - state not as expected"
    i2cset -f -y "$B0" $PMIC 0xce $2 b || stop "write 0xCE failed"
    v=$(rd 0xce); [ $(( v )) -eq $(( $2 )) ] || stop "0xCE read back $v, expected $2"
    echo "0xCE <- $2: read back $v -> $(( 600 + (v & 0x7f) * 25 )) mV"
    sleep 0.1
}

case "$MODE" in
check)   echo "=== check done - nothing was written ==="; exit 0 ;;
restore) setldo2 0x18 0x0c; echo "=== restore done ==="; exit 0 ;;
esac

setldo2 0x0c 0x18

W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

capture() {   # $1 = test pattern 1/0, $2 = output file
    echo; echo "--- capture, test pattern $1 -> $2 (driver only, no register pokes) ---"
    v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=$1
    rm -f "$2"
    timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to="$2" 2>&1 | tail -3
    echo "capture exit ${PIPESTATUS[0]} (124 = timeout); $2: $(stat -c %s "$2" 2>/dev/null || echo none) bytes (3 frames = $((W * H * 2 * 3)))"
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$2" 2>/dev/null
}
capture 1 cam41_bars.raw
capture 0 cam41_scene.raw
echo; echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
echo; echo "LDO2 stays at 1.2 V until a full power-off (or: sudo bash test_41.sh restore)"
echo "=== done ==="
