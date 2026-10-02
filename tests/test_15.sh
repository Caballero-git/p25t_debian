#!/bin/bash
# test_15.sh - microphone: is anything reaching the ADC, and on which channel?
#
# Android records (quietly), so the mic exists. Here a recording sounded
# silent (2026-09-27), but nobody measured it. This script measures.
#
# What we know (stock DT, Rockchip vendor driver, RK817 datasheet):
#  - The RK817 has ONE mic input pair, MIC1P/MIC1N. Stock DT has no
#    "rockchip,mic-in-differential", so the mic is single-ended; the
#    vendor driver then records it on the LEFT ADC only (it mutes the
#    right one). Stock capture-volume = 0x15 (-7.9 dB digital).
#  - RK817 datasheet V1.7 (p. 59-60): AMIC_CFG1 (0x28) = chopping
#    enables only (vendor writes 0x30 = MIC + PGA chopping, mainline
#    leaves 0x00): a noise detail, not a reason for silence.
#    AMIC_CFG0 bits 3:2 = left mic boost (mainline: "Mic Boost L1/L2",
#    up to +30 dB), bits 1:0 = right boost (mainline never sets them).
#    PGA L takes the positive end of the mic amplifier.
#  - The RK817 has no MICBIAS pin. An electret mic must get its bias
#    from a board rail. Candidate: RK817 LDO9 "vcc2v8_dvp" (2.8 V,
#    always-on in Android, no consumer in the stock DT, off in our boot).
#    If this test shows only faint noise, LDO9 is the next thing to try.
#
# The script records three 5 s clips while you talk or tap near the
# tablet, and for each one prints, per channel: peak, RMS (dBFS) and the
# share of samples that are exactly zero. That tells apart:
#   all exact zeros        -> no data from the ADC at all (path/clock/I2S)
#   steady faint noise     -> ADC runs, mic not powered/biased (LDO9?)
#   peaks when you talk    -> mic works, only the gain is wrong
# It also dumps the codec registers (0x12-0x4F) while recording.
#
# Writes only ALSA mixer controls (normal audio use, through the codec
# driver - no direct RK817 register writes; LDO9 state is only read),
# and restores them at the end
# from a saved copy. Needs alsa-utils and python3 (both installed).
#
#   sudo bash test_15.sh | tee result_15.txt
#
# The clips stay in /tmp/p25t-mic/ (gone after reboot); the last step
# plays clip C back so you can hear it.
#
# Run it once without headphones. A 4-pole headset with a mic may switch
# the input; leave that for later.

set -u
echo "=== microphone capture (test_15) ==="
date; uname -r
[ "$(id -u)" -eq 0 ] || { echo "ABORT: run with sudo"; exit 1; }
command -v arecord >/dev/null || { echo "ABORT: alsa-utils missing"; exit 1; }
command -v python3 >/dev/null || { echo "ABORT: python3 missing"; exit 1; }

C=RK817
W=/tmp/p25t-mic
mkdir -p "$W"
alsactl -f "$W/mixer-before.state" store "$C" || { echo "ABORT: cannot save mixer state"; exit 1; }
echo "mixer state saved to $W/mixer-before.state"

RM=""
for d in /sys/kernel/debug/regmap/*; do
    case "$d" in *0-0020*) RM=$d ;; esac
done
regs() {
    if [ -n "$RM" ] && [ -r "$RM/registers" ]; then
        grep -E '^(1[2-9a-f]|[23][0-9a-f]|4[0-9a-f]): ' "$RM/registers" | tr '\n' ' ' | fold -w 96
        echo
    else
        echo "(regmap debugfs not found - skipped)"
    fi
}

analyse() {
python3 - "$1" <<'EOF'
import sys, wave, array, math
w = wave.open(sys.argv[1])
ch, n = w.getnchannels(), w.getnframes()
a = array.array('h', w.readframes(n))
for c, name in enumerate("LR"[:ch]):
    s = a[c::ch]
    if not s:
        print(f"  {name}: no samples"); continue
    peak = max(abs(x) for x in s)
    rms = math.sqrt(sum(x * x for x in s) / len(s))
    zeros = sum(1 for x in s if x == 0) / len(s)
    db = lambda v: "-inf" if v == 0 else f"{20 * math.log10(v / 32768):6.1f}"
    print(f"  {name}: peak {peak:5d} ({db(peak)} dBFS)  rms {db(rms)} dBFS  exact zeros {zeros * 100:5.1f} %")
EOF
}

rec() {   # rec <label> <what to do>
    echo
    echo ">>> clip $1: $2"
    echo ">>> recording starts in 3 s and lasts 5 s - talk, count aloud, tap near the tablet edges"
    sleep 3
    echo ">>> RECORDING"
    arecord -q -D plughw:"$C" -f S16_LE -r 48000 -c 2 -d 5 "$W/clip_$1.wav" &
    local pid=$!
    sleep 1.5
    echo "--- codec registers during clip $1 (hex reg: value) ---"
    regs
    wait "$pid"
    echo ">>> stop"
    analyse "$W/clip_$1.wav"
}

echo; echo "--- 1. capture controls as they are ---"
amixer -c "$C" contents | grep -A3 -i -E "capture|mic" | grep -v "^--"

echo; echo "--- 2. codec registers, idle ---"
regs

echo; echo "--- 2b. RK817 LDO9 (vcc2v8_dvp, possible mic bias supply) - read only ---"
if command -v i2cget >/dev/null; then
    B0=""
    for a in /sys/bus/i2c/devices/i2c-*; do
        case "$(readlink -f "$a")" in */fdd40000.i2c/*) B0=${a##*/i2c-} ;; esac
    done
    if [ -n "$B0" ]; then
        EN3=$(i2cget -f -y "$B0" 0x20 0xb4 b); V9=$(i2cget -f -y "$B0" 0x20 0xdc b)
        echo "0xB4 = $EN3 -> LDO9 $(( EN3 & 1 )) (1 = on);  0xDC = $V9 -> LDO9 set to $(( 600 + (V9 & 0x7f) * 25 )) mV"
    else
        echo "(i2c0 fdd40000 not found - skipped)"
    fi
else
    echo "(i2c-tools missing - skipped)"
fi

rec A "current mixer settings"

echo; echo "--- 3. digital volume to 0 dB (Master Capture Volume max) ---"
amixer -q -c "$C" cset name='Master Capture Volume' 255,255
amixer -c "$C" cget name='Master Capture Volume' | tail -2
rec B "Master Capture 0 dB, mic gain unchanged"

echo; echo "--- 4. plus analog PGA gain to +27 dB (Mic Capture Gain max) ---"
amixer -q -c "$C" cset name='Mic Capture Gain' 15,15
amixer -c "$C" cget name='Mic Capture Gain' | tail -2
rec C "Master Capture 0 dB, Mic Capture Gain +27 dB"

echo; echo "--- 5. restore mixer ---"
alsactl -f "$W/mixer-before.state" restore "$C" && echo "restored"
amixer -c "$C" cget name='Mic Capture Gain' | tail -1
amixer -c "$C" cget name='Master Capture Volume' | tail -1

echo; echo "--- 6. play clip C back ---"
echo ">>> listen - speaker or headphones, whichever is active"
timeout 8 aplay -q -D plughw:"$C" "$W/clip_C.wav"
echo "Write next to the result: anything heard in clip C playback? where is the mic hole on the tablet, if you know?"
echo; echo "=== done ==="
