#!/bin/bash
# test_43.sh - LDO2 1.2 V: does a SECOND capture freeze the tablet?
#
# test_42 (2026-10-07): LDO2 at 1.2 V for 11 s, no freeze, and the colour
# bars came out PERFECT with the unchanged driver - the sensor needs
# LDO2 = 1.2 V (its core supply), as Android has it.
# test_41 froze at its SECOND capture. Two suspects:
#   a) LDO2 at 1.2 V itself (it may also feed SoC blocks)
#   b) restarting a stream after a stream that really carried frames
#      (never happened before test_41)
# This keeps LDO2 at 1.2 V and runs three captures in a row, with a pause,
# 'sync' and a timestamp between them, then puts LDO2 back to 0.9 V:
#   1. colour bars  -> cam43_bars1.raw
#   2. colour bars  -> cam43_bars2.raw   (same as 1: a pure restart)
#   3. scene        -> cam43_scene.raw   (point it at something lit)
# If it freezes, the last line on the PC tells which step.
# RK817 writes: 0xCE only (LDO2 voltage), as approved for test_41.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t 'sudo dmesg -w'
#   ssh -t p25t 'cd tests && sudo bash test_43.sh 2>&1' | tee result_43.txt

set -u
PMIC=0x20
say() { echo "$@"; sync; }
say "=== rear camera, LDO2 1.2 V, three captures (test_43) ==="
date; uname -v
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v i2cget >/dev/null || { echo "ABORT: i2c-tools missing"; exit 1; }
stop() { say "STOP: $*"; exit 1; }
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
[ $(( EN & 0x02 )) -ne 0 ] || stop "LDO2 is off - not as expected"
[ $(( CE )) -eq $(( 0x0c )) ] || stop "0xCE = $CE, expected 0x0c (0.9 V)"
setce() {
    i2cset -f -y "$B0" $PMIC 0xce $1 b || stop "write 0xCE failed"
    v=$(rd 0xce); [ $(( v )) -eq $(( $1 )) ] || stop "0xCE read back $v, expected $1"
    say "0xCE <- $1: read back $v -> $(( 600 + (v & 0x7f) * 25 )) mV  ($(date +%T))"
}

W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

capture() {   # $1 = step, $2 = test pattern 1/0, $3 = output file
    say "$1. capture, test pattern $2 -> $3  (start $(date +%T.%N | cut -c1-12))"
    v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=$2
    rm -f "$3"
    timeout 10 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to="$3" >/dev/null 2>&1
    RC=$?
    sync
    say "   exit $RC (124 = timeout); $3: $(stat -c %s "$3" 2>/dev/null || echo none) bytes  (end $(date +%T.%N | cut -c1-12))"
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$3" 2>/dev/null
    for i in 1 2 3; do sleep 1; say "   alive +${i} s"; done
}

say "LDO2 -> 1.2 V"
setce 0x18
sleep 2; say "   alive"
capture 1 1 cam43_bars1.raw
capture 2 1 cam43_bars2.raw
capture 3 0 cam43_scene.raw
say "LDO2 back to 0.9 V"
setce 0x0c
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
say "=== done ==="
