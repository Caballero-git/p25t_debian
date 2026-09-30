#!/bin/bash
# test_08.sh - does the GSL3673 touchscreen need RK817 LDO9 (2.8 V)?
#
# test_07: even the vendor driver's exact start-up sequence leaves status
# register 0xB0 at 0x00000000 - the chip answers I2C but never runs its
# firmware. Android keeps RK817 LDO9 ("vcc2v8_dvp", 2.8 V) always-on with no
# consumer listed in the stock DT; the vendor touch driver requests no
# regulator at all; the stock U-Boot switches LDO9 on, our boot path does
# not (notes/p25t-boot10-findings.org). 2.8 V is the classic touch
# controller AVDD. Hypothesis: LDO9 powers the touch chip's analog/MCU side.
#
#   sudo bash test_08.sh          CHECK (default): read-only. Shows RK817 and
#                                 LDO9 state and the touchscreen state.
#   sudo bash test_08.sh apply    APPLY: only with Jose's explicit OK. Sets
#                                 LDO9 to 2.8 V and switches it on (Android's
#                                 own setting, already run once harmlessly in
#                                 the "rails" experiment), then asks the
#                                 silead driver to probe again.
#
# RK817 writes (APPLY only), both read back, stops at the first surprise:
#   0xDC <- 0x58   LDO9 voltage 2.8 V (0.6 V + 88 x 25 mV); only while LDO9 is off
#   0xB4 <- 0x11   bit 4 = write-enable for LDO9 only, bit 0 = LDO9 on.
#                  BOOST/OTG (bits 1,2) are untouched: their write-enable
#                  bits (5,6) are 0 in this write.
# Nothing is switched off; no DCDC register is touched. The Linux rk808 driver
# never manages LDO9 (no DT node), and its own writes to 0xB4 never carry
# LDO9's write-enable bit, so it can't undo this either. LDO9 stays on until a
# full power-off (the RK817 resets it to off, as in every boot so far).
#
# Run:  sudo bash test_08.sh | tee result_08.txt
#       sudo bash test_08.sh apply | tee result_08_apply.txt

set -u
MODE=${1:-check}
PMIC=0x20

echo "=== RK817 LDO9 / touchscreen power (test_08, mode: $MODE) ==="
date
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
case "$MODE" in check|apply) ;; *) echo "ABORT: mode must be 'check' or 'apply'"; exit 1 ;; esac
command -v i2cget >/dev/null || { echo "ABORT: i2c-tools missing"; exit 1; }

stop() { echo "STOP: $* (nothing further written)"; exit 1; }
bus_of() { # bus_of <controller address> -> bus number, by hardware address only
    local a
    for a in /sys/bus/i2c/devices/i2c-*; do
        case "$(readlink -f "$a")" in */"$1".i2c/*) echo "${a##*/i2c-}"; return ;; esac
    done
}
compat_has() { tr '\0' '\n' < "$1/of_node/compatible" 2>/dev/null | grep -qx "$2"; }

# --- RK817 on i2c0 (fdd40000) --------------------------------------------
B0=$(bus_of fdd40000); [ -n "$B0" ] || stop "i2c0 (fdd40000) not found"
PDEV=/sys/bus/i2c/devices/$B0-0020
compat_has "$PDEV" rockchip,rk817 || stop "$PDEV is not the rockchip,rk817 node"
rd() { i2cget -f -y "$B0" $PMIC "$1" b 2>/dev/null; }
msb=$(rd 0xed); lsb=$(rd 0xee)
[ -n "$msb" ] && [ -n "$lsb" ] || stop "cannot read RK817 chip id"
[ $(( (msb << 8 | lsb) & 0xfff0 )) -eq $(( 0x8170 )) ] || stop "chip id $msb $lsb is not RK817"
echo "RK817 on bus $B0 (fdd40000), chip id $msb $lsb"

B4=$(rd 0xb4); DC=$(rd 0xdc)
[ -n "$B4" ] && [ -n "$DC" ] || stop "cannot read 0xB4/0xDC"
LDO9_ON=$(( B4 & 0x01 ))
echo "  0xB4 = $B4  -> LDO9 $([ $LDO9_ON -eq 1 ] && echo ON || echo off), BOOST $(( (B4 >> 1) & 1 )), OTG $(( (B4 >> 2) & 1 ))"
echo "  0xDC = $DC  -> LDO9 set to $(( 600 + (DC & 0x7f) * 25 )) mV"

# --- touchscreen on i2c1 (fe5a0000) --------------------------------------
B1=$(bus_of fe5a0000); [ -n "$B1" ] || stop "i2c1 (fe5a0000) not found"
TDEV=/sys/bus/i2c/devices/$B1-0040
compat_has "$TDEV" silead,gsl3673 || stop "$TDEV is not the silead,gsl3673 node"
if [ -L "$TDEV/driver" ]; then echo "touchscreen $TDEV: driver BOUND"; else echo "touchscreen $TDEV: not bound"; fi
echo "  status 0xB0: $(i2ctransfer -y "$B1" w1@0x40 0xb0 r4 2>&1)"

if [ "$MODE" = check ]; then
    echo
    echo "=== check done - nothing was written ==="
    exit 0
fi

# --- APPLY ----------------------------------------------------------------
echo
echo "--- APPLY: LDO9 2.8 V on ---"
[ -L "$TDEV/driver" ] && stop "touchscreen driver already bound - nothing to test"
if [ $LDO9_ON -eq 1 ]; then
    echo "  LDO9 is already on - no RK817 write needed"
    [ $(( DC & 0x7f )) -eq $(( 0x58 )) ] || stop "LDO9 is on but not at 2.8 V ($DC) - not touching it"
else
    [ $(( DC & 0x7f )) -eq $(( 0x30 )) ] || [ $(( DC & 0x7f )) -eq $(( 0x58 )) ] || \
        stop "0xDC = $DC is neither the reset value 0x30 nor 0x58 - state not as expected"
    i2cset -f -y "$B0" $PMIC 0xdc 0x58 b || stop "write 0xDC failed"
    v=$(rd 0xdc); [ $(( v & 0x7f )) -eq $(( 0x58 )) ] || stop "0xDC read back $v, expected 0x58"
    echo "  0xDC <- 0x58: read back $v (2.8 V)"
    i2cset -f -y "$B0" $PMIC 0xb4 0x11 b || stop "write 0xB4 failed"
    v=$(rd 0xb4)
    [ $(( v & 0x01 )) -eq 1 ] || stop "0xB4 read back $v - LDO9 did not switch on"
    [ $(( v & 0x06 )) -eq $(( B4 & 0x06 )) ] || stop "0xB4 read back $v - BOOST/OTG changed (was $B4)!"
    echo "  0xB4 <- 0x11: read back $v (LDO9 on, BOOST/OTG unchanged)"
fi
sleep 0.2
echo "  status 0xB0 with LDO9 on, before probe: $(i2ctransfer -y "$B1" w1@0x40 0xb0 r4 2>&1)"

echo
echo "--- probe the silead driver again (patch 0018 kernel) ---"
MARK=$(dmesg | wc -l)
echo "$B1-0040" > /sys/bus/i2c/drivers/silead_ts/bind 2>/dev/null
sleep 6   # the firmware upload alone takes ~3.5 s
dmesg | tail -n +"$((MARK + 1))" | grep -i silead || echo "(no new silead messages)"
if [ -L "$TDEV/driver" ]; then
    echo "RESULT: driver BOUND with LDO9 on -> LDO9 powers the touchscreen."
    grep -i -B1 -A5 silead /proc/bus/input/devices
    echo "Next: sudo evtest  (pick the Silead device, touch the four corners, Ctrl-C)"
else
    echo "RESULT: still not bound with LDO9 on -> LDO9 is not (the only) missing piece."
    echo "  status 0xB0 now: $(i2ctransfer -y "$B1" w1@0x40 0xb0 r4 2>&1)"
fi
echo
echo "=== done (LDO9 stays on until the next full power-off) ==="
