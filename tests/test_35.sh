#!/bin/bash
# test_35.sh - rear camera: does stream-on wipe the sensor's settings?
#
# test_34 (2026-10-07): both read methods agree, so the reads are right.
# While the driver streams, the system registers (0xf0-0xfc) hold the
# driver's values but EVERY paged register is back at its reset value
# (00, page 1 0x40-0x7f = 80). In test_32 our own paged writes did stick.
# So something resets the sensor's core after the driver writes it, while
# the I/O part (system registers) survives. Prime suspect: the moment
# streaming starts (0x3e = 0x91) the PLL and MIPI switch on, the current
# jumps, a supply sags and the core resets.
#
# While the driver keeps the camera powered (background capture), this:
#  1. writes the driver's own table by hand (global + 1296x972, 255 writes)
#     and reads back 6 marker registers right away and after 300 ms
#  2. writes 0xfe = 0, 0x3e = 0x91 (stream on) and polls the markers and
#     the CSI receiver every ~20 ms for 1 s, printing every change
#  3. same with 0x3e = 0x01 (stream bit off) for comparison
# Writes: camera sensor registers only.
#
#   cd ~/tests
#   sudo bash test_35.sh | tee result_35.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera stream-on reset check (test_35) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_sr.py <<'EOF'
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
mfd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
csi = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfb0000)
phy = lambda: struct.unpack("<I", csi[0x14:0x18])[0]
h = lambda v: "--" if v is None else "%02x" % v
# markers: (page, reg, driver value)
MK = [(0, 0x05, 0x02), (0, 0x06, 0xda), (0, 0x46, 0x83), (1, 0x41, 0x28), (3, 0x01, 0x87), (3, 0x23, 0x48)]
def markers():
    out = []
    for p, r, v in MK:
        wr(0xfe, p); out.append(rd(r))
    wr(0xfe, 0)
    return out
def fmt(m):
    return " ".join("p%d.%02x=%s" % (p, r, h(x)) for (p, r, _), x in zip(MK, m))
def ok(m):
    n = sum(1 for (p, r, v), x in zip(MK, m) if x == v)
    return "%d/%d markers hold the driver value" % (n, len(MK))
def state(t, m):
    p = phy()
    print("%-22s %s | %s | PHY_STATE 0x%03x HS clock %s | f0=%s fc=%s"
          % (t, fmt(m), ok(m), p, "ACTIVE" if p & 0x100 else "off", h(rd(0xf0)), h(rd(0xfc))))
def poll(tag, secs=1.0):
    t0 = time.time(); last = None; n = 0
    while time.time() - t0 < secs:
        m = markers(); key = (tuple(m), phy() & 0x1ff0)
        if key != last:
            state("%s +%4d ms" % (tag, (time.time() - t0) * 1000), m); last = key; n += 1
        time.sleep(0.02)
    print("  (%s: %d distinct states in %.1f s)" % (tag, n, secs))

state("as the driver left it", markers())
bad = sum(0 if wr(r, v) else 1 for r, v in SEQ)
print("1. driver table written by hand: %d writes, %d failed" % (len(SEQ), bad))
state("right after", markers())
time.sleep(0.3)
state("after 300 ms", markers())
print("2. stream on: 0xfe=00, 0x3e=0x91")
wr(0xfe, 0); wr(0x3e, 0x91)
poll("stream on")
print("3. rewrite table, then 0x3e=0x01 (stream bit off)")
bad = sum(0 if wr(r, v) else 1 for r, v in SEQ)
wr(0xfe, 0); wr(0x3e, 0x01)
poll("3e=01")
EOF

echo; echo "--- capture in the background ---"
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null >/dev/null 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_sr.py
kill $BG 2>/dev/null; wait $BG 2>/dev/null
rm -f /tmp/p25t_sr.py
echo "=== done ==="
