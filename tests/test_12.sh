#!/bin/bash
# test_12.sh - patches 0021 + 0022: built-in speaker amplifier, headphone
# detect, polled accelerometer; LDO8/vccio6, vcc_camera and rear torch.
# Run after booting the kernel/DTB with both patches and
# CONFIG_SND_SOC_SIMPLE_AMPLIFIER=y.
#
#   sudo bash test_12.sh | tee result_12.txt              (headphones out)
#   sudo bash test_12.sh | tee result_12_hp.txt           (headphones in)
#
# Plays two short tones (headphone stage, which feeds the amplifier):
# the first with the speaker switch ON (you should hear it from the
# built-in speaker), the second with it OFF (silent speaker). Then puts
# the switch back ON. Then switches the torch on for 3 s and off again
# (watch the rear LED). Nothing else is changed.

set -u
echo "=== speaker amp + accelerometer after patch 0021 (test_12) ==="
date; uname -r
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }

echo; echo "--- 1. the IRQ storm is gone (expect: nothing) ---"
dmesg | grep -i "nobody cared" || echo "(no 'nobody cared' - good)"
grep -i "sc7a20" /proc/interrupts || echo "(no sc7a20 interrupt line - expected, it is polled now)"

echo; echo "--- 2. amplifier device and pin ---"
ls -d /sys/bus/platform/devices/*audio-amplifier* 2>/dev/null || echo "audio-amplifier device MISSING"
for d in /sys/bus/platform/devices/*audio-amplifier*; do
    [ -L "$d/driver" ] && echo "driver: $(basename "$(readlink -f "$d/driver")")" || echo "driver: none (CONFIG_SND_SOC_SIMPLE_AMPLIFIER missing?)"
done
command -v gpioinfo >/dev/null && for c in /sys/bus/gpio/devices/gpiochip*; do
    case "$(readlink -f "$c")" in *fe760000.gpio*) gpioinfo -c "$(basename "$c")" 2 ;; esac
done

echo; echo "--- 3. accelerometer still reads (polled) ---"
for d in /sys/bus/iio/devices/iio:device*; do
    case "$(cat "$d/name" 2>/dev/null)" in *sc7a20*|*accel*)
        echo "$d: $(cat "$d/name")  x=$(cat "$d/in_accel_x_raw") y=$(cat "$d/in_accel_y_raw") z=$(cat "$d/in_accel_z_raw")" ;;
    esac
done

echo; echo "--- 4. mixer controls ---"
CARD=$(awk '/RK817/ {print $1; exit}' /proc/asound/cards)
amixer -c "$CARD" controls | grep -i -E "Playback Mux|Internal Speakers|Headphones"
amixer -q -c "$CARD" cset name='Playback Mux' HP

echo; echo "--- 4b. headphone jack (GPIO3_A1) - run once without and once with headphones ---"
amixer -c "$CARD" cget name='Headphones Jack' 2>/dev/null | tail -1 || echo "(no 'Headphones Jack' control - hp-det not active?)"
grep -i "Headphone detection" /sys/kernel/debug/gpio 2>/dev/null || true

echo; echo "--- 5. tone 1: Internal Speakers Switch ON - listen to the speaker ---"
amixer -q -c "$CARD" cset name='Internal Speakers Switch' on
timeout 6 speaker-test -D plughw:"$CARD" -c 2 -t sine -f 440 -l 1 >/dev/null 2>&1
echo "--- tone 2: Internal Speakers Switch OFF - speaker should be silent ---"
amixer -q -c "$CARD" cset name='Internal Speakers Switch' off
timeout 6 speaker-test -D plughw:"$CARD" -c 2 -t sine -f 660 -l 1 >/dev/null 2>&1
amixer -q -c "$CARD" cset name='Internal Speakers Switch' on
echo "switch back ON: $(amixer -c "$CARD" cget name='Internal Speakers Switch' | tail -1)"
echo "Write next to the result: tone 1 heard? tone 2 silent?"

echo; echo "--- 6. patch 0022: rails and torch ---"
grep -E "vcc1v8_dvp|vcc_camera" /sys/kernel/debug/regulator/regulator_summary 2>/dev/null || \
    for r in /sys/class/regulator/regulator.*; do
        n=$(cat "$r/name"); case "$n" in vcc1v8_dvp|vcc_camera) echo "$n: $(cat "$r/state" 2>/dev/null) $(cat "$r/microvolts" 2>/dev/null)";; esac
    done
L=/sys/class/leds/white:flash
if [ -d "$L" ]; then
    echo ">>> torch ON for 3 s - look at the rear LED"
    echo 1 > "$L/brightness"; sleep 3; echo 0 > "$L/brightness"
    echo "torch off again (brightness $(cat "$L/brightness"))"
    echo "Write next to the result: torch lit?"
else
    echo "$L MISSING"; ls /sys/class/leds
fi
echo; echo "=== done ==="
