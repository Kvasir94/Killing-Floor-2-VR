"""Collect only timestamped, logged replay screenshots inside their owned run."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
from urllib.parse import quote
import zlib

MAX_CAPTURES = 128
MAX_BYTES = 256 * 1024 * 1024
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MARKER = 'KF2VR_REPLAY_CAPTURE'
NAME = re.compile(r'KF2VR_Replay_([0-9]{20})_([1-9][0-9]*)_([1-9][0-9]*)')


def capture_requests(text, max_captures=None, max_cases=16):
    """Parse diagnostic requests, never filesystem paths supplied by a log."""
    max_captures = max_captures or MAX_CAPTURES
    entries, errors, seen, per_case = [], [], set(), Counter()
    for line_number, line in enumerate(text.splitlines(), 1):
        if not re.search(r'\b'+MARKER+r'\b', line):
            continue
        try:
            payload = line.split(MARKER, 1)[1].strip()
            fields = re.findall(r'([A-Za-z]+)=([^\s]+)', payload)
            row = dict(fields)
            required = {'caseIndex', 'index', 'name', 'event', 'time'}
            extended = required | {'eventTime', 'deferred'}
            if (len(fields) != len(row) or set(row) not in (required, extended) or
                    ' '.join(k+'='+v for k, v in fields) != payload):
                raise ValueError('Malformed or duplicate capture fields')
            name = NAME.fullmatch(row['name'])
            case, index = int(row['caseIndex']), int(row['index'])
            seconds = float(row['time'])
            if not name or (int(name[2]), int(name[3])) != (case, index):
                raise ValueError('Capture name does not match case/sequence')
            if not 1 <= case <= max_cases or not 1 <= index <= 16:
                raise ValueError(f'Capture case must be 1..{max_cases} and sequence 1..16')
            if not math.isfinite(seconds) or seconds <= 0:
                raise ValueError('Capture game time must be positive and finite')
            event_seconds, deferred = seconds, False
            if set(row) == extended:
                event_seconds = float(row['eventTime'])
                if not math.isfinite(event_seconds) or event_seconds <= 0 or event_seconds > seconds+0.001:
                    raise ValueError('Capture event time must be positive, finite and no later than request time')
                if row['deferred'].lower() not in ('true', 'false'):
                    raise ValueError('Invalid capture deferred flag')
                deferred = row['deferred'].lower() == 'true'
            if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,63}', row['event']):
                raise ValueError('Invalid capture event token')
            if (case, index) in seen:
                raise ValueError('Duplicate capture case/sequence')
            if len(entries) >= max_captures or per_case[case] >= 16:
                raise ValueError('Capture request count exceeds suite/case bound')
            if index != per_case[case] + 1:
                raise ValueError('Missing or unordered capture sequence')
            seen.add((case, index))
            per_case[case] += 1
            entries.append(dict(case_index=case, index=index, name=row['name'], event=row['event'],
                                log_line=line_number, requested_game_seconds=seconds,
                                event_game_seconds=event_seconds, deferred=deferred, status='missing'))
        except (ValueError, OverflowError) as error:
            errors.append(f'Log line {line_number}: {error}')
    if not entries:
        errors.append('No valid logged replay capture requests')
    return entries, errors


def _bmp_info(data):
    if len(data) < 54 or data[:2] != b'BM':
        raise ValueError('Not a BMP screenshot')
    offset, header = struct.unpack_from('<II', data, 10)
    width, signed_height, planes, bits, compression = struct.unpack_from('<iiHHI', data, 18)
    height = abs(signed_height)
    if header < 40 or offset < 14+header or planes != 1 or bits not in (24, 32) or compression != 0:
        raise ValueError('Unsupported BMP screenshot encoding')
    if not (0 < width <= 8192 and 0 < height <= 8192):
        raise ValueError('Invalid BMP screenshot dimensions')
    stride = ((width*bits + 31)//32)*4
    if height*stride > MAX_IMAGE_BYTES or offset+height*stride > len(data):
        raise ValueError('Truncated or oversized BMP screenshot')
    first = data[offset:offset+3]
    different = any(data[offset+y*stride+x*(bits//8):offset+y*stride+x*(bits//8)+3] != first
                    for y in range(height) for x in range(width))
    return dict(width=width, height=height, nonuniform=different)


def _png_info(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Not a PNG screenshot')
    position, chunks, header, complete = 8, [], None, False
    while position+12 <= len(data):
        length = struct.unpack_from('>I', data, position)[0]
        kind = data[position+4:position+8]
        end = position+12+length
        if end > len(data):
            raise ValueError('Truncated PNG chunk')
        value = data[position+8:end-4]
        crc = struct.unpack_from('>I', data, end-4)[0]
        if zlib.crc32(kind+value) != crc:
            raise ValueError('PNG chunk checksum mismatch')
        if kind == b'IHDR':
            if header is not None or length != 13 or position != 8:
                raise ValueError('Invalid PNG header')
            header = struct.unpack('>IIBBBBB', value)
        elif kind == b'IDAT':
            if header is None:
                raise ValueError('PNG pixel data precedes its header')
            chunks.append(value)
        elif kind == b'IEND':
            if length != 0 or end != len(data):
                raise ValueError('Invalid PNG end chunk')
            complete = True
            break
        position = end
    if not header or not complete or not chunks:
        raise ValueError('Incomplete PNG screenshot')
    width, height, depth, color, compression, filtering, interlace = header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if (not 0 < width <= 8192 or not 0 < height <= 8192 or depth != 8 or not channels
            or compression or filtering or interlace):
        raise ValueError('Unsupported PNG screenshot encoding/dimensions')
    stride = width*channels
    expected = (stride+1)*height
    if expected > MAX_IMAGE_BYTES:
        raise ValueError('Oversized decoded PNG screenshot')
    decoder = zlib.decompressobj()
    raw = decoder.decompress(b''.join(chunks), expected+1)
    if len(raw) != expected or not decoder.eof or decoder.unconsumed_tail or decoder.unused_data:
        raise ValueError('Truncated or oversized PNG pixel stream')
    previous, first, different = bytearray(stride), None, False
    for y in range(height):
        start = y*(stride+1)
        filter_kind, row = raw[start], bytearray(raw[start+1:start+1+stride])
        if filter_kind > 4:
            raise ValueError('Invalid PNG row filter')
        for x in range(stride):
            left = row[x-channels] if x >= channels else 0
            above = previous[x]
            corner = previous[x-channels] if x >= channels else 0
            if filter_kind == 1:
                row[x] = (row[x]+left) & 255
            elif filter_kind == 2:
                row[x] = (row[x]+above) & 255
            elif filter_kind == 3:
                row[x] = (row[x]+((left+above)//2)) & 255
            elif filter_kind == 4:
                predictor = left+above-corner
                distances = (abs(predictor-left), abs(predictor-above), abs(predictor-corner))
                prediction = (left, above, corner)[distances.index(min(distances))]
                row[x] = (row[x]+prediction) & 255
        for x in range(0, stride, channels):
            pixel = bytes(row[x:x+(3 if color in (2, 6) else 1)])
            if color in (4, 6) and row[x+channels-1] == 0:
                continue
            if first is None:
                first = pixel
            elif pixel != first:
                different = True
        previous = row
    return dict(width=width, height=height, nonuniform=different)


def _linked(path):
    return path.is_symlink() or bool(getattr(path, 'is_junction', lambda: False)())


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def _utc(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat()


def collect_captures(run, game_log, *, started_unix, finished_unix, source_roots=None,
                     max_captures=None, max_cases=16, max_bytes=None):
    """Collect logged screenshots from the run and caller-supplied trusted roots.

    Scripted replays raise the bounds; the legacy suites keep the defaults.

    Engine originals remain untouched; only verified copies and lossless PNGs
    are written inside the run. No source root is ever read from a log.
    """
    max_bytes = max_bytes or MAX_BYTES
    run = Path(run).resolve()
    destination, source_root = run/'captures', run/'driver/ScreenShotPath'
    trusted_roots = [source_root] + [Path(path).absolute() for path in (source_roots or [])]
    entries, errors = capture_requests(game_log, max_captures, max_cases)
    result = dict(schema='kf2vr/replay-captures/1', passed=False, entries=entries, errors=errors,
                  started_unix=started_unix, finished_unix=finished_unix,
                  source_root=str(source_root), index=str(destination/'index.json'),
                  source_roots=[str(path) for path in trusted_roots],
                  html=str(destination/'index.html'), game_log='../driver/game.log',
                  collected_bytes=0, visual_acceptance_verified=False)
    try:
        if (not math.isfinite(started_unix) or not math.isfinite(finished_unix)
                or not 0 < started_unix <= finished_unix):
            raise ValueError('Invalid actual replay time bounds')
        if _linked(destination) or _linked(source_root) or _linked(source_root.parent):
            raise ValueError('Screenshot directories must not be links/junctions')
        if not source_root.resolve().is_relative_to(run) or not destination.resolve().is_relative_to(run):
            raise ValueError('Screenshot paths escape their owned replay run')
        destination.mkdir(exist_ok=True)
        originals = destination/'originals'
        if _linked(originals) or not originals.resolve().is_relative_to(run):
            raise ValueError('Original screenshot copies must remain inside the owned run')
        originals.mkdir(exist_ok=True)
        candidates = {entry['name']: [] for entry in entries}
        exact = {entry['name']: [] for entry in entries}
        suffixed = {entry['name']: [] for entry in entries}
        patterns = {name: re.compile(r'[A-Za-z0-9_.() -]*'+re.escape(name)+r'(?:0)?\.(?:bmp|png)', re.I)
                    for name in candidates}
        visited_roots, seen_paths = set(), set()
        for trusted_root in trusted_roots:
            if _linked(trusted_root):
                errors.append('Trusted screenshot root is a link/junction: '+str(trusted_root))
                continue
            if not trusted_root.exists():
                continue
            resolved_root = trusted_root.resolve()
            if resolved_root in visited_roots:
                continue
            visited_roots.add(resolved_root)
            if not trusted_root.is_dir():
                errors.append('Trusted screenshot root is not a directory: '+str(trusted_root))
                continue
            inspected = directories = 0
            def walk_error(error):
                errors.append('Screenshot search failed: '+str(error))
            for folder, dirs, files in os.walk(trusted_root, followlinks=False, onerror=walk_error):
                directories += 1
                if directories > 128:
                    raise ValueError('Screenshot search exceeded its directory bound')
                dirs[:] = [name for name in sorted(dirs) if not _linked(Path(folder)/name)
                           and (Path(folder)/name).resolve().is_relative_to(resolved_root)]
                # The game's shared screenshot folder keeps every older shot
                # (thousands). Only this run's window counts toward the bound;
                # older files are skipped unread and left in place.
                current = []
                for filename in files:
                    try:
                        mtime = os.stat(os.path.join(folder, filename), follow_symlinks=False).st_mtime
                    except OSError:
                        continue
                    if started_unix <= mtime <= finished_unix:
                        current.append(filename)
                inspected += len(current)
                if inspected > 4096:
                    raise ValueError('Screenshot search exceeded its file bound')
                for filename in sorted(current):
                    for name, pattern in patterns.items():
                        if not pattern.fullmatch(filename):
                            continue
                        path = Path(folder)/filename
                        if _linked(path) or not path.resolve().is_relative_to(resolved_root) or not path.is_file():
                            errors.append('Capture is not an ordinary file within its trusted root: '+filename)
                            continue
                        stat = path.stat()
                        if started_unix <= stat.st_mtime <= finished_unix:
                            resolved_path = path.resolve()
                            # The same explicit root may be supplied through an
                            # overlapping trusted parent; do not invent duplicates.
                            if (name, resolved_path) in seen_paths:
                                continue
                            seen_paths.add((name, resolved_path))
                            candidates[name].append(path)
                            target = suffixed if re.search(re.escape(name)+r'0\.(?:bmp|png)$', filename, re.I) else exact
                            target[name].append(path)
        # A literal sequence 10 and sequence 1 plus UE's trailing 0 overlap.
        # Resolve a complete, consistent naming convention across the run;
        # never attach the same file to two requests.
        modes = [mode for mode in (exact, suffixed) if entries and all(len(mode[e['name']]) == 1 for e in entries)]
        if len(modes) == 1:
            used = {path for paths in modes[0].values() for path in paths}
            all_paths = {path for paths in candidates.values() for path in paths}
            if all_paths - used:
                errors.append('Extra current-session images match capture requests ambiguously')
            candidates = modes[0]
        elif len(modes) > 1:
            errors.append('Both exact and UE-suffixed screenshot sequences exist; collection is ambiguous')
        assigned_sources = set()
        for entry in entries:
            paths = candidates[entry['name']]
            if len(paths) != 1:
                entry['status'] = 'ambiguous' if paths else 'missing-or-stale'
                errors.append(entry['name']+': '+entry['status'])
                continue
            source = paths[0]
            try:
                if source in assigned_sources:
                    raise ValueError('One screenshot cannot satisfy two capture requests')
                assigned_sources.add(source)
                stat = source.stat()
                if not 0 < stat.st_size <= MAX_IMAGE_BYTES or result['collected_bytes']+stat.st_size > max_bytes:
                    raise ValueError('Screenshot exceeds image/suite byte budget')
                data = source.read_bytes()
                if len(data) != stat.st_size:
                    raise ValueError('Screenshot changed while reading')
                result['collected_bytes'] += stat.st_size
                source_hash = hashlib.sha256(data).hexdigest().upper()
                copied = originals/(entry['name']+source.suffix.lower())
                if _linked(copied):
                    raise ValueError('Original screenshot copy is a link; preserved')
                if copied.exists():
                    if _sha(copied) != source_hash:
                        raise ValueError('Existing original screenshot copy differs; preserved')
                else:
                    with copied.open('xb') as outgoing:
                        outgoing.write(data)
                if _sha(copied) != source_hash:
                    raise ValueError('Original screenshot copy hash mismatch')
                entry.update(original_source_path=str(source.resolve()), original_source_name=source.name,
                             original_source_sha256=source_hash, source_path=str(copied.resolve()),
                             source_sha256=source_hash, copied_sha256=_sha(copied),
                             source_size_bytes=stat.st_size, file_written_utc=_utc(stat.st_mtime),
                             game_log_relative='../driver/game.log')
                image_info = _bmp_info(data) if source.suffix.lower() == '.bmp' else _png_info(data)
                entry.update(**image_info)
                if not image_info['nonuniform']:
                    raise ValueError('Screenshot has uniform/blank pixels')
                image = copied
                if source.suffix.lower() == '.bmp':
                    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
                    from melee_runtime_launcher import bmp_to_png
                    image = destination/(entry['name']+'.png')
                    if _linked(image):
                        raise ValueError('Converted screenshot must not be a link')
                    fd, temporary = tempfile.mkstemp(prefix='.capture-', suffix='.png', dir=destination)
                    os.close(fd)
                    temporary = Path(temporary)
                    try:
                        bmp_to_png(copied, temporary)
                        if result['collected_bytes']+temporary.stat().st_size > max_bytes:
                            raise ValueError('Converted screenshots exceed suite byte budget')
                        if image.exists():
                            if _sha(image) != _sha(temporary):
                                raise ValueError('Existing converted screenshot differs; preserved')
                        else:
                            with image.open('xb') as outgoing, temporary.open('rb') as incoming:
                                shutil.copyfileobj(incoming, outgoing)
                        result['collected_bytes'] += image.stat().st_size
                    finally:
                        temporary.unlink(missing_ok=True)
                if _sha(source) != source_hash or source.stat().st_mtime != stat.st_mtime:
                    raise ValueError('Engine screenshot changed during collection')
                entry.update(status='collected', image_path=str(image.resolve()), image_sha256=_sha(image),
                             image_relative=os.path.relpath(image, destination).replace('\\', '/'),
                             source_relative=os.path.relpath(copied, destination).replace('\\', '/'))
            except (OSError, ValueError, zlib.error, struct.error) as error:
                entry.update(status='invalid', error=str(error))
                errors.append(entry['name']+': '+str(error))
        result['passed'] = bool(entries) and not errors and all(e['status'] == 'collected' for e in entries)
    except (OSError, ValueError, TypeError) as error:
        errors.append(str(error))
    # Never follow an unexpected output link even when recording a failure.
    if destination.is_dir() and not _linked(destination) and destination.resolve().is_relative_to(run):
        for path in (destination/'index.json', destination/'index.html'):
            if _linked(path):
                errors.append('Capture index is a link; preserved')
                result['passed'] = False
                return result
        Path(result['index']).write_text(json.dumps(result, indent=2), encoding='utf-8')
        lines = ['<!doctype html><meta charset="utf-8"><title>Replay captures</title>',
                 '<style>body{font:16px system-ui;max-width:1100px;margin:auto}img{max-width:100%;height:auto}article{margin:2em 0}</style>',
                 '<h1>Replay captures</h1><p>Actual engine screenshots; subjective visual acceptance remains unverified.</p>',
                 '<p><a href="../driver/game.log">Game log</a> · <a href="index.json">Capture metadata</a></p>']
        for entry in entries:
            lines.append('<article><h2>Case '+str(entry['case_index'])+' / '+html.escape(entry['event'])+'</h2>')
            lines.append('<p>Event game time '+str(entry['event_game_seconds'])+' s · screenshot request '+
                         str(entry['requested_game_seconds'])+' s · deferred '+str(entry['deferred'])+
                         ' · log line '+str(entry['log_line'])+
                         ' · '+html.escape(entry['status'])+'</p>')
            if entry.get('image_path'):
                lines.append('<p>Written UTC '+html.escape(entry['file_written_utc'])+
                             ' · <a href="'+quote(entry['source_relative'], safe='/')+'">Original engine image</a></p>')
                lines.append('<details><summary>File hashes</summary><p>Original SHA-256: <code>'+
                             entry['source_sha256']+'</code></p><p>Displayed image SHA-256: <code>'+
                             entry['image_sha256']+'</code></p></details>')
                lines.append('<img loading="lazy" src="'+quote(entry['image_relative'], safe='/')+'" alt="'+
                             html.escape(entry['name'], quote=True)+'">')
            lines.append('</article>')
        if errors:
            lines.append('<h2>Collection errors</h2><ul>'+''.join('<li>'+html.escape(e)+'</li>' for e in errors)+'</ul>')
        Path(result['html']).write_text('\n'.join(lines)+'\n', encoding='utf-8')
    return result
