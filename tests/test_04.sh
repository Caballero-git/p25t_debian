#!/bin/bash
# test_04.sh - check the GPU (Panfrost/Mali Bifrost, patch 0014) probed
# cleanly, the vdd_gpu regulator is present, and a DRM/render device
# node showed up.

echo "=== GPU / Panfrost check (patch 0014) ==="
date

echo
echo "--- dmesg (gpu/panfrost/mali/vdd_gpu related) ---"
dmesg | grep -iE "panfrost|mali|gpu|vdd_gpu" || echo "(nothing matched)"

echo
echo "--- regulator present? (vdd_gpu) ---"
for d in /sys/class/regulator/regulator.*/; do
    name=$(cat "$d"name 2>/dev/null)
    if [ "$name" = "vdd_gpu" ]; then
        echo "$d name=$name state=$(cat "$d"state 2>/dev/null) microvolts=$(cat "$d"microvolts 2>/dev/null)"
    fi
done

echo
echo "--- DRM devices ---"
ls -l /sys/class/drm/ 2>/dev/null || echo "no /sys/class/drm/"
ls -l /dev/dri/ 2>/dev/null || echo "no /dev/dri/"

echo
echo "--- Panfrost devfreq (GPU DVFS) ---"
for d in /sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    echo "$d -> governor=$(cat "$d/governor" 2>/dev/null) cur_freq=$(cat "$d/cur_freq" 2>/dev/null) available=$(cat "$d/available_frequencies" 2>/dev/null)"
done

echo
echo "--- charger/battery sanity check (unaffected?) ---"
cat /sys/class/power_supply/rk817-battery/uevent 2>/dev/null | grep -E "STATUS|CAPACITY" || echo "no rk817-battery"

echo
echo "=== done ==="
