"""The bundled manual VR workshop, mounted without changing game files."""
from pathlib import Path

MAP_NAME = "KF-VRRange"
GAME_CLASS = "KF2VRNet.KF2VRRangeGame"


def bundled_map(root=None):
    root = Path(root) if root is not None else Path(__file__).resolve().parents[2]
    path = root / "Packages" / (MAP_NAME + ".kfm")
    return path if path.is_file() else None


def include_bundled(maps, root=None):
    result = list(maps)
    if bundled_map(root) and MAP_NAME not in result:
        result.append(MAP_NAME)
    return result
