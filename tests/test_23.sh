#!/bin/bash
# test_23.sh - rear camera, step 2: first raw frames.
#
# Kernel 0028/0029 (step 1 passed 2026-10-07: GC5035 detected, graph
# sensor -> dw-mipi-csi2rx -> rkcif-mipi0 -> /dev/video0).
# Sets 1296x972 SGRBG10 on every pad, then captures with v4l2-ctl:
#   cam23_bars.raw   sensor test pattern (colour bars) - checks the data
#                    path independent of lens, light and exposure
#   cam23_scene.raw  a real picture: point the rear camera at something lit
# Each capture skips 4 frames and keeps the 5th; a 15 s timeout guards a
# stream that never delivers. Frame format BA10 = 16 bits per pixel,
# 10 bits used. Turn into PNGs on the PC with tools/raw2png.py.
#
#   cd ~/tests
#   sudo bash test_23.sh | tee result_23.txt
# Needs v4l-utils. Writes the .raw files into the current folder.
# v2 2026-10-07: "field:none" on every pad. Without it media-ctl stores
# field ANY on the receiver pads, the sensor reports NONE, and link
# validation refuses the stream (VIDIOC_STREAMON: Broken pipe, -EPIPE).

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v media-ctl >/dev/null || { echo "ABORT: sudo apt install v4l-utils"; exit 1; }
W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
echo "=== rear camera first frames (test_23) ==="
date; uname -v

SENS=$(media-ctl -d $M -e "gc5035 2-0037")
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
echo "sensor subdev: $SENS   capture node: $VID"

echo; echo "--- formats on every pad ---"
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":1 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" ||
    echo "WARNING: a media-ctl -V failed (see above)"
media-ctl -d $M -p 2>&1 | grep -E -A1 "^- entity|fmt:" | grep -v "^--" | head -30
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 && v4l2-ctl -d "$VID" --get-fmt-video

echo; echo "--- sensor controls ---"
v4l2-ctl -d "$SENS" --list-ctrls

capture() {   # capture <name>
    rm -f "$1.raw"
    echo; echo "--- capture $1 ---"
    dmesg -C
    timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-skip=4 --stream-count=1 --stream-to="$1.raw" --verbose 2>&1 | tail -6
    local rc=${PIPESTATUS[0]}
    echo "exit $rc (124 = timeout: no frames) ; file: $(stat -c %s "$1.raw" 2>/dev/null || echo none) bytes (one frame = $((W * H * 2)))"
    echo "kernel log during the capture:"; dmesg | tail -15
}

v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=1
capture cam23_bars
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
capture cam23_scene

[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam23_*.raw 2>/dev/null
echo; ls -l cam23_*.raw 2>/dev/null
echo "=== done ==="
