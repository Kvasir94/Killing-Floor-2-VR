"""Deterministic spray-paint masks for the weapon wheel.

White RGB with the shape in alpha, so the Canvas tints each draw. Atlas
regions (512 x 512):
  slash   (0,   0, 512, 192)  selected-item brush slash
  stroke  (0, 192, 512,  48)  ammo bar / underline, drawn horizontally scaled
  smoke   (0, 256, 256, 256)  dark vignette behind the whole wheel
  burst   (256, 256, 256, 256) spray ring flung out when the wheel opens
"""
import math
import struct
from pathlib import Path

SIZE = 512


def _hash(i, j, seed):
    h = (i * 374761393 + j * 668265263 + seed * 982451653) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def _noise(x, y, seed):
    xi, yi = math.floor(x), math.floor(y)
    xf, yf = x - xi, y - yi
    u, v = xf * xf * (3 - 2 * xf), yf * yf * (3 - 2 * yf)
    a = _hash(xi, yi, seed); b = _hash(xi + 1, yi, seed)
    c = _hash(xi, yi + 1, seed); d = _hash(xi + 1, yi + 1, seed)
    return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v


def _fbm(x, y, seed):
    return (_noise(x, y, seed) * .55 + _noise(x * 2.1, y * 2.1, seed + 1) * .3
            + _noise(x * 4.3, y * 4.3, seed + 2) * .15)


def _clamp(v):
    return 0.0 if v < 0 else (1.0 if v > 1 else v)


def _slash(x, y):
    u, v = (x - 256) / 232.0, (y - 96) / 66.0
    d = (abs(u) ** 2.4 + abs(v) ** 2) ** .5
    d += (_fbm(x / 38.0, y / 11.0, 11) - .5) * .38
    alpha = _clamp((1 - d) / .08)
    alpha *= .7 + .3 * _fbm(x / 95.0, y / 3.2, 12)
    if 1 < d < 1.4 and _hash(x, y, 13) > .986:
        alpha = max(alpha, .85)
    return alpha


def _stroke(x, y):
    if x < 10 or x > 502:
        return 0.0
    t = (x - 10) / 492.0
    half = 12 * min(1, t * 10, (1 - t) * 10) ** .5 + (_fbm(x / 16.0, 3.0, 21) - .5) * 5
    dy = abs(y - 24 + (_fbm(x / 70.0, 7.0, 22) - .5) * 5)
    alpha = _clamp((half - dy) / 2.2) * (.82 + .18 * _fbm(x / 45.0, y / 2.0, 23))
    if half < dy < half + 7 and _hash(x, y, 24) > .965:
        alpha = max(alpha, .7)
    return alpha


def _smoke(x, y):
    r = math.hypot(x - 128, y - 128) / 128.0
    if r >= 1:
        return 0.0
    if r < .62:
        return .72 - (.72 - .48) * r / .62
    return .48 * (1 - (r - .62) / .38)


def _burst(x, y):
    dx, dy = x - 128, y - 128
    r = math.hypot(dx, dy)
    a = math.atan2(dy, dx)
    wobble = (_fbm(a * 6 + 20, r / 12.0, 31) - .5) * 16
    alpha = _clamp(1 - abs(r - 100 + wobble) / 8) * (.55 + .45 * _fbm(a * 14 + 20, r / 4.0, 32))
    # Thin outward drips on a third of the angles.
    lane = int((a + math.pi) / (2 * math.pi) * 72)
    if _hash(lane, 0, 33) > .66 and 104 < r < 104 + 22 * _hash(lane, 1, 33):
        across = abs(((a + math.pi) / (2 * math.pi) * 72 - lane) - .5)
        alpha = max(alpha, _clamp(1 - across * 6) * .9)
    if 84 < r < 124 and _hash(x, y, 34) > .975:
        alpha = max(alpha, .8)
    return alpha


def generate(path):
    pixels = bytearray(SIZE * SIZE * 4)
    for y in range(SIZE):
        for x in range(SIZE):
            if y < 192:
                alpha = _slash(x, y)
            elif y < 240:
                alpha = _stroke(x, y - 192)
            elif y < 256:
                alpha = 0.0
            elif x < 256:
                alpha = _smoke(x, y - 256)
            else:
                alpha = _burst(x - 256, y - 256)
            i = (y * SIZE + x) * 4
            pixels[i:i + 4] = bytes((255, 255, 255, int(alpha * 255 + .5)))
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28) + pixels
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)
    return path


if __name__ == '__main__':
    import sys
    print(generate(sys.argv[1] if len(sys.argv) > 1 else
                   Path(__file__).resolve().parents[1] / 'build/hand-meshes/VRHorzineWheelSpray.tga'))
