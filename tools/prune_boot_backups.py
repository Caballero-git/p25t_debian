#!/usr/bin/env python3
"""prune_boot_backups.py - keep P25TBOOT to the backup rule after a deploy.

Run it on the tablet once the new kernel has booted and works:

    sudo python3 prune_boot_backups.py           # dry run: shows the plan only
    sudo python3 prune_boot_backups.py --apply   # does it

Rule (docs/boot.org, "Rescue and rollback"):
  - P25TBOOT keeps the running kernel plus the 2 previous kernels:
    Image.pre-<TAG>-backup for the 2 highest tags, each with the role DTBs
    of the same tag (rk3566-teclast-p25t-normal.dtb.pre-<TAG>-backup and
    -usbhost.dtb.pre-<TAG>-backup) - the DTBs that last ran with it.
  - DTB backups with a tag *higher* than the newest Image backup belong to
    DTB-only deploys on the running kernel (like 0026, 0027): kept, they
    are the rollback for those.
  - Everything else with a numeric tag (older Image backups, their DTBs,
    DTB-only backups of a kernel that is no longer the running one) moves
    to /home/jose/boot-backups/old/.
  - /home/jose/boot-backups/ itself mirrors the backups kept on the card
    (deploy_kernel.sh puts a copy there): a kept card backup without a copy
    there gets one (second copy off the FAT card); copies whose tag is no
    longer kept on the card move to old/ as well.
  - Names without a 4-digit tag (pre-accel, stage4, ...) are reported and
    left alone. The live files (Image, the DTBs without .pre-, initramfs,
    CARD-SHA256SUMS, logs/) are never touched.

Moving = copy, compare byte for byte, then remove the source. If old/
already has a file of that name: identical -> the source is removed (it is
a duplicate); different -> that file is skipped and reported.
Lines of files moved off the card are removed from CARD-SHA256SUMS, then
the whole list is checked with sha256sum -c.

BOOT / BK environment variables override the two folders (testing only).
"""
import filecmp
import os
import re
import shutil
import subprocess
import sys

BOOT = os.environ.get("BOOT", "/boot/firmware")
BK = os.environ.get("BK", "/home/jose/boot-backups")
OLD = os.path.join(BK, "old")
SUMS = os.path.join(BOOT, "CARD-SHA256SUMS")
KEEP_KERNELS = 2

TAGGED = re.compile(r"^(?P<base>.+)\.pre-(?P<tag>[^.]+)-backup$")


def tag_of(name):
    m = TAGGED.match(name)
    return m.group("tag") if m else None


def is_numeric(tag):
    return tag is not None and re.fullmatch(r"\d{4}", tag) is not None


def plan():
    card = sorted(f for f in os.listdir(BOOT) if os.path.isfile(os.path.join(BOOT, f)))
    img_tags = sorted({tag_of(f) for f in card
                       if f.startswith("Image.pre-") and is_numeric(tag_of(f))},
                      reverse=True)
    keep = set(img_tags[:KEEP_KERNELS])
    newest_img = img_tags[0] if img_tags else "0000"

    def kept(tag):
        return tag in keep or tag > newest_img   # 4-digit strings compare as numbers

    moves, kept_files, untouched = [], [], []
    for f in card:
        t = tag_of(f)
        if t is None:
            continue                       # live files
        if not is_numeric(t):
            untouched.append(("card", f))
        elif kept(t):
            kept_files.append(("card", f))
        else:
            moves.append((os.path.join(BOOT, f), f))

    bk_moves = []
    if os.path.isdir(BK):
        for f in sorted(os.listdir(BK)):
            p = os.path.join(BK, f)
            if not os.path.isfile(p):
                continue
            t = tag_of(f)
            if t is None or not is_numeric(t):
                untouched.append(("backups", f))
            elif kept(t):
                kept_files.append(("backups", f))
            else:
                bk_moves.append((p, f))
    return keep, newest_img, kept_files, moves, bk_moves, untouched


def move(src, name, apply):
    dst = os.path.join(OLD, name)
    if os.path.exists(dst):
        if filecmp.cmp(src, dst, shallow=False):
            if apply:
                os.remove(src)
            return "duplicate of old/" + name + " -> source removed"
        return "SKIPPED: old/" + name + " exists and differs"
    if apply:
        shutil.copy2(src, dst)
        if not filecmp.cmp(src, dst, shallow=False):
            os.remove(dst)
            return "SKIPPED: copy differs"
        os.remove(src)
    return "moved to old/"


def main():
    apply = "--apply" in sys.argv[1:]
    if apply and os.geteuid() != 0:
        sys.exit("STOP: run with sudo")
    for d in (BOOT, BK):
        if not os.path.isdir(d):
            sys.exit("STOP: " + d + " not found")

    keep, newest, kept_files, moves, bk_moves, untouched = plan()
    print("=== backup rule: running kernel + %d previous ===" % KEEP_KERNELS)
    print("Image backups kept on the card: " + ", ".join(sorted(keep, reverse=True)))
    print("DTB-only backups newer than %s are kept too\n" % newest)
    print("--- kept ---")
    for where, f in kept_files:
        print("  %-8s %s" % (where, f))
    print("--- to old/ ---" if moves or bk_moves else "--- nothing to move ---")
    if apply:
        os.makedirs(OLD, exist_ok=True)
    moved_card = []
    for src, name in moves:
        res = move(src, name, apply) if apply else "(dry run)"
        print("  card     %-52s %s" % (name, res))
        if apply and not res.startswith("SKIPPED"):
            moved_card.append(name)
    for src, name in bk_moves:
        res = move(src, name, apply) if apply else "(dry run)"
        print("  backups  %-52s %s" % (name, res))
    missing = [f for where, f in kept_files
               if where == "card" and not os.path.exists(os.path.join(BK, f))]
    if missing:
        print("--- kept card backups without a copy in %s ---" % BK)
        for f in missing:
            res = "(dry run)"
            if apply:
                src, dst = os.path.join(BOOT, f), os.path.join(BK, f)
                shutil.copy2(src, dst)
                res = "copied" if filecmp.cmp(src, dst, shallow=False) else "COPY DIFFERS"
            print("  card     %-52s %s" % (f, res))
    if untouched:
        print("--- left alone (no 4-digit tag) ---")
        for where, f in untouched:
            print("  %-8s %s" % (where, f))

    if not apply:
        print("\nDry run - nothing changed. To do it: sudo python3 prune_boot_backups.py --apply")
        return

    if moved_card and os.path.isfile(SUMS):
        lines = open(SUMS).read().splitlines()
        new = [l for l in lines if not (len(l.split()) == 2 and l.split()[1] in moved_card)]
        if len(new) != len(lines):
            open(SUMS, "w").write("\n".join(new) + "\n")
            print("\nCARD-SHA256SUMS: %d line(s) of moved files removed" % (len(lines) - len(new)))
    sys.stdout.flush()
    subprocess.run(["sync"])
    r = subprocess.run(["sha256sum", "-c", "--quiet", "CARD-SHA256SUMS"], cwd=BOOT)
    print("CARD-SHA256SUMS: all entries OK" if r.returncode == 0 else "CARD-SHA256SUMS: CHECK FAILED - see above", flush=True)
    subprocess.run(["df", "-h", BOOT])


if __name__ == "__main__":
    main()
