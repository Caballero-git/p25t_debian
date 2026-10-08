#!/bin/bash
# test_37.sh - rear camera: does the sensor's PLL run?
#
# test_36 (2026-10-07) found the switch: register 0xfc.
#   0xfc = 0x01 / 0x81 / 0x8f  (bit 0 set)   -> paged registers work
#   0xfc = 0x8e                (bit 0 clear) -> paged registers freeze
# The table sets bit 0 while it programs the PLL (0xf4-0xfa, 0xf7 = PLL
# on), then clears it: the sensor's logic leaves the raw 24 MHz input
# clock and runs from the PLL. If the PLL gives no clock, the logic stops:
# writes are lost, nothing streams. Exactly what we see.
#
# While our driver keeps the camera powered (background capture), this:
#  A. writes the driver's table but keeps 0xfc bit 0 set (0x8e -> 0x8f),
#     stream on, watches 1 s: do the registers hold, does MIPI start?
#  B. writes the table again, waits 100 ms after "PLL on" before every
#     0xfc = 0x8e (maybe the PLL just needs time to lock), stream on, 1 s
# Each step: 6 marker registers, page-1 write test (OPEN/locked), the CSI
# receiver's HS clock, and the capture file size at the end.
# Writes: camera sensor registers only.
#
#   cd ~/tests
#   sudo bash test_37.sh | tee result_37.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera PLL check (test_37) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_pll.py <<'EOF'
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
mfd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
csi = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfb0000)
phy = lambda: struct.unpack("<I", csi[0x14:0x18])[0]
MK = [(0, 0x05, 0x02), (0, 0x06, 0xda), (0, 0x46, 0x83), (1, 0x41, 0x28), (3, 0x01, 0x87), (3, 0x23, 0x48)]
tog = [0x5a]
def show(t):
    m = []
    for p, r, v in MK:
        wr(0xfe, p); m.append(rd(r))
    tog[0] ^= 0xff
    wr(0xfe, 1); wr(0x42, tog[0]); o = rd(0x42) == tog[0]; wr(0x42, 0x21)
    wr(0xfe, 0)
    n = sum(1 for (p, r, v), x in zip(MK, m) if x == v)
    p = phy()
    print("%-26s markers %d/6 | %-6s | fc=%s | PHY_STATE 0x%03x HS clock %s"
          % (t, n, "OPEN" if o else "locked", h(rd(0xfc)), p, "ACTIVE" if p & 0x100 else "off"))
def watch(tag):
    for i in range(4):
        time.sleep(0.25); show("%s +%d ms" % (tag, 250 * (i + 1)))
show("as the driver left it")
print("A. table with 0xfc bit 0 kept set (8e -> 8f), stream on")
for r, v in SEQ:
    wr(r, 0x8f if (r, v) == (0xfc, 0x8e) else v)
show("A table written")
wr(0xfe, 0); wr(0x3e, 0x91)
watch("A stream on")
print("B. table as the driver has it, 100 ms after PLL on before each fc=8e")
pll_on = False
for r, v in SEQ:
    if r == 0xf7: pll_on = True
    if (r, v) == (0xfc, 0x8e) and pll_on:
        time.sleep(0.1); pll_on = False
    wr(r, v)
show("B table written")
wr(0xfe, 0); wr(0x3e, 0x91)
watch("B stream on")
EOF

echo; echo "--- capture in the background ---"
rm -f cam37.raw
timeout 10 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam37.raw >/dev/null 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_pll.py
sleep 1
kill $BG 2>/dev/null; wait $BG 2>/dev/null
echo "cam37.raw: $(stat -c %s cam37.raw 2>/dev/null || echo none) bytes (3 frames = $((W * H * 2 * 3)))"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam37.raw 2>/dev/null
rm -f /tmp/p25t_pll.py
echo "=== done ==="
