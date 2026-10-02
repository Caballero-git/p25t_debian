#!/bin/bash
# tune_panel.sh - try panel line timings by editing the DTB on the card
# (needs patches 0024 + 0025: the jadard driver takes its mode from the
# panel-timing node of the DT). No kernel rebuild; a reboot per try.
#
# Why: with the stock timing (hfp 18, hsync 18, hbp 18) every panel line
# shows ~3 px late (tests/test_18.sh). The obvious correction (hbp 15,
# hfp 21: data 3 px earlier) is tried here first; further values by
# trying, keeping hfp + hbp = 36 (same line length, same refresh).
#
#   sudo bash tune_panel.sh show             current values (active DTB)
#   sudo bash tune_panel.sh set <HFP> <HBP>  write them, then reboot
#   sudo bash tune_panel.sh restore          back to the DTB as installed
#
# <HFP> and <HBP> are numbers of pixels (e.g. set 15 21). hsync-len (18)
# and the vertical values are not touched.
#
# Only the active DTB /boot/firmware/rk3566-teclast-p25t.dtb is edited;
# the first "set" keeps a copy as rk3566-teclast-p25t.dtb.pre-tune, which
# "restore" puts back. The DTB line in CARD-SHA256SUMS is updated each
# time and the whole file checked. set-usb-role.sh would overwrite the
# tuned DTB with a role copy - do not switch roles while tuning; the
# final values go into the DTS (patch 0025) and a normal DTB build.
#
# Needs fdtput/fdtget: sudo apt install device-tree-compiler

set -u
D=/boot/firmware
DTB=$D/rk3566-teclast-p25t.dtb
KEEP=$DTB.pre-tune
SUMS=$D/CARD-SHA256SUMS
NODE=/dsi@fe060000/panel@0/panel-timing
MODE=${1:-show}

[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v fdtput >/dev/null || { echo "ABORT: fdtput missing - sudo apt install device-tree-compiler"; exit 1; }
[ -f "$DTB" ] || { echo "ABORT: $DTB not found"; exit 1; }
fdtget "$DTB" "$NODE" hback-porch >/dev/null 2>&1 || { echo "ABORT: no $NODE in $DTB (patch 0025 not installed?)"; exit 1; }

show() {
    local f h s b v
    f=$(fdtget "$DTB" "$NODE" hfront-porch); s=$(fdtget "$DTB" "$NODE" hsync-len); b=$(fdtget "$DTB" "$NODE" hback-porch)
    h=$(fdtget "$DTB" "$NODE" hactive); v=$(( $(fdtget "$DTB" "$NODE" vactive) + $(fdtget "$DTB" "$NODE" vfront-porch) + $(fdtget "$DTB" "$NODE" vsync-len) + $(fdtget "$DTB" "$NODE" vback-porch) ))
    echo "active DTB: hfp $f  hsync $s  hbp $b  -> line $(( h + f + s + b )) px, frame $(( (h + f + s + b) * v )) px, $(( $(fdtget "$DTB" "$NODE" clock-frequency) / ((h + f + s + b) * v) )) Hz"
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
    [ $# -eq 3 ] || { echo "usage: sudo bash tune_panel.sh set <HFP> <HBP>"; exit 1; }
    HFP=$2; HBP=$3
    case "$HFP$HBP" in *[!0-9]*) echo "ABORT: numbers only"; exit 1 ;; esac
    [ "$HFP" -ge 2 ] && [ "$HFP" -le 120 ] && [ "$HBP" -ge 2 ] && [ "$HBP" -le 120 ] \
        || { echo "ABORT: keep both between 2 and 120"; exit 1; }
    [ -f "$KEEP" ] || { cp -p "$DTB" "$KEEP" && echo "kept the installed DTB as $KEEP"; }
    echo -n "before: "; show
    fdtput -t u "$DTB" "$NODE" hfront-porch "$HFP"
    fdtput -t u "$DTB" "$NODE" hback-porch "$HBP"
    [ "$(fdtget "$DTB" "$NODE" hfront-porch)" = "$HFP" ] && [ "$(fdtget "$DTB" "$NODE" hback-porch)" = "$HBP" ] \
        || { echo "STOP: read-back differs"; exit 1; }
    echo -n "after:  "; show
    fix_sums
    sync
    echo "now: sudo reboot   (then sudo bash test_18.sh)" ;;
restore)
    [ -f "$KEEP" ] || { echo "nothing to restore ($KEEP missing)"; exit 1; }
    cp -p "$KEEP" "$DTB" && rm "$KEEP"
    echo -n "restored: "; show
    fix_sums
    sync
    echo "now: sudo reboot" ;;
*)
    echo "usage: sudo bash tune_panel.sh show | set <HFP> <HBP> | restore"; exit 1 ;;
esac
