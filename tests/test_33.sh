#!/bin/bash
# test_33.sh - rear camera: did the driver's whole register table stick?
#
# test_32 (2026-10-07): the sensor works. MCLK reaches it (gating the
# clock in the CRU kills I2C), system registers and pages 1-3 keep what
# we write. So the earlier "paged registers read 0" was wrong for most
# registers: some (0x3e, page-3 0x01) simply read back differently.
# Now: while our driver streams, dump all four register pages
# (0x00-0xef) and compare with the values the driver wrote (its global
# table + the 1296x972 mode table, page by page). Exposure, gain, frame
# length and test pattern are set by controls afterwards and may differ.
# Read-only: the sensor is only read (plus the page select 0xfe).
#
#   cd ~/tests
#   sudo bash test_33.sh | tee result_33.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera register table check (test_33) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_tab.py <<'EOF'
import fcntl, os
# page:reg:value written by the driver (global + 1296x972 tables, last write wins)
EXP = "0:05:02 0:06:da 0:09:00 0:0a:04 0:0b:00 0:0c:03 0:0d:07 0:0e:a8 0:0f:0a 0:10:30 0:11:02 0:16:0c 0:17:80 0:19:05 0:1a:1a 0:1b:20 0:1f:19 0:20:10 0:21:60 0:28:22 0:29:30 0:33:20 0:36:00 0:3e:01 0:44:18 0:46:83 0:4a:04 0:4b:10 0:4e:20 0:50:11 0:52:33 0:53:44 0:54:02 0:55:10 0:5b:11 0:62:00 0:72:8f 0:73:89 0:7a:05 0:7d:cc 0:87:18 0:8c:20 0:90:00 0:91:15 0:92:3a 0:93:20 0:95:45 0:96:35 0:97:20 0:9d:0c 0:b0:6e 0:b1:01 0:b2:00 0:b3:00 0:b4:00 0:b6:00 0:c5:02 0:ce:18 0:d0:b3 0:d2:40 0:d3:87 0:d5:f0 0:d9:c0 0:e6:e0 0:ee:30 1:41:28 1:42:21 1:44:02 1:48:02 1:49:00 1:4a:01 1:4b:f8 1:4c:00 1:4d:00 1:4e:06 1:53:00 1:55:00 1:60:40 1:89:03 1:8c:10 1:91:00 1:92:04 1:93:00 1:94:03 1:95:03 1:96:cc 1:97:05 1:98:10 1:99:00 2:12:01 2:13:01 2:14:02 2:15:00 2:22:7c 2:30:03 2:31:03 2:32:38 2:33:05 2:91:00 2:92:00 2:93:00 2:94:00 3:01:87 3:02:58 3:03:b7 3:15:14 3:18:0f 3:21:22 3:22:03 3:23:48 3:24:12 3:25:28 3:26:06 3:29:03 3:2a:58 3:2b:06"
exp = {}
for t in EXP.split():
    p, r, v = (int(x, 16) for x in t.split(":"))
    exp[(p, r)] = v
i2c = os.open("/dev/i2c-2", os.O_RDWR)
fcntl.ioctl(i2c, 0x0706, 0x37)                    # I2C_SLAVE_FORCE
def wr(r, v): os.write(i2c, bytes((r, v)))
def rd(r):
    try: os.write(i2c, bytes((r,))); return os.read(i2c, 1)[0]
    except OSError: return None
dump = {}
for p in range(4):
    wr(0xfe, p)
    for r in range(0xf0):
        dump[(p, r)] = rd(r)
wr(0xfe, 0)
h = lambda v: "--" if v is None else "%02x" % v
CTRL = {(0, 0x03), (0, 0x04), (0, 0xb0), (0, 0xb1), (0, 0xb2), (0, 0xb3), (0, 0xb4),
        (0, 0xb6), (0, 0x41), (0, 0x42), (0, 0x8c), (1, 0x8c)}
same = [k for k in sorted(exp) if dump[k] == exp[k]]
diff = [k for k in sorted(exp) if dump[k] != exp[k]]
print("driver-written registers: %d, read back the same: %d, different: %d"
      % (len(exp), len(same), len(diff)))
print("different (page reg: written -> read)%s:" % ("" if diff else " none"))
for k in diff:
    print("  p%d 0x%02x: %02x -> %s%s" % (k[0], k[1], exp[k], h(dump[k]),
          "   (control)" if k in CTRL else ""))
print()
print("full dump, pages 0-3, regs 0x00-0xef:")
for p in range(4):
    print("page %d" % p)
    for base in range(0, 0xf0, 0x10):
        print("  %02x: %s" % (base, " ".join(h(dump[(p, r)]) for r in range(base, base + 0x10))))
EOF

echo; echo "--- capture in the background ---"
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null >/dev/null 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_tab.py
kill $BG 2>/dev/null; wait $BG 2>/dev/null
rm -f /tmp/p25t_tab.py
echo "=== done ==="
