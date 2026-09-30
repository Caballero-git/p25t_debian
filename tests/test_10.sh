#!/bin/bash
# test_10.sh - why do the VT consoles lose their login prompt?
#
# Symptoms (docs/todo.org, "Only a blinking cursor..." and "Multiple VT
# sessions"): some boots show only a blinking cursor on the panel (SSH
# works); a getty that is started *after* boot (logind autovt on tty4-6,
# respawn after logout, systemctl restart) never gets a working login;
# meanwhile "systemctl ..." answered "Connection timed out", "login" hung
# after the user name, and "reboot" hung until "reboot -f".
#
# Hypotheses this script tells apart:
#  H1  PID 1 (systemd) itself is blocked - e.g. in a tty write/drain/reset
#      on the USB gadget serial port ttyGS0 (serial-getty@ttyGS0 with no
#      host listening), or on the kernel console ttyS2. A blocked PID 1
#      starts no new getty, answers no systemctl, and lets pam_systemd /
#      logind hang every new login. Known elsewhere:
#      raspberrypi/linux#1929, gist hngouveia01 (serial getty + systemctl
#      "Connection timed out").
#  H2  PID 1 is fine, but the getty's own child "(agetty)" waits forever
#      to make the VT its controlling terminal, because another session
#      still owns that VT.
#  H3  logind does not spawn autovt@ttyN because it sees the VT as busy
#      (someone holds it open: systemd #23660, #39462) or has no VT seat.
#  H4  (blinking cursor only) the getty did print its prompt, but the
#      screen does not show it: fbcon/DRM or the font switch redrew over
#      it. /dev/vcsN holds the VT's text even if the panel does not show it.
#
#   sudo bash test_10.sh          CHECK (default): read-only. Collects
#                                 everything below. Safe to run any time;
#                                 every systemd/logind call has a timeout,
#                                 so the script itself cannot hang.
#   sudo bash test_10.sh vt 4     VT: switches the panel to tty4 (the same
#                                 thing Ctrl+Alt+F4 does), waits 8 s for
#                                 logind to start autovt@tty4, records what
#                                 happened, then switches back. Changes
#                                 nothing but which VT is on screen.
#
# When to run (over SSH, with the tablet showing the situation):
#   a) a boot showing only the blinking cursor, before touching the tablet:
#        sudo bash test_10.sh | tee result_10a.txt
#   b) a good boot (login prompt on the panel), as the baseline:
#        sudo bash test_10.sh | tee result_10b.txt
#   c) on-demand VT:     sudo bash test_10.sh vt 4 | tee result_10c.txt
#   d) log out of tty3 on the panel, wait 10 s, then:
#        sudo bash test_10.sh | tee result_10d.txt
#   Write down the USB-C role (normal/host) and whether the cable was
#   plugged in for each - H1 predicts a difference.

set -u
MODE=${1:-check}
VTN=${2:-4}
T=10    # timeout in seconds for every call that talks to systemd/logind/D-Bus

echo "=== VT / getty / PID 1 evidence (test_10, mode: $MODE) ==="
date
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
case "$MODE" in
    check) ;;
    vt) case "$VTN" in [4-6]) ;; *) echo "ABORT: vt mode takes 4, 5 or 6"; exit 1 ;; esac ;;
    *) echo "ABORT: mode must be 'check' or 'vt N'"; exit 1 ;;
esac
command -v python3 >/dev/null || { echo "ABORT: needs python3"; exit 1; }

sec() { echo; echo "--- $* ---"; }
tm()  { timeout "$T" "$@"; rc=$?; [ $rc -eq 124 ] && echo "!!! TIMED OUT after ${T}s: $*"; return $rc; }

# Python helpers. VT ioctls go through /dev/tty1 opened O_NOCTTY and closed
# at once: /dev/tty0 would open the *foreground* VT and itself make it look
# busy (the same reason logind's vt_is_busy() uses tty1).
PY=$(mktemp); trap 'rm -f "$PY"' EXIT
cat > "$PY" <<'EOF'
import os, sys, struct, fcntl, glob
VT_GETSTATE, VT_ACTIVATE = 0x5603, 0x5606

def vtstate():
    fd = os.open("/dev/tty1", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        buf = fcntl.ioctl(fd, VT_GETSTATE, b"\0" * 6)
    finally:
        os.close(fd)
    active, _sig, state = struct.unpack("HHH", buf)
    return active, state

def cmd_vtstate():
    a, s = vtstate()
    inuse = [n for n in range(1, 16) if s & (1 << n)]
    print(f"active VT {a}; VTs open by someone (VT_GETSTATE v_state=0x{s:04x}): {inuse}")

def cmd_activate(n):
    fd = os.open("/dev/tty1", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, VT_ACTIVATE, int(n))
    finally:
        os.close(fd)

def ttyname(nr):
    major = (nr >> 8) & 0xfff
    minor = (nr & 0xff) | ((nr >> 12) & 0xfff00)
    if nr == 0:
        return "-"
    if major == 4 and minor < 64:
        return f"tty{minor}"
    if major == 4:
        return f"ttyS{minor - 64}"
    return f"{major}:{minor}"

def cmd_ttyowners():
    # every process whose controlling tty is a VT, ttyS* or a gadget tty
    print(f"{'PID':>6} {'PPID':>6} {'SID':>6} {'PGID':>6} {'TPGID':>6} CTTY     ST COMM")
    for p in sorted(glob.glob("/proc/[0-9]*"), key=lambda x: int(x[6:])):
        try:
            raw = open(p + "/stat").read()
        except OSError:
            continue
        comm = raw[raw.index("(") + 1: raw.rindex(")")]
        f = raw[raw.rindex(")") + 2:].split()
        st, ppid, pgid, sid, ttynr, tpgid = f[0], f[1], f[2], f[3], int(f[4]), f[5]
        if ttynr == 0:
            continue
        print(f"{p[6:]:>6} {ppid:>6} {sid:>6} {pgid:>6} {tpgid:>6} {ttyname(ttynr):8} {st}  {comm}")

def cmd_openers():
    # who holds a VT / console / serial / gadget tty open right now
    pat = ("/dev/tty", "/dev/console", "/dev/vcs")
    rows = []
    for p in glob.glob("/proc/[0-9]*"):
        try:
            comm = open(p + "/comm").read().strip()
            for fd in os.listdir(p + "/fd"):
                try:
                    t = os.readlink(f"{p}/fd/{fd}")
                except OSError:
                    continue
                if t.startswith(pat):
                    rows.append((t, int(p[6:]), comm, fd))
        except OSError:
            continue
    for t, pid, comm, fd in sorted(rows):
        print(f"{t:16} pid {pid:>6} {comm:16} fd {fd}")
    if not rows:
        print("(nobody)")

def cmd_vcs(n):
    # what is really written on VT n, whether or not the panel shows it
    try:
        hdr = open(f"/dev/vcsa{n}", "rb").read(4)
        text = open(f"/dev/vcs{n}", "rb").read()
    except OSError as e:
        print(f"tty{n}: not readable ({e.strerror}) - VT not allocated?")
        return
    rows, cols, x, y = hdr[0], hdr[1], hdr[2], hdr[3]
    lines = [text[i:i + cols].decode("latin-1").rstrip() for i in range(0, len(text), cols)]
    used = [(i, l) for i, l in enumerate(lines) if l.strip()]
    print(f"tty{n}: {cols}x{rows}, cursor at column {x} row {y}, {len(used)} non-empty lines")
    for i, l in used[-12:]:
        print(f"  {i:3}| {l}")

c = sys.argv[1]
if c == "vtstate": cmd_vtstate()
elif c == "activate": cmd_activate(sys.argv[2])
elif c == "ttyowners": cmd_ttyowners()
elif c == "openers": cmd_openers()
elif c == "vcs": cmd_vcs(sys.argv[2])
EOF
py() { python3 "$PY" "$@" 2>&1; }

snapshot() {
    sec "kernel, cmdline, consoles"
    uname -r; cut -d' ' -f1 /proc/uptime | sed 's/^/uptime s: /'
    cat /proc/cmdline
    cat /proc/consoles
    echo "active VT (/sys/class/tty/tty0/active): $(cat /sys/class/tty/tty0/active 2>&1)"
    echo "console devices (/sys/class/tty/console/active): $(cat /sys/class/tty/console/active 2>&1)"
    for v in /sys/class/vtconsole/vtcon*; do echo "$v: $(cat $v/name) bind=$(cat $v/bind)"; done
    echo "fbcon cursor_blink: $(cat /sys/class/graphics/fbcon/cursor_blink 2>&1)"
    py vtstate

    sec "H1: is PID 1 responsive?"
    grep -E '^(State|SigPnd|ShdPnd)' /proc/1/status
    echo "wchan: $(cat /proc/1/wchan 2>/dev/null)"
    echo "syscall (nr args...): $(cat /proc/1/syscall 2>/dev/null)"
    echo "kernel stack:"; sed 's/^/  /' /proc/1/stack 2>/dev/null
    t0=$(date +%s.%N)
    tm systemctl show -p Version --value
    echo "systemctl round trip: $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}') s"
    echo "system state: $(tm systemctl is-system-running 2>&1)"
    echo "pending jobs:"; tm systemctl list-jobs --no-pager 2>&1 | sed 's/^/  /'
    echo "PID 1 open ttys:"; ls -l /proc/1/fd 2>/dev/null | grep -E 'tty|console' | sed 's/^/  /' || echo "  (none)"

    sec "processes in D state or waiting on a tty"
    ps -eo pid,ppid,sid,tty,stat,wchan:28,comm,args --sort=pid | awk 'NR==1 || $5 ~ /D/ || $6 ~ /tty|n_tty|uart|gs_|serial|console|vt_/'

    sec "H2: getty / login processes in detail"
    for p in $(ps -eo pid=,comm= | awk '$2 ~ /getty|login|^\(agetty|^\(login|executor/ {print $1}'); do
        echo "pid $p: comm=$(cat /proc/$p/comm) cmd=$(tr '\0' ' ' < /proc/$p/cmdline)"
        echo "  $(grep -E '^(State|PPid)' /proc/$p/status | tr '\n' ' ')"
        echo "  wchan=$(cat /proc/$p/wchan) syscall=$(cat /proc/$p/syscall 2>/dev/null)"
        sed 's/^/  stack: /' /proc/$p/stack 2>/dev/null | head -8
        ls -l /proc/$p/fd 2>/dev/null | awk 'NR>1 {print "  fd " $9 " -> " $11}'
    done

    sec "H2: which session owns each tty as controlling terminal"
    py ttyowners

    sec "H3: who has a tty / console / vcs open"
    py openers

    sec "H4: text actually on each VT (/dev/vcsN)"
    for n in 1 2 3 4 5 6; do py vcs $n; done

    sec "H1: serial ports - kernel console ttyS2 and gadget ttyGS0"
    grep -E '^ *2:' /proc/tty/driver/serial 2>/dev/null || echo "(no /proc/tty/driver/serial line for port 2)"
    # no stty here on purpose: closing a serial/gadget tty can wait for its
    # output to drain - exactly the kind of block H1 is about
    ls -l /dev/ttyGS* 2>&1
    for u in /sys/class/udc/*; do [ -e "$u" ] && echo "$u state: $(cat $u/state)"; done

    sec "systemd units: getty / autovt / serial-getty / logind / console setup"
    tm systemctl list-units --all --no-pager 'getty@*' 'autovt@*' 'serial-getty@*' 'container-getty@*' 2>&1
    for u in getty@tty1 getty@tty2 getty@tty3 serial-getty@ttyGS0 serial-getty@ttyS2 systemd-logind dbus console-setup keyboard-setup p25t-gadget; do
        echo "[$u] $(tm systemctl show -p ActiveState,SubState,NRestarts,MainPID,ExecMainStartTimestampMonotonic,InactiveEnterTimestampMonotonic "$u.service" 2>&1 | tr '\n' ' ')"
    done

    sec "H3: logind"
    for prop in NAutoVTs KillUserProcesses; do
        echo "$prop = $(tm busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager $prop 2>&1)"
    done
    echo "seat0 CanTTY = $(tm busctl get-property org.freedesktop.login1 /org/freedesktop/login1/seat/seat0 org.freedesktop.login1.Seat CanTTY 2>&1)"
    echo "logind ping: $(tm busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.DBus.Peer Ping 2>&1 && echo ok)"
    tm loginctl list-sessions --no-pager 2>&1
    tm loginctl seat-status seat0 --no-pager 2>&1 | head -20
}

if [ "$MODE" = check ]; then
    snapshot

    sec "configuration (unit files as systemd sees them, logind.conf, tty users)"
    tm systemctl cat getty@tty1.service serial-getty@ttyGS0.service --no-pager 2>&1 | grep -vE '^#|^$'
    tm systemd-analyze cat-config systemd/logind.conf 2>&1 | grep -vE '^#|^$'
    echo "units that touch a tty (TTYPath / StandardInput=tty / /dev/tty*):"
    grep -rlE 'TTYPath|StandardInput=tty|/dev/tty[0-9]' /etc/systemd /usr/lib/systemd/system 2>/dev/null | sed 's/^/  /'
    grep -vE '^#|^$' /etc/default/console-setup 2>/dev/null

    sec "journal this boot: getty, logind, login, console, PID 1 warnings (monotonic time)"
    journalctl -b -o short-monotonic --no-pager 2>/dev/null \
        | grep -iE 'getty|autovt|logind|login\[|session|console|vhangup|tty|freez|timed out|hung|blocked|idle' | tail -150

    sec "journal previous boot (if persistent): same filter"
    journalctl -b -1 -o short-monotonic --no-pager 2>/dev/null \
        | grep -iE 'getty|autovt|logind|login\[|console|tty|timed out|hung|blocked' | tail -60 \
        || echo "(no previous boot in the journal)"

    sec "dmesg: display, fbcon, consoles, hung tasks"
    dmesg | grep -iE 'fbcon|console|fb0|drm|dsi|panel|vop|tty|hung_task|blocked for more|gadget|dwc3|acm' | tail -80
fi

if [ "$MODE" = vt ]; then
    before=$(cat /sys/class/tty/tty0/active)
    sec "before the switch (active: $before)"
    py vtstate
    echo "autovt@tty$VTN: $(tm systemctl is-active autovt@tty$VTN.service 2>&1) / getty@tty$VTN: $(tm systemctl is-active getty@tty$VTN.service 2>&1)"
    since=$(date +%s)
    echo; echo ">>> switching the panel to tty$VTN (like Ctrl+Alt+F$VTN)"
    py activate "$VTN"
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        echo "  +${i}s active=$(cat /sys/class/tty/tty0/active) autovt@tty$VTN=$(tm systemctl is-active autovt@tty$VTN.service 2>&1)"
    done
    sec "state on tty$VTN after 8 s"
    py vtstate
    py vcs "$VTN"
    ps -eo pid,ppid,sid,tty,stat,wchan:28,comm,args | awk -v t="tty$VTN" 'NR==1 || index($0, t)'
    tm systemctl status autovt@tty$VTN.service --no-pager -n 20 2>&1
    sec "journal since the switch"
    journalctl --since "@$since" -o short-monotonic --no-pager 2>&1 | tail -60
    sec "PID 1 and logind after the switch"
    grep -E '^State' /proc/1/status; echo "PID 1 wchan: $(cat /proc/1/wchan)"
    echo "logind ping: $(tm busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.DBus.Peer Ping 2>&1 && echo ok)"
    echo; echo ">>> switching back to $before"
    py activate "${before#tty}"
    sleep 1; echo "active now: $(cat /sys/class/tty/tty0/active)"
fi

echo
echo "=== done ==="
