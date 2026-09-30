#!/bin/bash
# test_07.sh - why does the GSL3673 never start its firmware (status 0x0)?
#
# test_05 (with patch 0018): probe gets through init/reset and uploads the
# whole firmware, then reads status register 0xB0 = 0x00000000 instead of
# 0x5A5A5A5A ("firmware running"). Mainline's sequence differs from the
# vendor Android driver (gsl3673_800x1280.c, the source of our firmware
# table):
#   mainline: init, reset, load_fw (4-byte writes), startup,          check
#   vendor:   clr_reg, reset, load_fw (128-byte bursts), startup, reset, startup
# and the vendor's reset_chip() writes FOUR zero bytes to 0xBC where
# mainline writes one. This script replays the vendor sequence by hand:
#   A. only the vendor's final reset_chip + startup_chip, on the firmware
#      the failed probe already left in the chip. Cheap; if status becomes
#      0x5A5A5A5A the missing piece is that second reset+startup.
#   B. otherwise the complete vendor sequence from scratch, byte-for-byte
#      in the vendor's transfer format, built from the firmware file on
#      this tablet.
#
# Safety: same as test_06 - only 0x40 on i2c1 (fe5a0000), located by
# hardware address (0x40 on bus 0 is the CPU regulator), only if that device
# is the silead,gsl3673 node with no driver bound. The chip is only ever
# written what the vendor driver writes on every Android boot. Nothing on
# disk is changed. A reboot puts everything back.
#
# Run:  sudo bash test_07.sh | tee result_07.txt

set -u
ADDR=0x40
FW=/lib/firmware/silead/gsl3673-p25t.fw
FW_SHA=03f58171f31eb3995c0c54af0083581c59045e8baffae5acbfc6fb1821794022

echo "=== GSL3673 vendor start-up replay (test_07) ==="
date

[ "$(id -u)" -eq 0 ] || { echo "ABORT: run as: sudo bash test_07.sh | tee result_07.txt"; exit 1; }
command -v i2ctransfer >/dev/null || { echo "ABORT: i2c-tools missing (sudo apt install i2c-tools)"; exit 1; }

# --- locate i2c1 by hardware address, check the target --------------------
BUS=""
for a in /sys/bus/i2c/devices/i2c-*; do
    case "$(readlink -f "$a")" in */fe5a0000.i2c/*) BUS=${a##*/i2c-} ;; esac
done
[ -n "$BUS" ] || { echo "ABORT: i2c1 (fe5a0000) not found"; exit 1; }
DEV=/sys/bus/i2c/devices/$BUS-0040
if ! tr '\0' '\n' < "$DEV/of_node/compatible" 2>/dev/null | grep -qx 'silead,gsl3673'; then
    echo "ABORT: $DEV is not the silead,gsl3673 DT node - refusing to touch it"; exit 1
fi
if [ -L "$DEV/driver" ]; then
    echo "ABORT: a driver is bound to $DEV - nothing to debug"; exit 1
fi
echo "i2c1 (fe5a0000) is bus $BUS; target $DEV is silead,gsl3673, unbound"

# --- helpers --------------------------------------------------------------
w() { # w <description> <reg> <byte>... : one I2C write, vendor style (reg + data)
    local desc=$1; shift
    local out
    if out=$(i2ctransfer -y "$BUS" "w$#@$ADDR" "$@" 2>&1); then
        echo "  write $desc: OK"
    else
        echo "  write $desc: FAILED - $out"
    fi
}
ms() { sleep "$(printf '0.%03d' "$1")"; }
status_rs() { i2ctransfer -y "$BUS" w1@$ADDR 0xb0 r4 2>&1; }              # repeated start
status_2x() { i2ctransfer -y "$BUS" w1@$ADDR 0xb0 >/dev/null 2>&1 && \
              i2ctransfer -y "$BUS" r4@$ADDR 2>&1; }                         # vendor: separate write, read
show_status() { # show_status <label>
    echo "  status 0xB0 $1: $(status_rs)   (separate write/read: $(status_2x))"
}

reset_chip() {   # vendor reset_chip()
    w "0xE0 <- 0x88 (reset; a NACK here is expected)" 0xe0 0x88; ms 5
    w "0xE4 <- 0x04 (clock)"                          0xe4 0x04; ms 5
    w "0xBC <- 00 00 00 00 (4 bytes)"                 0xbc 0x00 0x00 0x00 0x00; ms 5
}
startup_chip() { # vendor startup_chip()
    w "0xE0 <- 0x00 (start)" 0xe0 0x00; ms 5
}
clr_reg() {      # vendor clr_reg()
    w "0xE0 <- 0x88 (reset; a NACK here is expected)" 0xe0 0x88; ms 20
    w "0x80 <- 0x03"                                  0x80 0x03; ms 5
    w "0xE4 <- 0x04 (clock)"                          0xe4 0x04; ms 5
    w "0xE0 <- 0x00"                                  0xe0 0x00; ms 20
}
check_running() { # 0 if status reads 5a 5a 5a 5a
    [ "$(status_rs)" = "0x5a 0x5a 0x5a 0x5a" ]
}

# --- A: vendor's final reset+startup on the already-loaded firmware ------
echo
echo "--- A: before anything ---"
show_status "now"
echo "--- A: vendor's final reset_chip + startup_chip ---"
reset_chip
startup_chip
ms 10;  show_status "+10 ms"
sleep 0.1; show_status "+~110 ms"
sleep 1;   show_status "+~1.1 s"
if check_running; then
    echo "RESULT A: firmware RUNNING after the extra reset+startup."
    echo "=> mainline is missing the vendor's second reset_chip+startup_chip after load_fw."
    exit 0
fi
echo "RESULT A: still not running -> full vendor sequence (B)."

# --- B: full vendor sequence from scratch ---------------------------------
echo
echo "--- B0: firmware file ---"
[ -r "$FW" ] || { echo "ABORT: cannot read $FW"; exit 1; }
if [ "$(sha256sum "$FW" | cut -d' ' -f1)" != "$FW_SHA" ]; then
    echo "ABORT: $FW checksum is not the expected $FW_SHA"; exit 1
fi
mapfile -t BY < <(od -An -v -tx1 -w1 "$FW" | tr -d ' ')
N=$(( ${#BY[@]} / 8 ))
echo "  $FW: ${#BY[@]} bytes, $N entries, checksum OK"

# Build the vendor's transfers: for every page, one 4-byte write to 0xF0,
# then the 32 data entries (offsets 0x00..0x7C) as ONE 128-byte burst
# starting at 0x00 - exactly what gsl_load_fw() sends with DMA_TRANS_LEN
# 0x20. Values go out in file byte order, as the vendor's fw2buf() does.
declare -a XFER=()
i=0; bad=""
while [ $i -lt "$N" ]; do
    b=$(( i * 8 ))
    off=${BY[$b]}
    [ "${BY[$b+1]}${BY[$b+2]}${BY[$b+3]}" = "000000" ] || { bad="entry $i: offset > 0xff"; break; }
    [ "$off" = "f0" ] || { bad="entry $i: expected a page write (0xf0), got 0x$off"; break; }
    XFER+=("0xf0 0x${BY[$b+4]} 0x${BY[$b+5]} 0x${BY[$b+6]} 0x${BY[$b+7]}")
    burst="0x00"
    for k in $(seq 0 31); do
        j=$(( i + 1 + k )); b=$(( j * 8 ))
        [ $j -lt "$N" ] || { bad="page at entry $i has fewer than 32 data entries"; break 2; }
        want=$(printf '%02x' $(( k * 4 )))
        [ "${BY[$b]}" = "$want" ] || { bad="entry $j: expected offset 0x$want, got 0x${BY[$b]}"; break 2; }
        burst+=" 0x${BY[$b+4]} 0x${BY[$b+5]} 0x${BY[$b+6]} 0x${BY[$b+7]}"
    done
    XFER+=("$burst")
    i=$(( i + 33 ))
done
[ -z "$bad" ] || { echo "ABORT: firmware layout not as expected ($bad) - not sending anything"; exit 1; }
echo "  built ${#XFER[@]} transfers ($(( ${#XFER[@]} / 2 )) pages x [page select + 128-byte burst])"

echo
echo "--- B1: clr_reg ---";   clr_reg
echo "--- B2: reset_chip ---"; reset_chip
echo "--- B3: load_fw (vendor burst format) ---"
fails=0; t0=$(date +%s%N)
for x in "${XFER[@]}"; do
    set -- $x
    if ! out=$(i2ctransfer -y "$BUS" "w$#@$ADDR" "$@" 2>&1); then
        fails=$((fails + 1))
        [ $fails -le 5 ] && echo "  FAILED transfer ($1 ... $# bytes): $out"
    fi
done
echo "  ${#XFER[@]} transfers in $(( ($(date +%s%N) - t0) / 1000000 )) ms, $fails failed"
echo "--- B4: startup_chip ---"; startup_chip
echo "--- B5: reset_chip ---";   reset_chip
echo "--- B6: startup_chip ---"; startup_chip
ms 10;     show_status "+10 ms"
sleep 0.1; show_status "+~110 ms"
sleep 1;   show_status "+~1.1 s"
if check_running; then
    echo "RESULT B: firmware RUNNING with the full vendor sequence."
    echo "=> the difference is in the load format / 0xBC write / 0x80 value, not only the extra reset."
else
    echo "RESULT B: still not running even with the vendor's exact sequence."
    echo "=> suspect the firmware table itself (not this panel's) or power/reset outside the chip."
fi

echo
echo "=== done (a reboot puts everything back to normal) ==="
