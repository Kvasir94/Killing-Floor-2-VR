"""Shared client/server Workshop content and persistent launch selections."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import functools
import msvcrt

from vr_config import profile_root
from workshop_map import MAP_NAME

DIFFICULTY_NAMES = ("normal", "hard", "suicidal", "hellonearth")
LENGTH_NAMES = ("short", "medium", "long")
VR_QUALITIES = ("quality", "balanced", "performance")
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
    name = getattr(args, "headset_preset", None)
    if not name:
        return
    quality, scale = HEADSET_PRESETS[name]
    # Explicit individual settings win; the bundle wins over saved preferences.
    if getattr(args, "vr_quality_requested", None) is None:
        args.vr_quality = quality
        args.vr_quality_requested = quality
    if getattr(args, "eye_render_percent", None) is None:
        args.eye_render_percent = scale


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
DEFAULT_MODS = []
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
DLSS_MODES = ("off", "dlaa", "quality", "balanced", "performance", "ultraperformance")


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
        args.vr = bool(saved.get("vr", True))
    if getattr(args, "map", None) is None:
        args.map = str(saved.get("map", "KF-BurningParis"))
        if not re.fullmatch(r"KF-[A-Za-z0-9_-]+", args.map):
            args.map = "KF-BurningParis"
    args.test_map = bool(getattr(args, "test_map", False)) or args.map == MAP_NAME
    if getattr(args, "difficulty", None) is None:
        args.difficulty = saved.get("difficulty") if saved.get("difficulty") in DIFFICULTY_NAMES else "normal"
    if getattr(args, "game_length", None) is None:
        args.game_length = saved.get("game_length") if saved.get("game_length") in LENGTH_NAMES else "short"
    apply_headset_preset(args)
    if getattr(args, "vr_quality", None) is None:
        args.vr_quality = saved.get("vr_quality") if saved.get("vr_quality") in VR_QUALITIES else "performance"
    if getattr(args, "inventory_focus", None) is None:
        args.inventory_focus = bool(saved.get("inventory_focus", False))
    if getattr(args, "multiplayer_grabs", None) is None:
        args.multiplayer_grabs = saved.get("multiplayer_grabs", False) is True
    if getattr(args, "breacher", None) is None:
        args.breacher = (saved.get("breacher", False) is True) if (getattr(args, "host", False) or getattr(args, "solo", False)) else False
    if scenario:
        args.breacher = False
    if getattr(args, "portal_gun", None) is None:
        args.portal_gun = saved.get("portal_gun", False) is True
    if getattr(args, "threaded_render", None) is None:
        args.threaded_render = saved.get("threaded_render", False) is True
    if getattr(args, "dlss", None) is None:
        mode = saved.get("dlss", "off")
        args.dlss = mode if mode in DLSS_MODES else "off"
    if getattr(args, "hide_bile_lens", None) is None:
        args.hide_bile_lens = saved.get("hide_bile_lens", True) is not False
    if getattr(args, "dlss_sharpness", None) is None:
        value = saved.get("dlss_sharpness", 0)
        args.dlss_sharpness = value if type(value) is int and 0 <= value <= 100 else 0
    if scenario or getattr(args, "solo", False):
        args.mods = []
        args.damage_popups = False
        args.test_map_players = 0
        if getattr(args, "solo", False):
            args.inventory_focus = False
            args.multiplayer_grabs = False
        return
    if args.mods is None:
        args.mods = parse_mods(",".join(saved.get("mods", DEFAULT_MODS)) or "none") if args.vr else []
    if args.damage_popups is None:
        args.damage_popups = bool(saved.get("damage_popups", True))
    if args.test_map_players is None:
        args.test_map_players = int(saved.get("test_map_players", 6))
    if args.test_map_players not in (0, 6):
        raise ValueError("Saved test map players must be 0 or 6")


@_preference_transaction
def save_dlss_preferences(args):
    # A join takes the host's match settings, but DLSS is the player's own.
    root = getattr(args, "profile_root", None) or profile_root()
    root.mkdir(parents=True, exist_ok=True)
    path = root / "launcher.json"
    saved = _read_preferences(path, strict=True)
    saved.update({"dlss": getattr(args, "dlss", None) or "off",
                  "dlss_sharpness": int(getattr(args, "dlss_sharpness", None) or 0),
                  "hide_bile_lens": getattr(args, "hide_bile_lens", True) is not False})
    temporary = path.with_suffix(".json.tmp")
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
    saved.update({"vr": bool(getattr(args, "vr", True)),
        "map": MAP_NAME if getattr(args, "test_map", False) else getattr(args, "map", "KF-BurningParis"),
        "difficulty": getattr(args, "difficulty", "normal"),
        "game_length": getattr(args, "game_length", "short"),
        "vr_quality": getattr(args, "vr_quality", "performance"),
        "threaded_render": bool(getattr(args, "threaded_render", False)),
        "dlss": getattr(args, "dlss", None) or "off",
        "dlss_sharpness": int(getattr(args, "dlss_sharpness", None) or 0),
        "hide_bile_lens": getattr(args, "hide_bile_lens", True) is not False,
        "breacher": bool(getattr(args, "breacher", False))})
    # Solo applies no hosted loadout. Remember its common choices without
    # erasing the mods and host settings the next hosted session will use.
    if not getattr(args, "solo", False):
        previous_mods = saved.get("mods", DEFAULT_MODS)
        saved.update({"mods": args.mods if getattr(args, "vr", True) or getattr(args, "mods_requested", False) else previous_mods,
            "damage_popups": args.damage_popups, "test_map_players": args.test_map_players,
            "inventory_focus": bool(getattr(args, "inventory_focus", False)),
            "multiplayer_grabs": bool(getattr(args, "multiplayer_grabs", False))})
    if getattr(args, "solo", False):
        saved["portal_gun"] = bool(getattr(args, "portal_gun", False))
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
            raise RuntimeError("SteamCMD is missing. Install the local server or subscribe to the item in Steam first.")
        log = Path(steam_root) / f"workshop-{item_id}.log"
        startup = subprocess.STARTUPINFO()
        startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        with log.open("wb") as output:
            result = subprocess.run([str(executable), "+login", "anonymous", "+workshop_download_item",
                "232090", item_id, "validate", "+quit"], cwd=steam_root, startupinfo=startup,
                stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, timeout=600)
        if result.returncode or not _packages(source):
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
    ids = [value[1] for value in MODS.values()] if "ukfp" in args.mods else []
    if args.map in MAPS:
        ids.append(MAPS[args.map])
    roots = {}
    for item_id in dict.fromkeys(ids):
        roots[item_id] = ensure_item(item_id, game, args.cache_root, steam_root, download=not args.prepare_only)
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
    from session import read_ini, set_ini
    content = getattr(args, "workshop_content", [])
    if not content:
        return
    path = Path(configs) / "KFEngine.ini"
    text = read_ini(path)
    section = re.search(r"(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    if not section:
        raise RuntimeError("Missing Core.System for Workshop content")
    directories = sorted({str((Path(item["root"]) / name).parent) for item in content for name in item["files_sha256"]})
    values = {key: directories + re.findall(r"(?im)^" + key + r"=([^\r\n]*)", section[1])
              for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths")}
    localization = [str(Path(item["root"]) / "Localization") for item in content
                    if (Path(item["root"]) / "Localization").is_dir()]
    values["LocalizationPaths"] = localization + re.findall(r"(?im)^LocalizationPaths=([^\r\n]*)", section[1])
    text = set_ini(text, "Core.System", values)
    if server:
        text = set_ini(text, "OnlineSubsystemSteamworks.KFWorkshopSteamworks", {
            "ServerSubscribedWorkshopItems": [item["workshop_id"] for item in content]})
    net = re.search(r"(?ims)^\[IpDrv\.TcpNetDriver\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    managers = re.findall(r"(?im)^DownloadManagers=([^\r\n]*)", net[1]) if net else []
    workshop_manager = "OnlineSubsystemSteamworks.SteamWorkshopDownload"
    text = set_ini(text, "IpDrv.TcpNetDriver", {"DownloadManagers": [workshop_manager] +
        [value for value in managers if value.lower() != workshop_manager.lower()]})
    path.write_text(text, encoding="utf-16")


def configure_mod_settings(role, args, game, user):
    """Use KF2's CONFIGSUBDIR for custom config() names, not invented *INI switches.

    KFGame appGameConfigDir (RVA bc4f0) appends this relative name. Stage matching
    install/default and user/virtualized directories; standard nine INI redirects
    still select the central role config. Nothing in either base config is edited.
    """
    if "ukfp" not in (getattr(args, "mods", None) or []):
        return
    from session import read_ini, set_ini, set_ini_defaults, config_hashes
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
        path.write_text(text, encoding="utf-16")
        destinations.append({"root": str(destination.resolve()), "files_sha256": config_hashes(destination)})
    role["args"].append(f"-CONFIGSUBDIR={subdir}")
    role["mod_config"] = {"subdir": str(subdir), "destinations": destinations}
