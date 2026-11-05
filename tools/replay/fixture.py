"""Per-lane replay fixtures: one KF2 game copy and one lock per agent lane.

Every replay used to queue on the one game install and the one
Local\\KF2VR_DevelopmentFixture lease. A lane (KF2VR_FIXTURE=<lane>, or
--fixture <lane> on scripted.py) gets its own copy of the game under
D:\\KF2-Fixtures\\<lane>\\killingfloor2 and its own lock, so lanes run at once.

The copy hard-links the read-only content (cooked packages, movies,
localization) from the Steam install, which costs no space, and makes real
copies of what a run writes to: Binaries (the native proxy is installed
there), Development (the observer compile) and the config folders. That is
about 400 MB per lane. Nothing links to the repository's build/ folder.

  python tools/replay/fixture.py create harness
  python tools/replay/fixture.py refresh harness   # after a Steam update
  python tools/replay/fixture.py remove harness
  python tools/replay/fixture.py list
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(os.environ.get('KF2VR_FIXTURE_ROOT', r'D:\KF2-Fixtures'))
GLOBAL_LOCK = r'Local\KF2VR_DevelopmentFixture'
# Written by a run, so each lane gets its own bytes; everything else is linked.
COPIED = ('Binaries', 'Development', 'KFGame/Config', 'KFGame/Script', 'Engine/Config')
SKIPPED = ('Artbook', 'Soundtrack', 'Wallpaper', 'KFGame/Logs', 'KFGame/Screenshots')
# The native proxy is installed and restored per run (NativeDeployment). A copy
# taken while another run's proxy sits in the install must not inherit it, and
# a refresh never touches a lane's own live install.
PROXY = ('dinput8.dll', 'openxr_loader.dll')
LANE = re.compile(r'[a-z][a-z0-9-]{0,23}')


def lane(explicit: str | None = None) -> str | None:
    """The lane this process runs in, or None for the shared install."""
    name = explicit or os.environ.get('KF2VR_FIXTURE') or None
    if name is not None and not LANE.fullmatch(name):
        raise ValueError(f'Fixture lane must match {LANE.pattern}: {name!r}')
    return name


def source_root() -> Path:
    return Path(json.loads((ROOT/'docs/intake/install_manifest.json').read_text())['game_root'])


def game_root(name: str | None = None) -> Path:
    name = lane(name)
    return source_root() if name is None else FIXTURES/name/'killingfloor2'


def lock_name(name: str | None = None) -> str:
    name = lane(name)
    return GLOBAL_LOCK if name is None else GLOBAL_LOCK+'_'+name


def owns(path: Path, root: Path) -> bool:
    try:
        return Path(path).resolve().is_relative_to(root.resolve())
    except OSError:
        return False


def _size(paths) -> int:
    return sum(f.stat().st_size for p in paths if p.exists() for f in p.rglob('*') if f.is_file())


def create(name: str, refresh: bool = False) -> Path:
    name = lane(name)
    if name is None:
        raise ValueError('A lane name is required')
    source, target = source_root().resolve(), game_root(name)
    if owns(target, ROOT/'build') or owns(target, source):
        raise RuntimeError('A fixture must live outside the repository build/ and the Steam install')
    if target.exists() and not refresh:
        raise RuntimeError(f'Fixture exists: {target} (use refresh)')
    if os.path.splitdrive(str(source))[0].lower() != os.path.splitdrive(str(target))[0].lower():
        raise RuntimeError('Hard links need the fixture on the same drive as the game install')
    need = _size([source/p for p in COPIED]) + (2 << 30)
    free = shutil.disk_usage(target.anchor).free
    if free < need:
        raise RuntimeError(f'Not enough space on {target.anchor}: {free >> 20} MB free, {need >> 20} MB needed')
    target.mkdir(parents=True, exist_ok=True)
    copied = {source/p for p in COPIED}
    skipped = {source/p for p in SKIPPED}
    linked = 0
    for folder, dirs, files in os.walk(source):
        here = Path(folder)
        dirs[:] = [d for d in dirs if here/d not in skipped]
        rel = here.relative_to(source)
        (target/rel).mkdir(parents=True, exist_ok=True)
        inside_copy = any(here == c or c in here.parents for c in copied)
        for file in files:
            src, dst = here/file, target/rel/file
            if rel == Path('Binaries/Win64') and file.lower() in PROXY:
                continue
            if inside_copy:
                if not dst.exists() or dst.stat().st_size != src.stat().st_size or dst.stat().st_mtime < src.stat().st_mtime:
                    if dst.exists() and dst.stat().st_nlink > 1:
                        dst.unlink()   # never write through a link into the install
                    shutil.copy2(src, dst)
                continue
            if dst.exists():
                if os.path.samefile(src, dst):
                    continue
                dst.unlink()
            os.link(src, dst)
            linked += 1
    (target.parent/'fixture.json').write_text(json.dumps(
        {'schema': 'kf2vr/replay-fixture/1', 'lane': name, 'source': str(source), 'game_root': str(target),
         'lock': lock_name(name), 'copied': list(COPIED), 'linked_files_refreshed': linked}, indent=2), encoding='utf-8')
    return target


def remove(name: str) -> None:
    name = lane(name)
    target = FIXTURES/name
    if not (target/'fixture.json').exists():
        raise RuntimeError(f'Not a fixture: {target}')
    for dll in ('dinput8.dll', 'openxr_loader.dll'):
        if (target/'killingfloor2/Binaries/Win64'/dll).exists():
            raise RuntimeError(f'A native proxy is still installed in {target}; restore its run first')
    # Linked files are removed as links; the install keeps its own copy.
    shutil.rmtree(target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('action', choices=('create', 'refresh', 'remove', 'list'))
    parser.add_argument('lane', nargs='?')
    opts = parser.parse_args()
    if opts.action == 'list':
        for receipt in sorted(FIXTURES.glob('*/fixture.json')):
            data = json.loads(receipt.read_text(encoding='utf-8'))
            print(f"{data['lane']}: {data['game_root']} lock={data['lock']}")
        return 0
    if not opts.lane:
        parser.error('lane is required')
    if opts.action == 'remove':
        remove(opts.lane)
        print(f'Removed fixture {opts.lane}')
        return 0
    print(f'Fixture {opts.lane}: {create(opts.lane, refresh=opts.action == "refresh")}')
    print('A new KFGame.exe path: once, from an elevated PowerShell, allow it through the firewall with')
    print('  powershell -NoProfile -ExecutionPolicy Bypass -File '+str(ROOT/'tools/replay/fixture-firewall.ps1'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
