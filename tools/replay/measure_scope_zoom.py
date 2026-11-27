"""Measure a physical optic's apparent magnification from a scripted replay.

Reads a run made with scripts/issues/212-scope-zoom.kfs: each eye distance has a
"lens-<d>" shot (eye behind the lens) and a "plain-<d>" shot (same view, gun
lowered). The lens circle is found in the lens shot; its central crop is matched
against the plain shot over a range of scales. The best scale is the apparent
magnification of the lens image against the world seen directly, which is what
a player compares when looking through the glass.

  python tools/replay/measure_scope_zoom.py <run or batch folder> [--expect gun=M ...]
"""
import argparse
import glob
import math
import os
import re
import sys

import cv2
import numpy as np


def captures(session):
    log = open(os.path.join(session, 'game.log'), encoding='utf-8', errors='replace').read()
    for case in re.split(r'KF2VR_SCRIPT case n=', log)[1:]:
        weapon = re.search(r'weapon=(\S+)', case)
        shots = dict((event, name) for name, event in re.findall(r'name=(\S+) event=(\S+)', case))
        yield (weapon.group(1) if weapon else '?'), shots


def lens_circle(gray):
    h, w = gray.shape
    blurred = cv2.medianBlur(gray, 5)
    circles = cv2.HoughCircles(blurred, cv2.HOUGH_GRADIENT, dp=1.5, minDist=40, param1=80, param2=40,
                               minRadius=int(h * 0.04), maxRadius=int(h * 0.45))
    if circles is None:
        return None
    best = min(circles[0], key=lambda c: (c[0] - w / 2) ** 2 + (c[1] - h / 2) ** 2)
    return float(best[0]), float(best[1]), float(best[2])


def magnification(lens_path, plain_path, crop_px):
    lens = cv2.imread(lens_path, cv2.IMREAD_GRAYSCALE)
    plain = cv2.imread(plain_path, cv2.IMREAD_GRAYSCALE)
    # The eye is on the lens axis, so the lens is centred in the eye's view.
    y, x = lens.shape[0] / 2, lens.shape[1] / 2
    circle = (x, y, crop_px)
    half = int(crop_px)
    crop = lens[int(y) - half:int(y) + half, int(x) - half:int(x) + half]
    if crop.size == 0:
        return None, circle
    best = (-1.0, None)
    for scale in np.arange(0.25, 4.01, 0.01):
        size = int(round(crop.shape[1] / scale))
        if size < 12 or size >= min(plain.shape):
            continue
        template = cv2.resize(crop, (size, size), interpolation=cv2.INTER_AREA)
        # The lens axis and the eye axis are parallel: search near the centre.
        cy, cx = plain.shape[0] // 2, plain.shape[1] // 2
        span = max(size, int(plain.shape[0] * 0.25))
        window = plain[max(0, cy - span):cy + span, max(0, cx - span):cx + span]
        if window.shape[0] <= size or window.shape[1] <= size:
            continue
        score = cv2.matchTemplate(window, template, cv2.TM_CCOEFF_NORMED).max()
        if score > best[0]:
            best = (float(score), float(scale))
    return best, circle


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folder')
    parser.add_argument('--expect', action='append', default=[], help='gun-substring=magnification')
    parser.add_argument('--radius', action='append', default=[], help='gun-substring=lens radius in UU')
    parser.add_argument('--width', type=float, default=1765, help='screenshot width in pixels')
    parser.add_argument("--crop", type=float, default=0.3, help='crop half-size as a fraction of the estimated lens radius')
    args = parser.parse_args()
    expect = dict(item.split('=', 1) for item in args.expect)
    radii = dict(item.split('=', 1) for item in args.radius)
    failures = 0
    for game_log in sorted(glob.glob(os.path.join(args.folder, '**', 'game.log'), recursive=True)):
        session = os.path.dirname(game_log)
        if os.path.basename(session) == 'driver':
            continue
        for weapon, shots in captures(session):
            target = next((float(v) for k, v in expect.items() if k.lower() in weapon.lower()), None)
            radius = next((float(v) for k, v in radii.items() if k.lower() in weapon.lower()), 1.2)
            for event in sorted(shots):
                found = re.fullmatch(r'lens-(\d+)', event)
                if not found or 'plain-' + found.group(1) not in shots:
                    continue
                lens = os.path.join(session, 'captures', shots[event] + '.png')
                plain = os.path.join(session, 'captures', shots['plain-' + found.group(1)] + '.png')
                # Crop half the lens's expected on-screen radius (flat view about 90 degrees wide).
                lens_px = math.degrees(math.atan(radius / float(found.group(1)))) / (90.0 / args.width)
                (score, scale), circle = magnification(lens, plain, lens_px * args.crop) if os.path.exists(lens) else ((None, None), None)
                line = f'{weapon} eye={found.group(1)} '
                if scale is None:
                    print(line + 'no lens/match found'); failures += 1; continue
                line += f'magnification={scale:.2f} match={score:.2f} crop_px={circle[2]:.0f}'
                if target:
                    error = scale / target - 1
                    line += f' expected={target:.2f} error={error:+.1%}'
                    if abs(error) > 0.05:
                        failures += 1
                print(line)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
