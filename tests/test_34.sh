#!/bin/bash
# test_34.sh - rear camera: are our register READS trustworthy?
#
# test_33 (2026-10-07): system registers 0xf4-0xfc hold exactly what the
# driver writes (f5=e4, f7=11, fa=01 ... from its mode table), so the
# driver's writes do reach the sensor. But the paged registers read
# all 00 (page 1 0x40-0x7f all 80, page 2 0x4f-0x6f all 01), while in
# test_32 the same registers read the driver's values. Paged reads change
# from run to run, so the READ method itself may be wrong.
# Our scripts read in two transactions: [write reg] STOP, [read 1 byte].
# The kernel (and Android) read in one: [write reg] REPEATED START [read].
# While our driver streams, this reads ~25 registers the driver wrote,
# three times with each method, and prints them side by side.
# Read-only (plus the page select 0xfe).
#
#   cd ~/tests
#   sudo bash test_34.sh | tee result_34.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera read method check (test_34) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_rd.py <<'EOF'
import ctypes, fcntl, os
ADDR = 0x37
i2c = os.open("/dev/i2c-2", os.O_RDWR)
fcntl.ioctl(i2c, 0x0706, ADDR)                    # I2C_SLAVE_FORCE
class Msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]
class RdWr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(Msg)), ("nmsgs", ctypes.c_uint32)]
def rd_combined(r):                               # I2C_RDWR: write reg, repeated start, read
    wbuf = (ctypes.c_uint8 * 1)(r); rbuf = (ctypes.c_uint8 * 1)()
    msgs = (Msg * 2)(Msg(ADDR, 0, 1, wbuf), Msg(ADDR, 1, 1, rbuf))
    try:
        fcntl.ioctl(i2c, 0x0707, RdWr(msgs, 2)); return rbuf[0]
    except OSError: return None
def rd_split(r):                                  # what tests 24-33 did
    try: os.write(i2c, bytes((r,))); return os.read(i2c, 1)[0]
    except OSError: return None
def wr(r, v): os.write(i2c, bytes((r, v)))
h = lambda v: "--" if v is None else "%02x" % v
# (page, reg, value the driver writes)
REGS = [(None, 0xf0, 0x50), (None, 0xf5, 0xe4), (None, 0xf7, 0x11), (None, 0xfc, 0x8e),
        (0, 0x05, 0x02), (0, 0x06, 0xda), (0, 0x0d, 0x07), (0, 0x0e, 0xa8),
        (0, 0x0f, 0x0a), (0, 0x10, 0x30), (0, 0x3e, 0x91), (0, 0x46, 0x83),
        (0, 0x91, 0x15), (0, 0x92, 0x3a), (0, 0xd0, 0xb3), (0, 0xee, 0x30),
        (1, 0x41, 0x28), (1, 0x42, 0x21), (1, 0x4b, 0xf8), (1, 0x96, 0xcc),
        (2, 0x22, 0x7c), (2, 0x32, 0x38), (3, 0x01, 0x87), (3, 0x02, 0x58),
        (3, 0x03, 0xb7), (3, 0x23, 0x48), (3, 0x2a, 0x58)]
print("page reg  driver | split read x3 | combined read x3")
for p, r, v in REGS:
    if p is not None: wr(0xfe, p)
    s = [h(rd_split(r)) for _ in range(3)]
    c = [h(rd_combined(r)) for _ in range(3)]
    ok = "  <- combined matches" if c[0] == "%02x" % v and s[0] != c[0] else ""
    print("  %s  0x%02x   %02x   | %s | %s%s" % ("-" if p is None else p, r, v, " ".join(s), " ".join(c), ok))
wr(0xfe, 0)
EOF

echo; echo "--- capture in the background ---"
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null > /tmp/p25t_v4l2.log 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_rd.py
kill $BG 2>/dev/null; wait $BG 2>/dev/null
echo; echo "--- v4l2-ctl output ---"; cat /tmp/p25t_v4l2.log
echo; echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
rm -f /tmp/p25t_rd.py /tmp/p25t_v4l2.log
echo "=== done ==="
