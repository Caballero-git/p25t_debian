#!/usr/bin/env python3
"""Verify the Teclast P25T eMMC backup made with rkdeveloptool 1.32.

Run inside the backup folder:
    cd ~/p25t-backup/emmc
    python3 verify_backup.py

Checks every partition image has exactly (sectors x 512) bytes, writes
SHA256SUMS (check later with: sha256sum -c SHA256SUMS) and prints ALL GOOD
or PROBLEMS FOUND. Also writes the report to verify-log.txt.
"""
import hashlib
import os

# name, sector count (from rkdeveloptool ppt / parameter.txt)
PARTS = [
    ("loader", 8192),
    ("security", 8192),
    ("uboot_a", 8192),
    ("uboot_b", 8192),
    ("trust_a", 8192),
    ("trust_b", 8192),
    ("misc", 8192),
    ("dtbo_a", 8192),
    ("dtbo_b", 8192),
    ("vbmeta_a", 2048),
    ("vbmeta_b", 2048),
    ("boot_a", 245760),
    ("boot_b", 245760),
    ("backup", 761856),
    ("cache", 786432),
    ("metadata", 32768),
    ("frp", 1024),
    ("baseparameter", 2048),
    ("super", 7987200),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ok = True
    report = []
    with open("SHA256SUMS", "w") as sums:
        for name, count in PARTS:
            fn = name + ".img"
            want = count * 512
            have = os.path.getsize(fn) if os.path.exists(fn) else -1
            if have > 0:
                sums.write(f"{sha256(fn)}  {fn}\n")
            status = "OK" if have == want else "WRONG SIZE"
            ok = ok and have == want
            line = f"{status:10} {fn:18} {have:>12} / {want:>12}"
            print(line, flush=True)
            report.append(line)
    final = "ALL GOOD" if ok else "PROBLEMS FOUND"
    print(final)
    report.append(final)
    with open("verify-log.txt", "w") as log:
        log.write("\n".join(report) + "\n")


if __name__ == "__main__":
    main()
