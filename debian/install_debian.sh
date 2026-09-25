#!/bin/bash
# Put the Debian root filesystem onto the P25T SD card and switch the card to boot it.
#
# Usage (SD card in the PC; it asks for sudo itself):
#     bash ~/p25t-backup/debian/install_debian.sh
#
# What it does to the card (and nothing else):
#   - moves the GPT's backup header to the real end of the card
#   - adds partition 5 "P25TROOT" from 1 GiB to the end, formats it ext4 (label p25troot)
#     (it starts at 1 GiB because our U-Boot writes its status note at sector 1331200,
#      about 650 MB, which must stay outside every partition)
#   - copies ~/p25t-backup/debian/rootfs onto it and verifies every file by checksum
#   - on P25TBOOT: new initramfs (with the Debian hand-over), flag file boot-debian,
#     removes the colour test autorun.sh, updates and checks CARD-SHA256SUMS
# Partitions 1-4 (U-Boot and P25TBOOT) are not changed otherwise.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo --preserve-env=HOME bash "$0" "$@"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/rootfs"
TABLET_USER=jose
ROOT_START=2097152          # sector of 1 GiB

say() { echo; echo "=== $*"; }
die() { echo; echo "STOPPED: $*"; exit 1; }

say "1/8 Checking the built root filesystem"
[ -x "$R/usr/lib/systemd/systemd" ] || die "no Debian in $R - run build_debian.sh first"
PWFIELD=$(awk -F: -v u="$TABLET_USER" '$1 == u {print $2}' "$R/etc/shadow")
case "$PWFIELD" in
    ""|"!"*|"*"*) die "user $TABLET_USER has no password yet - run build_debian.sh again" ;;
esac
[ -f "$HERE/initramfs.cpio.gz" ] || die "missing $HERE/initramfs.cpio.gz"
( cd "$HERE" && sha256sum -c initramfs.cpio.gz.sha256 ) || die "initramfs.cpio.gz damaged"
echo "root filesystem OK ($(du -sh "$R" | cut -f1)), user $TABLET_USER has a password"

say "2/8 Finding the P25T card"
BOOTPART=$(blkid -L P25TBOOT || true)
[ -n "$BOOTPART" ] || die "no partition labelled P25TBOOT - is the card in the PC?"
DISK=/dev/$(lsblk -no PKNAME "$BOOTPART" | head -n 1)
[ -b "$DISK" ] || die "cannot find the disk of $BOOTPART"
DNAME=$(basename "$DISK")
SIZE_GB=$(( $(cat /sys/block/"$DNAME"/size) / 2097152 ))
REMOVABLE=$(cat /sys/block/"$DNAME"/removable)
TRAN=$(lsblk -dno TRAN "$DISK" || true)
if findmnt -no SOURCE / | grep -q "^$DISK"; then die "$DISK holds the PC's own system"; fi
[ "$SIZE_GB" -ge 4 ] && [ "$SIZE_GB" -le 256 ] || die "$DISK is $SIZE_GB GB - not a plausible SD card"
[ "$REMOVABLE" = "1" ] || [ "$TRAN" = "usb" ] || die "$DISK is not removable/USB"
case "$DISK" in *[0-9]) P5="${DISK}p5" ;; *) P5="${DISK}5" ;; esac
echo "card: $DISK, $SIZE_GB GB, transport ${TRAN:-?}, removable $REMOVABLE, P25TBOOT = $BOOTPART"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$DISK"

P4_END=$( (sgdisk -i 4 "$DISK" 2>/dev/null || true) | awk '/^Last sector/ {print $3}')
[ -n "$P4_END" ] && [ "$P4_END" -lt 1331200 ] || die "unexpected layout: partition 4 ends at ${P4_END:-?}"
EXISTING=$( (sgdisk -i 5 "$DISK" 2>/dev/null || true) | awk -F"'" '/^Partition name/ {print $2}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != "P25TROOT" ]; then
    die "partition 5 exists and is called '$EXISTING' - not touching it"
fi

echo
echo "This will ERASE partition 5 (P25TROOT) on $DISK and install Debian there."
[ -n "$EXISTING" ] && echo "(partition 5 P25TROOT already exists and will be reformatted)"
read -r -p "Type YES to continue: " ANSWER
[ "$ANSWER" = "YES" ] || die "not confirmed"

say "3/8 Unmounting the card's partitions"
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
    umount "$p" 2>/dev/null && echo "unmounted $p" || true
done

say "4/8 Partition 5 (P25TROOT, from 1 GiB to the end)"
sgdisk -e "$DISK" > /dev/null
if [ -z "$EXISTING" ]; then
    sgdisk -n 5:$ROOT_START:0 -c 5:P25TROOT -t 5:8300 "$DISK"
fi
partprobe "$DISK" || partx -u "$DISK" || true
for i in $(seq 1 10); do [ -b "$P5" ] && break; sleep 1; done
[ -b "$P5" ] || die "$P5 did not appear"
P5_START=$( (sgdisk -i 5 "$DISK" 2>/dev/null || true) | awk '/^First sector/ {print $3}')
[ -n "$P5_START" ] && [ "$P5_START" -ge $ROOT_START ] || die "partition 5 starts at $P5_START, below 1 GiB"
(sgdisk -p "$DISK" || true) | tail -n 7

say "5/8 Formatting ext4 (label p25troot)"
umount "$P5" 2>/dev/null || true
mkfs.ext4 -F -q -L p25troot "$P5"

say "6/8 Copying Debian onto the card (a few minutes)"
MNT=$(mktemp -d)
mount "$P5" "$MNT"
rsync -aHAX --numeric-ids "$R"/ "$MNT"/
sync
echo "copied; now verifying every file by checksum ..."
DIFFS=$(rsync -aHAXn --checksum --numeric-ids --itemize-changes "$R"/ "$MNT"/ | wc -l)
umount "$MNT"
[ "$DIFFS" -eq 0 ] || die "$DIFFS files differ between $R and the card"
e2fsck -fn "$P5" > /dev/null || die "file system check of $P5 failed"
echo "ROOT FILE SYSTEM VERIFIED"

say "7/8 Updating P25TBOOT (initramfs, boot-debian flag)"
mount "$BOOTPART" "$MNT"
cp "$HERE/initramfs.cpio.gz" "$MNT/initramfs.cpio.gz"
echo "Delete this file to boot the stage-1 test system instead of Debian." > "$MNT/boot-debian"
rm -f "$MNT/autorun.sh"
grep -v "  autorun.sh$" "$MNT/CARD-SHA256SUMS" | grep -v "  initramfs.cpio.gz$" > "$MNT/CARD-SHA256SUMS.new"
( cd "$MNT" && sha256sum initramfs.cpio.gz >> CARD-SHA256SUMS.new )
mv "$MNT/CARD-SHA256SUMS.new" "$MNT/CARD-SHA256SUMS"
sync
( cd "$MNT" && sha256sum -c CARD-SHA256SUMS ) || die "P25TBOOT check failed"
umount "$MNT"
rmdir "$MNT"
sync

say "8/8 Done"
echo "ALL OK - if the file manager mounted P25TROOT or P25TBOOT again, eject them there;"
echo "then take the card out."
