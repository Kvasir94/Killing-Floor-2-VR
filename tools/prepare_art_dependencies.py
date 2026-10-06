"""Fetch pinned public PSK importer source/library into local build directories."""
import hashlib
import json
import subprocess
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / 'tools/art-dependency-pins.json').read_text())


def fetch(pin, destination):
    destination = Path(destination)
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        pending = destination.with_suffix('.download')
        urllib.request.urlretrieve(pin['url'], pending)
        if hashlib.sha256(pending.read_bytes()).hexdigest().upper() != pin['sha256']:
            raise RuntimeError('Downloaded art dependency differs from its pin.')
        pending.replace(destination)
    if hashlib.sha256(destination.read_bytes()).hexdigest().upper() != pin['sha256']:
        raise RuntimeError('Cached art dependency differs from its pin.')
    return destination


def extract_checked(archive, source):
    with zipfile.ZipFile(archive) as z:
        for entry in z.infolist():
            target = (source / entry.filename).resolve()
            if not target.is_relative_to(source.resolve()):
                raise RuntimeError('Art dependency archive escapes extraction directory.')
            if entry.is_dir():
                continue
            data = z.read(entry)
            if target.exists() and target.read_bytes() != data:
                raise RuntimeError('Extracted art dependency changed: ' + entry.filename)
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                target.write_bytes(data)


def main():
    cache = ROOT / 'build/art-dependencies'
    archive = fetch(PINS['psk_importer'], cache / 'psk-importer-9.1.3.zip')
    wheel = fetch(PINS['psk_library'], cache / 'psk_psa_py-0.0.4-py3-none-any.whl')
    umodel = fetch(PINS['umodel'], cache / 'umodel.exe')
    fetch(PINS['umodel_sdl'], cache / 'SDL2.dll')
    for name, folder in [('sourceio', 'SourceIO'), ('openxr', 'openxr-sdk')]:
        pin = PINS[name]
        checkout = ROOT / 'third_party' / folder
        if not checkout.exists():
            subprocess.run(['git', 'clone', '--no-checkout', pin['repository'], str(checkout)], check=True)
            subprocess.run(['git', '-C', str(checkout), 'checkout', '--detach', pin['commit']], check=True)
        head = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
        changes = subprocess.check_output(['git', '-C', str(checkout), 'status', '--porcelain'], text=True).strip()
        if head != pin['commit'] or changes:
            raise RuntimeError('Dependency checkout differs from its clean pin: ' + name)
    source = cache / 'source'
    extract_checked(archive, source)
    extract_checked(wheel, cache / 'library')
    # The runner loads only this reviewed source and pure Python wheel. No
    # global addon installation or access to the author's Blender preferences.
    location = source / PINS['psk_importer']['root']
    print('PSK importer source ready:', location)
    print('PSK format library ready:', wheel)
    print('Pinned local UModel ready:', umodel)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
