"""Console selections and host URL shared by the normal launcher."""
from pathlib import Path
from workshop_map import MAP_NAME, cached_solo_map
from workshop_loadout import MAPS, choose_mods, launch_options, load_preferences
from installed_map_catalog import catalog
import range_map

DIFFICULTIES = {"normal": 0, "hard": 1, "suicidal": 2, "hellonearth": 3}
LENGTHS = {"short": 0, "medium": 1, "long": 2}
NORMAL_GAME = "KF2VRNet.KF2VRNetGame"
TEST_MODE_MUTATOR = "KF2VR.VRTestMode"
# Zed spawn overrides and their stock values (UKFP settings).
SPAWN_OPTIONS = (("max_zeds", 0), ("wave_zeds_percent", 100), ("spawn_rate_percent", 100))


def installed_solo_maps(game):
    """All maps already installed for this client, including Workshop caches."""
    available = set(catalog(game))
    available.discard(MAP_NAME)  # Explicit test-map route retains its verified pin.
    preferred = ["KF-BurningParis", "KF-Outpost"]
    return range_map.include_bundled([m for m in preferred if m in available] + sorted(available - set(preferred)))


def resolve_solo_map(args, maps):
    """A remembered hosted map may fall back; an explicit selection may not."""
    if getattr(args, "map_requested", False) and (args.test_map or args.map == MAP_NAME):
        args.test_map_path = cached_solo_map(args.cache_root)
        args.map, args.test_map = MAP_NAME, True
        return
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
    available.update(catalog(game))
    preferred = ["KF-BurningParis", "KF-Outpost"]
    available.update(MAPS)
    return range_map.include_bundled([m for m in preferred if m in available] + [MAP_NAME] + sorted(available - set(preferred) - {MAP_NAME}))


def add_mutator(url, mutator):
    """Add a mutator to the URL's single ?Mutator= list; a second ?Mutator= would be ignored."""
    marker = "?Mutator="
    if marker not in url:
        return url + marker + mutator
    start = url.index(marker) + len(marker)
    end = url.find("?", start)
    end = len(url) if end < 0 else end
    mutators = url[start:end].split(",")
    if mutator not in mutators:
        mutators.append(mutator)
    return url[:start] + ",".join(mutators) + url[end:]


def with_test_mode(url, args):
    """Opt-in perk test mode; the server-side mutator reads ?KF2VRTestMode=1."""
    if not getattr(args, "test_mode", False):
        return url
    return add_mutator(url, TEST_MODE_MUTATOR) + "?KF2VRTestMode=1"


def spawn_summary(args):
    max_zeds = getattr(args, "max_zeds", None) or 0
    return (f"max alive {max_zeds if max_zeds else 'stock'}, "
            f"wave size {getattr(args, 'wave_zeds_percent', None) or 100}%, "
            f"spawn rate {getattr(args, 'spawn_rate_percent', None) or 100}%")


def host_url(args):
    name = MAP_NAME if getattr(args, "test_map", False) else getattr(args, "map", "KF-BurningParis")
    difficulty = DIFFICULTIES[getattr(args, "difficulty", "normal")]
    length = LENGTHS[getattr(args, "game_length", "short")]
    game = range_map.GAME_CLASS if name == range_map.MAP_NAME else NORMAL_GAME
    # Spawn overrides are UKFP settings (workshop_loadout.ukfp_spawn_settings).
    return with_test_mode(f"{name}?Game={game}?Difficulty={difficulty}?GameLength={length}"
            + launch_options(args) + "?VRInventoryFocus=0"
            + f"?VRMultiplayerGrabs={int(getattr(args, 'zed_grabs', None) is not False)}"
            + f"?VRGravityPull={int(getattr(args, 'gravity_grab', None) is not False)}", args)


def solo_url(args, vr_demo=False):
    """Solo's local game URL; the mod options are present only when UKFP was required."""
    game = range_map.GAME_CLASS if args.map == range_map.MAP_NAME else "KFGameContent.KFGameInfo_Survival"
    url = (f"{args.map}?Game={game}?Difficulty={DIFFICULTIES[args.difficulty]}"
           f"?GameLength={LENGTHS[args.game_length]}" + launch_options(args))
    if vr_demo:
        url = add_mutator(add_mutator(url, "KF2VR.VRBootstrap"), "KF2VR.VRDemo") + "?VRNormalGame=1"
    return with_test_mode(url, args)


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
            write(f"  Z. Zed spawns: {spawn_summary(args)}")
            write("  Enter / 0. " + ("Prepare configuration" if args.prepare_only else "Launch game"))
            write("  Q. Quit")
            action = read("Selection: ").strip().lower()
            if action in ("", "0"):
                return True
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
            elif action == "8" and not solo:
                if args.mods is None:
                    load_preferences(args)
                choose_mods(args, read=read, write=write)
                args.mods_requested = True
            elif action == "z":
                choose_spawns(args, read=read, write=write)
            else:
                write("Choose one of the options shown above.")
    except (EOFError, KeyboardInterrupt):
        write("\nLaunch cancelled.")
        return False


def choose_spawns(args, read=input, write=print):
    """Edit the three optional spawn overrides; Enter keeps a value, 0/100 restore stock."""
    import settings_registry
    titles = {"max_zeds": "Max zeds alive at once (0 = stock, 10-32 by players)",
              "wave_zeds_percent": "Zeds per wave, percent of stock (100 = stock)",
              "spawn_rate_percent": "Spawn rate, percent (100 = stock, 200 = twice as often)"}
    write("\nZed spawns (applied through the Unofficial KF2 Patch, which they turn on)")
    for dest, stock in SPAWN_OPTIONS:
        option = settings_registry.option(dest)
        current = getattr(args, dest, None)
        current = stock if current is None else current
        write(titles[dest])
        while True:
            value = read(f"  {option.minimum}-{option.maximum} [Enter keeps {current}]: ").strip()
            if not value:
                break
            if value.isdigit() and option.minimum <= int(value) <= option.maximum:
                setattr(args, dest, int(value))
                break
            write(f"Please enter a whole number from {option.minimum} to {option.maximum}.")
