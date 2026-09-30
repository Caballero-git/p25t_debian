#!/usr/bin/env python3
"""test_09.py - touchscreen orientation and raw range, for the DT properties.

The GSL3673 now works (stock firmware), but reports in its own coordinate
space: the long axis comes out as raw X (~0..1600), the short one as raw Y
(~0..860), while the DT still announces 800 x 1280 with no swap/invert.

In the kernel (drivers/input/touchscreen.c) touchscreen-size-x/-y describe the
chip's RAW axes, touchscreen-inverted-x/-y act on raw coordinates
(x = max_x - x), and touchscreen-swapped-x-y is applied last. This script
measures exactly those:
  1. touch the four corners in a fixed order -> swap and inversion
  2. slide along all four edges -> raw min/max of each axis
  3. several fingers at once -> multi-touch works
and prints the DT lines to use.

"Top-left" etc. means as you look at the screen with the console text upright.

Run on the tablet (needs root to read /dev/input and to bind the driver):
  sudo python3 test_09.py | tee result_09.txt
"""
import glob
import os
import select
import struct
import sys
import time

sys.stdout.reconfigure(line_buffering=True)   # prompts show up even through tee

EV_KEY, EV_ABS = 1, 3
BTN_TOUCH = 330
ABS_X, ABS_Y, ABS_MT_SLOT, ABS_MT_TRACKING_ID = 0, 1, 47, 57
EVENT = struct.Struct('llHHi')                 # struct input_event on 64-bit
BIND = '/sys/bus/i2c/drivers/silead_ts/bind'


def find_device():
    for n in glob.glob('/sys/class/input/event*/device/name'):
        if open(n).read().strip() == 'silead_ts':
            return '/dev/input/' + n.split('/')[4]
    return None


def ensure_bound():
    dev = find_device()
    if dev:
        return dev
    # locate i2c1 (fe5a0000) by hardware address, never by bus number
    bus = None
    for a in glob.glob('/sys/bus/i2c/devices/i2c-*'):
        if '/fe5a0000.i2c/' in os.path.realpath(a):
            bus = a.rsplit('-', 1)[1]
    if bus is None:
        sys.exit('ABORT: i2c1 (fe5a0000) not found')
    print(f'silead_ts not bound - binding {bus}-0040 (firmware upload takes ~4 s) ...')
    try:
        with open(BIND, 'w') as f:
            f.write(f'{bus}-0040')
    except OSError as e:
        sys.exit(f'ABORT: bind failed ({e}) - check dmesg')
    for _ in range(20):
        time.sleep(0.5)
        dev = find_device()
        if dev:
            return dev
    sys.exit('ABORT: bound, but no silead_ts input device appeared')


class Touch:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        self.x = self.y = None
        self.down = False
        self.slots = set()

    def events(self, timeout):
        """Yield ('down'|'move'|'up', x, y) until timeout seconds pass."""
        end = time.time() + timeout
        buf = b''
        while True:
            left = end - time.time()
            if left <= 0:
                return
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                return
            buf += os.read(self.fd, EVENT.size * 64)
            while len(buf) >= EVENT.size:
                _, _, typ, code, val = EVENT.unpack_from(buf)
                buf = buf[EVENT.size:]
                if typ == EV_ABS and code == ABS_X:
                    self.x = val
                elif typ == EV_ABS and code == ABS_Y:
                    self.y = val
                elif typ == EV_ABS and code == ABS_MT_SLOT:
                    self.slots.add(val)
                elif typ == EV_KEY and code == BTN_TOUCH:
                    if val and not self.down:
                        self.down = True
                    elif not val and self.down:
                        self.down = False
                        yield ('up', self.x, self.y)
                        continue
                elif typ == 0 and self.down and self.x is not None and self.y is not None:
                    yield ('move', self.x, self.y)

    def drain(self):
        for _ in self.events(0.3):
            pass


def median(v):
    v = sorted(v)
    return v[len(v) // 2]


def one_touch(t, name, timeout=30):
    t.drain()
    print(f'\n>>> Touch the {name} corner, as close to the corner as you can, then lift.')
    xs, ys = [], []
    for kind, x, y in t.events(timeout):
        if kind == 'move':
            xs.append(x)
            ys.append(y)
        elif kind == 'up' and xs:
            p = (median(xs), median(ys))
            print(f'    {name}: raw x={p[0]} y={p[1]}  ({len(xs)} samples)')
            return p
    sys.exit(f'ABORT: no touch seen for {name} within {timeout} s')


def main():
    if os.geteuid() != 0:
        sys.exit('ABORT: run as: sudo python3 test_09.py | tee result_09.txt')
    print('=== Touchscreen orientation / range (test_09) ===')
    print(time.strftime('%c'))
    dev = ensure_bound()
    print(f'device: {dev}')
    t = Touch(dev)

    # --- 1. corners ---------------------------------------------------------
    print('\n--- 1. corners ("top-left" = as you read the console text) ---')
    c = {}
    for name in ('TOP-LEFT', 'TOP-RIGHT', 'BOTTOM-RIGHT', 'BOTTOM-LEFT'):
        c[name] = one_touch(t, name)

    # --- 2. edges -----------------------------------------------------------
    print('\n>>> Now slide one finger slowly along ALL FOUR EDGES, right up to the')
    print('    bezel, once around the whole screen. You have 20 s.')
    t.drain()
    xs, ys = [], []
    for kind, x, y in t.events(20):
        if kind == 'move':
            xs.append(x)
            ys.append(y)
    if len(xs) < 20:
        sys.exit('ABORT: too few samples during the edge sweep')
    xmin, xmax, ymin, ymax = min(xs), max(xs), min(ys), max(ys)
    print(f'    edge sweep: {len(xs)} samples, raw x {xmin}..{xmax}, raw y {ymin}..{ymax}')

    # --- 3. multi-touch -----------------------------------------------------
    print('\n>>> Put 3 fingers on the screen at the same time and hold 3 s.')
    t.slots.clear()
    t.drain()
    for _ in t.events(8):
        pass
    print(f'    slots seen: {sorted(t.slots) or "[0] only"}  -> '
          f'{"multi-touch OK" if len(t.slots) >= 2 else "only one finger reported"}')

    # --- analysis -----------------------------------------------------------
    print('\n--- analysis ---')
    tl, tr, br, bl = c['TOP-LEFT'], c['TOP-RIGHT'], c['BOTTOM-RIGHT'], c['BOTTOM-LEFT']
    hx, hy = tr[0] - tl[0], tr[1] - tl[1]          # moving right on screen
    vx, vy = bl[0] - tl[0], bl[1] - tl[1]          # moving down on screen
    swap = abs(hy) > abs(hx)
    if swap:
        # reported X = raw y (after inversion), reported Y = raw x
        inv_y = hy < 0      # raw y must grow left->right
        inv_x = vx < 0      # raw x must grow top->bottom
        ok = abs(vx) > abs(vy)
    else:
        inv_x = hx < 0
        inv_y = vy < 0
        ok = abs(vy) > abs(vx)
    # rectangle sanity: opposite sides roughly parallel
    rect = (abs((br[0] - bl[0]) - hx) < 0.2 * max(abs(hx), abs(hy)) and
            abs((br[1] - bl[1]) - hy) < 0.2 * max(abs(hx), abs(hy)))
    print(f'  right-on-screen moves raw ({hx:+d},{hy:+d}), down-on-screen moves raw ({vx:+d},{vy:+d})')
    print(f'  swap x/y: {swap}   invert raw x: {inv_x}   invert raw y: {inv_y}')
    if not ok or not rect:
        print('  WARNING: corners are not a clean rectangle - repeat the test before using these values')
    sx, sy = xmax + 1, ymax + 1
    print('\n  Suggested DT properties for touchscreen@40 (replace touchscreen-size-x/-y):')
    print(f'\t\ttouchscreen-size-x = <{sx}>;\t/* raw x max {xmax} + 1 */')
    print(f'\t\ttouchscreen-size-y = <{sy}>;\t/* raw y max {ymax} + 1 */')
    if swap:
        print('\t\ttouchscreen-swapped-x-y;')
    if inv_x:
        print('\t\ttouchscreen-inverted-x;')
    if inv_y:
        print('\t\ttouchscreen-inverted-y;')
    print(f'  (raw minima seen: x {xmin}, y {ymin} - a finger rarely reaches 0 at the bezel;')
    print('   left at 0 unless they turn out to be far from it)')
    print('\n=== done ===')


if __name__ == '__main__':
    main()
