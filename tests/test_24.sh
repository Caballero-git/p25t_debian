#!/bin/bash
# test_24.sh - rear camera: why no frames? Register snapshot while streaming.
#
# test_23 v2 (2026-10-07): STREAMON succeeds, but no frame ever arrives
# (15 s timeout), no kernel message. This starts the same stream in the
# background and, while it runs, reads (read-only):
#  - the sensor over I2C (bus 2, 0x37, forced next to the driver): page,
#    chip ID, stream mode register 0x3e (0x91 = streaming)
#  - the CSI-2 host registers (fdfb0000): lanes, reset, PHY state, error
#    registers - taken 3 times, 0.5 s apart
#  - the D-PHY lane enables in the GRF (VI_CON0)
#  - the VICAP registers (fdfe0000, 0x000-0x1fc), twice, to see which
#    counters/status bits move
# Registers are only read while the stream runs: then all clocks and the
# VI power domain are on (reading a powered-down block can hang the SoC).
#
#   cd ~/tests
#   sudo bash test_24.sh | tee result_24.txt
# Needs v4l-utils, i2c-tools, python3.

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera stream snapshot (test_24) ==="
date; uname -v

SENS=$(media-ctl -d $M -e "gc5035 2-0037")
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=1

cat > /tmp/p25t_regs.py <<'EOF'
import mmap, os, struct, sys
def dump(base, start, end, title, all_words=False):
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    page = base & ~0xfff
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    print("--- %s (0x%08x) ---" % (title, base))
    line = []
    for off in range(start, end, 4):
        v = struct.unpack("<I", m[base - page + off: base - page + off + 4])[0]
        if v or all_words:
            line.append("+%03x=%08x" % (off, v))
        if len(line) == 4:
            print("  " + "  ".join(line)); line = []
    if line:
        print("  " + "  ".join(line))
    m.close(); os.close(fd)
what = sys.argv[1]
if what == "csi":
    dump(0xfdfb0000, 0x00, 0x50, "CSI-2 host 0x00-0x4c (all words)", True)
elif what == "grf":
    dump(0xfdc60000 + 0x340, 0, 4, "GRF VI_CON0 (D-PHY: bits 0-3 forcerx, 4-7 data lanes, 8 clock lane)", True)
elif what == "vicap":
    dump(0xfdfe0000, 0x000, 0x200, "VICAP 0x000-0x1fc (non-zero words)")
EOF

echo; echo "--- start stream in the background (test pattern on) ---"
dmesg -C
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/tmp/p25t_cam24.raw > /tmp/p25t_cam24.log 2>&1 &
BG=$!
sleep 2

echo; echo "--- sensor while streaming ---"
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
for r in 0xfe 0xf0 0xf1 0x3e; do
    echo "reg $r = $(i2cget -f -y 2 0x37 $r 2>&1)"
done

echo
python3 /tmp/p25t_regs.py grf
for i in 1 2 3; do python3 /tmp/p25t_regs.py csi; sleep 0.5; done
python3 /tmp/p25t_regs.py vicap
sleep 1
python3 /tmp/p25t_regs.py vicap

wait $BG
echo; echo "--- v4l2-ctl exit $? (124 = timeout); its output ---"
tail -5 /tmp/p25t_cam24.log
ls -l /tmp/p25t_cam24.raw 2>/dev/null
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
echo; echo "--- kernel log ---"
dmesg | tail -20
rm -f /tmp/p25t_regs.py
echo "=== done ==="
