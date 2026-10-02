#!/bin/bash
# test_17.sh - microphone: is the mic always on the same channel?
#
# The mic is mono and single-ended; it shows up on one channel of the
# stereo capture, the other channel is empty. That channel carries a DC
# offset of about 400 (-38 dBFS), so it can be found without speech.
# test_15 found it on R, test_16 on L. If the order changes from one
# capture to the next (LRCK phase at stream start), a fixed "take the
# left channel" ALSA setting would fail half of the time.
#
# Records 12 clips of 1 s each (quiet - nothing to do) and, for each,
# prints the DC and AC level of both channels and which one is the mic.
# Then one 4 s TALK clip (count aloud) as a cross-check that the voice is
# on the channel with the DC offset.
#
# Only ALSA mixer writes (capture 0 dB, PGA 0 dB), restored at the end.
# No RK817 register writes. Clips in ~/p25t-mic/ (overwritten each run).
#
#   sudo bash test_17.sh | tee result_17.txt

set -u
C=RK817
echo "=== microphone channel order (test_17) ==="
date; uname -r
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
for t in arecord alsactl python3; do
    command -v $t >/dev/null || { echo "ABORT: $t missing"; exit 1; }
done
H=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
W=$H/p25t-mic
mkdir -p "$W"
alsactl -f "$W/mixer-before.state" store "$C" || { echo "ABORT: cannot save mixer state"; exit 1; }
amixer -q -c "$C" cset name='Master Capture Volume' 255,255
amixer -q -c "$C" cset name='Mic Capture Gain' 6,6

stats() {
python3 - "$@" <<'EOF'
import sys, wave, array, math
def db(v): return "  -inf" if v <= 0 else f"{20 * math.log10(v / 32768):6.1f}"
for path in sys.argv[1:]:
    w = wave.open(path); a = array.array('h', w.readframes(w.getnframes()))
    rate = w.getframerate()
    out = []; dcs = []
    for c, side in enumerate("LR"):
        s = a[c::2][rate // 10:]                    # skip the first 0.1 s
        m = sum(s) / len(s)
        rms = math.sqrt(sum((x - m) ** 2 for x in s) / len(s))
        out.append(f"{side}: DC {m:7.1f} AC {db(rms)} dBFS")
        dcs.append(abs(m))
    mic = "L" if dcs[0] > dcs[1] else "R"
    print(f"  {path.rsplit('/', 1)[-1]:14s} {out[0]}   {out[1]}   -> mic on {mic}")
EOF
}

echo; echo "--- 12 quiet clips of 1 s (nothing to do) ---"
for i in $(seq -w 1 12); do
    arecord -q -D plughw:"$C" -f S16_LE -r 48000 -c 2 -d 1 "$W/order_$i.wav"
done
stats "$W"/order_*.wav
echo
echo "count:"
stats "$W"/order_*.wav | awk '{print $NF}' | sort | uniq -c

echo; echo "--- TALK clip, 4 s: count aloud close to the tablet - starts in 3 s ---"
sleep 3
echo ">>> RECORDING"
arecord -q -D plughw:"$C" -f S16_LE -r 48000 -c 2 -d 4 "$W/order_talk.wav"
echo ">>> stop"
stats "$W/order_talk.wav"
echo "(the voice should be on the channel with the DC offset: its AC level is far above the other one)"

echo; echo "--- restore mixer ---"
alsactl -f "$W/mixer-before.state" restore "$C" && echo "mixer restored"
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$W"
echo; echo "=== done ==="
