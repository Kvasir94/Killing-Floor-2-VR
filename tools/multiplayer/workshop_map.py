"""One stock-game-compatible test map, shared by play and release acceptance."""
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import urllib.request
import zipfile

ITEM_ID = "1337395223"
MAP_NAME = "KF-Remilly_Test_Map"
WORKSHOP_URL = f"https://steamcommunity.com/sharedfiles/filedetails/?id={ITEM_ID}"
# Exact existing map accepted by the bounded, read-only Solo route. Updating
# this pin requires reviewing the replacement; Solo never downloads or imports.
SOLO_MAP_SHA256 = "CC427E7689C9E60EAD3486F5320B210C021CCA82C2D778DD1B1B2408E390FE14"


def cached_solo_map(cache_root):
    """Return verified existing Remilly content without creating any files."""
    path = Path(cache_root) / ITEM_ID / "0/Unpublished/BrewedPC" / (MAP_NAME + ".kfm")
    validate_map(path)
    if hashlib.sha256(path.read_bytes()).hexdigest().upper() != SOLO_MAP_SHA256:
        raise RuntimeError("Cached Solo Remilly map differs from the verified version; no files were changed.")
    return path


def installed_map(cache_root, *steam_roots):
    """Existing Remilly content read in place, for the VR menu's Solo match:
    the launcher cache first, then each Steam or SteamCMD root's Workshop
    download. Never downloads or copies; None when this PC has none."""
    paths = [Path(cache_root) / ITEM_ID / "0/Unpublished/BrewedPC" / (MAP_NAME + ".kfm")]
    paths += [Path(root) / "steamapps/workshop/content/232090" / ITEM_ID / "BrewedPC" / (MAP_NAME + ".kfm")
              for root in steam_roots if root]
    for path in paths:
        try:
            return validate_map(path)
        except (OSError, RuntimeError):
            continue
    return None


def validate_map(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size < 1024:
        raise RuntimeError(f"Test map is missing or empty: {path}")
    with path.open("rb") as stream:
        if stream.read(4) != b"\xc1\x83\x2a\x9e":
            raise RuntimeError(f"Test map is not an Unreal package: {path}")
    return path


def ensure_map(cache_root, tools_root, *, download=True):
    """Stage Workshop content into its own cache directory; never replace stock files."""
    target = Path(cache_root) / ITEM_ID / "0/Unpublished/BrewedPC" / (MAP_NAME + ".kfm")
    if target.exists():
        return validate_map(target)
    steam_root = Path(tools_root)
    source = steam_root / "steamapps/workshop/content/232090" / ITEM_ID / "BrewedPC" / target.name
    if not source.exists():
        if not download:
            raise RuntimeError("Test map not installed. Run Play-KF2VR.cmd -TestMap once to download it.")
        steam_root.mkdir(parents=True, exist_ok=True)
        executable = steam_root / "steamcmd.exe"
        if not executable.exists():
            archive = steam_root / "steamcmd.zip"
            from dependencies import extract_verified
            extract_verified("steamcmd.zip", archive, steam_root)
        from dependencies import workshop_download
        downloaded, log = workshop_download(steam_root, ITEM_ID, source.exists)
        if not downloaded:
            raise RuntimeError(f"SteamCMD did not download the test map; see {log}")
    validate_map(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    return validate_map(target)


def add_map_path(config_root, map_path):
    from launch_support import read_ini, set_ini
    path = Path(config_root) / "KFEngine.ini"
    text = read_ini(path)
    core = re.search(r"(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    if not core:
        raise RuntimeError("Missing Core.System in test-map configuration")
    values = {key: [str(Path(map_path).parent)] + re.findall(r"(?im)^" + key + r"=([^\r\n]*)", core[1])
              for key in ("Paths", "SeekFreePCPaths", "BrewedPCPaths")}
    path.write_text(set_ini(text, "Core.System", values), encoding="utf-16")


def receipt(path):
    return {"workshop_id": ITEM_ID, "map": MAP_NAME, "url": WORKSHOP_URL,
            "path": str(path), "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()}
