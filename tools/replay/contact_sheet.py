"""Lay out a replay run's named screenshots as a labelled contact sheet.

Groups captures by session case (number and weapon) from each run's
captures/index.json (captures.py names the case, weapon and settings on every
entry); older runs without those fields fall back to the game log's "drawn"
lines. Each group wraps onto rows of --columns tiles, so a long session gives
a tall sheet rather than one 14000-pixel row. For reviewing screenshot
replays by eye (e.g. 227-melee-zone-view.kfs, #227).

  python tools/replay/contact_sheet.py <run folder> <out.png> [--names a,b,c] [--width 480] [--columns 6]
"""
import argparse
import json
import re
from pathlib import Path

CAPTURE = re.compile(r'KF2VR_REPLAY_CAPTURE .*?name=(KF2VR_Replay_\S+) event=(\S+)')
DRAWN = re.compile(r'KF2VR_SCRIPT .*drawn hand=\d+ held=(\S+)')


def group_label(entry):
    parts = [f"case {entry['case']}" if entry.get('case') is not None else '']
    parts += [entry.get('weapon', '').split('.')[-1], entry.get('settings', '')]
    return '  '.join(p for p in parts if p) or 'captures'


def index_groups(index, folder):
    """[(label, [(event, image path)])] from one captures/index.json."""
    groups, current = [], None
    for entry in index.get('entries', []):
        if not entry.get('image_relative'):
            continue
        label = group_label(entry)
        if current is None or current[0] != label:
            current = (label, [])
            groups.append(current)
        held = '/'.join(entry.get(k, '') for k in ('held_left', 'held_right') if entry.get(k))
        current[1].append((entry['event'] + (f' [{held}]' if held else ''), folder/entry['image_relative']))
    return groups


def log_groups(log, captures):
    """Fallback for runs whose index has no case fields: weapon from "drawn" lines."""
    out, weapon, current = [], None, None
    for line in log.read_text(encoding='utf-8', errors='replace').splitlines():
        m = DRAWN.search(line)
        if m:
            if m.group(1) != weapon:
                weapon = m.group(1)
                current = (weapon, [])
                out.append(current)
            continue
        m = CAPTURE.search(line)
        if m and current is not None:
            image = captures / (m.group(1) + '.png')
            if image.exists():
                current[1].append((m.group(2), image))
    return out


def rows(run):
    out = []
    for log in sorted(Path(run).rglob('game.log')):
        # Solo sessions keep a copy in driver/; online clients only have that one.
        if log.parent.name == 'driver' and (log.parent.parent / 'game.log').exists():
            continue
        captures = log.parent / 'captures'
        if not captures.exists():
            captures = log.parent.parent / 'captures'
        index = captures / 'index.json'
        data = json.loads(index.read_text(encoding='utf-8')) if index.exists() else {}
        if any(e.get('case') is not None for e in data.get('entries', [])):
            out += index_groups(data, captures)
        else:
            out += log_groups(log, captures)
    return out


def layout(groups, columns):
    """Wrap each group onto rows of at most `columns` tiles: [(label, tiles)];
    a continued row's label says so."""
    out = []
    for label, shots in groups:
        for start in range(0, len(shots), columns):
            out.append((label if start == 0 else f'{label} (cont.)', shots[start:start+columns]))
    return out


def main():
    from PIL import Image, ImageDraw
    ap = argparse.ArgumentParser()
    ap.add_argument('run', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--names', default='')
    ap.add_argument('--width', type=int, default=480)
    ap.add_argument('--columns', type=int, default=6, help='Tiles per row before wrapping (default 6)')
    a = ap.parse_args()
    keep = [n for n in a.names.split(',') if n]
    data = []
    for label, shots in rows(a.run):
        shots = [s for s in shots if not keep or s[0].split(' [')[0] in keep]
        if shots:
            data.append((label, shots))
    if not data:
        raise SystemExit('no captures found')
    lines = layout(data, max(1, a.columns))
    cols = max(len(s) for _, s in lines)
    first = Image.open(lines[0][1][0][1])
    w = a.width
    h = int(first.height * w / first.width)
    label_h, caption = 22, 18
    sheet = Image.new('RGB', (cols * w, len(lines) * (h + label_h + caption)), (20, 20, 20))
    draw = ImageDraw.Draw(sheet)
    for r, (label, shots) in enumerate(lines):
        y = r * (h + label_h + caption)
        draw.text((6, y + 4), label, fill=(255, 220, 120))
        for c, (event, path) in enumerate(shots):
            img = Image.open(path).convert('RGB').resize((w, h))
            sheet.paste(img, (c * w, y + label_h))
            draw.text((c * w + 6, y + label_h + h + 2), event, fill=(255, 255, 255))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(a.out)
    print(a.out, len(lines), 'rows')


if __name__ == '__main__':
    main()
