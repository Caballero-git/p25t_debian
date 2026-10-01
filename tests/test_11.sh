#!/bin/bash
# test_11.sh - built-in speaker amplifier and camera torch: find the pins.
#
# From the stock device tree (Firmware/dt/boot-0-0x6c0fe00.dts) and the
# Android boot log in the bugreport:
#  - rk817 codec: use-ext-amplifier; spk-ctl-gpios = GPIO3_A2, active high.
#  - accelerometer "gs_sc7a20": irq-gpio also GPIO3_A2, but irq_enable = 0
#    (polled). So in Android the pin drives the speaker amp; the accel
#    IRQ was never used. Our patch 0013 gave GPIO3_A2 to the accel as an
#    IRQ, which keeps the amp off.
#  - flash-rgb13h "gpio-flash" (rear camera LED): enable-gpio = GPIO4_A6,
#    active high.
#
#   sudo bash test_11.sh           CHECK (default): read-only. Who owns the
#                                  two pins, accel IRQ count, mixer state.
#   sudo bash test_11.sh speaker   With Jose's OK: unbinds the accel driver
#                                  (frees GPIO3_A2), drives GPIO3_A2 high,
#                                  plays a 3 s tone with Playback Mux=HP,
#                                  then puts everything back. Listen.
#                                  (Run 1 used Mux=SPK: only a click. The
#                                  Rockchip driver, with use-ext-amplifier,
#                                  feeds the external amp from the HP stage
#                                  and keeps the internal class D off.)
#   sudo bash test_11.sh torch     With Jose's OK: GPIO4_A7 high (stock
#                                  "vcc_camera" fixed regulator, always on
#                                  in Android), then GPIO4_A6 high for 3 s,
#                                  then both low. Look at the rear LED.
# Both writes are what Android itself does to these pins. Nothing else is
# touched. Needs the gpiod package (gpiodetect/gpioinfo/gpioset v2).
#
# Run:  sudo bash test_11.sh | tee result_11.txt
#       sudo bash test_11.sh speaker | tee result_11_speaker.txt
#       sudo bash test_11.sh torch | tee result_11_torch.txt

set -u
MODE=${1:-check}
echo "=== speaker amp / torch pins (test_11, mode: $MODE) ==="
date
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
case "$MODE" in check|speaker|torch) ;; *) echo "ABORT: mode must be check, speaker or torch"; exit 1 ;; esac
command -v gpioset >/dev/null || { echo "ABORT: install gpiod first:  sudo apt install gpiod"; exit 1; }

# find gpiochip by its controller address (never by number)
chip_of() {
    for c in /sys/bus/gpio/devices/gpiochip*; do
        case "$(readlink -f "$c")" in *"$1"*) basename "$c"; return ;; esac
    done
}
CHIP3=$(chip_of fe760000.gpio)   # gpio3
CHIP4=$(chip_of fe770000.gpio)   # gpio4
echo "gpio3 (fe760000) = ${CHIP3:-NOT FOUND}, gpio4 (fe770000) = ${CHIP4:-NOT FOUND}"
[ -n "$CHIP3" ] && [ -n "$CHIP4" ] || { echo "ABORT: gpio controllers not found"; exit 1; }

ACC=$(for d in /sys/bus/i2c/devices/*-0019; do [ -e "$d" ] && echo "$d"; done | head -1)
CARD=$(awk '/RK817|rk817/ {print $1; exit}' /proc/asound/cards)
mux_numid() { amixer -c "$CARD" controls 2>/dev/null | awk -F'[=,]' "/Playback Mux/ {print \$2; exit}"; }

echo; echo "--- GPIO3_A2 (line 2) and GPIO4_A6 (line 6) owners ---"
gpioinfo -c "$CHIP3" 2 2>&1 | head -3
gpioinfo -c "$CHIP4" 6 2>&1 | head -3
echo; echo "--- accelerometer ---"
echo "device: ${ACC:-none}  driver: $([ -n "$ACC" ] && [ -L "$ACC/driver" ] && basename "$(readlink -f "$ACC/driver")" || echo none)"
grep -i -E "gpio3|sc7a20|accel|st_accel|0019" /proc/interrupts || echo "(no accel line in /proc/interrupts)"
echo "spurious-IRQ reports this boot (a level-low IRQ on a pin that is really an"
echo "output held low would fire 100000 times and then be disabled):"
dmesg | grep -i -A3 "nobody cared" | head -8 || true
echo; echo "--- sound card / mux ---"
cat /proc/asound/cards
N=$(mux_numid); echo "Playback Mux numid: ${N:-not found}"
[ -n "$N" ] && amixer -c "$CARD" cget numid="$N"

if [ "$MODE" = speaker ]; then
    [ -n "$ACC" ] && [ -n "$N" ] || { echo "ABORT: accel device or mux control missing"; exit 1; }
    DRV=$(readlink -f "$ACC/driver"); DEV=$(basename "$ACC")
    echo; echo ">>> unbind $DEV from $(basename "$DRV")"
    echo "$DEV" > "$DRV/unbind" || { echo "ABORT: unbind failed"; exit 1; }
    sleep 0.5
    echo ">>> GPIO3_A2 high"
    gpioset -c "$CHIP3" 2=1 & GP=$!
    sleep 0.5
    amixer -q -c "$CARD" cset numid="$N" HP
    echo ">>> tone for about 3 s, Playback Mux=HP - listen to the built-in speaker"
    timeout 6 speaker-test -D plughw:"$CARD" -c 2 -t sine -f 440 -l 1 2>&1 | grep -i -E "error|rate|channels" | head -5
    echo ">>> restore: mux HP, release pin, re-bind accel"
    amixer -q -c "$CARD" cset numid="$N" HP
    kill "$GP"; wait "$GP" 2>/dev/null
    gpioset -c "$CHIP3" -t0 2=0   # leave it low: a released line keeps its last level
    echo "$DEV" > "$DRV/bind" && echo "accel re-bound" || { echo "WARNING: re-bind failed (a reboot restores it):"; dmesg | tail -4; }
    amixer -c "$CARD" cget numid="$N" | tail -1
    gpioinfo -c "$CHIP3" 2 2>&1 | head -2
    echo "Did you hear the tone from the built-in speaker? Write yes/no next to the result."
fi

if [ "$MODE" = torch ]; then
    gpioinfo -c "$CHIP4" 6 | grep -q 'consumer=' && { echo "ABORT: GPIO4_A6 is claimed by someone - not touching it"; exit 1; }
    gpioinfo -c "$CHIP4" 7 | grep -q 'consumer=' && { echo "ABORT: GPIO4_A7 is claimed by someone - not touching it"; exit 1; }
    echo; echo ">>> GPIO4_A7 high (vcc_camera), then GPIO4_A6 high for 3 s - look at the rear camera LED"
    timeout 4 gpioset -c "$CHIP4" 7=1 6=1
    gpioset -c "$CHIP4" -t0 6=0 7=0   # both off again (a released line keeps its last level)
    gpioinfo -c "$CHIP4" 6 2>&1 | head -2
    gpioinfo -c "$CHIP4" 7 2>&1 | head -2
    echo "Did the LED light? Write yes/no next to the result."
fi
echo; echo "=== done ==="
