#!/usr/bin/env python3
"""Compare the tablet's eMMC boot images with the official firmware boot.img.

Usage (from ~/p25t-backup):
    python3 Firmware/check_boot_images.py

Read-only. Writes a short report to emmc/image-check.txt and prints it.
For each image: SHA-256, how much of it is 0xCC / 0x00 filler, the Android
boot header fields, where Rockchip resource blocks (RSCE) and device-tree
blobs (d00dfeed) are, and whether it equals the official boot.img.
"""
import hashlib
import struct
from pathlib import Path

BASE = Path.home() / "p25t-backup"
IMAGES = [
    BASE / "Firmware/unpacked/Image/boot.img",
    BASE / "emmc/boot_a.img",
    BASE / "emmc/boot_b.img",
]
OUT = BASE / "emmc/image-check.txt"


def header(d):
    if d[:8] != b"ANDROID!":
        return "no ANDROID! header (first 16 bytes: %s)" % d[:16].hex()
    ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack_from("<8I", d, 8)
    ver = struct.unpack_from("<I", d, 40)[0]
    s = "ANDROID! v%d page=%d kernel=%d ramdisk=%d second=%d" % (ver, ps, ks, rs, ss)
    if ver >= 1:
        rec = struct.unpack_from("<I", d, 1632)[0]
        s += " recovery_dtbo=%d" % rec
    if ver >= 2:
        dtb = struct.unpack_from("<I", d, 1648)[0]
        s += " dtb=%d" % dtb
    if ver >= 3:
        s = "ANDROID! v%d (v3/v4 layout: kernel=%d ramdisk=%d)" % (
            struct.unpack_from("<I", d, 40)[0], ks, ka)
    return s


def find_all(d, magic, limit=20):
    out, pos = [], 0
    while len(out) < limit and (pos := d.find(magic, pos)) != -1:
        out.append(hex(pos))
        pos += 4
    return out


lines = []
digests = {}
for p in IMAGES:
    lines.append("== %s" % p.relative_to(BASE))
    if not p.exists():
        lines.append("   missing")
        continue
    d = p.read_bytes()
    h = hashlib.sha256(d).hexdigest()
    digests[p.name] = h
    lines.append("   size %d  sha256 %s" % (len(d), h))
    lines.append("   0xCC bytes %.1f%%  0x00 bytes %.1f%%" % (
        100.0 * d.count(0xCC) / len(d), 100.0 * d.count(0) / len(d)))
    lines.append("   header: " + header(d))
    lines.append("   RSCE (resource) at: %s" % find_all(d, b"RSCE"))
    lines.append("   FDT magic at: %s" % find_all(d, b"\xd0\x0d\xfe\xed"))
    lines.append("   'rk-kernel.dtb' at: %s" % find_all(d, b"rk-kernel.dtb"))

ref = digests.get("boot.img")
for name in ("boot_a.img", "boot_b.img"):
    if name in digests and ref:
        lines.append("%s identical to official boot.img: %s" % (name, digests[name] == ref))

text = "\n".join(lines) + "\n"
OUT.write_text(text)
print(text)
print("Report written to", OUT)
