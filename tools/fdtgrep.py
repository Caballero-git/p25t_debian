#!/usr/bin/env python3
"""Find device-tree blobs inside a binary and print properties matching a word.

Usage:
    python3 fdtgrep.py FILE [WORD ...]
    (default words: boot-order boot_devices bootargs model compatible)

Pure Python (no dtc needed). Phandle references in the matching properties
are resolved to node paths, so e.g. u-boot,spl-boot-order prints as
"same-as-spl /mmc@fe2b0000 /mmc@fe310000" instead of raw numbers.
"""
import struct
import sys

MAGIC = b"\xd0\x0d\xfe\xed"
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def parse(blob):
    total, off_struct, off_strings = struct.unpack_from(">III", blob, 4)
    strings = blob[off_strings:]
    pos, path, nodes = off_struct, [], {}
    while pos < total:
        (tok,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if tok == FDT_BEGIN_NODE:
            end = blob.index(b"\0", pos)
            path.append(blob[pos:end].decode("ascii", "replace"))
            pos = (end + 4) & ~3
            nodes["/" + "/".join(p for p in path if p)] = {}
        elif tok == FDT_END_NODE:
            path.pop()
        elif tok == FDT_PROP:
            ln, nameoff = struct.unpack_from(">II", blob, pos)
            pos += 8
            name = strings[nameoff:strings.index(b"\0", nameoff)].decode()
            nodes["/" + "/".join(p for p in path if p)][name] = blob[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise ValueError("bad token")
    return nodes


def render(val, phandles):
    # printable string list?
    if val and val[-1:] == b"\0" and all(32 <= c < 127 or c == 0 for c in val):
        return " ".join(s.decode() for s in val[:-1].split(b"\0"))
    if len(val) % 4 == 0 and val:
        cells = struct.unpack(">%dI" % (len(val) // 4), val)
        return " ".join(phandles.get(c, hex(c)) for c in cells)
    return val.hex()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = open(sys.argv[1], "rb").read()
    words = sys.argv[2:] or ["boot-order", "boot_devices", "bootargs", "model", "compatible"]
    pos, n = 0, 0
    while (pos := data.find(MAGIC, pos)) != -1:
        try:
            total, _, _, _, version = struct.unpack_from(">5I", data, pos + 4)
            if version not in (16, 17) or not 40 < total <= 4 << 20:
                raise ValueError
            nodes = parse(data[pos:pos + total])
        except Exception:
            pos += 4
            continue
        phandles = {}
        for p, props in nodes.items():
            for key in ("phandle", "linux,phandle"):
                if key in props and len(props[key]) == 4:
                    phandles[struct.unpack(">I", props[key])[0]] = p
        print(f"=== DTB #{n} at offset 0x{pos:x} ({total} bytes, {len(nodes)} nodes)")
        for p, props in nodes.items():
            for name, val in props.items():
                if any(w in name for w in words):
                    print(f"  {p or '/'} : {name} = {render(val, phandles)}")
        n += 1
        pos += total
    print(f"{n} device tree(s) scanned")


if __name__ == "__main__":
    main()
