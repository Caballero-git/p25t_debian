#!/usr/bin/env python3
"""Unpack a Rockchip RKFW update image (e.g. Teclast Firmware.img).

Usage:
    python3 rkunpack.py Firmware.img OUTDIR          # extract everything
    python3 rkunpack.py Firmware.img OUTDIR --list   # only show the table

Layout (from rkflashtool/afptool sources):
  RKFW header: 0x15 chip, 0x19/0x1D loader off/len, 0x21/0x25 image off/len
  RKAF image : 0x88 num_parts, parts start at 0x8C, 0x70 bytes each:
               name[32] filename[60] nand_size pos nand_addr padded_size size
"""
import struct
import sys
from pathlib import Path

CHUNK = 16 * 1024 * 1024


def cstr(b):
    return b.split(b"\0", 1)[0].decode("ascii", "replace")


def copy_range(f, off, length, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    f.seek(off)
    with open(dest, "wb") as out:
        left = length
        while left:
            buf = f.read(min(CHUNK, left))
            if not buf:
                raise IOError(f"unexpected EOF while writing {dest}")
            out.write(buf)
            left -= len(buf)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    img, outdir = Path(sys.argv[1]), Path(sys.argv[2])
    only_list = "--list" in sys.argv[3:]
    total = img.stat().st_size

    with open(img, "rb") as f:
        hdr = f.read(0x66)
        if hdr[:4] != b"RKFW":
            sys.exit("not an RKFW image")
        chip, loff, llen, ioff, ilen = struct.unpack_from("<5I", hdr, 0x15)
        print(f"RKFW  chip=0x{chip:x}  loader @0x{loff:x} ({llen} B)  "
              f"RKAF @0x{ioff:x} ({ilen} B)  file={total} B")

        f.seek(ioff)
        rkaf = f.read(0x8C + 0x70 * 32)
        if rkaf[:4] != b"RKAF":
            sys.exit(f"no RKAF magic at 0x{ioff:x}")
        model = cstr(rkaf[0x08:0x2A])
        manuf = cstr(rkaf[0x48:0x80])
        nparts = struct.unpack_from("<I", rkaf, 0x88)[0]
        print(f"RKAF  model='{model}'  manufacturer='{manuf}'  parts={nparts}\n")

        parts = []
        for i in range(min(nparts, 32)):
            e = rkaf[0x8C + 0x70 * i: 0x8C + 0x70 * (i + 1)]
            name, fname = cstr(e[:32]), cstr(e[32:92])
            nand_size, pos, nand_addr, padded, size = struct.unpack_from("<5I", e, 92)
            parts.append((name, fname, pos, size, nand_addr))

        print(f"{'name':<16}{'file':<28}{'offset':>12}{'size':>14}{'nand_addr':>12}")
        for name, fname, pos, size, nand_addr in parts:
            print(f"{name:<16}{fname:<28}{pos:>12}{size:>14}{nand_addr:>#12x}")

        if only_list:
            return

        outdir.mkdir(parents=True, exist_ok=True)
        copy_range(f, loff, llen, outdir / "loader.bin")
        print("\nwrote loader.bin")
        for name, fname, pos, size, _ in parts:
            if size == 0 or fname in ("", "RESERVED", "SELF"):
                continue
            dest = outdir / fname
            if ioff + pos + size > total:
                print(f"skip {fname}: beyond end of file")
                continue
            copy_range(f, ioff + pos, size, dest)
            print(f"wrote {fname}  ({size} B)")


if __name__ == "__main__":
    main()
