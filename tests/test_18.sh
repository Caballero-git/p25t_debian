#!/bin/bash
# test_18.sh - display edges: how many pixels are hidden or wrapped at
# each edge of the panel?
#
# Seen 2026-10-02: in landscape the top ~5 px of the first console line
# are missing and show up at the bottom instead (wrap); the left edge is
# hard to read. In portrait the top edge (= landscape left) was already
# poor: in aptitude, the blue background visibly lacked its top rows.
#
# Draws a test pattern straight into the framebuffer (/dev/fb0), on an
# empty virtual terminal (tty7), so the console does not draw over it.
# Coordinates are the panel's own (portrait, 800 x 1280); the colours tell
# the edges apart whatever the console rotation:
#
#   panel edge        portrait view   landscape view (now)   colour
#   x = 799 (right)   right           TOP                    GREEN
#   x = 0   (left)    left            BOTTOM                 RED
#   y = 0   (top)     top             LEFT                   BLUE
#   y = 1279 (bottom) bottom          RIGHT                  YELLOW
#
# At each edge: 4 bars of that colour, 3 px wide with 3 px black between
# them, the first touching the edge: pixels 0-2, 6-8, 12-14, 18-20 from
# the edge. Count the bars you see at each edge (4 = nothing hidden;
# 3 = 3-8 px hidden; ...). A bar of the WRONG colour at an edge, beyond
# the bars of the right colour, means wrap-around from the opposite edge.
# A white 1 px frame 40 px inside the edges and a white cross in the
# middle check that nothing is grossly shifted.
#
# Read-only for the hardware: only framebuffer pixels are written; the
# console is restored by switching back to tty1. Also prints the DRM mode
# and plane state (debugfs) for the record.
#
#   sudo bash test_18.sh | tee result_18.txt             bars (default)
#   sudo bash test_18.sh black | tee result_18_black.txt  whole screen black
#   sudo bash test_18.sh blue | tee result_18_blue.txt    whole screen blue
#
# black / blue (added 2026-10-02): in the bars run, panel rows y = 6-7
# (landscape: a line 6-7 px from the left edge, full height) blinked
# blue/white along their whole length. A plain field shows whether that
# line blinks by itself (panel/timing) or only with the pattern.
#
# Run it over SSH (the tablet screen shows the pattern). When the pattern
# is up, look at all four edges; it stays for 60 s, then the console
# comes back by itself (no key needed: under sudo + tee the script
# could not see Enter, 2026-10-02).
# Write next to the result, for each colour: bars seen, and any bar of a
# wrong colour (where). A photo helps too.

set -u
MODE=${1:-bars}
case "$MODE" in bars|black|blue) ;; *) echo "ABORT: mode must be bars, black or blue"; exit 1 ;; esac
echo "=== display edges test pattern (test_18, mode: $MODE) ==="
date; uname -r
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v python3 >/dev/null || { echo "ABORT: python3 missing"; exit 1; }
command -v chvt >/dev/null || { echo "ABORT: chvt missing (package kbd)"; exit 1; }
F=/sys/class/graphics/fb0
[ -e /dev/fb0 ] && [ -d "$F" ] || { echo "ABORT: no /dev/fb0"; exit 1; }

echo; echo "--- framebuffer ---"
for a in name virtual_size bits_per_pixel stride pan rotate mode modes; do
    [ -r "$F/$a" ] && echo "$a: $(tr '\n' ' ' < "$F/$a")"
done
echo "fbcon rotate: $(cat /sys/class/graphics/fbcon/rotate 2>/dev/null)"

echo; echo "--- DRM connector modes ---"
for c in /sys/class/drm/card*-*; do
    [ -r "$c/modes" ] && echo "$(basename "$c"): status $(cat "$c/status") modes $(tr '\n' ' ' < "$c/modes")"
done
echo; echo "--- DRM state (debugfs): crtc mode and plane positions ---"
for s in /sys/kernel/debug/dri/*/state; do
    [ -r "$s" ] || continue
    echo "$s"
    grep -E "^(plane|crtc|connector)|crtc-pos|src-pos|rotation|mode:|\"[0-9]+x[0-9]+\"|enable=|active=|fb=" "$s" | head -60
done

VS=$(cat "$F/virtual_size"); W=${VS%,*}; H=${VS#*,}
BPP=$(cat "$F/bits_per_pixel"); STRIDE=$(cat "$F/stride")
echo; echo "drawing on ${W}x${H}, ${BPP} bpp, stride ${STRIDE}"

ORIG=$(fgconsole 2>/dev/null || echo 1)
chvt 7
trap 'chvt "$ORIG"' EXIT   # back to the console even after Ctrl+C
TERM=linux setterm --cursor off --blank 0 > /dev/tty7 2>/dev/null || true   # no blinking cursor over the pattern
sleep 1
python3 - "$W" "$H" "$BPP" "$STRIDE" "$MODE" <<'EOF'
import sys
W, H, BPP, STRIDE = map(int, sys.argv[1:5])
MODE = sys.argv[5]
VIS_H = 1280 if H >= 1280 else H          # draw in the first (visible) page
bpp = BPP // 8
def px(r, g, b):
    if bpp == 4: return bytes((b, g, r, 0))
    if bpp == 2:
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3); return v.to_bytes(2, 'little')
    raise SystemExit(f"unsupported bpp {BPP}")
RED, GREEN, BLUE, YELLOW, WHITE = px(255,0,0), px(0,255,0), px(0,0,255), px(255,255,0), px(255,255,255)
buf = bytearray(STRIDE * VIS_H)
if MODE in ("black", "blue"):
    if MODE == "blue":
        row = BLUE * W + bytes(STRIDE - W * bpp)
        buf = bytearray(row * VIS_H)
    with open('/dev/fb0', 'r+b') as f:
        f.write(buf)
    print(f"plain {MODE} field drawn"); raise SystemExit(0)
def hline(y, x0, x1, c):        # x0..x1-1 on row y
    o = y * STRIDE; buf[o + x0 * bpp:o + x1 * bpp] = c * (x1 - x0)
def rect(x0, y0, x1, y1, c):
    for y in range(y0, y1): hline(y, x0, x1, c)
BARS = [0, 6, 12, 18]
for d in BARS:
    rect(d, 0, d + 3, VIS_H, RED)                   # x = 0 edge
    rect(W - d - 3, 0, W - d, VIS_H, GREEN)         # x = W-1 edge
    rect(0, d, W, d + 3, BLUE)                      # y = 0 edge
    rect(0, VIS_H - d - 3, W, VIS_H - d, YELLOW)    # y = H-1 edge
m = 40                                              # white frame 40 px inside
hline(m, m, W - m, WHITE); hline(VIS_H - 1 - m, m, W - m, WHITE)
rect(m, m, m + 1, VIS_H - m, WHITE); rect(W - 1 - m, m, W - m, VIS_H - m, WHITE)
cx, cy = W // 2, VIS_H // 2                         # cross in the middle
hline(cy, cx - 50, cx + 50, WHITE); rect(cx, cy - 50, cx + 1, cy + 50, WHITE)
with open('/dev/fb0', 'r+b') as f:
    f.write(buf)
print("pattern drawn")
EOF
echo
if [ "$MODE" = bars ]; then
    echo ">>> The tablet shows the pattern. Look at all four edges (landscape:"
    echo ">>> top GREEN, bottom RED, left BLUE, right YELLOW; 4 bars each)."
else
    echo ">>> The tablet shows a plain $MODE screen. Look near the LEFT edge"
    echo ">>> (landscape) for a thin blinking line, and anywhere else for flicker."
fi
echo ">>> The pattern stays for 60 s, then the console comes back."
for left in 60 50 40 30 20 10; do
    echo "    $left s left"
    sleep 10
done
TERM=linux setterm --cursor on > /dev/tty7 2>/dev/null || true
chvt "$ORIG"
echo "back on tty$ORIG"
echo
echo "Write next to the result: for each colour, bars seen (0-4), and any"
echo "bar of a wrong colour (which colour, at which edge)."
echo; echo "=== done ==="
