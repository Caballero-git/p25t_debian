#!/bin/bash
# Build the Debian 13 (trixie) arm64 root filesystem for the Teclast P25T, on the PC.
# Nothing here touches the SD card or the tablet: the result is a folder,
#     ~/p25t-backup/debian/rootfs
# which install_debian.sh later copies onto the card.
#
# Usage (from your normal account, it asks for sudo itself):
#     bash ~/p25t-backup/debian/build_debian.sh
#
# Steps: 1 host tools, 2 Debian signing keys, 3 download+install Debian (mmdebstrap,
# 5-15 min), 4 tablet configuration, 5 password for your account, 6 summary.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo --preserve-env=HOME bash "$0" "$@"
fi

TABLET_USER=jose
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/rootfs"
LOG="$HERE/build-log.txt"
SUITE=trixie
MIRROR=http://deb.debian.org/debian
COMPONENTS="main contrib non-free non-free-firmware"

PKGS="systemd-sysv,udev,dbus,systemd-resolved,systemd-timesyncd,kmod,\
sudo,openssh-server,nano,vim-tiny,less,bash-completion,console-setup,kbd,\
iproute2,iputils-ping,ca-certificates,curl,wget,wpasupplicant,iw,wireless-regdb,\
i2c-tools,usbutils,htop,procps,psmisc,file,rsync,e2fsprogs,dosfstools,fdisk,parted,\
evtest,fbset,tzdata,apt-utils,debian-archive-keyring"

say() { echo; echo "=== $*"; }

say "0/6 Checks"
[ "$(uname -m)" = "x86_64" ] || { echo "This script expects an x86_64 PC."; exit 1; }
if [ -e "$R" ]; then
    echo "The folder $R already exists (an earlier build)."
    echo "Remove it first with:  sudo rm -rf $R"
    exit 1
fi
FREE_KB=$(df -Pk "$HERE" | awk 'NR == 2 {print $4}')
[ "$FREE_KB" -gt 3000000 ] || { echo "Need at least 3 GB free in $HERE."; exit 1; }
echo "build folder: $R   (free space: $((FREE_KB / 1024)) MB)"

say "1/6 Installing host tools (mmdebstrap, qemu-user-static, keyring)"
apt-get update -qq
apt-get install -y -qq mmdebstrap qemu-user-static binfmt-support debian-archive-keyring \
    gpg curl rsync > /dev/null
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || update-binfmts --enable qemu-aarch64 || true
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "arm64 emulation (binfmt qemu-aarch64) is not active."; exit 1; }
echo "arm64 emulation active"

say "2/6 Debian signing keys"
KEYS=$(mktemp -d)
cp /usr/share/keyrings/debian-archive-keyring.gpg "$KEYS/"
for k in archive-key-13 archive-key-13-security release-13; do
    if curl -fsS -m 30 "https://ftp-master.debian.org/keys/$k.asc" -o "$KEYS/$k.asc"; then
        gpg --dearmor < "$KEYS/$k.asc" > "$KEYS/$k.gpg" && echo "added $k"
    else
        echo "could not download $k (continuing with the installed keyring)"
    fi
    rm -f "$KEYS/$k.asc"
done

say "3/6 Downloading and installing Debian $SUITE arm64 (5-15 minutes)"
mmdebstrap --architectures=arm64 --variant=minbase \
    --components="$COMPONENTS" --keyring="$KEYS" \
    --include="$PKGS" \
    "$SUITE" "$R" \
    "deb $MIRROR $SUITE $COMPONENTS" \
    "deb $MIRROR $SUITE-updates $COMPONENTS" \
    "deb http://security.debian.org/debian-security $SUITE-security $COMPONENTS" \
    2>&1 | tee "$LOG" | grep -E "^I: (downloading|extracting|installing|running|creating)|^E:" || true
[ -x "$R/usr/lib/systemd/systemd" ] || { echo "Debian install failed, see $LOG"; exit 1; }
rm -rf "$KEYS"
echo "Debian installed ($(du -sh "$R" | cut -f1))"

say "4/6 Tablet configuration"
cp "$HERE/p25t-setup.sh" "$R/root/p25t-setup.sh"
[ -f /etc/timezone ] && cp /etc/timezone "$R/root/host-timezone"
chroot "$R" /bin/bash /root/p25t-setup.sh "$TABLET_USER" 2>&1 | tee -a "$LOG"
rm -f "$R/root/p25t-setup.sh" "$R/root/host-timezone"

say "5/6 Password for '$TABLET_USER' on the tablet (you type it; it is not stored anywhere else)"
until chroot "$R" passwd "$TABLET_USER"; do echo "Try again."; done

say "6/6 Summary"
echo "root filesystem: $R ($(du -sh "$R" | cut -f1))"
echo "user: $TABLET_USER (sudo), hostname: $(cat "$R/etc/hostname")"
echo "log: $LOG"
echo "BUILD OK - next: bash $HERE/install_debian.sh"
