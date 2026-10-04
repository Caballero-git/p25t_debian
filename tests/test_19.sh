#!/bin/bash
# test_19.sh - accelerometer: does the mount-matrix point the right way?
#
# The SC7A20 (i2c1 0x19, patch 0013) reads fine, but its DT mount-matrix
# was translated from the stock driver's flags (swap_xy, revert_y) and
# never checked against real tilts. Auto-rotation in a future graphical
# session depends on it.
#
# Convention (kernel Documentation/devicetree/bindings/iio/mount-matrix.txt):
# corrected = mount-matrix x raw gives the device frame of the display in
# the tablet's natural orientation, which is LANDSCAPE since patch 0023
# (panel rotation = 90, the way Jose holds it):
#   x -> landscape right edge
#   y -> landscape top edge
#   z -> out of the screen, toward the user
# and at rest the reading points UP (+1 g on the axis that points up).
#
# Four poses, 10 s to get into each, then 2 s of readings:
#   1 flat on the table, screen up          expect z = +1 g
#   2 upright, landscape the usual way      expect y = +1 g
#   3 upright, landscape upside down        expect y = -1 g
#   4 upright, portrait: landscape LEFT up  expect x = -1 g
#
# 2026-10-03, first run: the SC7A20 reports a left-handed frame (the right
# matrix has determinant -1, a mirror), the same as on the PineTab2
# (rk3566-pinetab2.dtsi, same chip); raw y also has a ~-0.17 g offset.
# Both are harmless for orientation.
# For each pose it prints raw and corrected values and OK/WRONG; at the
# end, if anything is wrong, the mount-matrix that would be right.
#
# Read-only, no sudo needed. No key presses: just follow the countdown.
# Best run over SSH (from the PC) so you can move the tablet freely:
#   bash test_19.sh | tee result_19.txt

set -u
echo "=== accelerometer mount-matrix check (test_19) ==="
date; uname -r
command -v python3 >/dev/null || { echo "ABORT: python3 missing"; exit 1; }

DEV=""
for d in /sys/bus/iio/devices/iio:device*; do
    case "$(cat "$d/name" 2>/dev/null)" in *sc7a20*|*accel*) DEV=$d ;; esac
done
[ -n "$DEV" ] || { echo "ABORT: accelerometer not found in /sys/bus/iio/devices"; exit 1; }
MM=""
for f in mount_matrix in_mount_matrix in_accel_mount_matrix; do
    [ -r "$DEV/$f" ] && MM=$(cat "$DEV/$f") && break
done
echo "device: $DEV ($(cat "$DEV/name"))"
# st_accel has one scale per axis (in_accel_x_scale); others share one
SCALE=$(cat "$DEV/in_accel_x_scale" 2>/dev/null || cat "$DEV/in_accel_scale" 2>/dev/null || echo 0)
echo "scale:  $SCALE (m/s^2 per raw count; 0 = not found, then only the signs are judged)"
echo "mount_matrix: ${MM:-NOT FOUND}"

sample() {   # 20 reads over ~2 s -> "x y z" averages of the raw values
    local i x=0 y=0 z=0
    for i in $(seq 1 20); do
        x=$(( x + $(cat "$DEV/in_accel_x_raw") ))
        y=$(( y + $(cat "$DEV/in_accel_y_raw") ))
        z=$(( z + $(cat "$DEV/in_accel_z_raw") ))
        sleep 0.1
    done
    echo "$(( x / 20 )) $(( y / 20 )) $(( z / 20 ))"
}

POSES=(
  "1|flat on the table, SCREEN UP|z+"
  "2|upright, LANDSCAPE the usual way|y+"
  "3|upright, LANDSCAPE UPSIDE DOWN|y-"
  "4|upright, PORTRAIT: the landscape LEFT edge goes UP|x-"
)
RESULTS=""
for p in "${POSES[@]}"; do
    IFS='|' read -r n text want <<< "$p"
    echo
    echo ">>> pose $n: $text"
    for s in 10 8 6 4 2; do echo "    $s s ..."; sleep 2; done
    echo "    hold still - reading"
    r=$(sample)
    echo "    raw: $r"
    RESULTS="$RESULTS$n $want $r
"
done

echo
echo "--- evaluation ---"
python3 - "$SCALE" "$MM" "$RESULTS" <<'EOF'
import sys
G = 9.80665
scale = float(sys.argv[1] or 0) or G / 1000; mm = sys.argv[2]; rows = [l.split() for l in sys.argv[3].strip().splitlines()]
G = 9.80665
M = [[float(v) for v in r.split(',')] for r in mm.split(';')] if mm else [[1,0,0],[0,1,0],[0,0,1]]
ax = "xyz"
def dom(v):                       # dominant axis and sign of a vector
    i = max(range(3), key=lambda k: abs(v[k])); return ax[i] + ('+' if v[i] > 0 else '-'), i
bad = 0; R = [[0, 0, 0] for _ in range(3)]; clash = False
for n, want, *r in rows:
    raw = [int(t) * scale / G for t in r]          # in g
    cor = [sum(M[i][j] * raw[j] for j in range(3)) for i in range(3)]
    got, _ = dom(cor); _, rj = dom(raw)
    ok = got == want
    bad += not ok
    i = ax.index(want[0]); sgn = (1 if raw[rj] > 0 else -1) * (1 if want[1] == '+' else -1)
    if R[i][rj] not in (0, sgn): clash = True
    R[i][rj] = sgn
    print(f"pose {n}: raw g = ({raw[0]:+.2f}, {raw[1]:+.2f}, {raw[2]:+.2f})  corrected = "
          f"({cor[0]:+.2f}, {cor[1]:+.2f}, {cor[2]:+.2f})  expect {want}, got {got}  "
          f"{'OK' if ok else 'WRONG'}   |g| = {sum(c*c for c in raw) ** 0.5:.2f}")
if bad == 0:
    print("\nRESULT: mount-matrix is right in all 4 poses.")
else:
    print(f"\nRESULT: {bad} pose(s) wrong.")
    full = all(sum(abs(R[i][j]) for j in range(3)) == 1 for i in range(3)) and \
           all(sum(abs(R[i][j]) for i in range(3)) == 1 for j in range(3))
    if clash or not full:
        print("The poses do not give a clean axis permutation - repeat the test.")
    else:
        cols = [R[i][j] for i in range(3) for j in range(3)]
        q = lambda v: f'"{v}"'
        print("Matrix that fits all 4 poses:")
        print("    mount-matrix = " + ", ".join(q(c) for c in cols[0:3]) + ",")
        print("                   " + ", ".join(q(c) for c in cols[3:6]) + ",")
        print("                   " + ", ".join(q(c) for c in cols[6:9]) + ";")
        det = (R[0][0]*(R[1][1]*R[2][2]-R[1][2]*R[2][1]) - R[0][1]*(R[1][0]*R[2][2]-R[1][2]*R[2][0])
               + R[0][2]*(R[1][0]*R[2][1]-R[1][1]*R[2][0]))
        if det == -1:
            print("(determinant -1: the SC7A20 reports a left-handed frame - expected, as on PineTab2)")
        print("For tests/set_accel_matrix.sh: set " + " ".join(str(c) for c in cols))
EOF
echo
echo "=== done ==="
