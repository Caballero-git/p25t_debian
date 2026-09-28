#!/bin/bash
# P25T test_01: vdd_cpu DVFS check (patch 0011).
# Run on the tablet (via ssh), output redirected to result_01.txt.
# Intentionally does not use `set -e`: a missing file or empty grep match
# is itself useful information, not a reason to abort early.

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "=== uname ==="
uname -r

echo
echo "=== regulator: is vdd_cpu present? ==="
VDD=""
for d in /sys/class/regulator/regulator.*/; do
    name=$(cat "${d}name" 2>/dev/null)
    echo "$d -> $name"
    if [ "$name" = "vdd_cpu" ]; then
        VDD="$d"
    fi
done
if [ -n "$VDD" ]; then
    echo "found vdd_cpu at: $VDD"
else
    echo "vdd_cpu NOT FOUND among regulators"
fi

echo
echo "=== dmesg: fan53555 / vdd_cpu / syr827 / cpufreq / opp lines ==="
dmesg | grep -iE "fan53555|vdd_cpu|syr827|cpufreq|opp"

echo
echo "=== cpufreq: available frequencies and governor ==="
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>&1
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>&1
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>&1

echo
echo "=== idle: freq and vdd_cpu voltage ==="
sleep 2
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>&1
if [ -n "$VDD" ]; then
    cat "${VDD}microvolts" 2>&1
fi

echo
echo "=== generating ~10s of load on all cores ==="
NPROC=$(nproc)
for i in $(seq 1 "$NPROC"); do
    ( timeout 10 sh -c 'while :; do :; done' & )
done
sleep 3

echo
echo "=== under load: freq and vdd_cpu voltage ==="
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>&1
if [ -n "$VDD" ]; then
    cat "${VDD}microvolts" 2>&1
fi

wait

echo
echo "=== back to idle (after load finished): freq and vdd_cpu voltage ==="
sleep 2
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>&1
if [ -n "$VDD" ]; then
    cat "${VDD}microvolts" 2>&1
fi

echo
echo "=== charger/battery sanity check (unrelated node, should be unaffected) ==="
ls /sys/class/power_supply/ 2>&1
cat /sys/class/power_supply/rk817-battery/uevent 2>&1 | grep -E "STATUS|CAPACITY"

echo
echo "=== done ==="
