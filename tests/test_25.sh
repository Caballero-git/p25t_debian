#!/bin/bash
# test_25.sh - rear camera: does the sensor start sending when told by hand?
#
# test_24 (2026-10-07): during the stream the CSI-2 receiver saw no
# high-speed clock (PHY_STATE 0x6f0: all lanes in LP-11 stop state) and the
# sensor's stream register 0x3e read 0x00, not 0x91 (streaming). Either the
# driver's start sequence did not take effect, or 0x3e does not read back.
#
# This starts the same stream (1296x972, colour-bar pattern) and, while it
# runs:
#  1. reads sensor registers: page, chip ID, 0x3e, frame length 0x41/0x42
#     (the driver writes 0x07/0xd8 = 2008 lines for this mode: if they read
#     so, the mode tables were written)
#  2. reads the receiver PHY state
#  3. writes 0x3e = 0x91 (page 0) by hand - the sensor's stream-on - and
#     reads everything again 1 s later
#  4. waits for the capture: if frames now arrive, cam25.raw has data
# Writes only to the camera sensor (page select 0xfe and 0x3e), nothing
# else. All registers are read only while the stream runs (clocks on).
#
#   cd ~/tests
#   sudo bash test_25.sh | tee result_25.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera manual stream-on (test_25) ==="
date; uname -v

SENS=$(media-ctl -d $M -e "gc5035 2-0037")
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=1

cat > /tmp/p25t_phy.py <<'EOF'
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
def rd(base, off):
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    v = struct.unpack("<I", m[off:off + 4])[0]; m.close(); return v
p = rd(0xfdfb0000, 0x14)
print("CSI PHY_STATE 0x%03x: HS clock %s, data lanes in stop state 0x%x, clock lane stop %d"
      % (p, "ACTIVE" if p & 0x100 else "off", (p >> 4) & 0xf, (p >> 10) & 1))
print("CSI ERR1 0x%08x ERR2 0x%08x" % (rd(0xfdfb0000, 0x20), rd(0xfdfb0000, 0x24)))
print("VICAP MIPI INTSTAT (+0x128) 0x%08x, frame status (+0x0c4..) not decoded" % rd(0xfdfe0000, 0x128))
EOF

sensor() {
    for r in 0xfe 0xf0 0xf1 0x3e 0x41 0x42; do
        printf "  reg %s = %s\n" $r "$(i2cget -f -y 2 0x37 $r 2>&1)"
    done
}

echo; echo "--- start stream in the background ---"
dmesg -C
rm -f cam25.raw
timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam25.raw > /tmp/p25t_cam25.log 2>&1 &
BG=$!
sleep 2

echo; echo "--- 1. as the driver left it ---"
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
sensor
python3 /tmp/p25t_phy.py

echo; echo "--- 2. stream-on by hand: page 0, 0x3e = 0x91 ---"
i2cset -f -y 2 0x37 0xfe 0x00
i2cset -f -y 2 0x37 0x3e 0x91
sleep 1
sensor
python3 /tmp/p25t_phy.py
sleep 1
python3 /tmp/p25t_phy.py

wait $BG
echo; echo "--- capture: v4l2-ctl exit $? (124 = timeout) ---"
tail -3 /tmp/p25t_cam25.log
echo "cam25.raw: $(stat -c %s cam25.raw 2>/dev/null || echo none) bytes (3 frames = $((W * H * 2 * 3)))"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam25.raw 2>/dev/null
echo; echo "--- kernel log ---"; dmesg | tail -20
rm -f /tmp/p25t_phy.py /tmp/p25t_cam25.log
echo "=== done ==="
