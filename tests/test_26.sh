#!/bin/bash
# test_26.sh - rear camera: is the sensor really awake while streaming?
#
# test_25 (2026-10-07): during the stream the sensor answers its chip ID
# (0xf0/0xf1 = 0x50/0x35) but every other register reads 0 (0x3e, frame
# length 0x41/0x42), and a hand-written 0x3e = 0x91 reads back 0. The
# driver writes about 300 registers at stream start, so either they never
# arrive or the sensor's core is not running (no clock on its MCLK pin, a
# pin holding it in power-down/reset, or a supply off) - only the ID
# registers answer then.
#
# While the stream runs this reads (debugfs, read-only):
#  - clk_cif_out (the sensor clock): enabled? rate?
#  - pin mux of GPIO4_C0 (must be the cif_clkout function, not GPIO)
#  - GPIO4 pin levels: B2 (rear powerdown, must be HIGH), B0, B3, A7
#  - the camera supplies
# and does one write/read-back test on the sensor: frame length 0x41.
#
#   cd ~/tests
#   sudo bash test_26.sh | tee result_26.txt

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
D=/sys/kernel/debug
echo "=== rear camera awake check (test_26) ==="
date; uname -v
mountpoint -q $D || mount -t debugfs none $D

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

state() {
    echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
    echo "clk_cif_out: enable_count=$(cat $D/clk/clk_cif_out/clk_enable_count 2>/dev/null) rate=$(cat $D/clk/clk_cif_out/clk_rate 2>/dev/null) parent=$(cat $D/clk/clk_cif_out/clk_parent 2>/dev/null)"
    echo "pin mux (GPIO4_C0 = cif_clkout, GPIO4_B2 = powerdown):"
    grep -h -E "pin 144 |pin 138 " $D/pinctrl/*/pinmux-pins 2>/dev/null | sed 's/^/  /'
    echo "GPIO4 bank (fe770000) lines in use (debugfs):"
    awk '/^gpiochip/ {p = ($0 ~ /fe770000/)} p' $D/gpio 2>/dev/null | head -14 | sed 's/^/  /'
    for r in /sys/class/regulator/regulator.*; do
        case "$(cat $r/name 2>/dev/null)" in vcc2v8_dvp|vcc1v8_dvp|vcc_camera)
            echo "supply $(cat $r/name): $(cat $r/state)" ;;
        esac
    done
}

echo; echo "--- idle (sensor suspended) ---"
state

echo; echo "--- start stream in the background ---"
timeout 10 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null >/dev/null 2>&1 &
BG=$!
sleep 2
echo; echo "--- while streaming ---"
state
echo "sensor 0xf0/0xf1: $(i2cget -f -y 2 0x37 0xf0) $(i2cget -f -y 2 0x37 0xf1)"
echo "sensor 0xfc (clock/analog enable, driver writes 0x8e): $(i2cget -f -y 2 0x37 0xfc)"
echo "write test: 0x41 = 0x07 (page 0)"
i2cset -f -y 2 0x37 0xfe 0x00
i2cset -f -y 2 0x37 0x41 0x07
echo "read back 0x41: $(i2cget -f -y 2 0x37 0x41)   (0x07 = registers work)"
wait $BG
echo; echo "--- kernel log ---"; dmesg | grep -i -E "gc5035|rkcif|csi" | tail -10
echo "=== done ==="
