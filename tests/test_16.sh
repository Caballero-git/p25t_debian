#!/bin/bash
# test_16.sh - microphone: does it need RK817 LDO9 (2.8 V) as bias supply?
#
# RESULT 2026-10-02 (check mode, LDO9 off): the mic works without LDO9 -
# TALK +37 dB over QUIET on L. The no-bias theory below was wrong; the
# apply mode was never needed or run. See docs/todo.org (Audio).
#
# test_15 (2026-10-02): the ADC runs (no all-zero data), but nothing
# looks like sound. Right channel = a steady DC offset; left = faint
# noise with ~30 % exact zeros; at +27 dB PGA both clip to full scale
# (the "crackle" heard on playback). That is what an electret mic with
# no bias voltage gives. The RK817 has no MICBIAS pin, so the bias must
# come from a board rail; Android keeps LDO9 "vcc2v8_dvp" (2.8 V) on
# with no consumer named in the stock DT, and our boot leaves it off
# (test_15: 0xB4 = 0x06 -> LDO9 off).
#
# Each condition records two 4 s clips: QUIET (say nothing) and TALK
# (count aloud close to the tablet). A working mic shows TALK clearly
# louder than QUIET, and an envelope that moves (speech comes in
# syllables); a dead input shows the two the same.
# Gains for all clips: digital 0 dB, PGA 0 dB (Mic Capture Gain 6); the
# driver itself sets the left mic boost to +30 dB. No clipping expected.
#
#   sudo bash test_16.sh          CHECK (default): LDO9 state + the QUIET/
#                                 TALK pair with LDO9 as it is. Only ALSA
#                                 mixer writes (restored at the end).
#   sudo bash test_16.sh apply    With Jose's explicit OK (RK817 write):
#                                 the CHECK pair first (control), then
#                                 LDO9 to 2.8 V and on, then the pair
#                                 again. LDO9 stays on until the next full
#                                 power-off. Same writes as test_08 apply
#                                 (2026-09-29, no side effects then):
#   0xDC <- 0x58   LDO9 voltage 2.8 V (0.6 V + 88 x 25 mV); only while off
#   0xB4 <- 0x11   bit 4 = write-enable for LDO9 only, bit 0 = LDO9 on.
#                  BOOST/OTG (bits 1-2) untouched: their write-enable
#                  bits (5-6) are 0 in this write. Each write is read back;
#                  the script stops at the first surprise.
#
# The clips are kept in ~/p25t-mic/ (your home, survives reboot) so they
# can be copied to the PC. At the end (apply) the TALK clip with LDO9 on
# is played back if it is not clipped.
#
#   sudo bash test_16.sh | tee result_16.txt
#   sudo bash test_16.sh apply | tee result_16_apply.txt
#
# Run without headphones. Needs alsa-utils, i2c-tools, python3.

set -u
MODE=${1:-check}
PMIC=0x20
C=RK817
echo "=== microphone bias / RK817 LDO9 (test_16, mode: $MODE) ==="
date; uname -r
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
case "$MODE" in check|apply) ;; *) echo "ABORT: mode must be 'check' or 'apply'"; exit 1 ;; esac
for t in arecord i2cget i2cset python3; do
    command -v $t >/dev/null || { echo "ABORT: $t missing"; exit 1; }
done

stop() { echo "STOP: $* (nothing further written to the RK817)"; restore_mixer; exit 1; }
restore_mixer() { [ -f "$W/mixer-before.state" ] && alsactl -f "$W/mixer-before.state" restore "$C" && echo "mixer restored"; }

H=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
W=$H/p25t-mic
mkdir -p "$W"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$W"
alsactl -f "$W/mixer-before.state" store "$C" || { echo "ABORT: cannot save mixer state"; exit 1; }

# --- RK817 on i2c0 (fdd40000), identified by address and chip id --------
B0=""
for a in /sys/bus/i2c/devices/i2c-*; do
    case "$(readlink -f "$a")" in */fdd40000.i2c/*) B0=${a##*/i2c-} ;; esac
done
[ -n "$B0" ] || stop "i2c0 (fdd40000) not found"
tr '\0' '\n' < /sys/bus/i2c/devices/$B0-0020/of_node/compatible 2>/dev/null | grep -qx rockchip,rk817 \
    || stop "$B0-0020 is not the rockchip,rk817 node"
rd() { i2cget -f -y "$B0" $PMIC "$1" b 2>/dev/null; }
msb=$(rd 0xed); lsb=$(rd 0xee)
[ -n "$msb" ] && [ -n "$lsb" ] || stop "cannot read RK817 chip id"
[ $(( (msb << 8 | lsb) & 0xfff0 )) -eq $(( 0x8170 )) ] || stop "chip id $msb $lsb is not RK817"
ldo9() {
    B4=$(rd 0xb4); DC=$(rd 0xdc)
    [ -n "$B4" ] && [ -n "$DC" ] || stop "cannot read 0xB4/0xDC"
    echo "  0xB4 = $B4 -> LDO9 $(( B4 & 1 )) (1 = on), BOOST $(( (B4 >> 1) & 1 )), OTG $(( (B4 >> 2) & 1 ));  0xDC = $DC -> $(( 600 + (DC & 0x7f) * 25 )) mV"
}
echo "RK817 on bus $B0, chip id $msb $lsb"
ldo9

# --- recording and analysis -----------------------------------------------
analyse() {
python3 - "$@" <<'EOF'
import sys, wave, array, math
def db(v): return "  -inf" if v <= 0 else f"{20 * math.log10(v / 32768):6.1f}"
res = {}
for path in sys.argv[1:]:
    w = wave.open(path); ch = w.getnchannels(); n = w.getnframes()
    a = array.array('h', w.readframes(n)); rate = w.getframerate()
    name = path.rsplit('/', 1)[-1]
    for c, side in enumerate("LR"[:ch]):
        s = a[c::ch][rate // 4:]                     # skip the first 0.25 s
        m = sum(s) / len(s)
        ac = [x - m for x in s]
        rms = math.sqrt(sum(x * x for x in ac) / len(ac))
        clip = sum(1 for x in s if abs(x) >= 32767) / len(s)
        win = rate // 10                                 # 100 ms windows
        env = [math.sqrt(sum(x * x for x in ac[i:i + win]) / win) for i in range(0, len(ac) - win, win)]
        env = sorted(e for e in env if e > 0)
        spread = 20 * math.log10(env[-1] / env[len(env) // 10]) if len(env) > 10 else 0.0
        res[(name, side)] = rms
        print(f"  {name:22s} {side}: DC {m:8.1f}  AC rms {db(rms)} dBFS  peak {db(max(abs(x) for x in s))} dBFS"
              f"  envelope spread {spread:5.1f} dB  clipped {clip * 100:4.1f} %")
names = sorted({k[0] for k in res})
for q in [x for x in names if "quiet" in x]:
    t = q.replace("quiet", "talk")
    if t in names:
        for side in "LR":
            if (q, side) in res and res[(q, side)] > 0:
                r = 20 * math.log10(max(res[(t, side)], 1e-9) / res[(q, side)])
                print(f"  TALK vs QUIET {q.replace('_quiet.wav', '')} {side}: {r:+5.1f} dB")
EOF
}

rec() {   # rec <file> <instruction>
    echo ">>> $2 - starts in 3 s, lasts 4 s"
    sleep 3
    echo ">>> RECORDING"
    arecord -q -D plughw:"$C" -f S16_LE -r 48000 -c 2 -d 4 "$W/$1"
    echo ">>> stop"
}

pair() {   # pair <label>
    amixer -q -c "$C" cset name='Master Capture Volume' 255,255
    amixer -q -c "$C" cset name='Mic Capture Gain' 6,6
    echo; echo "--- pair $1 (digital 0 dB, PGA 0 dB) ---"
    rec "$1_quiet.wav" "QUIET: say nothing, keep still"
    rec "$1_talk.wav" "TALK: count aloud, close to the tablet"
    analyse "$W/$1_quiet.wav" "$W/$1_talk.wav"
}

pair ldo9_as_is

if [ "$MODE" = apply ]; then
    echo; echo "--- APPLY: LDO9 2.8 V on ---"
    ldo9
    if [ $(( B4 & 1 )) -eq 1 ]; then
        echo "  LDO9 is already on - no RK817 write"
        [ $(( DC & 0x7f )) -eq $(( 0x58 )) ] || stop "LDO9 is on but not at 2.8 V ($DC) - not touching it"
    else
        [ $(( DC & 0x7f )) -eq $(( 0x30 )) ] || [ $(( DC & 0x7f )) -eq $(( 0x58 )) ] \
            || stop "0xDC = $DC is neither the reset value 0x30 nor 0x58"
        i2cset -f -y "$B0" $PMIC 0xdc 0x58 b || stop "write 0xDC failed"
        v=$(rd 0xdc); [ $(( v & 0x7f )) -eq $(( 0x58 )) ] || stop "0xDC read back $v, expected 0x58"
        echo "  0xDC <- 0x58: read back $v (2.8 V)"
        i2cset -f -y "$B0" $PMIC 0xb4 0x11 b || stop "write 0xB4 failed"
        v=$(rd 0xb4)
        [ $(( v & 0x01 )) -eq 1 ] || stop "0xB4 read back $v - LDO9 did not switch on"
        [ $(( v & 0x06 )) -eq $(( B4 & 0x06 )) ] || stop "0xB4 read back $v - BOOST/OTG changed (was $B4)!"
        echo "  0xB4 <- 0x11: read back $v (LDO9 on, BOOST/OTG unchanged)"
    fi
    ldo9
    sleep 1
    pair ldo9_on

    echo; echo "--- all four clips together ---"
    analyse "$W"/ldo9_as_is_quiet.wav "$W"/ldo9_as_is_talk.wav "$W"/ldo9_on_quiet.wav "$W"/ldo9_on_talk.wav
fi

echo; echo "--- restore mixer ---"
restore_mixer
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$W"/*

if [ "$MODE" = apply ]; then
    echo; echo "--- play back the TALK clip with LDO9 on (only if not clipped) ---"
    if python3 -c "
import wave, array, sys
w = wave.open('$W/ldo9_on_talk.wav'); a = array.array('h', w.readframes(w.getnframes()))
sys.exit(0 if sum(1 for x in a if abs(x) >= 32767) < len(a) // 1000 else 1)"; then
        echo ">>> listen"
        timeout 6 aplay -q -D plughw:"$C" "$W/ldo9_on_talk.wav"
    else
        echo "(clip is clipped - not played, to spare the speaker)"
    fi
    echo "Write next to the result: did you hear your voice? (LDO9 stays on until a full power-off)"
fi
echo; echo "clips in $W:"; ls -l "$W"/*.wav
echo; echo "=== done ==="
