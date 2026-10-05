"""Extract Portal 2 gun assets from an installed, locally owned copy.

Archives and loose files are read-only. VPK entries are CRC checked and every
generated file records its SHA-256 and source provenance. Output is local art,
not redistributable project source.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

from extract_source_weapons import VPK


def extract(source_root: Path, output: Path):
    source_root, output = source_root.resolve(), output.resolve()
    if not (source_root / 'portal2').is_dir():
        raise ValueError('source_root must be the Portal 2 installation directory')
    index = {}
    # Later search paths override the base game, matching Portal 2 updates.
    for folder in ('portal2', 'portal2_dlc1', 'portal2_dlc2', 'update'):
        root = source_root / folder
        for archive_path in sorted(root.glob('*_dir.vpk')):
            if 'sound_vo' in archive_path.name:
                continue
            archive = VPK(archive_path)
            index.update({name: (archive, name) for name in archive.entries})
        for path in (root / 'scripts').glob('*.txt'):
            index['scripts/' + path.name.lower()] = (None, path)
    patterns = [r'^models/weapons/(?:[vw]_portalgun|w_models/w_portalgun/w_portalgun)\.',
                r'^materials/models/weapons/(?:v_models/v_portalgun|w_models/portalgun)/',
                r'^materials/(?:effects|sprites|particle)/[^/]*portal',
                r'^materials/portals/', r'^sound/weapons/portalgun',
                r'^particles/(?:portalgun|portal_projectile|portals)\.pcf$',
                r'^scripts/(?:game_sounds_weapons_portal|game_sounds_portal|weapon_portalgun)\.txt$']
    pending = {n for n in index if any(re.search(p, n) for p in patterns)}
    if 'models/weapons/v_portalgun.mdl' not in pending:
        raise ValueError('Original Portal 2 viewmodel was not found')
    files = {}
    while pending:
        name = pending.pop()
        if name in files:
            continue
        archive, source = index[name]
        data = archive.read(source) if archive else source.read_bytes()
        path = output.joinpath(*PurePosixPath(name).parts)
        if not path.resolve().is_relative_to(output):
            raise ValueError('Output escapes extraction root')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        files[name] = {'sha256': hashlib.sha256(data).hexdigest(),
                       'source': str(archive.path if archive else source)}
        if name.endswith(('.vmt', '.txt')):
            text = data.decode('utf-8', errors='replace')
            for token in re.findall(r'"([^"\r\n]+)"', text):
                token = token.lower().replace('\\', '/').lstrip('*#@^)(<>!')
                candidates = ['sound/' + token] if token.endswith('.wav') else []
                material = token.removesuffix('.vtf').removesuffix('.vmt').removeprefix('materials/')
                candidates += ['materials/' + material + e for e in ('.vtf', '.vmt')]
                pending.update(n for n in candidates if n in index and n not in files)
    manifest = {'schema': 'kf2vr/portal-extract/1', 'source_root': str(source_root),
                'extractor_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'files': dict(sorted(files.items()))}
    output.mkdir(parents=True, exist_ok=True)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps({'files': len(files), 'models': [n for n in files if n.endswith('.mdl')]}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    extract(args.source_root, args.output)
