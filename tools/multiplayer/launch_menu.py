"""Console selections and host URL shared by the normal launcher."""
from pathlib import Path
import breacher
from workshop_map import MAP_NAME
from workshop_loadout import MAPS, choose_mods, launch_options, load_preferences

DIFFICULTIES = {"normal": 0, "hard": 1, "suicidal": 2, "hellonearth": 3}
LENGTHS = {"short": 0, "medium": 1, "long": 2}


def installed_solo_maps(game):
    """Client BrewedPC maps only; never offer downloadable Workshop entries."""
    available = {p.stem for p in (Path(game) / "KFGame/BrewedPC/Maps").rglob("KF-*.kfm")}
    available.difference_update(set(MAPS) | {MAP_NAME})
    preferred = ["KF-BurningParis", "KF-Outpost"]
    return [m for m in preferred if m in available] + sorted(available - set(preferred))


def resolve_solo_map(args, maps):
    """A remembered hosted map may fall back; an explicit selection may not."""
    if not maps:
        raise RuntimeError("No installed client maps are available for Solo.")
    if args.map not in maps:
        if getattr(args, "map_requested", False):
            raise RuntimeError(f"Solo map {args.map} is not an installed client map; choose an installed map or Host.")
        args.map = maps[0]
    args.test_map = False


def installed_maps(game, server):
    def names(root):
        return {p.stem for p in (Path(root) / "KFGame/BrewedPC/Maps").rglob("KF-*.kfm")}
    client = names(game)
    # A first-time host can install its dedicated server after making choices.
    available = client & names(server) if (Path(server) / "Binaries/Win64/KFServer.exe").exists() else client
    preferred = ["KF-BurningParis", "KF-Outpost"]
    available.update(MAPS)
    return [m for m in preferred if m in available] + [MAP_NAME] + sorted(available - set(preferred) - {MAP_NAME})


def host_url(args):
    name = MAP_NAME if getattr(args, "test_map", False) else getattr(args, "map", "KF-BurningParis")
    difficulty = DIFFICULTIES[getattr(args, "difficulty", "normal")]
    length = LENGTHS[getattr(args, "game_length", "short")]
    url = (f"{name}?Game=KF2VRNet.KF2VRNetGame?Difficulty={difficulty}?GameLength={length}"
            + launch_options(args) + f"?VRInventoryFocus={int(getattr(args, 'inventory_focus', False))}"
            + f"?VRMultiplayerGrabs={int(getattr(args, 'multiplayer_grabs', False))}")
    return breacher.add_mutator(url, args) + breacher.options(args)


def choose_options(args, maps, read=input, write=print):
    solo = getattr(args, "solo", False)
    def choose(title, labels, current):
        write("\n" + title)
        for index, label in enumerate(labels, 1):
            write(f"  {index}. {label}" + (" [current]" if index - 1 == current else ""))
        while True:
            value = read(f"Select 1-{len(labels)} [Enter keeps current]: ").strip()
            if not value:
                return current
            if value.isdigit() and 1 <= int(value) <= len(labels):
                return int(value) - 1
            write("Please enter a number from the list.")
    try:
        while True:
            current_map = MAP_NAME if args.test_map else args.map
            write("\n=== KF2-VR launcher ===")
            write(f"  1. Play mode: {'VR headset' if args.vr else 'Desktop'}")
            write(f"  2. Map: {current_map}" + (" (Remilly test map)" if args.test_map else ""))
            write(f"  3. Difficulty: {args.difficulty}")
            write(f"  4. Match length: {args.game_length}")
            if args.vr:
                write(f"  5. VR graphics: {args.vr_quality}")
                scale = f"{args.eye_render_percent}%" if args.eye_render_percent is not None else "saved preference (100% first run)"
                write(f"  6. Headset render scale: {scale}")
            if not solo:
                write(f"  7. Experimental inventory slowdown: {'On' if args.inventory_focus else 'Off'}")
                write("  8. Mods: " + (", ".join(args.mods or []) or "none"))
                write(f"  9. Experimental multiplayer Zed grabbing (all players): {'On' if args.multiplayer_grabs else 'Off'}")
            write("  Enter / 0. " + ("Prepare configuration" if args.prepare_only else "Launch game"))
            write(f"  B. Breacher experimental mod: {'On' if getattr(args, 'breacher', False) else 'Off'} (matching local package required)")
            write("  Q. Quit")
            action = read("Selection: ").strip().lower()
            if action in ("", "0"):
                return True
            if action == "b":
                args.breacher = not getattr(args, "breacher", False)
                continue
            if action == "q":
                return False
            if action == "1":
                args.vr = choose("Play mode", ["VR headset", "Desktop"], 0 if args.vr else 1) == 0
                args.mode_requested = True
                if not solo and args.vr and not args.mods and not args.mods_requested:
                    args.mods = None
                    load_preferences(args)
            elif action == "2":
                current = maps.index(current_map) if current_map in maps else 0
                title = "Map (installed client maps)" if solo else "Map (Workshop content is prepared for client and server on launch)"
                args.map = maps[choose(title,
                    [m + (" - Remilly test map" if m == MAP_NAME else "") for m in maps], current)]
                args.map_requested = True
                args.test_map = args.map == MAP_NAME
            elif action == "3":
                args.difficulty = list(DIFFICULTIES)[choose("Difficulty", ["Normal", "Hard", "Suicidal", "Hell on Earth"], list(DIFFICULTIES).index(args.difficulty))]
            elif action == "4":
                args.game_length = list(LENGTHS)[choose("Match length", ["Short - 4 waves + boss", "Medium - 7 waves + boss", "Long - 10 waves + boss"], list(LENGTHS).index(args.game_length))]
            elif action == "5" and args.vr:
                quality = ["quality", "balanced", "performance"]
                args.vr_quality = quality[choose("VR graphics", quality, quality.index(args.vr_quality))]
                args.vr_quality_requested = args.vr_quality
            elif action == "6" and args.vr:
                scales = [None] + list(range(100, 49, -5))
                current = scales.index(args.eye_render_percent) if args.eye_render_percent in scales else 0
                args.eye_render_percent = scales[choose("Headset render scale", ["Use saved preference"] + [f"{n}%" for n in scales[1:]], current)]
            elif action == "7" and not solo:
                args.inventory_focus = not args.inventory_focus
            elif action == "9" and not solo:
                args.multiplayer_grabs = not args.multiplayer_grabs
                write("The host's choice applies to every VR player in this session.")
            elif action == "8" and not solo:
                if args.mods is None:
                    load_preferences(args)
                choose_mods(args, read=read, write=write)
                args.mods_requested = True
            else:
                write("Choose one of the options shown above.")
    except (EOFError, KeyboardInterrupt):
        write("\nLaunch cancelled.")
        return False
