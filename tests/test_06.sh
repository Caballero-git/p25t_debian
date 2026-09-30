#!/bin/bash
# test_06.sh - pin down WHICH write of silead_ts_init() gets NACKed (-6).
#
# Background (test_05): the chip ID read works, then silead_ts_init()'s
# 4-write sequence fails with -6 (NACK). The kernel log can't say which
# of the 4 writes failed. This script:
#   A. asks the driver to probe again, now, long after boot. If it binds,
#      the problem is boot-time timing, not the init sequence itself.
#   B. otherwise replays the driver's exact init sequence by hand, one
#      write at a time with i2c-tools, and after the soft-reset write
#      polls the chip to measure how long it stays deaf.
#
# Safety: only ever talks to address 0x40 on i2c1 (the controller at
# fe5a0000), found by hardware address, never by bus number - 0x40 on
# bus 0 is the SYR837 CPU regulator. Aborts unless that device is our
# silead,gsl3673 DT node and no driver is bound to it. The writes are
# exactly the ones silead_ts_init() already makes on every boot.
#
# Run:  sudo bash test_06.sh | tee result_06.txt
# Needs i2c-tools (sudo apt install i2c-tools).

set -u
ADDR=0x40

echo "=== Touchscreen init replay (test_06) ==="
date

[ "$(id -u)" -eq 0 ] || { echo "ABORT: run as: sudo bash test_06.sh | tee result_06.txt"; exit 1; }

# --- locate i2c1 by hardware address --------------------------------------
BUS=""
for a in /sys/bus/i2c/devices/i2c-*; do
    case "$(readlink -f "$a")" in
        */fe5a0000.i2c/*) BUS=${a##*/i2c-} ;;
    esac
done
[ -n "$BUS" ] || { echo "ABORT: i2c1 (fe5a0000) not found"; exit 1; }
DEV=/sys/bus/i2c/devices/$BUS-0040
echo "i2c1 (fe5a0000) is bus $BUS; target $DEV"

if ! tr '\0' '\n' < "$DEV/of_node/compatible" 2>/dev/null | grep -qx 'silead,gsl3673'; then
    echo "ABORT: $DEV is not the silead,gsl3673 DT node - refusing to touch it"
    exit 1
fi
if [ -L "$DEV/driver" ]; then
    echo "ABORT: a driver is already bound to $DEV ($(basename "$(readlink -f "$DEV/driver")")) - nothing to debug"
    exit 1
fi
echo "OK: target is the silead,gsl3673 node, no driver bound"

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# --- A: re-probe now ------------------------------------------------------
echo
echo "--- A: re-probe via the driver, well after boot ---"
MARK=$(dmesg | wc -l)
echo "$BUS-0040" > /sys/bus/i2c/drivers/silead_ts/bind 2>/dev/null
sleep 2
dmesg | tail -n +"$((MARK + 1))" | grep -i silead || echo "(no new silead messages)"
if [ -L "$DEV/driver" ]; then
    echo "RESULT A: probe SUCCEEDED on retry -> boot-time timing problem, not the init sequence."
    echo "Check: ls /dev/input/ ; grep -i -A4 silead /proc/bus/input/devices"
    exit 0
fi
echo "RESULT A: re-probe failed too -> deterministic, going on to B."

# --- B: manual replay -----------------------------------------------------
command -v i2cset >/dev/null && command -v i2ctransfer >/dev/null || {
    echo "i2c-tools missing: sudo apt install i2c-tools, then run this again"; exit 1; }

read_id() { i2ctransfer -y "$BUS" w1@"$ADDR" 0xfc r4 2>&1; }
write_reg() { # $1 reg, $2 value, $3 description
    local out rc
    out=$(i2cset -y "$BUS" "$ADDR" "$1" "$2" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then echo "  write $1 <- $2  ($3): OK"
    else echo "  write $1 <- $2  ($3): FAILED - $out"; fi
    return $rc
}

echo
echo "--- B1: is the chip awake right now? (ID read, reg 0xFC) ---"
echo "  ID bytes: $(read_id)   (driver saw 0x50910000 = 0x00 0x00 0x91 0x50)"

echo
echo "--- B2: first write of silead_ts_init(): soft reset ---"
write_reg 0xe0 0x88 "RESET <- CMD_RESET"
T0=$(now_ms)

echo
echo "--- B3: poll ID read every ~10 ms for up to 1 s after the reset ---"
FIRST_OK=""; FAILS=0
for i in $(seq 1 100); do
    if out=$(read_id) && [[ $out == 0x* ]]; then
        FIRST_OK=$(( $(now_ms) - T0 )); break
    fi
    FAILS=$((FAILS + 1)); sleep 0.01
done
if [ -n "$FIRST_OK" ]; then
    echo "  chip answered again after ~${FIRST_OK} ms ($FAILS failed polls before). ID: $out"
else
    echo "  chip did NOT answer for 1 s after the reset write ($FAILS failed polls)"
fi

echo
echo "--- B4: rest of silead_ts_init(), 20 ms apart (driver uses 10-20 ms) ---"
sleep 0.02
write_reg 0x80 0x0a "TOUCH_NR <- 10 fingers"; sleep 0.02
write_reg 0xe4 0x04 "CLOCK <- 0x04";           sleep 0.02
write_reg 0xe0 0x00 "RESET <- CMD_START";      sleep 0.02

echo
echo "--- B5: final ID read ---"
echo "  ID bytes: $(read_id)"

echo
echo "=== done (a reboot puts everything back to normal) ==="
