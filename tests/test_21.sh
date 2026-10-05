#!/bin/bash
# test_21.sh - what does userspace spend its boot time on?
#
# systemd-analyze said kernel 5.7 s + userspace 21-36 s (2026-10-05; the
# userspace part varies between boots). This collects, read-only:
#  - the boot time of this boot and of earlier boots (journal)
#  - default target, failed units
#  - systemd-analyze blame (slowest units) and critical-chain (what the
#    default target really waited for)
#  - who pulls in network-online.target (the usual "wait online" delay)
#  - network links as networkd sees them
#  - the largest pauses in the first 60 s of this boot's journal, with the
#    line before and after each, plus timeout messages
#  - a boot chart: boot_21.svg in the current folder (open it on the PC
#    with a web browser)
#
#   sudo bash test_21.sh | tee result_21.txt
# (v2 2026-10-05: only boots of PID 1, pauses only in the first 60 s)
# (v3: prints the USB-C role, peripheral = normal DTB, host = usbhost DTB)
# Run it a few minutes after a normal boot; it changes nothing.

set -u
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo (journal and systemd-analyze)"; exit 1; }
echo "=== userspace boot time (test_21) ==="
date; uname -v; uptime

echo; echo "--- this boot ---"
systemd-analyze time 2>&1 | head -3
echo "default target: $(systemctl get-default)"
R=/proc/device-tree/usb@fcc00000/dr_mode
echo "USB-C role (dr_mode): $(tr -d '\0' < "$R" 2>/dev/null || echo unknown)"
echo "USB host-side entries (root hubs included): $(ls /sys/bus/usb/devices 2>/dev/null | grep -c -v ':')"

echo; echo "--- earlier boots (from the journal; none if it is not kept) ---"
for b in -5 -4 -3 -2 -1 0; do
    journalctl -b "$b" -q --no-pager -o short _PID=1 --grep "Startup finished" 2>/dev/null | tail -1
done

echo; echo "--- failed units ---"
systemctl --failed --no-legend --no-pager || true

echo; echo "--- blame: slowest 25 units ---"
systemd-analyze blame --no-pager 2>&1 | head -25

echo; echo "--- critical chain of the default target ---"
systemd-analyze critical-chain --no-pager 2>&1 | head -40

echo; echo "--- network-online.target: who wants it, who provides it ---"
systemctl list-dependencies --reverse --plain --no-pager network-online.target 2>&1 | head -20
for u in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    echo "$u: $(systemctl is-enabled "$u" 2>/dev/null) / $(systemctl is-active "$u" 2>/dev/null)"
done
systemctl show -p ExecStart --no-pager systemd-networkd-wait-online.service 2>/dev/null | head -1

echo; echo "--- network links (networkd) ---"
networkctl list --no-pager 2>&1 | head -12

echo; echo "--- largest pauses in the first 60 s of this boot's journal (>= 1 s) ---"
journalctl -b -q --no-pager -o short-monotonic 2>/dev/null | python3 -c '
import sys, re
rows = []
for l in sys.stdin:
    m = re.match(r"\[\s*([0-9.]+)\]\s*(.*)", l.rstrip("\n"))
    if m and float(m.group(1)) <= 60.0:
        rows.append((float(m.group(1)), m.group(2)[:150]))
gaps = []
for i in range(1, len(rows)):
    d = rows[i][0] - rows[i - 1][0]
    if d >= 1.0:
        gaps.append((d, i))
gaps.sort(reverse=True)
if not gaps:
    print("no pause of 1 s or more")
for d, i in gaps[:12]:
    print(f"{d:6.2f} s pause")
    print(f"   before [{rows[i-1][0]:8.3f}] {rows[i-1][1]}")
    print(f"   after  [{rows[i][0]:8.3f}] {rows[i][1]}")
'

echo; echo "--- timeouts and waits mentioned in this boot ---"
journalctl -b -q --no-pager -o short-monotonic 2>/dev/null \
    | grep -i -E "timed out|timeout|wait-online|waiting for|job .* running" | head -20

echo; echo "--- boot chart ---"
if systemd-analyze plot > boot_21.svg 2>/dev/null; then
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": boot_21.svg
    echo "written: $(pwd)/boot_21.svg ($(stat -c %s boot_21.svg) bytes)"
else
    echo "systemd-analyze plot failed"
fi
echo; echo "=== done ==="
