#!/usr/bin/env python3
"""Extract a Silead GSL touchscreen firmware table from a stock Android
kernel Image and write it in the format mainline silead.c loads.

Why: the vendor GSL drivers compile their firmware table into the kernel as
    static const struct fw_data { u32 offset:8; u32:0; u32 val; } XXX_FW[];
i.e. 8-byte little-endian records {offset, value}. For every "page" the
table has one record with offset 0xF0 (page select) followed by 32 records
with offsets 0x00, 0x04, ... 0x7C. That shape is distinctive enough to find
by scanning the binary. Mainline's struct silead_fw_data {u32 offset; u32
val;} is the same 8-byte layout, so the table bytes ARE the .fw file.

Several GSL drivers can be built into one kernel, each with its own table.
The P25T stock kernel has three touchscreen drivers side by side; each
driver's .rodata is laid out as
    of_device_id (compatible string) ... i2c_device_id (name) ... FW table
and the next driver's .rodata follows right after the table. So the table
belonging to a compatible string is the first table found after that
string, with no other "GSL," compatible string in between.

History (2026-09-29): the table first used for this tablet came from an
unrelated product's GPL source (54shady/qop_kernel gsl3673_800x1280.h). It
uploads fine but the chip never starts it (status 0xB0 stays 0). It is not
in the stock kernel at all; the stock kernel's GSL3673_800X1280 table shares
only 6 of its 141 pages with it.

Usage:
  python3 gsl_fw_from_stock_kernel.py stock-kernel.bin GSL,GSL3673_800X1280 out.fw
  python3 gsl_fw_from_stock_kernel.py stock-kernel.bin --list
"""
import hashlib
import re
import struct
import sys

PAGE_RECORDS = 33          # 1 page select + 32 data records
PAGE_BYTES = PAGE_RECORDS * 8
MAX_GAP = 4096             # compatible string -> its table, in bytes


def u32(b, p):
    return struct.unpack_from('<I', b, p)[0]


def is_page(b, p):
    if p + PAGE_BYTES > len(b) or u32(b, p) != 0xF0:
        return False
    return all(u32(b, p + 8 * (j + 1)) == 4 * j for j in range(32))


def find_tables(b):
    tables, p = [], 0
    while True:
        q = b.find(b'\xf0\x00\x00\x00', p)
        if q < 0 or q > len(b) - PAGE_BYTES:
            return tables
        if q % 4 == 0 and is_page(b, q):
            start, pages = q, 0
            while is_page(b, q):
                pages += 1
                q += PAGE_BYTES
            tables.append((start, pages))
            p = q
        else:
            p = q + 1


def find_compatibles(b):
    return [(m.start(), m.group(1).decode()) for m in re.finditer(rb'(GSL,[A-Za-z0-9_]+)\x00', b)]


def main(argv):
    if len(argv) == 3 and argv[2] == '--list':
        b = open(argv[1], 'rb').read()
        for s, n in find_tables(b):
            print(f"table at 0x{s:08x}: {n} pages, {n * PAGE_BYTES} bytes")
        for o, c in find_compatibles(b):
            print(f"compatible at 0x{o:08x}: {c}")
        return 0
    if len(argv) != 4:
        print(__doc__)
        return 1
    kernel, compat, out = argv[1], argv[2], argv[3]
    b = open(kernel, 'rb').read()
    comps = find_compatibles(b)
    mine = [o for o, c in comps if c == compat]
    if len(mine) != 1:
        print(f"ERROR: compatible '{compat}' found {len(mine)} times (need exactly 1)")
        return 1
    co = mine[0]
    after = [(s, n) for s, n in find_tables(b) if s > co]
    if not after:
        print("ERROR: no firmware table after the compatible string")
        return 1
    s, n = after[0]
    if s - co > MAX_GAP:
        print(f"ERROR: first table is {s - co} bytes after the compatible string (> {MAX_GAP})")
        return 1
    others = [c for o, c in comps if co < o < s]
    if others:
        print(f"ERROR: other compatible(s) {others} between '{compat}' and the table")
        return 1
    fw = b[s:s + n * PAGE_BYTES]
    open(out, 'wb').write(fw)
    print(f"'{compat}' at 0x{co:08x} -> table at 0x{s:08x} ({s - co} bytes later)")
    print(f"{n} pages, {n * PAGE_RECORDS} records, {len(fw)} bytes -> {out}")
    print(f"sha256 {hashlib.sha256(fw).hexdigest()}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
