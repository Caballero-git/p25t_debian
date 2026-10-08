#!/bin/bash
# test_40.sh - RK817 rails: our voltages vs Android's (READ-ONLY)
#
# test_39 (2026-10-07): with 0xfc = 0x8f frames flow (HS clock bursts
# every frame, few receiver errors), but the picture is black level even
# facing a lamp, and the colour bars are a flat grey band with damaged
# 4-pixel groups. Bit 0 of 0xfc keeps the sensor's logic on the slow
# 24 MHz input; 0x8e (the PLL, ~88 MHz) freezes it. A logic that works
# slowly but dies when clocked fast = a core supply that is too LOW.
# The stock DT has the clue: RK817 LDO2 is named "vdda_0v9" but Android
# sets it to 1.2 V - the usual camera core (DVDD) voltage. If our boot
# leaves it at 0.9 V, that is the whole story.
# This reads every RK817 LDO: on/off and set voltage, next to Android's
# value. Nothing is written.
#
#   cd ~/tests
#   sudo bash test_40.sh | tee result_40.txt

set -u
PMIC=0x20
echo "=== RK817 rails vs Android (test_40, read-only) ==="
date; uname -v
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v i2cget >/dev/null || { echo "ABORT: i2c-tools missing"; exit 1; }
stop() { echo "STOP: $*"; exit 1; }
bus_of() {
    local a
    for a in /sys/bus/i2c/devices/i2c-*; do
        case "$(readlink -f "$a")" in */"$1".i2c/*) echo "${a##*/i2c-}"; return ;; esac
    done
}
compat_has() { tr '\0' '\n' < "$1/of_node/compatible" 2>/dev/null | grep -qx "$2"; }
B0=$(bus_of fdd40000); [ -n "$B0" ] || stop "i2c0 (fdd40000) not found"
compat_has "/sys/bus/i2c/devices/$B0-0020" rockchip,rk817 || stop "$B0-0020 is not the rk817 node"
rd() { i2cget -f -y "$B0" $PMIC "$1" b 2>/dev/null; }
msb=$(rd 0xed); lsb=$(rd 0xee)
[ $(( (msb << 8 | lsb) & 0xfff0 )) -eq $(( 0x8170 )) ] || stop "chip id $msb $lsb is not RK817"
echo "RK817 on bus $B0, chip id $msb $lsb"
EN2=$(rd 0xb2); EN3=$(rd 0xb3); EN4=$(rd 0xb4)
echo "enable registers: 0xB2 = $EN2 (LDO1-4), 0xB3 = $EN3 (LDO5-8), 0xB4 = $EN4 (LDO9)"
echo
printf "%-6s %-14s %-4s %-8s %-9s %s\n" rail "stock name" on "ours mV" "stock mV" ""
STOCK=(0 1800 1200 900 3300 1800 3300 1800 1800 2800)
NAME=(x vcca1v8_pmu vdda_0v9 vdda0v9_pmu vccio_acodec vccio_sd vcc3v3_pmu vcc_1v8 vcc1v8_dvp vcc2v8_dvp)
for n in 1 2 3 4 5 6 7 8 9; do
    reg=$(( 0xcc + 2 * (n - 1) ))
    v=$(rd $(printf "0x%02x" $reg))
    if [ $n -le 4 ]; then e=$(( (EN2 >> (n - 1)) & 1 ))
    elif [ $n -le 8 ]; then e=$(( (EN3 >> (n - 5)) & 1 ))
    else e=$(( EN4 & 1 )); fi
    mv=$(( 600 + (v & 0x7f) * 25 ))
    note=""; [ $mv -ne ${STOCK[$n]} ] && note="<-- DIFFERS"
    printf "LDO%-3s %-14s %-4s %-8s %-9s %s\n" $n ${NAME[$n]} $([ $e -eq 1 ] && echo yes || echo NO) "$mv" ${STOCK[$n]} "$note  (reg 0x$(printf %02x $reg) = $v)"
done
echo "=== done (nothing written) ==="
