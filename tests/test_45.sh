#!/bin/bash
# test_45.sh - first real picture: long capture, exposure and gain up
#
# test_44 (2026-10-07): with the VICAP kept powered (sysfs power/control
# = on, so no reset of the capture block + IOMMU between captures) three
# captures in a row worked, no freeze, IOMMU paging on and no page fault
# after each. The freeze is the VICAP runtime-suspend reset.
# But the scene frames were pure black level (64-70): frame 1 empty,
# frames 2-3 taken before any useful exposure took effect.
# This one, same setup (LDO2 1.2 V, VICAP kept on), ONE capture of 20
# frames with exposure at its maximum and analogue gain 4x, keeping only
# the last 2 frames. POINT THE CAMERA AT THE LAMP / A LIT SCENE.
#   -> cam45_scene.raw (2 frames)
# RK817 writes: 0xCE only (LDO2 voltage), as approved for test_41.
#
# Run it FROM THE PC (repo's tests folder), dmesg -w in a second terminal:
#   ssh p25t 'sudo dmesg -w'
#   ssh -t p25t 'cd tests && sudo bash test_45.sh 2>&1' | tee result_45.txt

set -u
PMIC=0x20
say() { echo "$@"; sync; }
say "=== rear camera, LDO2 1.2 V, first picture (test_45) ==="
date; uname -v
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v i2cget >/dev/null || { echo "ABORT: i2c-tools missing"; exit 1; }
stop() { say "STOP: $*"; exit 1; }
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
EN=$(rd 0xb2); CE=$(rd 0xce)
[ $(( EN & 0x02 )) -ne 0 ] || stop "LDO2 is off - not as expected"
[ $(( CE )) -eq $(( 0x0c )) ] || stop "0xCE = $CE, expected 0x0c (0.9 V)"
setce() {
    i2cset -f -y "$B0" $PMIC 0xce $1 b || stop "write 0xCE failed"
    v=$(rd 0xce); [ $(( v )) -eq $(( $1 )) ] || stop "0xCE read back $v, expected $1"
    say "0xCE <- $1: read back $v -> $(( 600 + (v & 0x7f) * 25 )) mV  ($(date +%T))"
}

# --- VICAP: keep it runtime-active ----------------------------------------
VDEV=$(ls -d /sys/bus/platform/devices/fdfe0000.* 2>/dev/null | head -1)
[ -n "$VDEV" ] && [ -w "$VDEV/power/control" ] || stop "VICAP device fdfe0000 not found in sysfs"
OLDCTL=$(cat "$VDEV/power/control")
echo on > "$VDEV/power/control"
say "VICAP $VDEV: power/control $OLDCTL -> $(cat "$VDEV/power/control"), runtime_status $(cat "$VDEV/power/runtime_status")"
restore() {
    echo "$OLDCTL" > "$VDEV/power/control"
    say "VICAP power/control back to $(cat "$VDEV/power/control")"
}

cat > /tmp/p25t_mmu.py <<'EOF'
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfdfe0000)
r = lambda o: struct.unpack("<I", m[o:o + 4])[0]
st = r(0x804)
print("   IOMMU: DTE_ADDR 0x%08x STATUS 0x%08x (paging %s, idle %s, page fault %s) | VICAP MIPI INTSTAT 0x%08x"
      % (r(0x800), st, "ON" if st & 1 else "off", "yes" if st & 8 else "no",
         "YES" if st & 2 else "no", r(0x128)), flush=True)
EOF
mmu() {   # only while the VICAP is runtime-active (it is, power/control = on)
    [ "$(cat "$VDEV/power/runtime_status")" = active ] && python3 /tmp/p25t_mmu.py || say "   (VICAP not active - registers not read)"
    sync
}

W=1296; H=972; FMT=SGRBG10_1X10
M=/dev/media0
VID=$(media-ctl -d $M -e "rkcif-mipi0-id0")
SENS=$(media-ctl -d $M -e "gc5035 2-0037")
media-ctl -d $M -V "\"gc5035 2-0037\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"dw-mipi-csi2rx fdfb0000.csi\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":0 [fmt:$FMT/${W}x$H field:none]" &&
media-ctl -d $M -V "\"rkcif-mipi0\":1 [fmt:$FMT/${W}x$H field:none crop:(0,0)/${W}x$H]" || echo "WARNING: media-ctl -V failed"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=BA10 >/dev/null

say "IOMMU before any capture:"; mmu
say "LDO2 -> 1.2 V"
setce 0x18
sleep 1; say "   alive"
v4l2-ctl -d "$SENS" --set-ctrl=test_pattern=0
v4l2-ctl -d "$SENS" --set-ctrl=exposure=1992 --set-ctrl=analogue_gain=1024 2>&1 | head -3
v4l2-ctl -d "$SENS" --get-ctrl=exposure --get-ctrl=analogue_gain --get-ctrl=digital_gain 2>&1
say "capture, 20 frames  (start $(date +%T.%N | cut -c1-12))"
rm -f cam45_all.raw cam45_scene.raw
timeout 15 v4l2-ctl -d "$VID" --stream-mmap --stream-count=20 --stream-to=cam45_all.raw >/dev/null 2>&1
RC=$?
sync
FR=$((W * H * 2))
say "   exit $RC (124 = timeout); cam45_all.raw: $(stat -c %s cam45_all.raw 2>/dev/null || echo none) bytes (20 frames = $((FR * 20)))  (end $(date +%T.%N | cut -c1-12))"
tail -c $((FR * 2)) cam45_all.raw > cam45_scene.raw && rm -f cam45_all.raw
say "   kept the last 2 frames: cam45_scene.raw $(stat -c %s cam45_scene.raw 2>/dev/null) bytes"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": cam45_scene.raw 2>/dev/null
mmu
say "LDO2 back to 0.9 V"
setce 0x0c
restore
rm -f /tmp/p25t_mmu.py
echo "--- kernel log ---"; dmesg | grep -v "retry_required" | tail -8
say "=== done ==="
