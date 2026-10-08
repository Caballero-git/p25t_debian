#!/bin/bash
# test_36.sh - rear camera: which write in the table locks the registers?
#
# test_35 (2026-10-07): even our own hand-written copy of the driver's
# table does not stick - read right after writing, every paged register
# is still at its reset value; stream-on changes nothing. But in test_32
# single writes to pages 1-3 DID stick. So the sensor has two states:
#   "open":   paged registers keep what we write
#   "locked": paged writes are lost (system registers 0xf0-0xff still work)
# and something - probably one of the system writes in the table (clock,
# PLL, resets) - switches it to "locked".
#
# While our driver keeps the camera powered (background capture), this:
#  1. tests open/locked now (write page 1 reg 0x42 = 5a, read it back)
#  2. if locked, tries to unlock: soft reset (0xfe = 80 x3), then a
#     powerdown pulse (GPIO4_B2 low 100 ms), then a camera-clock pulse
#     (CRU gate off 50 ms) - testing after each and dumping 0xf0-0xff
#  3. writes the driver's table one register at a time, testing after
#     EVERY write, and prints each write where the state flips
# Writes: camera sensor registers, GPIO4_B2 and the clk_cif_out gate
# (both put back).
#
#   cd ~/tests
#   sudo bash test_36.sh | tee result_36.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera register lock bisection (test_36) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_bis.py <<'EOF'
import fcntl, mmap, os, struct, time
SEQ = [(int(t[:2], 16), int(t[2:], 16)) for t in "fc01 f440 f5e9 f614 f849 f982 fa00 fc81 fe00 3601 d387 3600 3300 fe03 01e7 f701 fc8f fc8f fc8e fe00 ee30 8718 fe01 8c90 fe00 fe00 0502 06da 9d0c 0900 0a04 0b00 0c03 0d07 0ea8 0f0a 1030 1102 1780 1905 fe02 3003 3103 fe00 d9c0 1b20 2148 2822 2958 4420 4b10 4e1a 5011 5233 5344 5510 5b11 c502 8c1a fe02 3305 3238 fe00 9180 9228 9320 95a0 96e0 d5fc 9728 160c 1a1a 1f11 2010 4683 4a04 5402 6200 728f 7389 7a05 7dcc 9000 ce18 d0b2 d240 e6e0 fe02 1201 1301 1401 1502 227c 9100 9200 9300 9400 fe00 fc88 fe10 fe00 fc8e fe00 fe00 fe00 fc88 fe10 fe00 fc8e fe00 b06e b101 b200 b300 b400 b600 fe01 5300 8903 6040 fe01 4221 4903 4aff 4bc0 5500 fe01 4128 4c00 4d00 4e3c 4408 4802 fe01 9100 9208 9300 9407 9507 9698 970a 9820 9900 fe03 0257 03b7 1514 180f 2122 2206 2348 2412 2528 2608 2906 2a58 2b08 fe01 8c10 fe00 3e01 fe00 3e01 fc01 f440 f5e4 f614 f849 f912 fa01 fc81 fe00 3601 d387 3600 3320 fe03 0187 f711 fc8f fc8f fc8e fe00 ee30 8718 fe01 8c90 fe00 fe00 0502 06da 9d0c 0900 0a04 0b00 0c03 0d07 0ea8 0f0a 1030 2160 2930 4418 4e20 8c20 9115 923a 9320 9545 9635 d5f0 9720 1f19 ce18 d0b3 fe02 1402 1500 fe00 fc88 fe10 fe00 fc8e fe00 fe00 fe00 fc88 fe10 fe00 fc8e fe01 4900 4a01 4bf8 fe01 4e06 4402 fe01 9100 9204 9300 9403 9503 96cc 9705 9810 9900 fe03 0258 2203 2606 2903 2b06 fe01 8c10".split()]
i2c = os.open("/dev/i2c-2", os.O_RDWR)
fcntl.ioctl(i2c, 0x0706, 0x37)                    # I2C_SLAVE_FORCE
def wr(r, v):
    try: os.write(i2c, bytes((r, v))); return True
    except OSError: return False
def rd(r):
    try: os.write(i2c, bytes((r,))); return os.read(i2c, 1)[0]
    except OSError: return None
h = lambda v: "--" if v is None else "%02x" % v
mfd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
gpio = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xfe770000)
cru = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xfdd20000)
csi = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfb0000)
GATE = 0x300 + 4 * 19
def b2(v): gpio[0:4] = struct.pack("<I", (1 << 26) | (v << 10))
def gate(off): cru[GATE:GATE + 4] = struct.pack("<I", (1 << 24) | ((1 if off else 0) << 8))
page = [0]
toggle = [0x5a]
def is_open():                                    # page 1 reg 0x42 keeps a write?
    toggle[0] ^= 0xff                             # 5a / a5 alternately
    wr(0xfe, 1); wr(0x42, toggle[0]); x = rd(0x42); wr(0xfe, page[0])
    return x == toggle[0]
def sysdump(t):
    print("  %-24s f0-ff: %s" % (t, " ".join(h(rd(r)) for r in range(0xf0, 0x100))))
def report(t):
    o = is_open()
    print("%-28s -> %s" % (t, "OPEN" if o else "locked"))
    return o

print("1. state now")
sysdump("now")
o = report("as the driver left it")
if not o:
    print("2. unlock attempts")
    for _ in range(3): wr(0xfe, 0x80)
    wr(0xfe, 0x00); time.sleep(0.01)
    o = report("soft reset fe=80 x3"); sysdump("after soft reset")
if not o:
    b2(0); time.sleep(0.1); b2(1); time.sleep(0.02)
    o = report("powerdown pulse 100 ms"); sysdump("after powerdown pulse")
if not o:
    gate(True); time.sleep(0.05); gate(False); time.sleep(0.02)
    o = report("camera clock pulse 50 ms"); sysdump("after clock pulse")
print("3. driver table, one write at a time (%d writes); state flips:" % len(SEQ))
page[0] = 0
last = is_open()
print("  start: %s" % ("OPEN" if last else "locked"))
flips = 0
for i, (r, v) in enumerate(SEQ):
    wr(r, v)
    if r == 0xfe: page[0] = v & 3
    st = is_open()
    if st != last:
        flips += 1
        print("  write #%3d  0x%02x = 0x%02x  (page %d)  -> %s" % (i, r, v, page[0], "OPEN" if st else "locked"))
        last = st
print("  end: %s, %d flips" % ("OPEN" if last else "locked", flips))
sysdump("end")
p = struct.unpack("<I", csi[0x14:0x18])[0]
print("PHY_STATE 0x%03x HS clock %s" % (p, "ACTIVE" if p & 0x100 else "off"))
EOF

echo; echo "--- capture in the background ---"
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null >/dev/null 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_bis.py
kill $BG 2>/dev/null; wait $BG 2>/dev/null
rm -f /tmp/p25t_bis.py
echo "=== done ==="
