"""Read installed map sources without copying or modifying game/Workshop files."""
import os
from pathlib import Path


def user_game_root():
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                       r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders") as key:
        documents = Path(os.path.expandvars(winreg.QueryValueEx(key, "Personal")[0]))
    return documents / "My Games/KillingFloor2/KFGame"


def catalog(game):
    """Map name -> (content root, Workshop ID); installed stock wins duplicates."""
    game = Path(game)
    roots = [(game / "KFGame/BrewedPC", "")]
    if not game.is_dir():
        return {}
    try:
        user = user_game_root()
    except OSError:
        user = None
    if user is not None:
        roots.append((user / "Unpublished/BrewedPC", ""))
    caches = [game / "KFGame/Cache"]
    if user is not None:
        caches.append(user / "Cache")
    if len(game.parents) >= 2:
        caches.append(game.parents[1] / "workshop/content/232090")
    for cache in caches:
        if cache.is_dir():
            roots.extend((p, p.name if p.name.isdecimal() else "")
                         for p in sorted(cache.iterdir()) if p.is_dir())
    result = {}
    seen = set()
    for root, item_id in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.kfm")):
            if (path.is_file() and path.suffix.lower() == ".kfm"
                    and path.stem.lower().startswith("kf-") and path.stem.lower() not in seen):
                seen.add(path.stem.lower())
                result[path.stem] = (root, item_id)
    return result
