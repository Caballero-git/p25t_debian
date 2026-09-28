#!/bin/bash
# test_03.sh - check the SC7A20 accelerometer (patch 0013) probed cleanly,
# and dump its raw axis values via the IIO sysfs interface so they can be
# sanity-checked against the tablet's physical orientation (the mount-matrix
# in patch 0013 is a best-effort translation of stock's Android flags, not
# verified against real driver source).

echo "=== SC7A20 accelerometer check (patch 0013) ==="
date

echo
echo "--- dmesg (accel/i2c1/st_accel related) ---"
dmesg | grep -iE "i2c1|fe5a0000|accel|sc7a20|st_accel|iio" || echo "(nothing matched)"

echo
echo "--- IIO devices present? ---"
ls -l /sys/bus/iio/devices/ 2>/dev/null || echo "no /sys/bus/iio/devices/"

echo
echo "--- looking for the accel IIO device ---"
for d in /sys/bus/iio/devices/iio:device*; do
    [ -d "$d" ] || continue
    name=$(cat "$d/name" 2>/dev/null)
    echo "$d -> name: $name"
done

ACCEL_DEV=""
for d in /sys/bus/iio/devices/iio:device*; do
    [ -d "$d" ] || continue
    name=$(cat "$d/name" 2>/dev/null)
    case "$name" in
        *sc7a20*|*accel*) ACCEL_DEV="$d" ;;
    esac
done

if [ -z "$ACCEL_DEV" ]; then
    echo
    echo "No matching accel IIO device found - probe likely failed. Check the"
    echo "dmesg output above for errors from st_accel/i2c."
else
    echo
    echo "--- using $ACCEL_DEV ---"
    echo "raw scale/available files:"
    ls "$ACCEL_DEV" | grep -iE "raw|scale|mount"
    echo
    echo "Reading axes 3 times, 1s apart - tilt the tablet between reads if"
    echo "you want to see the values change:"
    for i in 1 2 3; do
        echo "--- reading $i ---"
        for axis in x y z; do
            f="$ACCEL_DEV/in_accel_${axis}_raw"
            if [ -f "$f" ]; then
                printf "%s: %s\n" "$axis" "$(cat "$f" 2>/dev/null)"
            fi
        done
        sleep 1
    done
fi

echo
echo "=== done ==="
