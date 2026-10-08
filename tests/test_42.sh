#!/bin/bash
# test_42.sh - LDO2 1.2 V, careful version: colour bars only, LDO2 back after
#
# test_41 (2026-10-07): with LDO2 at 1.2 V the tablet froze hard during
# the second capture (scene); power button, full power-off. LDO2 came back
# at 0.9 V (after41_check.txt). Nothing of the run reached the disk: the
# last journal line is 20:12:09, result_41.txt and the raw files are gone
# (written, but not yet flushed when it froze).
# Open question: did the sensor work at 1.2 V before the freeze, and is
# the freeze LDO2 itself or the capture?
#
# This run, in small steps, with 'sync' after each so the disk keeps what
# happened, and LDO2 put back to 0.9 V at the end automatically:
#  1. LDO2 -> 1.2 V (0xCE <- 0x18, read back), wait 5 s idle: alive?
#  2. colour-bar capture (unchanged driver, its own 0xfc = 0x8e); during
#     it, check the sensor: 0xfc and the page-1 write test (OPEN/locked)
#  3. report the capture, LDO2 -> 0.9 V (0xCE <- 0x0c, read back)
# No scene capture this time.
# RK817 writes: 0xCE only (LDO2 voltage), as approved for test_41.
#
# Run it FROM THE PC so the output survives a freeze (on the PC, in the
# repo's tests folder - one line):
#   ssh -t p25t 'cd tests && sudo bash test_42.sh 2>&1' | tee result_42.txt
# and, before that, in a SECOND PC terminal, the kernel log live:
#   ssh p25t 'sudo dmesg -w'

set -u
PMIC=0x20
say() { echo "$@"; sync; }
say "=== rear camera, LDO2 1.2 V, bars only (test_42) ==="
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

say "1. LDO2 -> 1.2 V"
setce 0x18
for i in 1 2 3 4 5; do sleep 1; say "   alive +${i} s"; done

W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=1

cat > /tmp/p25t_open.py <<'EOF'
import fcntl, os, sys
i2c = os.open("/dev/i2c-2", os.O_RDWR)
fcntl.ioctl(i2c, 0x0706, 0x37)                    # I2C_SLAVE_FORCE
def wr(r, v): os.write(i2c, bytes((r, v)))
def rd(r):
    try: os.write(i2c, bytes((r,))); return os.read(i2c, 1)[0]
    except OSError: return None
fc = rd(0xfc)
wr(0xfe, 1); old = rd(0x42); wr(0x42, 0xa5); x = rd(0x42); wr(0x42, old if old is not None else 0x21); wr(0xfe, 0)
p0 = []
for r in (0x05, 0x06): p0.append(rd(r))
print("   sensor: 0xfc = %s, page-1 write test %s, p0.05/06 = %s (driver writes 02 da)"
      % ("--" if fc is None else "%02x" % fc, "OPEN" if x == 0xa5 else "locked",
         " ".join("--" if v is None else "%02x" % v for v in p0)), flush=True)
EOF

say "2. colour-bar capture, driver only ($(date +%T))"
rm -f cam42_bars.raw
timeout 10 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam42_bars.raw >/dev/null 2>&1 &
BG=$!
sleep 1.5
python3 /tmp/p25t_open.py; sync
wait $BG; RC=$?
sync
say "   capture exit $RC (124 = timeout); cam42_bars.raw: $(stat -c %s cam42_bars.raw 2>/dev/null || echo none) bytes (3 frames = $((W * H * 2 * 3)))"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam42_bars.raw 2>/dev/null
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
rm -f /tmp/p25t_open.py

say "3. LDO2 back to 0.9 V"
setce 0x0c
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
say "=== done ==="
