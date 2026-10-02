#!/bin/bash
# p25t-console-colors.sh - softer colours and brightness for the consoles.
#
# The Linux console (fbcon) has 16 colours: 8 normal + 8 bright. The
# default palette is harsh: pure black background (#000000), grey text
# (#aaaaaa) and pure white for bold/bright text (#ffffff). The palette can
# be redefined (programs keep using the same 16 colour numbers, they only
# look different). Three palettes to compare:
#
#   dim      the usual colours, toned down: background #1c1c1c instead of
#            black, text #b0b0b0, bold #d0d0d0 instead of white
#   gruvbox  warm: background #282828, beige text, cream instead of white
#   nord     cool: blue-grey background #2e3440, light grey text
#
# Run on the tablet (also from SSH; all consoles tty1-tty6 change at once):
#   sudo bash p25t-console-colors.sh list                show the palettes
#   sudo bash p25t-console-colors.sh try <PALETTE>       apply now, until reboot
#   sudo bash p25t-console-colors.sh vga                 default colours now
#   sudo bash p25t-console-colors.sh bright <N>          backlight now, until reboot
#   sudo bash p25t-console-colors.sh install <PALETTE> <N>
#                                                        palette + backlight now
#                                                        and at every boot
#   sudo bash p25t-console-colors.sh remove              undo install
#
# <PALETTE> is dim, gruvbox or nord; <N> is the backlight level 0-248 (boot
# default 120; Jose likes 80). The command "reset" puts the default palette
# back on that console until "try"/"install" or the next boot.
# Needs setvtrgb (package kbd, already installed).

set -eu
MODE=${1:-}
PAL=/etc/p25t-vtrgb
UNIT=/etc/systemd/system/p25t-console-colors.service
BL=/sys/class/backlight/backlight/brightness
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v setvtrgb >/dev/null || { echo "ABORT: setvtrgb missing (sudo apt install kbd)"; exit 1; }

# 16 colours: black red green yellow blue magenta cyan white, then the
# bright versions of the same eight. Colour 0 is the background, 7 the
# normal text, 15 bold/bright text.
colours() {
    case "$1" in
    dim)     echo "1c1c1c aa3a3a 3a9a3a aa7a2a 3a5aaa 9a4a9a 3a9a9a b0b0b0 5c5c5c c86464 64b464 c8b464 6482c8 b464b4 64b4b4 d0d0d0" ;;
    gruvbox) echo "282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2" ;;
    nord)    echo "2e3440 bf616a a3be8c ebcb8b 81a1c1 b48ead 88c0d0 c0c6d0 4c566a d08770 b4cc9c e8d29b 8fb0d0 c4a0c0 8fbcbb d8dee9" ;;
    *)       return 1 ;;
    esac
}

# setvtrgb format: three lines (red, green, blue), 16 decimal values each
write_palette() {   # write_palette <PALETTE> <file>
    local hex line c i
    hex=$(colours "$1") || { echo "ABORT: unknown palette '$1' (dim, gruvbox, nord)"; exit 1; }
    : > "$2"
    for i in 0 2 4; do
        line=""
        for c in $hex; do line="$line,$((16#${c:$i:2}))"; done
        echo "${line#,}" >> "$2"
    done
}

check_level() {
    case "${1:-x}" in *[!0-9]*|"") echo "ABORT: brightness must be a number 0-248"; exit 1 ;; esac
    [ "$1" -le 248 ] || { echo "ABORT: brightness must be 0-248"; exit 1; }
    [ "$1" -ge 10 ] || { echo "ABORT: below 10 the screen is nearly black - not allowed here"; exit 1; }
}

case "$MODE" in
list)
    for p in dim gruvbox nord; do echo "$p: $(colours $p)"; done ;;
try)
    T=$(mktemp)
    write_palette "${2:-}" "$T"
    setvtrgb "$T"; rm -f "$T"
    echo "palette ${2} on (until reboot). Default back: sudo bash $0 vga" ;;
vga)
    setvtrgb vga
    echo "default palette on" ;;
bright)
    check_level "${2:-}"
    echo "$2" > "$BL"
    echo "backlight $(cat "$BL") (until reboot)" ;;
install)
    [ $# -eq 3 ] || { echo "usage: sudo bash $0 install <PALETTE> <BRIGHTNESS>"; exit 1; }
    check_level "$3"
    write_palette "$2" "$PAL"
    cat > "$UNIT" <<EOF
[Unit]
Description=P25T console palette ($2) and backlight ($3)
After=systemd-vconsole-setup.service console-setup.service systemd-backlight@backlight:backlight.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/bin/setvtrgb $PAL
ExecStart=/bin/sh -c 'echo $3 > $BL'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable p25t-console-colors.service
    systemctl restart p25t-console-colors.service
    systemctl is-active p25t-console-colors.service
    echo "backlight now $(cat "$BL")"
    sha256sum "$PAL" "$UNIT"
    echo "installed: palette $2 and backlight $3, now and at every boot" ;;
remove)
    systemctl disable --now p25t-console-colors.service 2>/dev/null || true
    rm -f "$UNIT" "$PAL"
    systemctl daemon-reload
    setvtrgb vga
    echo "removed: default palette; backlight stays as it is until reboot" ;;
*)
    echo "usage: sudo bash p25t-console-colors.sh list | try <PALETTE> | vga | bright <N> | install <PALETTE> <N> | remove"
    exit 1 ;;
esac
