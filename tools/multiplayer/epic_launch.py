"""Epic's documented protocol activation, without handling account credentials.

https://dev.epicgames.com/docs/epic-games-store/protocol-activation
The documented app protocol accepts action and silent. It does not document
per-launch arguments/environment or return the game PID. Do not treat the URI
handler process as the game, and do not infer VR-session ownership from time.
"""
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
from urllib.parse import quote

import game_install


class EpicHandoffUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class EpicTarget:
    root: Path
    namespace: str
    catalog_item: str
    artifact: str

    def uri(self) -> str:
        parts = (self.namespace, self.catalog_item, self.artifact)
        if self.artifact != 'Finch' or any(not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', part) for part in parts):
            raise ValueError('Invalid Epic KF2 application identity')
        return 'com.epicgames.launcher://apps/' + quote(':'.join(parts), safe='') + '?action=launch&silent=true'


def resolve_target(installation, manifest_dir=None):
    """Bind launcher app identity to the selected completed installation."""
    if installation.store != 'epic':
        raise ValueError('Epic protocol requires an Epic installation')
    if manifest_dir is None:
        manifest_dir = Path(os.environ.get('ProgramData', 'C:/ProgramData'))/'Epic/EpicGamesLauncher/Data/Manifests'
    targets = set()
    for path in sorted(Path(manifest_dir).glob('*.item')):
        try:
            item = json.loads(path.read_text(encoding='utf-8-sig'))
            if not isinstance(item, dict) or item.get('AppName') != 'Finch' or item.get('bIsIncompleteInstall') is not False:
                continue
            location = item.get('InstallLocation')
            if not isinstance(location, str) or not Path(location).is_absolute():
                continue
            if str(Path(location).resolve()).casefold() != str(installation.root.resolve()).casefold():
                continue
            if str(item.get('LaunchExecutable', '')).replace('\\', '/').casefold() != game_install.EXECUTABLE.as_posix().casefold():
                continue
            target = EpicTarget(installation.root.resolve(), item.get('CatalogNamespace', ''),
                                item.get('CatalogItemId', ''), item.get('AppName', ''))
            target.uri()  # Validate before making it selectable.
            targets.add(target)
        except (OSError, ValueError, TypeError):
            continue
    if len(targets) != 1:
        raise ValueError('Epic launch identity is missing or ambiguous for this installation. Repair it in Epic Games Launcher.')
    if not installation.executable.is_file():
        raise ValueError('Epic KF2 executable is missing')
    return targets.pop()


def require_session_handoff(*, arguments=(), environment=None):
    """Fail before deployment until a supported early-start handoff is wired.

    A file read by AdapterMain cannot replace Unreal's startup URL and INI
    arguments. Epic's already-running launcher also does not inherit our env.
    Never silently discard these requirements or invent undocumented URI keys.
    """
    if arguments or environment:
        raise EpicHandoffUnavailable(
            'Epic-managed VR session launch is not ready: Epic must supply the '
            'session launch options before KF2 starts. The documented launch '
            'protocol cannot carry those options. No game or deployment was started.')


def prepare_vanilla(installation, manifest_dir=None):
    target = resolve_target(installation, manifest_dir)
    if (installation.executable.parent/'dinput8.dll').exists():
        raise RuntimeError('Native mod files remain in this Epic installation. Finish the owning session recovery before vanilla launch.')
    return target


def activate_vanilla(installation, manifest_dir=None, *, opener=None):
    """Explicit user action only. Returns no game PID or ownership claim.

    Authentication stays within Epic and KF2. Do not enumerate command lines,
    copy exchange codes, or replace the handler with a shell command.
    """
    target = prepare_vanilla(installation, manifest_dir)
    if opener is None:
        if os.name != 'nt':
            raise OSError('Epic protocol activation requires Windows')
        opener = os.startfile
    opener(target.uri())
    return {'status': 'activation_requested', 'store': 'epic',
            'root': str(target.root), 'game_pid': None, 'owns_game_process': False}
