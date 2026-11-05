"""Shared client/server Workshop content and persistent launch selections."""
from pathlib import Path
import hashlib
import json
import settings_registry
import re
import shutil
import subprocess
import functools
import msvcrt

from vr_config import profile_root
from workshop_map import MAP_NAME

DIFFICULTY_NAMES = settings_registry.DIFFICULTIES
LENGTH_NAMES = settings_registry.GAME_LENGTHS
VR_QUALITIES = settings_registry.VR_QUALITIES
# Provisional PC workload starting points, not certified headset performance.
# Quest models share the streamed-PC family; actual OpenXR sizes vary by runtime.
HEADSET_PRESETS = {
    "quest2": ("performance", 75),
    "quest3": ("performance", 75),
    "quest3s": ("performance", 75),
    "index": ("balanced", 100),
    "high-resolution": ("performance", 65),
}


def apply_headset_preset(args):
    # Retired compatibility input. Existing resolved quality and scale stay untouched.
    return



# Names, dependency IDs and Load* parameters are from the authors' Workshop
# pages and UKFPGuide/UKFPMutator. Dependencies are installed even when their
# optional feature is switched off; UKFP loads them through its own options.
MODS = {
    "ukfp": ("Unofficial KF2 Patch", "2875147606", None),
    "friendlyhud": ("Friendly HUD", "1819268190", "LoadFHUD"),
    "yas": ("Yet Another Scoreboard", "2521826524", "LoadYAS"),
    "aal": ("Admin Auto Login", "2848836389", "LoadAAL"),
    "cvc": ("Controlled Vote Collector", "2847465899", "LoadCVC"),
    "lti": ("Looted Trader Inventory", "2864857909", "LoadLTI"),
}
MAPS = {
    "KF-TF2_Upward": "3295814646",
    "KF-Edge_Of_Reality": "1150705478",
    "KF-TF2_Gorge": "3274600667",
    "KF-TF2_Harvest": "1300634093",
    "KF-MountainPass_zfix": "857015700",
    "KF-BikiniAtoll": "643383080",
}
LEGACY_MODS = list(MODS)
DEFAULT_MODS = settings_registry.default("mods")
# Keys older launchers saved for retired choices; dropped on the next save.
RETIRED_KEYS = ("multiplayer_grabs", "standing_holds", "breacher", "zed_defense", "portal_gun",
                "flex", "headset_preset")
REQUIRED_PACKAGES = {
    "2875147606": {"UnofficialKFPatch.u", "UnofficialKFPatch_LevelTransition.u", "FriendlyHudExt.u"},
    **{item: {filename} for item, filename in zip(
        ("1819268190", "2521826524", "2848836389", "2847465899", "2864857909"),
        ("FriendlyHUD.u", "YAS.u", "AAL.u", "CVC.u", "LTI.u"))},
    **{item: {name + ".kfm"} for name, item in MAPS.items()},
}


def damage_popups_enabled(args):
    """Return whether UKFP's screen-space damage overlay is safe to render.

    UKFP implements these numbers as a 2D HUD movie, rather than world-space
    actors. The VR renderer runs the HUD for each eye, which makes the same
    flat number appear at two screen positions. Do not let a saved desktop
    preference re-enable that uncomfortable overlay in a headset session.
    """
    return bool(getattr(args, "damage_popups", True)) and not bool(getattr(args, "vr", False))


def parse_mods(value):
    keys = LEGACY_MODS.copy() if value.lower() == "legacy" else ([] if value.lower() == "none" else value.lower().split(","))
    if any(key not in MODS for key in keys):
        raise ValueError("Mods must be 'none' or comma-separated: " + ",".join(MODS))
    if keys and "ukfp" not in keys:
        keys.insert(0, "ukfp")
    return [key for key in MODS if key in keys]


# Every launcher choice is remembered, not only the content ones. A value the
# caller passed explicitly always wins; anything left unset comes from the last
# launch, and only a profile with nothing in it falls back to the shipped
# default. Saved play mode applies to Host and Solo; a friend joining still gets the
# flat screen unless they ask for --vr.
DLSS_MODES = settings_registry.DLSS_MODES
FLEX_MODES = settings_registry.FLEX_MODES
# Shipped defaults for anything a profile has not saved.
D = settings_registry.default
SPAWN_KEYS = ("max_zeds", "wave_zeds_percent", "spawn_rate_percent")


def ukfp_spawn_settings(args):
    """Spawn overrides as Unofficial KF2 Patch settings (stock KF2 has none).

    Unset choices give UKFP's own stock values, so a session copy never inherits
    an override from an earlier launch.
    """
    value = lambda key: getattr(args, key, None) if getattr(args, key, None) is not None else D(key)
    return {"MaxMonsters": str(int(value("max_zeds"))),
            "WaveCountMultiplier": f"{value('wave_zeds_percent') / 100:.6f}",
            "SpawnRateMultiplier": f"{value('spawn_rate_percent') / 100:.6f}"}


def spawn_overrides_set(args):
    return any(getattr(args, key, None) not in (None, D(key)) for key in SPAWN_KEYS)


def require_ukfp_for_spawns(args):
    """A spawn override needs UKFP, as its dependent mods already do; Solo loads only UKFP."""
    mods = list(getattr(args, "mods", None) or [])
    if spawn_overrides_set(args) and "ukfp" not in mods:
        args.mods = parse_mods(",".join(["ukfp"] + mods))
# The full item also exposes the game packages for desktop players joining a host.
KF2VR_WORKSHOP_ID = "3817663661"
KF2VR_FULL_WORKSHOP_ID = KF2VR_WORKSHOP_ID
KF2VR_FULL_WORKSHOP_URL = "https://steamcommunity.com/sharedfiles/filedetails/?id=" + KF2VR_FULL_WORKSHOP_ID


def _read_preferences(path, *, strict=False):
    try:
        value = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        if not isinstance(value, dict):
            raise ValueError("Launcher preferences must be an object")
        return value
    except (ValueError, OSError):
        if strict:
            raise ValueError("Cannot save malformed launcher preferences; preserve and repair launcher.json first")
        return {}


def _preference_transaction(function):
    @functools.wraps(function)
    def locked(args):
        root = getattr(args, "profile_root", None) or profile_root()
        root.mkdir(parents=True, exist_ok=True)
        # Serialize read/merge/replace across launcher processes, including Join.
        with (root / "launcher.lock").open("a+b") as lock:
            lock.seek(0)
            if not lock.read(1):
                lock.write(b"0");lock.flush()
            lock.seek(0);msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
            try:
                return function(args)
            finally:
                lock.seek(0);msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
    return locked


def load_preferences(args):
    root = getattr(args, "profile_root", None) or profile_root()
    path = root / "launcher.json"
    saved = _read_preferences(path)
    # Existing diagnostic scenarios have their own content contract, so they
    # take the shipped defaults for anything the caller left unset and nothing
    # from the profile. Every selection still ends up set: the rest of the
    # launcher reads these attributes whichever scenario asked for them.
    scenario = getattr(args, "replay_teammate", False) or getattr(args, "avatar_preview", False)
    if scenario:
        saved = {}
    if (not scenario and (getattr(args, "host", False) or getattr(args, "solo", False))
            and not getattr(args, "mode_requested", False)):
        args.vr = bool(saved.get("vr", D("vr")))
    mode = "solo" if getattr(args, "solo", False) else "host"
    match = saved.get(mode + "_match", {})
    if not isinstance(match, dict): match = {}
    saved_match = match
    match = {key: match.get(key, saved.get(key, D(key))) for key in ("map", "difficulty", "game_length")}
    if getattr(args, "map", None) is None:
        args.map = str(match["map"])
        if not re.fullmatch(r"KF-[A-Za-z0-9_-]+", args.map):
            args.map = D("map")
    args.test_map = bool(getattr(args, "test_map", False)) or args.map == MAP_NAME
    if getattr(args, "difficulty", None) is None:
        args.difficulty = match.get("difficulty") if match.get("difficulty") in DIFFICULTY_NAMES else D("difficulty")
    if getattr(args, "game_length", None) is None:
        args.game_length = match.get("game_length") if match.get("game_length") in LENGTH_NAMES else D("game_length")
    # Spawn overrides are remembered per mode, like the rest of the match.
    for key in SPAWN_KEYS:
        if getattr(args, key, None) is None:
            option, value = settings_registry.option(key), saved_match.get(key)
            setattr(args, key, value if type(value) is int and option.minimum <= value <= option.maximum else D(key))
    apply_headset_preset(args)
    if getattr(args, "vr_quality", None) is None:
        args.vr_quality = saved.get("vr_quality") if saved.get("vr_quality") in VR_QUALITIES else D("vr_quality")
    if getattr(args, "inventory_focus", None) is None:
        args.inventory_focus = bool(saved.get("inventory_focus", D("inventory_focus")))
    # Rendering modes are fixed, not options (Kvasir94, 11-05, #200): the
    # separate render thread and single-pass stereo always, on Steam and Epic.
    # DLSS blurred distant detail in two-pass stereo.
    args.threaded_render = True
    args.single_pass = True
    for key in ("workshop_desktop", "open_server"):
        if getattr(args, key, None) is None:
            setattr(args, key, saved.get(key, D(key)) is True if getattr(args, "host", False) else False)
    # Host permissions for VR interactions; on unless the host turned them off.
    for key in ("zed_grabs", "gravity_grab"):
        if getattr(args, key, None) is None:
            setattr(args, key, saved.get(key, D(key)) is not False)
    for key in ("hbao", "reflections"):
        if getattr(args, key, None) is None:
            value = saved.get(key, D(key)) is True
            setattr(args, key, value)
    args.flex = "off"
    if getattr(args, "dlss", None) is None:
        mode = saved.get("dlss", D("dlss"))
        args.dlss = mode if mode in DLSS_MODES else D("dlss")
    if getattr(args, "hide_bile_lens", None) is None:
        args.hide_bile_lens = saved.get("hide_bile_lens", D("hide_bile_lens")) is not False
    if getattr(args, "hide_blood_lens", None) is None:
        args.hide_blood_lens = saved.get("hide_blood_lens", D("hide_blood_lens")) is not False
    if getattr(args, "dlss_sharpness", None) is None:
        value = saved.get("dlss_sharpness", D("dlss_sharpness"))
        args.dlss_sharpness = value if type(value) is int and 0 <= value <= 100 else D("dlss_sharpness")
    if scenario or getattr(args, "solo", False):
        args.mods = []
        args.damage_popups = False
        args.test_map_players = 0
        if getattr(args, "solo", False):
            args.inventory_focus = False
        return
    if args.mods is None:
        args.mods = parse_mods(",".join(saved.get("mods", DEFAULT_MODS)) or "none") if args.vr else []
    if args.damage_popups is None:
        args.damage_popups = bool(saved.get("damage_popups", D("damage_popups")))
    if args.test_map_players is None:
        args.test_map_players = int(saved.get("test_map_players", D("test_map_players")))
    if args.test_map_players not in (0, 6):
        raise ValueError("Saved test map players must be 0 or 6")


@_preference_transaction
def _update_preferences(args):
    root = getattr(args, "profile_root", None) or profile_root()
    path = root / "launcher.json"
    saved = _read_preferences(path, strict=True)
    for key in RETIRED_KEYS:
        saved.pop(key, None)
    saved.update({key: value for key, value in args.values.items() if key not in RETIRED_KEYS})
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(saved, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def update_preferences(values, profile_root=None):
    """Store individual choices from the Settings page without a launch."""
    from types import SimpleNamespace
    _update_preferences(SimpleNamespace(profile_root=profile_root, values=dict(values)))


def last_session(profile_root_override=None):
    """"solo" or "host": what the one-click Play button repeats."""
    saved = _read_preferences((profile_root_override or profile_root()) / "launcher.json")
    return saved.get("last_session") if saved.get("last_session") in ("solo", "host") else "solo"


@_preference_transaction
def save_dlss_preferences(args):
    # A join takes the host's match settings, but graphics are the player's own.
    root = getattr(args, "profile_root", None) or profile_root()
    root.mkdir(parents=True, exist_ok=True)
    path = root / "launcher.json"
    saved = _read_preferences(path, strict=True)
    for key in RETIRED_KEYS:
        saved.pop(key, None)
    # Join can explicitly choose the same preset as Solo/Host. An omitted
    # choice keeps the saved preset and headset edits without overwriting a
    # newer preference with a value resolved when this window first opened.
    if getattr(args, "vr_quality_requested", None) in VR_QUALITIES:
        saved["vr_quality"] = args.vr_quality_requested
    saved.update({"flex": "off",
                  "dlss": getattr(args, "dlss", None) or "off",
                  "dlss_sharpness": int(getattr(args, "dlss_sharpness", None) or 0),
                  "hide_bile_lens": getattr(args, "hide_bile_lens", True) is not False,
                  "hide_blood_lens": getattr(args, "hide_blood_lens", True) is not False})
    temporary = path.with_suffix(".json.tmp")
    saved.pop("flex",None)
    temporary.write_text(json.dumps(saved, indent=2), encoding="utf-8")
    temporary.replace(path)


@_preference_transaction
def save_preferences(args):
    root = getattr(args, "profile_root", None) or profile_root()
    root.mkdir(parents=True, exist_ok=True)
    path = root / "launcher.json"
    temporary = path.with_suffix(".json.tmp")
    # Headset render scale is deliberately absent: it lives with the rest of
    # the in-headset preferences in the profile KFGame.ini, and two owners for
    # one setting is how they start disagreeing.
    saved = _read_preferences(path, strict=True)
    for key in RETIRED_KEYS:
        saved.pop(key, None)
    saved["last_session"] = "solo" if getattr(args, "solo", False) else "host"
    saved.update({"vr": bool(getattr(args, "vr", True)),
        "map": (saved.get("map", "KF-BurningParis")
                if getattr(args, "solo", False) and getattr(args, "test_map", False)
                else MAP_NAME if getattr(args, "test_map", False) else getattr(args, "map", "KF-BurningParis")),
        "difficulty": getattr(args, "difficulty", "normal"),
        "game_length": getattr(args, "game_length", D("game_length")),
        "vr_quality": getattr(args, "vr_quality", "performance"),
        "hbao": bool(getattr(args, "hbao", D("hbao"))),
        "reflections": bool(getattr(args, "reflections", D("reflections"))),
        "single_pass": bool(getattr(args, "single_pass", True)),
        "threaded_render": bool(getattr(args, "threaded_render", True)),
        "flex": "off",
        "dlss": getattr(args, "dlss", None) or "off",
        "dlss_sharpness": int(getattr(args, "dlss_sharpness", None) or 0),
        "hide_bile_lens": getattr(args, "hide_bile_lens", True) is not False,
        "hide_blood_lens": getattr(args, "hide_blood_lens", True) is not False})
    mode = "solo" if getattr(args,"solo",False) else "host"
    if not (mode == "solo" and getattr(args,"test_map",False)):
        saved[mode + "_match"] = {key: saved[key] for key in ("map","difficulty","game_length")}
        saved[mode + "_match"].update({key: int(getattr(args, key, None) if getattr(args, key, None) is not None else D(key))
                                       for key in SPAWN_KEYS})
    saved.pop("flex",None)
    # Solo applies no hosted loadout. Remember its common choices without
    # erasing the mods and host settings the next hosted session will use.
    if not getattr(args, "solo", False):
        previous_mods = saved.get("mods", DEFAULT_MODS)
        saved.update({"mods": args.mods if getattr(args, "vr", True) or getattr(args, "mods_requested", False) else previous_mods,
            "damage_popups": args.damage_popups, "test_map_players": args.test_map_players,
            "inventory_focus": bool(getattr(args, "inventory_focus", False)),
            "open_server": bool(getattr(args, "open_server", False)),
            "zed_grabs": getattr(args, "zed_grabs", None) is not False,
            "gravity_grab": getattr(args, "gravity_grab", None) is not False,
            "workshop_desktop": bool(getattr(args, "workshop_desktop_session_off", False)
                                     or getattr(args, "workshop_desktop", D("workshop_desktop")))})
    temporary.write_text(json.dumps(saved, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def launch_options(args):
    mods = getattr(args, "mods", None) or []
    if "ukfp" not in mods:
        return ""
    options = "?Mutator=UnofficialKFPatch.UKFPMutator"
    for key, (_, _, option) in MODS.items():
        if option:
            options += f"?{option}={int(key in mods)}"
    # FHUD and its extension are alternative loaders, not two mutators to add.
    options += "?LoadFHUDExt=0?UnsuppressLogs=1"
    options += f"?AllowDamagePopups={int(damage_popups_enabled(args))}"
    players = getattr(args, "test_map_players", 6) if getattr(args, "test_map", False) else 0
    return options + f"?FakePlayers={players}"


def choose_mods(args, read=input, write=print):
    while True:
        write("\nMods (Unofficial Patch manages the optional dependency features)")
        for i, (key, (label, _, _)) in enumerate(MODS.items(), 1):
            write(f"  {i}. [{'ON' if key in args.mods else 'OFF'}] {label}")
        patch = "ukfp" in args.mods
        if args.vr:
            write("  7. Damage popups: OFF (UKFP's flat overlay is incompatible with VR)")
        else:
            write(f"  7. Damage popups: {'ON' if patch and args.damage_popups else 'OFF'}")
        write(f"  8. Remilly scaling: {'6 players' if patch and args.test_map_players == 6 else 'actual players'}")
        write("  Enter. Back (choices are saved on launch/preparation)")
        action = read("Toggle: ").strip()
        if not action:
            return
        if action.isdigit() and 1 <= int(action) <= len(MODS):
            key = list(MODS)[int(action) - 1]
            if key in args.mods:
                args.mods.remove(key)
                if key == "ukfp":
                    args.mods = []
            else:
                args.mods = parse_mods(",".join(args.mods + [key]))
        elif action in ("7", "8"):
            if not patch:
                args.mods = ["ukfp"]
            if action == "7":
                if args.vr:
                    write("Damage popups stay off in VR: UKFP renders them as a flat HUD overlay.")
                else:
                    args.damage_popups = not args.damage_popups if patch else True
            else:
                args.test_map_players = 0 if patch and args.test_map_players == 6 else 6
        else:
            write("Choose 1-8 or Enter.")


def _packages(root):
    return sorted(p for p in Path(root).rglob("*") if p.is_file() and p.suffix.lower() in (".u", ".upk", ".kfm"))


def package_hashes(root, item_id):
    files = {}
    for package in _packages(root):
        with package.open("rb") as stream:
            if stream.read(4) != b"\xc1\x83\x2a\x9e":
                raise RuntimeError(f"Not an Unreal package: {package}")
            stream.seek(0)
            files[str(package.relative_to(root))] = hashlib.file_digest(stream, "sha256").hexdigest().upper()
    missing = {name.lower() for name in REQUIRED_PACKAGES.get(item_id, ())} - {Path(name).name.lower() for name in files}
    if not files or missing:
        raise RuntimeError(f"Workshop {item_id} is incomplete; missing {', '.join(sorted(missing)) or 'Unreal packages'}")
    return files


def ensure_item(item_id, game, cache, steam_root, *, download):
    if not re.fullmatch(r"[0-9]+", item_id):
        raise ValueError("Invalid Workshop ID")
    target = Path(cache) / item_id / "content"
    marker = target.parent / "content.json"
    if marker.is_file():
        expected = json.loads(marker.read_text(encoding="utf-8"))
        try:
            actual = package_hashes(target, item_id)
        except RuntimeError as cache_error:
            # A game/cleanup tool can remove staged packages while leaving the
            # receipt behind. Restore only from the matching Steam copy, never
            # by accepting a different Workshop revision silently.
            source = Path(game).parents[1] / "workshop/content/232090" / item_id
            if not _packages(source):
                source = Path(steam_root) / "steamapps/workshop/content/232090" / item_id
            if _packages(source) and package_hashes(source, item_id) == expected["files_sha256"]:
                shutil.copytree(source, target, dirs_exist_ok=True)
                if package_hashes(target, item_id) == expected["files_sha256"]:
                    return target
            raise cache_error
        if actual != expected["files_sha256"]:
            raise RuntimeError(f"Workshop cache changed: {target}. Restore its files or use a fresh --cache-root.")
        return target
    source = Path(game).parents[1] / "workshop/content/232090" / item_id
    if not _packages(source):
        source = Path(steam_root) / "steamapps/workshop/content/232090" / item_id
    if not _packages(source):
        if not download:
            raise RuntimeError(f"Workshop {item_id} is missing. Subscribe/download in Steam or launch once without -PrepareOnly.")
        executable = Path(steam_root) / "steamcmd.exe"
        if not executable.is_file():
            from dependencies import extract_verified
            Path(steam_root).mkdir(parents=True, exist_ok=True)
            extract_verified("steamcmd.zip", Path(steam_root) / "steamcmd.zip", Path(steam_root))
        if not executable.is_file():
            raise RuntimeError("SteamCMD is missing. Install the local server or subscribe to the item in Steam first.")
        from dependencies import workshop_download
        downloaded, log = workshop_download(steam_root, item_id, lambda: bool(_packages(source)))
        if not downloaded:
            raise RuntimeError(f"Workshop {item_id} download failed; see {log}")
    # Publish a receipt only after the entire copy validates. A partial previous
    # copy is never accepted as an installed dependency.
    files = package_hashes(source, item_id)
    shutil.copytree(source, target, dirs_exist_ok=True)
    if package_hashes(target, item_id) != files:
        raise RuntimeError(f"Incomplete Workshop cache copy: {target}")
    marker.write_text(json.dumps({"workshop_id": item_id, "files_sha256": files}, indent=2), encoding="utf-8")
    return target


def prepare_content(args, game, steam_root):
    from installed_map_catalog import catalog
    installed = catalog(game).get(args.map)
    args.installed_map_paths = []
    if installed is not None and installed[0] == Path(game) / "KFGame/BrewedPC":
        # A custom map may have been installed alongside stock maps. A local
        # host needs the same map and companion packages even if its dedicated
        # installation lacks them. Mount paths; never copy/hash the whole game.
        args.installed_map_paths = sorted({str(p.parent) for p in _packages(installed[0])})
    ukfp = MODS["ukfp"][1]
    solo = getattr(args, "solo", False)
    ids = ([ukfp] if solo else [value[1] for value in MODS.values()]) if "ukfp" in args.mods else []
    if args.map in MAPS and installed is None:
        ids.append(MAPS[args.map])
    roots = {}
    for item_id in dict.fromkeys(ids):
        try:
            # Solo uses UKFP only for spawn overrides and never downloads it.
            roots[item_id] = ensure_item(item_id, game, args.cache_root, steam_root,
                                         download=not args.prepare_only and not (solo and item_id == ukfp))
        except RuntimeError as error:
            if solo and item_id == ukfp:
                raise RuntimeError("Solo zed spawn overrides need the Unofficial KF2 Patch, which is not on this PC. "
                                   f"Subscribe to Workshop item {ukfp} in Steam (or host once so the launcher caches it), "
                                   "or set the spawn options back to stock.") from error
            raise
    # A selected installed custom map mounts its complete content directory,
    # including companion packages, in both client and local host configs.
    if installed is not None and installed[0] != Path(game) / "KFGame/BrewedPC":
        roots[installed[1] or "local-map"] = installed[0]
    names = {}
    receipt = []
    for item_id, root in roots.items():
        files = package_hashes(root, item_id)
        for name, digest in files.items():
            key = Path(name).name.lower()
            if key in names and names[key] != digest:
                raise RuntimeError(f"Conflicting selected Workshop packages: {key}")
            names[key] = digest
        receipt.append({"workshop_id": item_id, "root": str(root.resolve()), "files_sha256": files})
    args.workshop_content = receipt
    return receipt


def configure_content(configs, args, *, server):
    from launch_support import read_ini, set_ini
    content = getattr(args, "workshop_content", [])
    installed_paths = getattr(args, "installed_map_paths", [])
    offer_mod = server and getattr(args, "workshop_desktop", False) is True
    if offer_mod and not getattr(args, "workshop_desktop_verified", False):
        raise RuntimeError("Workshop desktop content has not been verified against this package. Use the matching KF2-VR ZIP.")
    if not content and not offer_mod and not installed_paths:
        return
    path = Path(configs) / "KFEngine.ini"
    text = read_ini(path)
    if content or installed_paths:
        section = re.search(r"(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)", text)
        if not section:
            raise RuntimeError("Missing Core.System for Workshop content")
        directories = sorted(set(installed_paths) | {str((Path(item["root"]) / name).parent) for item in content for name in item["files_sha256"]})
        # Keep the selected release and stock packages ahead of custom content;
        # stale development scripts in Unpublished must not shadow this build.
        values = {key: re.findall(r"(?im)^" + key + r"=([^\r\n]*)", section[1]) + directories
                  for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths")}
        localization = [str(Path(item["root"]) / "Localization") for item in content
                        if (Path(item["root"]) / "Localization").is_dir()]
        values["LocalizationPaths"] = localization + re.findall(r"(?im)^LocalizationPaths=([^\r\n]*)", section[1])
        text = set_ini(text, "Core.System", values)
    if server:
        text = set_ini(text, "OnlineSubsystemSteamworks.KFWorkshopSteamworks", {
            "ServerSubscribedWorkshopItems": [item["workshop_id"] for item in content if item["workshop_id"].isdecimal()] + ([KF2VR_WORKSHOP_ID] if offer_mod else [])})
    net = re.search(r"(?ims)^\[IpDrv\.TcpNetDriver\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    managers = re.findall(r"(?im)^DownloadManagers=([^\r\n]*)", net[1]) if net else []
    workshop_manager = "OnlineSubsystemSteamworks.SteamWorkshopDownload"
    text = set_ini(text, "IpDrv.TcpNetDriver", {"DownloadManagers": [workshop_manager] +
        [value for value in managers if value.lower() != workshop_manager.lower()]})
    path.write_text(text, encoding="utf-16")


def desktop_workshop_availability(release, cache):
    """Read cached compatibility for the Host form; launch still verifies actual packages."""
    try:
        manifest=json.loads((Path(release)/"release.json").read_text(encoding="utf-8-sig"))
        published=json.loads((Path(cache)/KF2VR_WORKSHOP_ID/"content.json").read_text(encoding="utf-8-sig"))
        local=manifest.get("script_build",{}).get("packages_sha256",{})
        remote=published.get("files_sha256",{})
        if not local or not remote:return None
        identities=lambda entries:{Path(name).name.lower():value.upper() for name,value in entries.items() if Path(name).suffix.lower() in (".u",".upk",".kfm")}
        return identities(local)==identities(remote)
    except (OSError,ValueError,TypeError,AttributeError):return None


def verify_desktop_workshop(args, game, steam_root, release):
    """Offer only matching packages; never mount published scripts over local ones."""
    args.workshop_desktop_verified = False
    root = ensure_item(KF2VR_WORKSHOP_ID, game, args.cache_root, steam_root, download=not args.prepare_only)
    published = package_hashes(root, KF2VR_WORKSHOP_ID)
    local = package_hashes(Path(release) / "Packages", KF2VR_WORKSHOP_ID)
    def identities(files):
        names = {}
        for name, digest in files.items():
            key = Path(name).name.lower()
            if key in names:
                raise RuntimeError("Its package names are ambiguous.")
            names[key] = digest
        return names
    if identities(local) != identities(published):
        raise RuntimeError("Its packages differ from this KF2-VR build.")
    args.workshop_desktop_verified = True


def configure_mod_settings(role, args, game, user):
    """Use KF2's CONFIGSUBDIR for custom config() names, not invented *INI switches.

    KFGame appGameConfigDir (RVA bc4f0) appends this relative name. Stage matching
    install/default and user/virtualized directories; standard nine INI redirects
    still select the central role config. Nothing in either base config is edited.
    """
    if "ukfp" not in (getattr(args, "mods", None) or []):
        return
    from launch_support import read_ini, set_ini, set_ini_defaults, config_hashes
    configs = Path(role["config_root"])
    subdir = Path("KF2VR") / configs.parent.parent.name / role["role"]
    install = (args.server_root if role["role"] == "server" else Path(game)) / "KFGame/Config"
    roots = [install] if role["role"] == "server" else [install, Path(user)]
    destinations = []
    for root in roots:
        destination = root / subdir
        destination.mkdir(parents=True, exist_ok=False)
        # The engine also resolves its platform default INIs below CONFIGSUBDIR.
        for folder in (Path("."), Path("Eos"), Path("PCServer"), Path("LinuxServer")):
            for source in (root / folder).glob("*.ini"):
                target = destination / folder / source.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        for source in configs.glob("*.ini"):
            # Client custom settings come from its existing profile. Server
            # custom settings stay with the dedicated server, not its player.
            if role["role"] != "server" or source.name.lower() in {
                    "kfengine.ini", "kfgame.ini", "kfinput.ini", "kfui.ini", "kfweb.ini",
                    "kfsystemsettings.ini", "kflightmass.ini", "kfbenchmarking.ini", "kfmap.ini"}:
                shutil.copy2(source, destination / source.name)
        for kind in ("YAS", "CVC"):
            path = destination / f"KF{kind}.ini"
            text = read_ini(path) if path.exists() else ""
            path.write_text(set_ini_defaults(text, f"{kind}.{kind}", {"Version": "0"}), encoding="utf-16")
        # Complete v2 empty configurations avoid the authors' example admin IDs
        # and LTI's example dual-9mm removal. Preserve existing configured files.
        for kind, extra in (
            ("AAL", "bAutoEnableCheats=False\n\n[AAL.AdminList]\n"),
            ("LTI", "bOfficialWeaponsList=False\n\n[LTI.RemoveItems]\nbAll=False\nbHRG=False\nbDLC=False\n")):
            path = destination / f"KF{kind}.ini"
            if not path.exists():
                path.write_text(f"[{kind}.{kind}]\nVersion=2\nLogLevel=LL_Info\n" + extra, encoding="utf-16")
        # A saved admin preference must not enable cheats on ordinary startup.
        # Change only this session's copies, including platform overrides.
        for path in destination.rglob("KFAAL.ini"):
            path.write_text(set_ini(read_ini(path), "AAL.AAL", {
                "bAutoEnableCheats": "False"}), encoding="utf-16")
        path = destination / "KFUnofficialPatch.ini"
        text = read_ini(path) if path.exists() else ""
        text = set_ini(text, "UnofficialKFPatch.UKFPHUDInteraction", {
            "bDisableDamagePopups": "False" if damage_popups_enabled(args) else "True"})
        # The game that runs the match: the dedicated server, or the Solo client.
        if role["role"] == "server" or getattr(args, "solo", False):
            text = set_ini(text, "UnofficialKFPatch.UKFPReplicationInfo", ukfp_spawn_settings(args))
        path.write_text(text, encoding="utf-16")
        destinations.append({"root": str(destination.resolve()), "files_sha256": config_hashes(destination)})
    role["args"].append(f"-CONFIGSUBDIR={subdir}")
    role["mod_config"] = {"subdir": str(subdir), "destinations": destinations}
