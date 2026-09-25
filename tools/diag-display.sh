#!/bin/sh
# P25T display diagnostics. Run on the TABLET (USB console):  sh /boot/diag-display.sh
# Writes /boot/logs/diag-display.txt and runs 3 short visual tests.

O=/boot/logs/diag-display.txt
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

{
    echo "=== dri state";      cat /sys/kernel/debug/dri/*/state 2>&1
    echo "=== dri summary";    cat /sys/kernel/debug/dri/*/summary 2>&1
    echo "=== clocks";         grep -iE "vop|dsi|dphy|vpll|hpll|pll_|dclk|mipi" /sys/kernel/debug/clk/clk_summary 2>&1
    echo "=== gpio";           cat /sys/kernel/debug/gpio 2>&1
    echo "=== pinmux gpio3";   grep -iE "gpio3" /sys/kernel/debug/pinctrl/*/pinmux-pins 2>&1 | head -40
    echo "=== regulators";     cat /sys/kernel/debug/regulator/regulator_summary 2>&1
    echo "=== pm domains";     cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>&1
    echo "=== fb0";            cat /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/bits_per_pixel 2>&1
    echo "=== dmesg (display)"; dmesg | grep -iE "drm|dsi|dphy|panel|vop|jadard|backlight" 2>&1
    echo "=== DSI host registers (read-only, base 0xfe060000)"
    for off in 0x00 0x04 0x08 0x0c 0x10 0x14 0x2c 0x34 0x38 0x3c 0x40 0x44 0x48 0x4c 0x50 0x54 0x58 0x5c 0x60 0x64 0x68 0x94 0x98 0x9c 0xa0 0xa4 0xa8 0xac 0xb0 0xb4 0xb8 0xbc 0xc0; do
        printf "%s = %s\n" "$off" "$(devmem $((0xfe060000 + off)) 32 2>&1)"
    done
    echo "=== PHY_STATUS read 5 times"
    for i in 1 2 3 4 5; do devmem 0xfe0600b0 32; done
} > "$O" 2>&1
sync
echo "Diagnostics written to $O"

BL=/sys/class/backlight/backlight
FBSIZE=$((800 * 1280 * 4))

echo
echo "TEST 1 (10 s): random noise on the framebuffer. WATCH THE TABLET SCREEN."
dd if=/dev/urandom of=/dev/fb0 bs=$FBSIZE count=1 2>/dev/null
sleep 10

echo "TEST 2 (10 s): all white framebuffer."
tr '\000' '\377' < /dev/zero | dd of=/dev/fb0 bs=$FBSIZE count=1 2>/dev/null
sleep 10

echo "TEST 3 (12 s): backlight off/on 3 times."
for i in 1 2 3; do
    echo 0 > $BL/brightness; sleep 2
    echo 248 > $BL/brightness; sleep 2
done
echo 120 > $BL/brightness

echo
echo "Done. Tell Claude what you saw in tests 1, 2 and 3."
