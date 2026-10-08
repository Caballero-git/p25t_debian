#!/bin/bash
# test_30.sh - rear camera: is the CSI D-PHY routed to the right receiver?
#
# test_29 (2026-10-07): the 24 MHz MCLK leaves the SoC pin (GPIO4_C0
# toggles), gate open, mux right. So clock, power, pins and the register
# sequence (Rockchip's own, test_28) are all as in Android - yet the CSI-2
# receiver sees nothing. One setting mainline never touches: GRF VI_CON1.
# Rockchip's own D-PHY driver writes there
#   bit 7  lane mode: 0 = full (one 4-lane PHY), 1 = split (2 + 2 lanes)
#   bit 11 which half feeds the CSI-2 host / VICAP ("CIF"): 0 = lanes 0-1
#   bit 12 which half feeds the ISP:                     1 = lanes 2-3
# Android ran split mode. If VI_CON1 still holds split mode with the halves
# routed elsewhere, our CSI-2 host never gets the rear camera's lanes.
#
# While a capture runs this:
#  1. reads GRF VI_CON0 / VI_CON1 and the receiver state
#  2. sets FULL mode (bit 7 = 0), waits, reads again
#  3. sets SPLIT mode with lanes 0-1 to the CSI-2 host (bit 7 = 1, bit 11 =
#     0, bit 12 = 1, as Rockchip does for the rear camera on the CIF path)
#  4. puts VI_CON1 back to the value it found
# and tells whether frames arrived (cam30.raw size). GRF writes use the
# write-enable mask in the upper 16 bits, so only those three bits change.
#
#   cd ~/tests
#   sudo bash test_30.sh | tee result_30.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera D-PHY routing (test_30) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=1

cat > /tmp/p25t_route.py <<'EOF'
import mmap, os, struct, sys, time
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
grf = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xfdc60000)
csi = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfb0000)
vic = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfe0000)
r = lambda m, o: struct.unpack("<I", m[o:o + 4])[0]
def w_grf(o, val, mask):           # hiword write: only bits in mask change
    grf[o:o + 4] = struct.pack("<I", (mask << 16) | (val & mask))
def show(t):
    c0, c1, p = r(grf, 0x340), r(grf, 0x344), r(csi, 0x14)
    print("%-26s VI_CON0=0x%04x VI_CON1=0x%04x (mode %s, CIF<-%s, ISP<-%s) | PHY_STATE 0x%03x HS clock %s | ERR1 0x%x ERR2 0x%x | VICAP INTSTAT 0x%x"
          % (t, c0 & 0xffff, c1 & 0xffff, "split" if c1 & 0x80 else "full",
             "2-3" if c1 & 0x800 else "0-1", "2-3" if c1 & 0x1000 else "0-1",
             p, "ACTIVE" if p & 0x100 else "off", r(csi, 0x20), r(csi, 0x24), r(vic, 0x128)))
orig = r(grf, 0x344) & 0xffff
show("as found")
for i in range(3):
    time.sleep(0.3); show("as found +%d" % i)
w_grf(0x344, 0x0000, 0x1880)       # full mode, both selects 0
for i in range(4):
    time.sleep(0.3); show("FULL mode +%d" % i)
w_grf(0x344, 0x1080, 0x1880)       # split, CIF <- lanes 0-1, ISP <- lanes 2-3
for i in range(4):
    time.sleep(0.3); show("SPLIT, CIF<-0-1 +%d" % i)
w_grf(0x344, orig, 0x1880)
show("restored")
EOF

echo; echo "--- capture in the background (test pattern on) ---"
rm -f cam30.raw
timeout 14 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=cam30.raw >/dev/null 2>&1 &
BG=$!
sleep 2
python3 /tmp/p25t_route.py
wait $BG
echo; echo "capture exit $? (124 = timeout); cam30.raw: $(stat -c %s cam30.raw 2>/dev/null || echo none) bytes (3 frames = $((W * H * 2 * 3)))"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam30.raw 2>/dev/null
echo; echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -10
rm -f /tmp/p25t_route.py
echo "=== done ==="
