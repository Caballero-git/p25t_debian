#!/bin/bash
# test_02.sh - identify which accelerometer chip is present on i2c1
# (SC7A20 @ 0x19, ST LIS3DH/LIS2DH12-compatible register map, vs.
#  DA223 @ 0x27, Domintech, no mainline driver). Needs patch 0012
# deployed (i2c1 bus enabled) and i2c-tools installed
# (sudo apt install i2c-tools) - installs it itself if missing and
# network is available.

echo "=== i2c1 accelerometer identification ==="
date

echo
echo "--- i2c-tools present? ---"
if ! command -v i2cdetect >/dev/null 2>&1; then
    echo "i2cdetect not found, attempting: sudo apt install -y i2c-tools"
    sudo apt install -y i2c-tools
fi
command -v i2cdetect && echo "i2cdetect: OK" || echo "i2cdetect: MISSING (rest of this script will fail)"

echo
echo "--- kernel i2c1 bus present? ---"
ls -l /dev/i2c-* 2>/dev/null
i2cdetect -l 2>/dev/null

echo
echo "--- i2cdetect -y 1 (scan) ---"
sudo i2cdetect -y 1

echo
echo "--- checking 0x19 (SC7A20 candidate) ---"
if sudo i2cget -y 1 0x19 0x00 2>/dev/null >/dev/null; then
    echo "0x19 responds."
    echo "WHOAMI (reg 0x0f) at 0x19:"
    sudo i2cget -y 1 0x19 0x0f
    echo "(expected 0x33 for ST LIS3DH/LIS2DH12 family - a match means the"
    echo " mainline st_accel driver should bind with a proper DT node; a"
    echo " mismatch means this is some other/clone chip even though it"
    echo " answers at the same address)"
else
    echo "0x19 did not respond (no ACK)."
fi

echo
echo "--- checking 0x27 (DA223 candidate) ---"
if sudo i2cget -y 1 0x27 0x00 2>/dev/null >/dev/null; then
    echo "0x27 responds. (DA223 - no mainline driver currently; register"
    echo " map would need to be worked out from a datasheet/Android driver"
    echo " if we want to support this chip)"
else
    echo "0x27 did not respond (no ACK)."
fi

echo
echo "--- dmesg (i2c/accel/sensor related, in case anything already probed) ---"
dmesg | grep -iE "i2c1|fe5a0000|accel|sc7a20|da223|st_accel" || echo "(nothing matched)"

echo
echo "=== done ==="
