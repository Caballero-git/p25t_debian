#!/usr/bin/env python3
"""Find and extract every flattened device tree (FDT) blob inside a file.

Usage:
    python3 dtbscan.py boot.img OUTDIR

Scans for the FDT magic 0xd00dfeed, checks the header (version 16/17,
plausible totalsize) and writes each blob as OUTDIR/<file>-<n>-<offset>.dtb.
Works on boot.img (kernel DTB or Rockchip resource), dtbo.img (overlays), etc.
"""
import struct
import sys
from pathlib import Path

MAGIC = b"\xd0\x0d\xfe\xed"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, outdir = Path(sys.argv[1]), Path(sys.argv[2])
    data = src.read_bytes()
    outdir.mkdir(parents=True, exist_ok=True)
    n, pos = 0, 0
    while (pos := data.find(MAGIC, pos)) != -1:
        if pos + 40 <= len(data):
            total, off_struct, off_strings, _, version = struct.unpack_from(">5I", data, pos + 4)
            if version in (16, 17) and 40 < total <= 4 * 1024 * 1024 \
                    and pos + total <= len(data) and off_struct < total and off_strings < total:
                out = outdir / f"{src.stem}-{n}-0x{pos:x}.dtb"
                out.write_bytes(data[pos:pos + total])
                print(f"{out.name}: {total} bytes")
                n += 1
                pos += total
                continue
        pos += 4
    print(f"{n} device tree blob(s) found in {src.name}")


if __name__ == "__main__":
    main()
