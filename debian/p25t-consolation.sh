#!/bin/bash
# p25t-consolation.sh - switch consolation's "mouse reporting" on or off.
#
# consolation (console mouse: left = select/copy, middle = paste, right =
# extend) by default hands mouse clicks to programs that ask for them (mc,
# aptitude, htop, emacs with mouse support): inside those programs it then
# does NOT select or paste. With --disable-mouse-reporting it always selects
# and pastes, and those programs no longer get mouse clicks.
#
# Debian's consolation.service reads its options from /etc/default/consolation
# (DAEMON_OPTS="..."); this script edits only that line, keeps any other
# option, and restarts the service.
#
#   sudo bash p25t-consolation.sh show    current options
#   sudo bash p25t-consolation.sh always  select/paste everywhere (adds the option)
#   sudo bash p25t-consolation.sh apps    default: programs get the clicks
#                                         (removes the option)
# The first change keeps a copy as /etc/default/consolation.orig.

set -eu
F=/etc/default/consolation
OPT=--disable-mouse-reporting
MODE=${1:-show}
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
[ -f "$F" ] || { echo "ABORT: $F not found (is consolation installed?)"; exit 1; }

current() { sed -n 's/^DAEMON_OPTS="\(.*\)"$/\1/p' "$F" | tail -1; }

write_opts() {   # write_opts <options>
    [ -f "$F.orig" ] || cp -p "$F" "$F.orig"
    if grep -q '^DAEMON_OPTS=' "$F"; then
        sed -i "s|^DAEMON_OPTS=.*|DAEMON_OPTS=\"$1\"|" "$F"
    else
        echo "DAEMON_OPTS=\"$1\"" >> "$F"
    fi
    systemctl restart consolation.service
}

show() {
    echo "--- $F (active lines)"
    grep -v '^#' "$F" | grep -v '^$' || echo "(no active lines)"
    echo "service: $(systemctl is-active consolation.service)"
    echo "running: $(ps -o args= -C consolation || true)"
}

case "$MODE" in
show)
    show ;;
always)
    o=$(current)
    case " $o " in *" $OPT "*) echo "already set" ;; *) write_opts "$(echo "$o $OPT" | sed 's/^ *//')" ;; esac
    show ;;
apps)
    o=$(current)
    write_opts "$(echo " $o " | sed "s| $OPT | |g; s/^ *//; s/ *$//")"
    show ;;
*)
    echo "usage: sudo bash p25t-consolation.sh show | always | apps"; exit 1 ;;
esac
