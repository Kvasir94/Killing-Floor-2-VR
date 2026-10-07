"""Resolved launcher selections as JSON, for the graphical launcher.

The console menu starts from a live argparse namespace that load_preferences
has already filled in. The GUI runs in Windows PowerShell, outside this
runtime, so the same resolution is performed here and handed over as data
rather than reimplemented against launcher.json in a second language.
"""
import argparse
import json
from pathlib import Path
import sys
from types import SimpleNamespace

# The embeddable runtime's ._pth fixes sys.path to the package's own module
# folder, so a copy of this file run from elsewhere (the repository, when a
# stale package predates it) must put its own siblings first.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from friends import find_game
from launch_menu import DIFFICULTIES, LENGTHS, installed_maps, installed_solo_maps
from workshop_loadout import MODS, VR_QUALITIES, load_preferences
from workshop_map import MAP_NAME


def resolve_game_root(game_root, package_root):
    """Find KF2 the way friends.py will: request, then saved, then Steam."""
    def playable(path):
        return path and (Path(path) / "Binaries/Win64/KFGame.exe").exists()
    if playable(game_root):
        return Path(game_root)
    settings = Path(package_root) / "settings.json" if package_root else None
    if settings and settings.is_file():
        saved = json.loads(settings.read_text(encoding="utf-8")).get("game_root")
        if playable(saved):
            return Path(saved)
    return find_game()


def selections(vr=None):
    args = SimpleNamespace(host=True, vr=True, map=None, difficulty=None, game_length=None,
                           vr_quality=None, inventory_focus=None, mods=None, damage_popups=None, portal_gun=None, threaded_render=None, dlss=None, dlss_sharpness=None, hide_bile_lens=None,
                           test_map_players=None, test_map=False, mode_requested=vr is not None,
                           replay_teammate=False, avatar_preview=False)
    if vr is not None:
        args.vr = vr
    load_preferences(args)
    return args


def describe(game, server, package_root):
    saved = selections()
    # A Desktop-mode profile resolves to no mods at all. Report what the same
    # profile means in VR as well, so switching the window to VR restores the
    # remembered loadout the way the console menu re-resolves it.
    vr_mods = saved.mods if saved.vr else selections(vr=True).mods
    return {
        "schema": "kf2vr/launch-state/1",
        "game_root": str(game) if game else None,
        "server_installed": bool(server and (Path(server) / "Binaries/Win64/KFServer.exe").is_file()),
        "maps": installed_maps(game, server) if game else [],
        "solo_maps": installed_solo_maps(game) if game else [],
        "test_map_name": MAP_NAME,
        "vr": bool(saved.vr),
        "map": MAP_NAME if saved.test_map else saved.map,
        "difficulty": saved.difficulty,
        "difficulties": list(DIFFICULTIES),
        "game_length": saved.game_length,
        "game_lengths": list(LENGTHS),
        "vr_quality": saved.vr_quality,
        "vr_qualities": list(VR_QUALITIES),
        "inventory_focus": bool(saved.inventory_focus),
        "multiplayer_grabs": bool(saved.multiplayer_grabs),
        "portal_gun": bool(saved.portal_gun),
        "breacher": bool(saved.breacher),
        "threaded_render": bool(saved.threaded_render),
        "mods": list(saved.mods or []),
        "vr_mods": list(vr_mods or []),
        "mod_catalog": [{"key": key, "label": label} for key, (label, _, _) in MODS.items()],
        "damage_popups": bool(saved.damage_popups),
        "test_map_players": int(saved.test_map_players),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-root", type=Path)
    parser.add_argument("--server-root", type=Path, required=True)
    parser.add_argument("--package-root", type=Path)
    args = parser.parse_args(argv)
    game = resolve_game_root(args.game_root, args.package_root)
    json.dump(describe(game, args.server_root, args.package_root), sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    raise SystemExit(main())
