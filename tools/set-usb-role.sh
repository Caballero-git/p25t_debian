#!/bin/bash
# set-usb-role.sh - choose which DTB U-Boot loads on the NEXT boot, to pick
# the USB-C port's role for that boot: "normal" (USB-C acts as a USB
# device - gives the PC a serial console + network link, current default)
# or "host" (USB-C acts as a USB host - a wired keyboard/mouse plugged
# into it works directly, but the console/network link over that cable is
# not available for that boot).
#
# Why a script instead of a boot menu: U-Boot's bootcmd on this board
# hardcodes the filename it loads - "fatload mmc 1:4 ${fdt_addr_r}
# rk3566-teclast-p25t.dtb" (see docs/boot.org) - so which DTB variant's
# *content* sits at that exact path decides the role. This can't be
# changed once the kernel has booted (the USB PHY's dr_mode is fixed at
# probe time) - only for the boot that hasn't happened yet.
#
# P25TBOOT is mounted at /boot/firmware in Debian (see docs/debian.org).
# Usage: set-usb-role.sh [host|normal|status]

set -euo pipefail
BOOT=/boot/firmware
NORMAL="$BOOT/rk3566-teclast-p25t-normal.dtb"
HOST="$BOOT/rk3566-teclast-p25t-usbhost.dtb"
ACTIVE="$BOOT/rk3566-teclast-p25t.dtb"

usage() {
    echo "Usage: $0 [host|normal|status]"
    echo "  host   - next boot: USB-C as host (wired keyboard/mouse works; no console/network over that cable)"
    echo "  normal - next boot: USB-C as device (console/network over the cable, current default)"
    echo "  status - show which role is currently set for the next boot"
    exit 1
}

[ $# -eq 1 ] || usage

for f in "$NORMAL" "$HOST" "$ACTIVE"; do
    [ -f "$f" ] || { echo "Missing expected file: $f" >&2; exit 1; }
done

case "$1" in
    host)
        sudo cp "$HOST" "$ACTIVE"
        echo "Set: host mode (USB-C keyboard/mouse) will be active on the next boot."
        echo "Reboot now with: sudo reboot"
        echo "Note: while in host mode the USB-C port sources power for the attached"
        echo "device instead of just receiving it, so charging behaviour over that"
        echo "same cable may change - keep an eye on the battery level."
        ;;
    normal)
        sudo cp "$NORMAL" "$ACTIVE"
        echo "Set: normal mode (USB-C console/network) will be active on the next boot."
        echo "Reboot now with: sudo reboot"
        ;;
    status)
        if cmp -s "$ACTIVE" "$HOST"; then
            echo "Currently set for: host (next boot)"
        elif cmp -s "$ACTIVE" "$NORMAL"; then
            echo "Currently set for: normal (next boot)"
        else
            echo "Active DTB matches neither known variant - check manually."
        fi
        ;;
    *)
        usage
        ;;
esac
