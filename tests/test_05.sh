#!/bin/bash
# test_05.sh - check the touchscreen (Silead GSL3673, patch 0017) probed
# cleanly, loaded its firmware, and registered an input device. Two
# things flagged as unconfirmed in the DT (see docs/todo.org) are exactly
# what a failed/partial probe here would help pin down: the IRQ trigger
# flag and the power-gpios polarity.

echo "=== Touchscreen (Silead GSL3673, patch 0017) check ==="
date

echo
echo "--- firmware file present on the target? ---"
ls -l /lib/firmware/silead/gsl3673-p25t.fw 2>/dev/null || echo "MISSING - copy it there first, see todo.org"

echo
echo "--- dmesg (silead/touchscreen/gsl related) ---"
dmesg | grep -iE "silead|gsl3673|touchscreen|i2c.*0040|0-0040|1-0040" || echo "(nothing matched)"

echo
echo "--- i2c device bound? (silead on i2c1 @0x40) ---"
found=0
for bus in /sys/bus/i2c/devices/*-0040; do
    [ -e "$bus" ] || continue
    found=$((found + 1))
    echo "$bus"
    if [ -L "$bus/driver" ]; then
        echo "  driver: $(basename "$(readlink -f "$bus/driver")")"
    else
        echo "  driver: (none - not bound)"
    fi
done
[ "$found" -gt 0 ] || echo "(no device at address 0x40 on any bus)"

echo
echo "--- input devices ---"
cat /proc/bus/input/devices 2>/dev/null | grep -iA 5 "gsl\|silead\|touch" || echo "(no touchscreen-looking input device found)"
ls -l /dev/input/event* 2>/dev/null

echo
echo "--- quick interactive check (if a touchscreen event device showed up above) ---"
echo "Run manually, then touch the screen a few times, Ctrl-C to stop:"
echo "  sudo evtest /dev/input/eventN     (install with: sudo apt install evtest)"
echo "Or without evtest, raw event bytes should appear while touching:"
echo "  sudo cat /dev/input/eventN | xxd | head"

echo
echo "=== done ==="
