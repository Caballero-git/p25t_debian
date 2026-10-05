#!/bin/bash
# test_20.sh - how long does the touchscreen hold up the boot?
#
# The Silead driver is built in and probes during kernel start-up; it
# uploads the 37 KB firmware as 4653 small I2C writes before the boot can
# go on. i2c1 runs at the default 100 kHz (no clock-frequency in our DT);
# the vendor driver used 350 kHz. Estimate: ~3 s at 100 kHz, ~1.3 s at
# 400 kHz. The PineTab2 (same SC7A20 accelerometer on its i2c bus) runs
# that bus at 400 kHz.
#
# Read-only. Prints:
#  - i2c1's clock-frequency in the running DT (none = 100 kHz)
#  - when the touchscreen is ready ("input: silead_ts") and how long after
#    its first log line (mostly the firmware upload)
#  - systemd-analyze (kernel + userspace boot time)
#  - accelerometer and touch still alive (same bus)
#
#   sudo bash test_20.sh | tee result_20.txt     (sudo: dmesg and systemd-analyze)
# Run once before and once after changing the bus speed.

set -u
echo "=== touchscreen boot delay (test_20) ==="
date; uname -v

echo; echo "--- i2c1 (fe5a0000) bus speed in the running DT ---"
F=/proc/device-tree/i2c@fe5a0000/clock-frequency
if [ -r "$F" ]; then
    echo "clock-frequency = $(od -An -tu4 --endian=big "$F" | tr -d ' ') Hz"
else
    echo "clock-frequency not set -> 100000 Hz (default)"
fi

echo; echo "--- kernel log around the touchscreen probe ---"
LOG=$(sudo -n dmesg 2>/dev/null || dmesg 2>/dev/null)
[ -n "$LOG" ] || { echo "cannot read dmesg - run with sudo"; exit 1; }
echo "$LOG" | grep -n -B2 -A1 "input: silead_ts" | head -8
echo "$LOG" | python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
ts = lambda l: float(re.match(r"\[\s*([0-9.]+)\]", l).group(1))
first = next((ts(l) for l in lines if "silead_ts" in l), None)
done = next((ts(l) for l in lines if "input: silead_ts" in l), None)
if done is None:
    print("no \"input: silead_ts\" line found")
else:
    print(f"touchscreen ready at {done:.2f} s after kernel start")
    if first is not None and first < done:
        print(f"from its first log line ({first:.2f} s): {done - first:.2f} s  (mostly the firmware upload)")
'

echo; echo "--- boot time ---"
systemd-analyze 2>/dev/null | head -2 || echo "(systemd-analyze not available)"

echo; echo "--- same bus still fine? ---"
for d in /sys/bus/iio/devices/iio:device*; do
    case "$(cat "$d/name" 2>/dev/null)" in *sc7a20*)
        echo "accelerometer: x=$(cat "$d/in_accel_x_raw") y=$(cat "$d/in_accel_y_raw") z=$(cat "$d/in_accel_z_raw")" ;;
    esac
done
grep -i -A4 "silead_ts" /proc/bus/input/devices | grep -E "^N:|^H:" | head -2
echo "Touch the screen once while this prints, then check that the touch works as usual."
echo; echo "=== done ==="
