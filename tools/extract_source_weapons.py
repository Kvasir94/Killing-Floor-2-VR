"""Extract the requested Valve weapon assets from a local, owned installation.

Only regenerable local output is written. Source VPKs are read-only; each entry
is CRC checked. The manifest records archive provenance and extracted hashes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import zlib


class VPK:
    def __init__(self, path):
        self.path = Path(path).resolve()
        with self.path.open('rb') as f:
            magic, version, size = struct.unpack('<III', f.read(12))
            if magic != 0x55AA1234 or version not in (1, 2):
                raise ValueError(f'Unsupported VPK: {path}')
            self.header = 28 if version == 2 else 12
            f.seek(self.header)
            data = f.read(size)
        self.data_start = self.header + size
        self.entries = {}
        pos = 0

        def string():
            nonlocal pos
            end = data.index(b'\0', pos)
            value = data[pos:end].decode('utf-8')
            pos = end + 1
            return value

        while (ext := string()):
            while (directory := string()):
                while (stem := string()):
                    crc, preload, archive, offset, length, end = struct.unpack_from('<IHHIIH', data, pos)
                    pos += 18
                    if end != 0xFFFF or pos + preload > len(data):
                        raise ValueError('Invalid VPK entry')
                    name = f'{directory}/{stem}.{ext}' if directory != ' ' else f'{stem}.{ext}'
                    if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts or ':' in name or '\\' in name:
                        raise ValueError(f'Unsafe VPK path: {name}')
                    self.entries[name.lower()] = (crc, archive, offset, length, data[pos:pos + preload])
                    pos += preload

    def read(self, name):
        crc, archive, offset, length, preload = self.entries[name]
        path = self.path if archive == 0x7FFF else self.path.with_name(self.path.name.removesuffix('_dir.vpk') + f'_{archive:03d}.vpk')
        with path.open('rb') as f:
            f.seek(offset + (self.data_start if archive == 0x7FFF else 0))
            result = preload + f.read(length)
        if len(result) != len(preload) + length or zlib.crc32(result) != crc:
            raise ValueError(f'VPK integrity failure: {name}')
        return result


def extract(root, output, kind):
    archives = [VPK(p) for p in sorted(Path(root).glob('*_dir.vpk')) if 'sound_vo' not in p.name]
    index = {name: archive for archive in archives for name in archive.entries}
    if kind == 'gravity':
        patterns = [r'models/weapons/(v_superphyscannon|w_physics)\.', r'materials/models/weapons/(v_physcannon|w_physics)/',
                    r'materials/(sprites/(blueflare1(_noz)?|lgtning(_noz)?|physcannon_blue[^/]+)|effects/fluttercore)\.vmt$',
                    r'sound/weapons/physcannon/', r'scripts/game_sounds_weapons\.txt$']
    else:
        patterns = [r'models/weapons/(c_models/c_stickybomb_launcher/c_stickybomb_launcher|w_models/w_stickybomb|v_models/v_stickybomb_launcher_demo)\.',
                    r'materials/models/weapons/[cvw]_.*(sticky|pipebomb)',
                    r'sound/weapons/(sticky|pipe_bomb|pipebomb|grenade_launcher|explode|explosion)',
                    r'particles/(explosion|explosion_high|rockettrail|stickybomb|firstperson_weapon_fx)\.pcf$',
                    r'scripts/(game_sounds_weapons|tf_weapon_pipebomblauncher)\.txt$']
    names = {name for name in index if any(re.search(p, name) for p in patterns)}
    if not any(name.endswith('.mdl') for name in names):
        raise ValueError(f'Original {kind} weapon model is missing from {root}')
    output = Path(output).resolve()
    files = {}
    while names:
        name = names.pop()
        if name in files:
            continue
        data = index[name].read(name)
        target = output.joinpath(*PurePosixPath(name).parts)
        if not target.resolve().is_relative_to(output):
            raise ValueError('Output escapes extraction root')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        files[name] = {'sha256': hashlib.sha256(data).hexdigest(), 'archive': str(index[name].path)}
        if name.endswith('.vmt'):
            # Resolve material patches and texture inputs, never external paths.
            for token in re.findall(r'"([^"\r\n]+)"', data.decode('utf-8', errors='replace')):
                token = token.lower().replace('\\', '/').removesuffix('.vtf').removesuffix('.vmt')
                for extension in ('.vtf', '.vmt'):
                    candidate = ('materials/' + token.removeprefix('materials/') + extension)
                    if candidate in index and candidate not in files:
                        names.add(candidate)
    manifest = {'schema': 'kf2vr/source-weapon-extract/1', 'kind': kind, 'source_root': str(Path(root).resolve()),
                'extractor_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'files': dict(sorted(files.items()))}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps({'kind': kind, 'files': len(files), 'models': [x for x in files if x.endswith('.mdl')]}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['gravity', 'sticky'])
    parser.add_argument('source_root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    extract(args.source_root, args.output, args.kind)
