"""Extract Engineer assets from an owned TF2 install into ignored local output.

VPK entries are CRC checked, and every extracted file has archive provenance
and a SHA256 receipt. This does not change or redistribute the TF2 install.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

from extract_source_weapons import VPK

PATTERNS = (
    r"models/buildables/(sentry[123](_blueprint|_heavy|_rockets)?|toolbox)\.",
    r"models/buildables/gibs/sentry[123]_gib\d+\.",
    r"models/buildables/sentry_shield\.",
    r"models/weapons/c_models/(c_wrangler|c_engineer_animations)\.",
    r"models/weapons/w_models/w_wrangler\.",
    r"models/weapons/[cvw]_models/[cvw]_(pda_engineer|builder|toolbox|wrench)\.",
    r"models/weapons/c_models/c_(pda_engineer|builder|toolbox|wrench)(/[^/]+)?\.",
    r"materials/models/buildables/(sentry[123]|toolbox)/.*\.vmt$",
    r"materials/models/weapons/[cvw]_(pda_engineer|builder|toolbox|wrench)/.*\.vmt$",
    r"materials/models/weapons/c_items/c_(pda|builder|toolbox|wrench)[^/]*\.vmt$",
    r"materials/models/weapons/(c_models/c_wrench/|c_items/c_wrangler)[^/]*\.vmt$",
    r"materials/models/buildables/sentry_shield/.*\.vmt$",
    r"materials/effects/sniperdot_(red|blue)\.vmt$",
    r"materials/backpack/weapons/c_models/c_wrangler(_large)?\.vmt$",
    r"materials/hud/(eng_(build|status)[^/]*|hud_obj_status_sentry_[123])\.vmt$",
    r"sound/weapons/(sentry|wrench|pda|build)[^/]*\.wav$",
    r"sound/\w+/(build|metal_pickup|ammo_pickup)[^/]*\.wav$",
    r"scripts/(objects|game_sounds_(weapons|items|player)|tf_weapon_(pda_engineer_build|pda_engineer_destroy|builder|wrench))\.txt$",
    r"resource/ui/(build_menu|hudobjstatus|hudmetal|hudbuilding)[^/]*\.res$",
)


def extract(source_root: Path, output: Path) -> dict:
    archives = [VPK(p) for p in sorted(source_root.glob('*_dir.vpk')) if 'sound_vo' not in p.name]
    index = {name: archive for archive in archives for name in archive.entries}
    pending = {n for n in index if any(re.search(pattern, n) for pattern in PATTERNS)}
    required = {f'models/buildables/sentry{i}.mdl' for i in (1, 2, 3)}
    if not required.issubset(pending):
        raise ValueError(f'TF2 sentry models missing from {source_root}')
    output = output.resolve()
    files = {}
    while pending:
        name = min(pending)
        pending.remove(name)
        if name in files:
            continue
        data = index[name].read(name)
        target = output.joinpath(*PurePosixPath(name).parts)
        if not target.resolve().is_relative_to(output):
            raise ValueError(f'Output escapes extraction root: {name}')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        files[name] = {'sha256': hashlib.sha256(data).hexdigest(), 'archive': str(index[name].path)}
        if name.endswith('.mdl'):
            # Studio models can keep their real sequences in an included MDL
            # (sentry1_heavy -> sentry1_animations). Follow owned archive
            # references, including animation blocks and model companions.
            for raw in re.findall(rb'[A-Za-z0-9_/\\.\-]+\.(?:mdl|ani)', data):
                candidate = raw.decode('ascii').lower().replace('\\', '/')
                if not candidate.startswith('models/'):
                    candidate = 'models/' + candidate
                if candidate not in index:
                    continue
                siblings = [candidate]
                if candidate.endswith('.mdl'):
                    siblings += [candidate[:-4] + ext for ext in ('.vvd', '.dx90.vtx', '.dx80.vtx', '.sw.vtx', '.phy', '.ani')]
                pending.update(n for n in siblings if n in index and n not in files)
        if name.endswith('.vmt'):
            for token in re.findall(r'"([^"\r\n]+)"', data.decode('utf-8', errors='replace')):
                token = token.lower().replace('\\', '/').removesuffix('.vtf').removesuffix('.vmt')
                for ext in ('.vtf', '.vmt'):
                    candidate = 'materials/' + token.removeprefix('materials/') + ext
                    if candidate in index and candidate not in files:
                        pending.add(candidate)
    receipt = {'schema': 'kf2vr/engineer-extract/1', 'source_root': str(source_root.resolve()),
               'extractor_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'vpk_reader_sha256': hashlib.sha256(Path(__file__).with_name('extract_source_weapons.py').read_bytes()).hexdigest(),
               'files': files}
    (output / 'manifest.json').write_text(json.dumps(receipt, indent=2))
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_root', type=Path)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'extract/engineer')
    args = parser.parse_args()
    receipt = extract(args.source_root, args.output)
    print(json.dumps({'files': len(receipt['files']), 'models': [n for n in receipt['files'] if n.endswith('.mdl')]}))
