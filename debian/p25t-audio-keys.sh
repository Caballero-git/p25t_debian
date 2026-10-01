#!/bin/bash
# p25t-audio-keys.sh - volume buttons and automatic speaker mute on the P25T.
#
# The kernel reports the volume buttons (adc-keys: KEY_VOLUMEUP/DOWN) and
# the headphone jack (sound card "Analog RK817 Headphones":
# SW_HEADPHONE_INSERT 1/0, patch 0021). Without a desktop sound server
# nothing acts on them, so this sets up triggerhappy (thd) to do it:
#   volume up/down       -> Master playback volume +/- 5 %
#   headphones in / out  -> "Internal Speakers" switch off / on
# and puts the speaker switch in the right state at boot.
#
# thd runs as root here: Debian's unit starts it with --user nobody, and
# nobody cannot open the sound card. It only runs the commands below.
#
# Run on the tablet:  sudo bash p25t-audio-keys.sh
# Idempotent: running it again rewrites the same three files.
# Undo: sudo rm /usr/local/sbin/p25t-audio /etc/triggerhappy/triggers.d/p25t-audio.conf
#       sudo rm -r /etc/systemd/system/triggerhappy.service.d
#       sudo systemctl daemon-reload; sudo systemctl restart triggerhappy

set -eu
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v thd >/dev/null || apt-get install -y --no-install-recommends triggerhappy

echo "--- /usr/local/sbin/p25t-audio"
cat > /usr/local/sbin/p25t-audio <<'EOF'
#!/bin/sh
# p25t-audio up|down|hp-in|hp-out|sync - called by triggerhappy (see
# /etc/triggerhappy/triggers.d/p25t-audio.conf) and at boot.
C=RK817
case "$1" in
    up)     amixer -q -c "$C" sset Master 5%+ ;;
    down)   amixer -q -c "$C" sset Master 5%- ;;
    hp-in)  amixer -q -c "$C" sset 'Internal Speakers' off ;;
    hp-out) amixer -q -c "$C" sset 'Internal Speakers' on ;;
    sync)   if amixer -c "$C" cget iface=CARD,name='Headphones Jack' | grep -q 'values=on'
            then "$0" hp-in; else "$0" hp-out; fi ;;
    *)      echo "usage: p25t-audio up|down|hp-in|hp-out|sync" >&2; exit 1 ;;
esac
EOF
chmod 755 /usr/local/sbin/p25t-audio

echo "--- /etc/triggerhappy/triggers.d/p25t-audio.conf"
mkdir -p /etc/triggerhappy/triggers.d
cat > /etc/triggerhappy/triggers.d/p25t-audio.conf <<'EOF'
# P25T: volume buttons and headphone jack (see /usr/local/sbin/p25t-audio)
# event	value	command	(1 = press/in, 2 = held, 0 = release/out)
KEY_VOLUMEUP	1	/usr/local/sbin/p25t-audio up
KEY_VOLUMEUP	2	/usr/local/sbin/p25t-audio up
KEY_VOLUMEDOWN	1	/usr/local/sbin/p25t-audio down
KEY_VOLUMEDOWN	2	/usr/local/sbin/p25t-audio down
SW_HEADPHONE_INSERT	1	/usr/local/sbin/p25t-audio hp-in
SW_HEADPHONE_INSERT	0	/usr/local/sbin/p25t-audio hp-out
EOF

echo "--- /etc/systemd/system/triggerhappy.service.d/p25t.conf"
mkdir -p /etc/systemd/system/triggerhappy.service.d
cat > /etc/systemd/system/triggerhappy.service.d/p25t.conf <<'EOF'
# P25T: run thd as root (nobody cannot open the sound card) and set the
# speaker switch from the jack state at start (no event if headphones
# were already plugged in at boot).
[Unit]
After=sound.target alsa-restore.service

[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --deviceglob /dev/input/event*
ExecStartPost=/usr/local/sbin/p25t-audio sync
EOF

systemctl daemon-reload
systemctl enable triggerhappy.service >/dev/null
systemctl restart triggerhappy.service
echo "--- check"
systemctl is-active triggerhappy.service
systemctl show -p ExecStart --value triggerhappy.service | head -1
sha256sum /usr/local/sbin/p25t-audio /etc/triggerhappy/triggers.d/p25t-audio.conf /etc/systemd/system/triggerhappy.service.d/p25t.conf
echo "done. Press the volume buttons; plug headphones in and out."
