"""Find one verified pending deployment across adjacent manual Epic candidates."""
import json
from pathlib import Path

from native_fixture import NativeDeployment


def recover_candidates(root, destination, digest):
    # Caller holds DevelopmentFixture and has excluded running games. Do not
    # search arbitrary release folders or accept a linked candidate/session.
    root, destination = Path(root).resolve(), Path(destination).resolve()
    roots = {root, *root.parent.glob('Epic-VR-Manual-*'), *root.parent.glob('KF2VR-Multiplayer-*')}
    if root.name == 'app':
        roots.update(p/'app' for p in root.parent.parent.glob('KF2VR-Multiplayer-*'))
    matches = []
    verified_clean = False
    allowed = {'dinput8.dll', 'openxr_loader.dll'}
    for candidate in sorted(roots):
        if not candidate.is_dir() or candidate.absolute() != candidate.resolve():
            continue
        manifest_path = candidate/'release.json'
        if not manifest_path.is_file():
            continue
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        if manifest.get('epic_manual_candidate') is not True and manifest.get('store_launcher_protocol') != 1:
            continue
        receipt = manifest.get('native_build', {})
        for journal_path in sorted((candidate/'sessions').glob('*/native-backup/deployment.json')):
            if journal_path.absolute() != journal_path.resolve():
                continue
            journal = json.loads(journal_path.read_text(encoding='utf-8'))
            items = journal.get('files', {})
            if (journal.get('schema') != 'kf2vr/native-deployment/1'
                    or journal.get('destination') != str(destination)
                    or not items or not set(items).issubset(allowed)):
                continue
            # Earlier completed owners must not compare their original absence
            # against a later session's installed DLL and block its recovery.
            if all(item.get('restored') is True for item in items.values()):
                if set(items) == allowed and not (destination/'dinput8.dll').exists() and all(not (destination/name).is_symlink() and
                       (digest(destination/name) if (destination/name).exists() else None) == item.get('original')
                       for name, item in items.items()):
                    verified_clean = True
                continue
            valid = True
            installed = False
            for name, item in items.items():
                target, source = destination/name, candidate/'Native'/name
                if (target.is_symlink() or source.is_symlink() or not source.is_file()
                        or item.get('installed') != receipt.get('artifacts_sha256', {}).get(name)
                        or digest(source) != item.get('installed')):
                    valid = False
                    break
                current = digest(target) if target.exists() else None
                if current not in (item.get('original'), item.get('installed')):
                    valid = False
                    break
                if item.get('restored') and current != item.get('original'):
                    valid = False
                    break
                installed |= not item.get('restored') and current == item.get('installed')
                if item.get('original'):
                    prior = journal_path.parent/name
                    if prior.is_symlink() or not prior.is_file() or digest(prior) != item['original']:
                        valid = False
                        break
            if valid and installed:
                matches.append((candidate, journal_path.parent, receipt))
    if len(matches) > 1:
        raise RuntimeError('Multiple ownership journals match; preserve DLLs for review.')
    if not matches:
        if verified_clean:
            return None
        if (destination/'dinput8.dll').exists() or (destination/'openxr_loader.dll').exists():
            raise RuntimeError('No unique pending owned deployment matches installed files; preserve them for review.')
        return None
    candidate, backup, receipt = matches[0]
    errors = NativeDeployment(candidate/'Native', destination, backup, receipt, digest).restore()
    if errors:
        raise RuntimeError('; '.join(errors))
    return backup
