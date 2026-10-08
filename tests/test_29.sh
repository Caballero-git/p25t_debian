#!/bin/bash
# test_29.sh - rear camera: does the 24 MHz clock really leave the SoC pin?
#
# test_28 (2026-10-07): even Rockchip's own init sequence, written by
# hand, gets no high-speed clock out of the sensor. Its MIPI lanes sit in
# LP-11 (stop state), so its MIPI block has power - but going to
# high-speed needs its PLL, and the PLL needs MCLK. Debugfs said the clock
# is on and the pin muxed; this checks the hardware itself, read-only,
# while a stream keeps everything powered:
#  - CRU: CLKSEL_CON35 (source/divider of clk_cif_out) and CLKGATE_CON19
#    bit 8 (1 = clock gated off)
#  - GRF: GPIO4C_IOMUX_L (function of GPIO4_C0; 1 = cif_clkout)
#  - PMU GRF: IO voltage selects (vccio6 = 1.8 V expected)
#  - GPIO4 input register EXT_PORT read 20000 times: the pad level of
#    GPIO4_C0 (bit 16). A running 24 MHz clock gives a mix of 0 and 1; a
#    dead pin gives always 0 or always 1. B2 (bit 10, powerdown) is
#    printed as a control: it must read 1 every time.
#
#   cd ~/tests
#   sudo bash test_29.sh | tee result_29.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera MCLK pin check (test_29) ==="
date; uname -v

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

cat > /tmp/p25t_mclk.py <<'EOF'
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
maps = {}
def rd(addr):
    page = addr & ~0xfff
    if page not in maps:
        maps[page] = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    o = addr - page
    return struct.unpack("<I", maps[page][o:o + 4])[0]
CRU, GRF, PMUGRF, GPIO4 = 0xfdd20000, 0xfdc60000, 0xfdc20000, 0xfe770000
sel = rd(CRU + 0x100 + 4 * 35)
gate = rd(CRU + 0x300 + 4 * 19)
print("CRU CLKSEL_CON35  = 0x%08x  clk_cif_out source bits[15:14]=%d (0 gpll, 1 usb480m, 2 xin24m), divider bits[13:8]=%d (+1)"
      % (sel, (sel >> 14) & 3, (sel >> 8) & 0x3f))
print("CRU CLKGATE_CON19 = 0x%08x  bit 8 = %d (0 = clock running, 1 = gated off)" % (gate, (gate >> 8) & 1))
mux = rd(GRF + 0x70)
print("GRF GPIO4C_IOMUX_L = 0x%08x  GPIO4_C0 function bits[2:0] = %d (1 = cif_clkout)" % (mux, mux & 7))
for off in (0x140, 0x144, 0x148):
    print("PMU_GRF IO_VSEL @+0x%03x = 0x%08x" % (off, rd(PMUGRF + off)))
print("GPIO4 SWPORT_DDR_H = 0x%08x (C0 = bit 0: 1 = output as GPIO)" % rd(GPIO4 + 0x0c))
ones = {16: 0, 10: 0}
N = 20000
for _ in range(N):
    v = rd(GPIO4 + 0x70)
    for b in ones:
        ones[b] += (v >> b) & 1
print("EXT_PORT GPIO4_C0 (bit 16, MCLK): %d of %d samples high -> %s"
      % (ones[16], N, "TOGGLING (clock present)" if 0 < ones[16] < N else "STATIC (no clock on the pad)"))
print("EXT_PORT GPIO4_B2 (bit 10, powerdown, control): %d of %d high" % (ones[10], N))
EOF

echo; echo "--- idle (sensor suspended, MCLK expected off) ---"
python3 /tmp/p25t_mclk.py 2>&1 | grep -E "GATE|EXT_PORT"
echo; echo "--- start stream in the background ---"
timeout 12 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null >/dev/null 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
python3 /tmp/p25t_mclk.py
kill $BG 2>/dev/null; wait $BG 2>/dev/null
rm -f /tmp/p25t_mclk.py
echo "=== done ==="
