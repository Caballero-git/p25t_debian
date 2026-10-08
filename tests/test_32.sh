#!/bin/bash
# test_32.sh - rear camera: does the sensor keep ANY register we write?
#
# test_31 (2026-10-07): PWDN polarity is right (B2 low kills I2C, high
# brings it back; a fresh edge changes nothing). So power and PWDN are as
# in Android, and the 24 MHz clock leaves the SoC pin (test_29).
# What we never proved: that a write to the sensor sticks. Every check so
# far read back either the chip ID (hard-wired, works without a clock) or
# 0xfc = 0x8e, which may simply be its power-on default. Paged registers
# (0x3e, 0x41) always read 0 after a write.
#
# While our driver keeps the camera powered (background capture), this:
#  1. dumps the system registers 0xf0-0xff
#  2. write test on system registers: page select 0xfe, PLL 0xf4/0xf9/0xfa
#     (value changed by one bit, read back, original put back)
#  3. write test on a paged register in pages 0-3
#  4. same as 1+2 with the camera clock GATED OFF in the CRU (CLKGATE_CON19
#     bit 8), then ungates it - does the sensor even notice the clock?
# Writes: the camera sensor's registers (restored), CRU gate of clk_cif_out
# (restored).
#
#   cd ~/tests
#   sudo bash test_32.sh | tee result_32.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera register write check (test_32) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_wr.py <<'EOF'
import fcntl, mmap, os, struct, time
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
cru = mmap.mmap(mfd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xfdd20000)
GATE = 0x300 + 4 * 19                             # CLKGATE_CON19, bit 8 = clk_cif_out
def gate(off):                                    # hiword write, bit 8 only
    cru[GATE:GATE + 4] = struct.pack("<I", (1 << 24) | ((1 if off else 0) << 8))
def gstate():
    return (struct.unpack("<I", cru[GATE:GATE + 4])[0] >> 8) & 1

def dump(t):
    print("%-22s f0-ff: %s" % (t, " ".join(h(rd(r)) for r in range(0xf0, 0x100))))
def wtest(label, reg, page=None):
    if page is not None: wr(0xfe, page)
    a = rd(reg)
    if a is None:
        print("  %-26s read fails" % label); return
    b = a ^ 0x01
    ok = wr(reg, b)
    c = rd(reg)
    wr(reg, a)
    d = rd(reg)
    if page is not None: wr(0xfe, 0)
    verdict = "STICKS" if c == b else ("ignored" if c == a else "reads %s" % h(c))
    print("  %-26s was %s, wrote %s (%s), reads %s -> %-8s | restored, reads %s"
          % (label, h(a), h(b), "ack" if ok else "NACK", h(c), verdict, h(d)))
def wpage():                                      # page select itself
    a = rd(0xfe); wr(0xfe, 0x02); c = rd(0xfe); wr(0xfe, 0x00); d = rd(0xfe)
    print("  %-26s was %s, wrote 02, reads %s -> %-8s | wrote 00, reads %s"
          % ("0xfe (page select)", h(a), h(c), "STICKS" if c == 2 else "ignored", h(d)))
def block(t):
    print("CRU clk_cif_out gate bit = %d (0 = running)" % gstate())
    dump(t)
    print(" system registers:")
    wpage()
    for r in (0xf4, 0xf9, 0xfa):
        wtest("0x%02x" % r, r)
    print(" paged registers:")
    for p, r in ((0, 0x41), (1, 0x42), (2, 0x67), (3, 0x01)):
        wtest("page %d reg 0x%02x" % (p, r), r, p)

print("1-3. clock running")
block("clock on")
print()
print("4. clock GATED OFF")
gate(True); time.sleep(0.05)
block("clock off")
gate(False); time.sleep(0.05)
print()
print("clock back on: gate bit = %d" % gstate())
dump("clock on again")
EOF

echo; echo "--- capture in the background ---"
rm -f cam32.raw
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam32.raw >/dev/null 2>&1 &
BG=$!
sleep 2
python3 /tmp/p25t_wr.py
kill $BG 2>/dev/null; wait $BG 2>/dev/null
rm -f cam32.raw /tmp/p25t_wr.py
echo "=== done ==="
