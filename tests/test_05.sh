#!/bin/bash
# test_05.sh - check the RK817 audio codec + i2s1_8ch (patch 0015) probed
# cleanly, an ALSA card showed up, and (if alsa-utils is installed) try an
# actual audible tone on the speaker/headphone output.

echo "=== Audio (RK817 codec, patch 0015) check ==="
date

echo
echo "--- dmesg (audio/codec/i2s/asoc related) ---"
dmesg | grep -iE "rk817.codec|rockchip-i2s|i2s1_8ch|fe410000|asoc|simple-audio-card|snd_soc|rk817-sound" || echo "(nothing matched)"

echo
echo "--- /proc/asound/cards (ALSA card registered?) ---"
cat /proc/asound/cards 2>/dev/null || echo "no /proc/asound/cards"

echo
echo "--- /proc/asound/pcm (playback/capture streams) ---"
cat /proc/asound/pcm 2>/dev/null || echo "no /proc/asound/pcm"

echo
echo "--- alsa-utils presence ---"
for tool in aplay arecord amixer speaker-test; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "$tool: present ($(command -v "$tool"))"
    else
        echo "$tool: NOT installed"
    fi
done

if command -v amixer >/dev/null 2>&1 && [ -e /proc/asound/cards ] && [ -s /proc/asound/cards ]; then
    echo
    echo "--- amixer -c0 controls (names only, for volume/mute follow-up) ---"
    amixer -c0 controls 2>&1 || echo "amixer -c0 controls failed"
fi

if command -v speaker-test >/dev/null 2>&1 && [ -e /proc/asound/cards ] && [ -s /proc/asound/cards ]; then
    echo
    echo "--- speaker-test: 2s sine tone on card 0, both channels ---"
    echo "(listen to the tablet now - speaker and/or headphone jack if plugged in)"
    timeout 3 speaker-test -D hw:0,0 -c2 -t sine -f 1000 -l 1 2>&1 | tail -20
else
    echo
    echo "(speaker-test not available or no ALSA card - skipping audible test)"
fi

echo
echo "=== done ==="
