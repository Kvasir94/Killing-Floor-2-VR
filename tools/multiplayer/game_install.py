"""Read-only KF2 store discovery and exact-build validation.

Recognition is deliberately separate from native support. Never use a store's
version string as permission to load the adapter into a different executable.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re

STEAM_SHA256 = "77AB9C2CF43AEAA3038274FFF3822064815A3EA02A1B3C81870CDC12A885C994"
EPIC_SHA256 = "80CE504F73DBC76C06E3888ABAA5B69DF6AE6E7C23C39ABB778D3C47B508DB9A"
BUILDS = {STEAM_SHA256: ("steam", "1.0.8767.0"),
          EPIC_SHA256: ("epic", "1.0.8767.0")}
EXECUTABLE = Path("Binaries/Win64/KFGame.exe")


@dataclass(frozen=True)
class Installation:
    store: str
    root: Path
    version: str = ""
    app_name: str = ""

    @property
    def executable(self) -> Path:
        return self.root / EXECUTABLE

    def to_dict(self) -> dict:
        return {**asdict(self), "root": str(self.root)}


def epic_installations(manifest_dir: Path) -> list[Installation]:
    """Read Epic's completed install records; never inspect auth data."""
    result = []
    for path in sorted(manifest_dir.glob("*.item")):
        try:
            item = json.loads(path.read_text(encoding="utf-8-sig"))
            if not isinstance(item, dict) or item.get("AppName") != "Finch":
                continue
            # Require explicit completion, not a missing or truthy string field.
            if item.get("bIsIncompleteInstall") is not False:
                continue
            root = item.get("InstallLocation")
            if not isinstance(root, str) or not root or not Path(root).is_absolute():
                continue
            launch = str(item.get("LaunchExecutable", "")).replace("\\", "/").lower()
            if launch != EXECUTABLE.as_posix().lower():
                continue
            install = Installation("epic", Path(root), str(item.get("AppVersionString", "")), "Finch")
            if install.executable.is_file():
                result.append(install)
        except (OSError, ValueError, TypeError):
            continue
    return deduplicate(result)


def steam_installations(steam_roots: list[Path]) -> list[Installation]:
    libraries = list(steam_roots)
    for root in steam_roots:
        try:
            text = (root / "steamapps/libraryfolders.vdf").read_text(encoding="utf-8-sig")
            libraries.extend(Path(value.replace("\\\\", "\\")) for value in
                             re.findall(r'"path"\s+"([^"\r\n]+)"', text, re.I))
        except OSError:
            continue
    result = []
    for library in libraries:
        try:
            text = (library / "steamapps/appmanifest_232090.acf").read_text(encoding="utf-8-sig")
            fields = dict(re.findall(r'"([^"\r\n]+)"\s+"([^"\r\n]*)"', text))
            name = fields.get("installdir", "")
            # App manifests identify the directory. Never follow traversal.
            if not name or name in (".", "..") or any(c in name for c in "\\/:"):
                continue
            if fields.get("appid") != "232090":
                continue
            if int(fields.get("StateFlags", "0")) != 4:
                continue
            install = Installation("steam", library / "steamapps/common" / name,
                                   fields.get("buildid", ""), "232090")
            if install.executable.is_file():
                result.append(install)
        except (OSError, ValueError):
            continue
    return deduplicate(result)


def deduplicate(installs: list[Installation]) -> list[Installation]:
    unique = {}
    for install in installs:
        unique.setdefault(str(install.root.resolve()).casefold(), install)
    return list(unique.values())


def discover(*, steam_roots=None, epic_manifest_dir=None) -> list[Installation]:
    if steam_roots is None:
        steam_roots = [Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Steam"]
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                steam_roots.insert(0, Path(winreg.QueryValueEx(key, "SteamPath")[0]))
        except (ImportError, OSError):
            pass
    if epic_manifest_dir is None:
        epic_manifest_dir = Path(os.environ.get("ProgramData", "C:/ProgramData")) / "Epic/EpicGamesLauncher/Data/Manifests"
    return deduplicate(steam_installations(steam_roots) + epic_installations(epic_manifest_dir))


def select(installs: list[Installation], *, store=None, root=None) -> Installation:
    candidates = [i for i in installs if (store is None or i.store == store)
                  and (root is None or str(i.root.resolve()).casefold() == str(Path(root).resolve()).casefold())]
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise ValueError("No completed Killing Floor 2 installation found for this selection.")
    raise ValueError("Choose a Killing Floor 2 installation: " + "; ".join(f"{i.store}: {i.root}" for i in candidates))


def fingerprint(install: Installation) -> dict:
    with install.executable.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest().upper()
    known = BUILDS.get(digest)
    return {"sha256": digest, "recognized": known is not None,
            "binary_store": known[0] if known else None,
            "file_version": known[1] if known else None}


def select_for_launch(*, store="auto", root=None, saved_root=None, installs=None):
    """Resolve a visible store choice, including manually located exact builds."""
    if store not in ("auto", "steam", "epic"):
        raise ValueError("Choose Auto, Steam or Epic.")
    if root is not None:
        root = Path(root).resolve()
        probe = Installation("unknown", root)
        if not probe.executable.is_file():
            raise ValueError("The selected folder does not contain Binaries/Win64/KFGame.exe.")
        identity = fingerprint(probe)
        actual = identity["binary_store"]
        if actual is None or (store != "auto" and actual != store):
            raise ValueError("KF2 version differs or the selected folder belongs to another store. No files were installed.")
        return Installation(actual, root, identity["file_version"], "Finch" if actual == "epic" else "232090")
    available = discover() if installs is None else installs
    candidates = [i for i in available if store == "auto" or i.store == store]
    if saved_root:
        saved = [i for i in candidates if str(i.root.resolve()).casefold() == str(Path(saved_root).resolve()).casefold()]
        if len(saved) == 1:
            return saved[0]
        # A manually located install may have no store manifest. Reuse it only
        # while its executable still identifies the requested exact store.
        probe = Installation("unknown", Path(saved_root))
        if probe.executable.is_file():
            identity = fingerprint(probe)
            actual = identity["binary_store"]
            if actual and (store == "auto" or actual == store):
                return Installation(actual, probe.root, identity["file_version"],
                                    "Finch" if actual == "epic" else "232090")
    return select(candidates)


def validate_native(install: Installation, supported_hashes) -> dict:
    identity = fingerprint(install)
    if not identity["recognized"] or identity["binary_store"] != install.store:
        raise ValueError(f"Unrecognized {install.store} KF2 executable ({identity['sha256']}). No VR files were installed.")
    # Caller supplies the hashes actually supported by this release, not the
    # recognition table. Recognizing Epic does not enable Steam hook addresses.
    if identity["sha256"] not in {value.upper() for value in supported_hashes}:
        raise ValueError(f"This VR release does not support the installed {install.store} KF2 build ({identity['sha256']}). No VR files were installed.")
    return identity


if __name__ == "__main__":
    print(json.dumps([dict(i.to_dict(), **fingerprint(i)) for i in discover()], indent=2))
