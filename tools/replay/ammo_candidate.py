"""Verify an explicit replay candidate without changing the player selection."""
import json
from pathlib import Path
from release_state import digest, verify_release, verify_workspace


def verify_candidate(root, record):
    root = Path(root).resolve()
    pointer = root / 'build/multiplayer/current-release.json'
    if digest(pointer) != record['selected_pointer_sha256']:
        raise RuntimeError('Player selection changed since ammo replay preparation')
    selection = json.loads(pointer.read_text(encoding='utf-8-sig'))
    if selection['release'] != record['selected_release']:
        raise RuntimeError('Player selection identity changed')
    candidate = Path(record['candidate_root']).resolve()
    if candidate.parent != (root / 'build/multiplayer/releases').resolve():
        raise RuntimeError('Ammo candidate must be a generated repository release')
    manifest = verify_release(candidate, record['candidate_manifest_sha256'])
    verify_workspace(root, manifest)
    return candidate, manifest
