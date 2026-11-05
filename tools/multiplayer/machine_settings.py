"""Per-PC launcher choices that must survive a new KF2-VR release.

The game folder, store, last join address, server name and host password used
to live in each extracted release's settings.json, so every update forgot them.
They now live in the profile beside launcher.json. A release's own
settings.json is still read for any key the profile does not have yet, so the
first launch of a new release picks up what the previous one remembered.
"""
import json
from pathlib import Path

import workshop_loadout

KEYS = ("game_root", "store", "address", "server_name", "host_password", "server_root")
FILE = "machine.json"


def _read(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {key: value[key] for key in KEYS if isinstance(value, dict) and isinstance(value.get(key), str)}


def _profile(profile_root):
    # Through workshop_loadout so a caller's profile override applies here too.
    return Path(profile_root or workshop_loadout.profile_root())


def load(package_root, profile_root=None):
    """Profile values, with the release's legacy settings.json filling any gaps."""
    return {**_read(Path(package_root) / "settings.json"), **_read(_profile(profile_root) / FILE)}


def save(updates, profile_root=None):
    folder = _profile(profile_root)
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / FILE
    values = _read(path)
    values.update({key: str(value) for key, value in updates.items() if key in KEYS and value is not None})
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(values, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)
