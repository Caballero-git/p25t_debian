#!/bin/bash
# test_27.sh - rear camera: is a second pin holding the sensor's core?
#
# test_26 (2026-10-07), during the stream: sensor clock clk_cif_out on at
# 24 MHz (xin24m), pin GPIO4_C0 muxed to cif-clk, powerdown GPIO4_B2 HIGH,
# all three supplies on, and 0xfc reads 0x8e - so the driver's start
# sequence DID reach the sensor. But a register in the paged area (0x41)
# does not keep a written value: the sensor's core is not running.
#
# Stock DT: the rear GC5035 lists only a powerdown pin; the front GC02M2
# has reset GPIO4_B0 and powerdown GPIO4_B3, and both modules carry the
# same module name (KYT-4877-V01). If the rear sensor's reset is wired to
# one of those front pins, it sits in reset now (the pins are unclaimed).
#
# While the stream runs, this drives B0, then B3, high and low in turn
# (gpioset holds the line for ~1 s) and after each step does the write /
# read-back test on 0x41 (page 0). Only the two front-camera pins and the
# camera sensor register are touched; on exit the pins are released again.
#
#   cd ~/tests
#   sudo bash test_27.sh | tee result_27.txt
# Needs gpiod (gpioset), i2c-tools, v4l-utils.

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v gpioset >/dev/null || { echo "ABORT: sudo apt install gpiod"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera second-pin test (test_27) ==="
date; uname -v
gpioset --version 2>&1 | head -1

CHIP=$(for c in /sys/bus/gpio/devices/gpiochip*; do
           readlink -f "$c" | grep -q fe770000 && basename "$c"; done | head -1)
echo "GPIO4 bank is $CHIP"
[ -n "$CHIP" ] || { echo "ABORT: GPIO4 chip not found"; exit 1; }

VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

wtest() {   # write/read-back test on 0x41, page 0
    i2cset -f -y 2 0x37 0xfe 0x00
    i2cset -f -y 2 0x37 0x41 0x07
    echo "    0x41 after writing 0x07: $(i2cget -f -y 2 0x37 0x41)   0xf0/0xf1: $(i2cget -f -y 2 0x37 0xf0) $(i2cget -f -y 2 0x37 0xf1)"
}

hold() {    # hold <line> <value>: drive the line, test, release
    if gpioset --version 2>&1 | grep -q "v2"; then
        gpioset -c "$CHIP" "$1=$2" &
    else
        gpioset --mode=signal "$CHIP" "$1=$2" &
    fi
    local P=$!
    sleep 0.5
    echo "  line $1 = $2:"
    wtest
    kill $P 2>/dev/null; wait $P 2>/dev/null
}

echo; echo "--- start stream in the background ---"
timeout 20 v4l2-ctl -d "$VID" --stream-mmap --stream-count=3 --stream-to=/dev/null >/dev/null 2>&1 &
BG=$!
sleep 2
echo "runtime PM: $(cat /sys/bus/i2c/devices/2-0037/power/runtime_status)"
echo "  baseline (B0, B3 untouched):"; wtest
echo; echo "--- GPIO4_B0 = line 8 (front reset in stock) ---"
hold 8 1
hold 8 0
echo; echo "--- GPIO4_B3 = line 11 (front powerdown in stock) ---"
hold 11 1
hold 11 0
echo; echo "--- both high ---"
if gpioset --version 2>&1 | grep -q "v2"; then
    gpioset -c "$CHIP" 8=1 11=1 &
else
    gpioset --mode=signal "$CHIP" 8=1 11=1 &
fi
P=$!; sleep 0.5; wtest; kill $P 2>/dev/null; wait $P 2>/dev/null

kill $BG 2>/dev/null; wait $BG 2>/dev/null
echo; echo "--- GPIO4 lines after the test (should be released) ---"
awk '/^gpiochip/ {p = ($0 ~ /fe770000/)} p' /sys/kernel/debug/gpio 2>/dev/null | head -10
echo "=== done ==="
