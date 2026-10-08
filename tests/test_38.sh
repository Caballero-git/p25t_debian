#!/bin/bash
# test_38.sh - rear camera: first frames with 0xfc = 0x8f?
#
# test_37 (2026-10-07): with the driver's table but 0xfc bit 0 kept set
# (0x8f instead of 0x8e) the registers hold, and one second after stream-on
# the CSI receiver saw the sensor's MIPI HIGH-SPEED CLOCK for the first
# time (PHY_STATE 0x3f0). The capture ended before frames could arrive.
#
# This writes that table (0x8e -> 0x8f) while the capture runs, streams,
# and watches the receiver for 5 s: HS clock, error registers, VICAP
# interrupt status. The capture keeps going up to 15 s and saves up to 3
# frames to cam38.raw.
# Writes: camera sensor registers only.
#
#   cd ~/tests
#   sudo bash test_38.sh | tee result_38.txt
# Then copy cam38.raw (if not 0 bytes) next to result_38.txt.

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera first frames, 0xfc = 0x8f (test_38) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_8f.py <<'EOF'
import fcntl, mmap, os, struct, time
SEQ = [(int(t[:2], 16), int(t[2:], 16)) for t in "fc01 f440 f5e9 f614 f849 f982 fa00 fc81 fe00 3601 d387 3600 3300 fe03 01e7 f701 fc8f fc8f fc8e fe00 ee30 8718 fe01 8c90 fe00 fe00 0502 06da 9d0c 0900 0a04 0b00 0c03 0d07 0ea8 0f0a 1030 1102 1780 1905 fe02 3003 3103 fe00 d9c0 1b20 2148 2822 2958 4420 4b10 4e1a 5011 5233 5344 5510 5b11 c502 8c1a fe02 3305 3238 fe00 9180 9228 9320 95a0 96e0 d5fc 9728 160c 1a1a 1f11 2010 4683 4a04 5402 6200 728f 7389 7a05 7dcc 9000 ce18 d0b2 d240 e6e0 fe02 1201 1301 1401 1502 227c 9100 9200 9300 9400 fe00 fc88 fe10 fe00 fc8e fe00 fe00 fe00 fc88 fe10 fe00 fc8e fe00 b06e b101 b200 b300 b400 b600 fe01 5300 8903 6040 fe01 4221 4903 4aff 4bc0 5500 fe01 4128 4c00 4d00 4e3c 4408 4802 fe01 9100 9208 9300 9407 9507 9698 970a 9820 9900 fe03 0257 03b7 1514 180f 2122 2206 2348 2412 2528 2608 2906 2a58 2b08 fe01 8c10 fe00 3e01 fe00 3e01 fc01 f440 f5e4 f614 f849 f912 fa01 fc81 fe00 3601 d387 3600 3320 fe03 0187 f711 fc8f fc8f fc8e fe00 ee30 8718 fe01 8c90 fe00 fe00 0502 06da 9d0c 0900 0a04 0b00 0c03 0d07 0ea8 0f0a 1030 2160 2930 4418 4e20 8c20 9115 923a 9320 9545 9635 d5f0 9720 1f19 ce18 d0b3 fe02 1402 1500 fe00 fc88 fe10 fe00 fc8e fe00 fe00 fe00 fc88 fe10 fe00 fc8e fe01 4900 4a01 4bf8 fe01 4e06 4402 fe01 9100 9204 9300 9403 9503 96cc 9705 9810 9900 fe03 0258 2203 2606 2903 2b06 fe01 8c10".split()]
i2c = os.open("/dev/i2c-2", os.O_RDWR)
fcntl.ioctl(i2c, 0x0706, 0x37)                    # I2C_SLAVE_FORCE
def wr(r, v):
    try: os.write(i2c, bytes((r, v))); return True
    except OSError: return False
mfd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
csi = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfb0000)
vic = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfe0000)
r = lambda m, o: struct.unpack("<I", m[o:o + 4])[0]
bad = sum(0 if wr(a, 0x8f if (a, v) == (0xfc, 0x8e) else v) else 1 for a, v in SEQ)
wr(0xfe, 0); wr(0x3e, 0x91)
print("table written (0xfc 8e -> 8f), %d failed writes; stream on" % bad)
t0 = time.time(); last = None
while time.time() - t0 < 5:
    p = r(csi, 0x14)
    key = (p & 0x1ff0, r(csi, 0x20), r(csi, 0x24), r(vic, 0x128))
    if key != last:
        print("+%5d ms  PHY_STATE 0x%03x HS clock %-6s | ERR1 0x%08x ERR2 0x%08x | VICAP INTSTAT 0x%08x"
              % ((time.time() - t0) * 1000, p, "ACTIVE" if p & 0x100 else "off", key[1], key[2], key[3]))
        last = key
    time.sleep(0.01)
EOF

echo; echo "--- capture in the background ---"
rm -f cam38.raw
timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam38.raw > /tmp/p25t_v4l2.log 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_8f.py
wait $BG
echo "capture exit $? (124 = timeout)"
echo "cam38.raw: $(stat -c %s cam38.raw 2>/dev/null || echo none) bytes (3 frames = $((W * H * 2 * 3)))"
echo "--- v4l2-ctl output ---"; cat /tmp/p25t_v4l2.log
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam38.raw 2>/dev/null
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
rm -f /tmp/p25t_8f.py /tmp/p25t_v4l2.log
echo "=== done ==="
