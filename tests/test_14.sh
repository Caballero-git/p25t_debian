#!/bin/bash
# test_14.sh - volume buttons and headphone jack as input events.
#
# The kernel already reports both: adc-keys sends KEY_VOLUMEUP/DOWN, and
# the sound card's jack (patch 0021, GPIO3_A1) sends a switch event when
# headphones go in/out. On a desktop a sound server turns those into
# volume changes / speaker muting; on our console nothing does. Plan: the
# small Debian daemon "triggerhappy" (thd), which runs a command per
# input event. This script shows what thd will see. Read-only.
#
#   sudo apt install triggerhappy        (once, before running this)
#   sudo bash test_14.sh | tee result_14.txt
#
# During the 15-second window: press volume up, volume down, then plug
# the headphones in and pull them out again.

set -u
echo "=== volume keys / headphone jack events (test_14) ==="
date; uname -r
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }

echo; echo "--- input devices (name, handlers, event types) ---"
awk '/^N:/ {n=$0} /^H:/ {h=$0} /^B: EV=/ {print n; print "   " h; print "   " $0}' /proc/bus/input/devices

echo; echo "--- mixer: playback volume control ---"
CARD=$(awk '/RK817/ {print $1; exit}' /proc/asound/cards)
amixer -c "$CARD" sget Master 2>&1 | head -8

echo; echo "--- triggerhappy package and service ---"
if command -v thd >/dev/null; then
    dpkg -l triggerhappy | tail -1
    systemctl cat triggerhappy.service 2>&1 | grep -v '^#' | grep -v '^$'
    systemctl is-active triggerhappy.service
    ls -l /etc/triggerhappy/triggers.d/ 2>&1
    echo; echo ">>> 15 s: press volume UP, volume DOWN, plug headphones IN, then OUT"
    timeout 15 thd --dump /dev/input/event* 2>&1 | grep -v -E "^EV_(SYN|ABS|MSC)" | head -60
    echo "<<< end of capture"
else
    echo "thd not found - install first: sudo apt install triggerhappy"
fi
echo; echo "=== done ==="
