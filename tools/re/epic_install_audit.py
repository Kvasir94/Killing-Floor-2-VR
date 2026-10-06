"""Compare installed KF2 store builds read-only; never launch or deploy.

Usage: python tools/re/epic_install_audit.py --steam ROOT --epic ROOT
       --server ROOT --output build/epic-install-audit.json
Only installation content is inspected. User profiles, launcher tokens and
process command lines are deliberately outside this audit.
"""
import argparse
import hashlib
import json
from pathlib import Path
from pe import PE


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest().upper()


def compare(steam, epic, relative):
    left, right = steam / relative, epic / relative
    result = dict(path=relative, steam_exists=left.is_file(), epic_exists=right.is_file())
    for name, path in [('steam', left), ('epic', right)]:
        if path.is_file():
            result[name + '_sha256'] = digest(path)
            result[name + '_bytes'] = path.stat().st_size
    result['identical'] = bool(left.is_file() and right.is_file() and result['steam_sha256'] == result['epic_sha256'])
    return result


def audit(steam, epic, server=None):
    packages = sorted({p.name for root in (steam, epic) for p in (root/'KFGame/BrewedPC').glob('*.u')})
    files = [compare(steam, epic, 'KFGame/BrewedPC/'+name) for name in packages]
    files += [compare(steam, epic, relative) for relative in (
        'KFGame/Config/DefaultEngine.ini', 'Engine/Config/BaseEngine.ini',
        'Binaries/Win64/EOSSDK-Win64-Shipping.dll', 'Binaries/Win64/steam_api64.dll')]
    binaries = {}
    for store, root in [('steam', steam), ('epic', epic)]:
        path = root/'Binaries/Win64/KFGame.exe'
        pe = PE(str(path))
        binaries[store] = dict(path=str(path), sha256=digest(path), machine=hex(pe.machine),
                              image_base=hex(pe.image_base), file_bytes=len(pe.data),
                              imports=[dll for dll, _ in pe.imports()],
                              delay_imports=[row[0] for row in pe.delay_imports()],
                              sdk_present=(root/'Binaries/Win64/KFEditor.exe').is_file())
    result = dict(schema='kf2vr/store-install-audit/1', read_only=True, binaries=binaries,
                  files=files, runtime_verified=False,
                  remaining=['Epic-managed authenticated launch and argument/environment handoff',
                             'Epic headset solo/menu/input/travel/exit acceptance',
                             'Epic/Steam cross-store host/join on pinned SteamCMD server',
                             'Epic deployment recovery and vanilla restoration',
                             'Optional classes/content under Epic account'])
    if server:
        stock = server/'Binaries/Win64/KFServer.exe'
        bundled = epic/'Binaries/Win64/KFServer.exe'
        result['server'] = dict(pinned_path=str(stock), pinned_sha256=digest(stock),
                                epic_bundled_sha256=digest(bundled),
                                identical=digest(stock)==digest(bundled),
                                use_shared_pinned_server=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--steam', type=Path, required=True)
    parser.add_argument('--epic', type=Path, required=True)
    parser.add_argument('--server', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.steam, args.epic, args.server)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    identical = sum(row['identical'] for row in result['files'])
    print(f"Compared {len(result['files'])} files: {identical} byte-identical. Runtime not verified.")


if __name__ == '__main__':
    main()
