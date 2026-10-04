#!/bin/bash
# set_accel_matrix.sh - try an accelerometer mount-matrix by editing the
# DTB on the card (fdtput), without a PC build; one reboot per try.
#
# test_19 (2026-10-03) found the DT matrix wrong in all 4 poses and gave
# the one that fits: -1 0 0  0 0 -1  0 1 0 (rows; landscape frame).
#
#   sudo bash set_accel_matrix.sh show                 current matrix
#   sudo bash set_accel_matrix.sh set A B C D E F G H I  write 9 values
#                                                      (each -1, 0 or 1)
#   sudo bash set_accel_matrix.sh restore              back to the DTB
#                                                      as installed
# e.g.  sudo bash set_accel_matrix.sh set -1 0 0 0 0 -1 0 1 0
#
# Only the active DTB /boot/firmware/rk3566-teclast-p25t.dtb is edited;
# the first "set" keeps a copy as rk3566-teclast-p25t.dtb.pre-accel, which
# "restore" puts back. The DTB line in CARD-SHA256SUMS is updated and the
# whole file checked. set-usb-role.sh would overwrite the edited DTB with
# a role copy - do not switch roles meanwhile; the final matrix goes into
# the DTS and a normal DTB build.
# Needs fdtput/fdtget (device-tree-compiler, installed for tune_panel.sh).

set -u
D=/boot/firmware
DTB=$D/rk3566-teclast-p25t.dtb
KEEP=$DTB.pre-accel
SUMS=$D/CARD-SHA256SUMS
NODE=/i2c@fe5a0000/accelerometer@19
MODE=${1:-show}

[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v fdtput >/dev/null || { echo "ABORT: fdtput missing - sudo apt install device-tree-compiler"; exit 1; }
[ -f "$DTB" ] || { echo "ABORT: $DTB not found"; exit 1; }
fdtget -t s "$DTB" "$NODE" mount-matrix >/dev/null 2>&1 || { echo "ABORT: no mount-matrix in $NODE of $DTB"; exit 1; }

show() { echo "active DTB mount-matrix (rows): $(fdtget -t s "$DTB" "$NODE" mount-matrix)"; }

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
    shift
    [ $# -eq 9 ] || { echo "usage: sudo bash set_accel_matrix.sh set A B C D E F G H I (9 values)"; exit 1; }
    for v in "$@"; do
        case "$v" in -1|0|1) ;; *) echo "ABORT: values must be -1, 0 or 1 (got '$v')"; exit 1 ;; esac
    done
    [ -f "$KEEP" ] || { cp -p "$DTB" "$KEEP" && echo "kept the installed DTB as $KEEP"; }
    echo -n "before: "; show
    fdtput -t s "$DTB" "$NODE" mount-matrix -- "$@"
    [ "$(fdtget -t s "$DTB" "$NODE" mount-matrix)" = "$*" ] || { echo "STOP: read-back differs"; exit 1; }
    echo -n "after:  "; show
    fix_sums
    sync
    echo "now: sudo reboot   (then: bash test_19.sh | tee result_19.txt)" ;;
restore)
    [ -f "$KEEP" ] || { echo "nothing to restore ($KEEP missing)"; exit 1; }
    cp -p "$KEEP" "$DTB" && rm "$KEEP"
    echo -n "restored: "; show
    fix_sums
    sync
    echo "now: sudo reboot" ;;
*)
    echo "usage: sudo bash set_accel_matrix.sh show | set A B C D E F G H I | restore"; exit 1 ;;
esac
