#!/bin/bash
# set_i2c1_speed.sh - try a bus speed for i2c1 (touchscreen + accelerometer)
# by editing the DTB on the card (fdtput), without a PC build.
#
# Why: the touchscreen firmware upload (4653 I2C writes) holds the boot up
# for ~3 s at the default 100 kHz (tests/test_20.sh measures it).
#
#   sudo bash set_i2c1_speed.sh show          current setting
#   sudo bash set_i2c1_speed.sh set <HZ>      e.g. set 400000, then reboot
#   sudo bash set_i2c1_speed.sh restore       back to the DTB as installed
#
# <HZ> is 100000 to 400000 (I2C fast mode is the limit for both chips).
# Only the active DTB /boot/firmware/rk3566-teclast-p25t.dtb is edited;
# the first "set" keeps a copy as rk3566-teclast-p25t.dtb.pre-i2c1, which
# "restore" puts back. The DTB line in CARD-SHA256SUMS is updated and the
# whole file checked. set-usb-role.sh would overwrite the edited DTB with a
# role copy - do not switch roles meanwhile; the final value goes into the
# DTS and a normal DTB build.
# If touch or the accelerometer stop working after the reboot: restore.
# Needs fdtput/fdtget (device-tree-compiler).

set -u
D=/boot/firmware
DTB=$D/rk3566-teclast-p25t.dtb
KEEP=$DTB.pre-i2c1
SUMS=$D/CARD-SHA256SUMS
NODE=/i2c@fe5a0000
MODE=${1:-show}

[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v fdtput >/dev/null || { echo "ABORT: fdtput missing - sudo apt install device-tree-compiler"; exit 1; }
[ -f "$DTB" ] || { echo "ABORT: $DTB not found"; exit 1; }
fdtget -l "$DTB" "$NODE" >/dev/null 2>&1 || { echo "ABORT: no $NODE in $DTB"; exit 1; }

show() {
    local v
    v=$(fdtget -t u "$DTB" "$NODE" clock-frequency 2>/dev/null) || v="not set (100000 default)"
    echo "active DTB i2c1 clock-frequency: $v"
}

fix_sums() {   # put the DTB's new hash into CARD-SHA256SUMS, then check all
    python3 - "$SUMS" "$DTB" <<'EOF'
import sys, hashlib, os
sums, dtb = sys.argv[1], sys.argv[2]
name = os.path.basename(dtb)
new = hashlib.sha256(open(dtb, 'rb').read()).hexdigest()
lines = open(sums).read().splitlines()
hit = 0
for i, l in enumerate(lines):
    parts = l.split()
    if len(parts) == 2 and parts[1] == name:
        lines[i] = new + "  " + name; hit += 1
if hit != 1:
    sys.exit(f"STOP: {name} found {hit} times in {sums}, not changed")
open(sums, 'w').write("\n".join(lines) + "\n")
print(f"CARD-SHA256SUMS: {name} -> {new}")
EOF
    ( cd "$D" && sha256sum -c "$SUMS" ) || { echo "STOP: checksum check failed"; exit 1; }
}

case "$MODE" in
show)
    show ;;
set)
    HZ=${2:-}
    case "$HZ" in ""|*[!0-9]*) echo "usage: sudo bash set_i2c1_speed.sh set <HZ>"; exit 1 ;; esac
    [ "$HZ" -ge 100000 ] && [ "$HZ" -le 400000 ] || { echo "ABORT: keep it between 100000 and 400000"; exit 1; }
    [ -f "$KEEP" ] || { cp -p "$DTB" "$KEEP" && echo "kept the installed DTB as $KEEP"; }
    echo -n "before: "; show
    fdtput -t u "$DTB" "$NODE" clock-frequency "$HZ"
    [ "$(fdtget -t u "$DTB" "$NODE" clock-frequency)" = "$HZ" ] || { echo "STOP: read-back differs"; exit 1; }
    echo -n "after:  "; show
    fix_sums
    sync
    echo "now: sudo reboot   (then: sudo bash test_20.sh | tee result_20_after.txt)" ;;
restore)
    [ -f "$KEEP" ] || { echo "nothing to restore ($KEEP missing)"; exit 1; }
    cp -p "$KEEP" "$DTB" && rm "$KEEP"
    echo -n "restored: "; show
    fix_sums
    sync
    echo "now: sudo reboot" ;;
*)
    echo "usage: sudo bash set_i2c1_speed.sh show | set <HZ> | restore"; exit 1 ;;
esac
