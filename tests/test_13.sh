#!/bin/bash
# test_13.sh - torch: is the GPIO4 bank unpowered? (RK817 LDO8 = vccio6)
#
# Android: the flashlight works (2026-10-01). test_11 drove GPIO4_A6
# (stock flash-rgb13h enable) and GPIO4_A7 (stock vcc_camera) high: no
# light. Stock DT: pmu-io-domains vccio6-supply = LDO8 "vcc1v8_dvp",
# 1.8 V, always-on. Our boot leaves LDO8 off (hardware.org, rails table),
# so the I/O bank those pins live in may have no supply at all - the
# pins cannot drive anything. The cameras' pwdn/reset pins (GPIO4_B0,
# B2, B3) are in the same place, so this matters beyond the torch.
#
#   sudo bash test_13.sh          CHECK (default): read-only. RK817 LDO8
#                                 state and voltage, GPIO4 pin owners.
#   sudo bash test_13.sh apply    With Jose's explicit OK (RK817 write):
#                                 LDO8 to 1.8 V (stock value) and on, then
#                                 GPIO4_A7 + GPIO4_A6 high for 3 s, then
#                                 both pins low again. LDO8 stays on until
#                                 the next full power-off (the RK817 resets
#                                 it), exactly as in the "rails" experiment.
#
# RK817 writes (APPLY only), each read back, stops at the first surprise:
#   0xDA <- 0x30   LDO8 voltage 1.8 V (0.6 V + 48 x 25 mV); only while off
#   0xB3 <- 0x88   bit 7 = write-enable for LDO8 only, bit 3 = LDO8 on.
#                  LDO5/6/7 (bits 0-2) are untouched: their write-enable
#                  bits (4-6) are 0 in this write.
# Needs i2c-tools and gpiod.
#
# Run:  sudo bash test_13.sh | tee result_13.txt
#       sudo bash test_13.sh apply | tee result_13_apply.txt

set -u
MODE=${1:-check}
PMIC=0x20
echo "=== RK817 LDO8 (vccio6) / torch (test_13, mode: $MODE) ==="
date
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
case "$MODE" in check|apply) ;; *) echo "ABORT: mode must be 'check' or 'apply'"; exit 1 ;; esac
command -v i2cget >/dev/null || { echo "ABORT: i2c-tools missing"; exit 1; }
command -v gpioset >/dev/null || { echo "ABORT: gpiod missing (sudo apt install gpiod)"; exit 1; }

stop() { echo "STOP: $* (nothing further written)"; exit 1; }
bus_of() {
    local a
    for a in /sys/bus/i2c/devices/i2c-*; do
        case "$(readlink -f "$a")" in */"$1".i2c/*) echo "${a##*/i2c-}"; return ;; esac
    done
}
compat_has() { tr '\0' '\n' < "$1/of_node/compatible" 2>/dev/null | grep -qx "$2"; }
chip_of() {
    for c in /sys/bus/gpio/devices/gpiochip*; do
        case "$(readlink -f "$c")" in *"$1"*) basename "$c"; return ;; esac
    done
}

B0=$(bus_of fdd40000); [ -n "$B0" ] || stop "i2c0 (fdd40000) not found"
PDEV=/sys/bus/i2c/devices/$B0-0020
compat_has "$PDEV" rockchip,rk817 || stop "$PDEV is not the rockchip,rk817 node"
rd() { i2cget -f -y "$B0" $PMIC "$1" b 2>/dev/null; }
msb=$(rd 0xed); lsb=$(rd 0xee)
[ $(( (msb << 8 | lsb) & 0xfff0 )) -eq $(( 0x8170 )) ] || stop "chip id $msb $lsb is not RK817"
echo "RK817 on bus $B0 (fdd40000), chip id $msb $lsb"

B3=$(rd 0xb3); DA=$(rd 0xda)
[ -n "$B3" ] && [ -n "$DA" ] || stop "cannot read 0xB3/0xDA"
LDO8_ON=$(( (B3 >> 3) & 1 ))
echo "  0xB3 = $B3 -> LDO5 $(( B3 & 1 )), LDO6 $(( (B3 >> 1) & 1 )), LDO7 $(( (B3 >> 2) & 1 )), LDO8 $LDO8_ON"
echo "  0xDA = $DA -> LDO8 set to $(( 600 + (DA & 0x7f) * 25 )) mV"

CHIP4=$(chip_of fe770000.gpio); [ -n "$CHIP4" ] || stop "gpio4 controller not found"
echo "gpio4 = $CHIP4"
for l in 6 7 8 10 11; do gpioinfo -c "$CHIP4" $l 2>&1 | head -1; done

if [ "$MODE" = check ]; then echo; echo "=== check done - nothing was written ==="; exit 0; fi

echo; echo "--- APPLY: LDO8 1.8 V on ---"
for l in 6 7; do gpioinfo -c "$CHIP4" $l | grep -q 'consumer=' && stop "GPIO4 line $l is claimed by someone"; done
if [ $LDO8_ON -eq 1 ]; then
    echo "  LDO8 is already on"
    [ $(( DA & 0x7f )) -eq $(( 0x30 )) ] || stop "LDO8 is on but not at 1.8 V ($DA) - not touching it"
else
    i2cset -f -y "$B0" $PMIC 0xda 0x30 b || stop "write 0xDA failed"
    v=$(rd 0xda); [ $(( v & 0x7f )) -eq $(( 0x30 )) ] || stop "0xDA read back $v, expected 0x30"
    echo "  0xDA <- 0x30: read back $v (1.8 V)"
    i2cset -f -y "$B0" $PMIC 0xb3 0x88 b || stop "write 0xB3 failed"
    v=$(rd 0xb3)
    [ $(( (v >> 3) & 1 )) -eq 1 ] || stop "0xB3 read back $v - LDO8 did not switch on"
    [ $(( v & 0x07 )) -eq $(( B3 & 0x07 )) ] || stop "0xB3 read back $v - LDO5/6/7 changed (was $B3)!"
    echo "  0xB3 <- 0x88: read back $v (LDO8 on, LDO5/6/7 unchanged)"
fi
sleep 0.2
echo; echo ">>> GPIO4_A7 + GPIO4_A6 high for 3 s - look at the rear LED"
timeout 4 gpioset -c "$CHIP4" 7=1 6=1
gpioset -c "$CHIP4" -t0 6=0 7=0
for l in 6 7; do gpioinfo -c "$CHIP4" $l 2>&1 | head -1; done
echo "Did the LED light? Write yes/no next to the result."
echo; echo "=== done (LDO8 stays on until the next full power-off) ==="
