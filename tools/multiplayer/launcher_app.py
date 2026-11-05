"""Player launcher state and launch logic, independent of the window toolkit.

The Qt window (launcher_gui.py and the launcher_ui_* modules) shows this state
and calls these methods; nothing here draws anything. All launch and
deployment work stays in friends.py, which runs as a separate process; this
module starts it and follows its structured events (launcher_events.py).

The Play, then Solo / Host / Join, then running-session flow comes from
OptimumBox's MIT-licensed launcher (v0.5.0-alpha.20261011, commit
e35ec355ae951dda72ee80b20cb1cef12345b9ac). Repository argument adaptation
lives in launcher_compat.py and player settings in launcher_settings.py.
"""
from datetime import datetime
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import game_install
import launcher_events as events
import launcher_settings as model
import launcher_updates
import machine_settings
import settings_registry
from launcher_compat import contextual_arguments, host_form_identity

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
# Packaged ZIPs keep everything in app/ beside a single start file.
OUTER = ROOT.parent if ROOT.name.lower() == "app" else ROOT
LOGS = events.logs_folder()
ICON = HERE / "assets/kf2vr-icon.png"
REPORT_BUTTON = "Save logs for a bug report"
REPORT_WHERE = "Post it with Help > Report a bug"
# Bug reports go to KF2-VR's thread on the Flat2VR Discord (Kvasir94, 11-04).
ISSUES_URL = "https://discord.com/channels/747967102895390741/1556770175335010444"
CREDITS = "Made by Kvasir94 and optimumbox."
DISCLAIMER = ("A fan project, not affiliated with Tripwire Interactive. The hands, gloves and watch come from "
              "Killing Floor 2's own first-person arms; their rights stay with their owners.")
# Where feel and calibration live, and how to get there (VRSessionUI: menu button or the two-stick chord).
HEADSET_MENU = "Press the Menu button on your left controller, or press and hold both sticks."
VR_MENU = model.VR_MENU   # "the in-game VR menu": KF2-VR's own menu, never the headset's system settings
NO_WINDOW = 0x08000000
PYTHON = Path(sys.executable).with_name("python.exe")
STORE_NAMES = {"steam": "Steam", "epic": "Epic Games"}
STORE_TAGS = {"steam": "Recommended: Solo, Host and Join", "epic": "Experimental: Solo in VR only"}
# One XP rule, said the same way everywhere: only a Solo match with changed Zed spawns earns none.
SOLO_XP = "Changed Zed spawns turn XP off for this Solo match; hosted games keep XP."
HOST_XP = "Hosted games keep XP with any Zed spawns; only Solo loses it."
# Said the same way on Welcome and Setup.
HEADSET_READY = "KF2-VR uses the headset app that's running on this PC."
HEADSET_MISSING = "Start SteamVR, Quest Link or your headset's PC app; you can also play on a flat screen."
GAME_MISSING = ("If Killing Floor 2 is installed, start it from Steam once, then press Check again. Installed "
                "somewhere KF2-VR can't see? Choose its folder.")
STEAM_STORE_URL = "https://store.steampowered.com/app/232090/Killing_Floor_2/"
GET_GAME = "Get Killing Floor 2 on Steam"
OTHER_FOLDER = "Choose game folder…"   # the one name for this action, here and on Game & headset
SETUP_NAV = "Game & headset"   # the rail name of the Setup page; "Settings" sits beside it
EPIC_LIMITS = "With the Epic copy you can play Solo in VR only; hosting and joining friends need the Steam copy."
# Graphics are saved choices, not per-match ones; every page says so the same way.
GRAPHICS_SCOPE = "Saved as you choose and used every time you play."
# First-time cards about the player rather than advice: never "recommended", never reset by Use recommended.
PERSONAL_CARDS = ("dominant_hand", "seated_mode")
# KF2-VR's own maps, offered to every player under their own heading.
MOD_MAPS = {"KF-VRRange": "VR Range (practice)"}

# Optional server-side spawn overrides: (registry option, form label, offered values).
SPAWN_FIELDS = (("max_zeds", "Max Zeds at once", (0, 8, 12, 16, 24, 32, 48, 64, 96, 128)),
                ("wave_zeds_percent", "Zeds per wave", (25, 50, 75, 100, 125, 150, 200, 300, 400, 500)),
                ("spawn_rate_percent", "Spawn speed", (50, 75, 100, 125, 150, 200, 300, 400, 500)))
DIFFICULTY_LABELS = {"normal": "Normal", "hard": "Hard", "suicidal": "Suicidal", "hellonearth": "Hell on Earth"}
LENGTH_LABELS = {"short": "Short (4 waves and the boss)", "medium": "Medium (7 waves and the boss)",
                 "long": "Long (10 waves and the boss)"}
LENGTH_SHORT = {"short": "Short", "medium": "Medium", "long": "Long"}
MOD_NAMES = {"ukfp": "Community fixes", "friendlyhud": "Teammate health bars", "yas": "Bigger scoreboard",
             "aal": "Automatic admin login", "cvc": "Better voting", "lti": "Trader inventory changes"}
MOD_HELP = {"ukfp": "Fixes bugs in the game. KF2-VR switches it on for you when another mod or a Zed spawn change needs it.",
            "friendlyhud": "Shows teammates' health and armor over their heads.",
            "yas": "A larger scoreboard with more detail.",
            "aal": "Makes you the admin of your own game, so you can kick players or change maps.",
            "cvc": "Clearer in-game votes to change the map or kick a player.",
            "lti": "Changes what the trader offers; its Workshop page has the details."}
# A mod whose help points at its Workshop page gets a link to it there.
MOD_PAGES = {"lti": "https://steamcommunity.com/sharedfiles/filedetails/?id=2864857909"}
SERVER_NAME_PROBLEM = "Use 1-48 letters, numbers, spaces or . , ' ! & ( ) + _ -"
SERVER_NAME_MISSING = "Type a name; friends see it when they join."
PASSWORD_PROBLEM = "Use up to 64 letters, numbers, _ or -"
PASSWORD_PATTERN = r"[A-Za-z0-9_-]{0,64}"

# What the player reads for each backend phase while it is current.
GUIDANCE = {
    "checking": "Checking your game and files...",
    "join-accepted": "Code accepted. Getting ready...",
    "server-install": "Setting up the game server...",
    "server-download": "Downloading the game server. The first time is about 9 GB (32 GB once installed).",
    "server-starting": "Game server ready. Starting it...",
    "connecting": "Connecting to the game server...",
    "host-ready": "Your game is up. Send your friends the code below.",
    "epic-options": "Copy the line below into Epic > Library > Killing Floor 2 > Manage > Launch Options.",
    "epic-connected": "Epic connected. Choose Play Solo Offline, your map and perk, then Ready. Keep this window open.",
    "game-starting": "Killing Floor 2 is starting. Pick your perk and press Ready. Keep this window open while you play.",
}
# The steps each kind of session shows; download and start fold into server setup.
STEPS = {
    "solo": ("checking", "game-starting"),
    "host": ("checking", "server-install", "connecting", "host-ready", "game-starting"),
    "join": ("checking", "join-accepted", "connecting", "game-starting"),
    "epic": ("checking", "epic-options", "epic-connected"),
}
STEP_OF = {"server-download": "server-install", "server-starting": "server-install"}
# Command-line choices that the window keeps for this launch unless the player
# changes the same setting on the Settings page.
OVERRIDABLE = tuple(s.key for s in model.SETTINGS if s.store == "launcher") + ("eye_render_percent", "vr_quality")
RUNTIMES = (("virtualdesktop", "Virtual Desktop"), ("vdxr", "Virtual Desktop"), ("steamvr", "SteamVR"),
            ("oculus", "Meta Quest Link"), ("meta", "Meta Quest Link"), ("mixedreality", "Windows Mixed Reality"),
            ("wmr", "Windows Mixed Reality"), ("pimax", "Pimax"), ("varjo", "Varjo"), ("vive", "VIVE"),
            ("pico", "PICO Connect"), ("monado", "Monado"))


def spawn_labels(key, offered, value):
    """Choice labels for one spawn override, keeping a value set elsewhere (command line, -Menu)."""
    option = settings_registry.option(key)
    if type(value) is not int or not option.minimum <= value <= option.maximum:
        value = option.default
    if key == "max_zeds":
        return {n: "Standard (the game decides)" if n == 0 else str(n) for n in sorted(set(offered) | {value})}, value
    return {n: "Standard (100%)" if n == 100 else f"{n}%" for n in sorted(set(offered) | {value})}, value


def developer_tools_present():
    """The player package leaves out recording, highlight and test-control tools."""
    import importlib.util
    return all(importlib.util.find_spec(name) is not None
               for name in ("motion_session", "promo_session", "local_test_control"))


def friendly(code_or_message):
    """Player wording for an error code, or for a raw message from an older backend."""
    text = str(code_or_message or "")
    code = text if text in events.ERROR_TEXT else events.classify(text)
    return events.ERROR_TEXT.get(code, text or "Something went wrong.")


def host_identity():
    """The remembered server name and host password."""
    saved = machine_settings.load(ROOT)
    return saved.get("server_name") or settings_registry.DEFAULT_SERVER_NAME, saved.get("host_password") or ""


def game_folder(store="auto"):
    saved = machine_settings.load(ROOT).get("game_root")
    try:
        return game_install.select_for_launch(store=store, saved_root=saved).root
    except (ValueError, OSError):
        return None


def headset_status():
    """(ready, runtime name) for the active OpenXR runtime, without starting anything."""
    try:
        from friends import active_openxr_runtime
        return True, active_openxr_runtime()[1]
    except (OSError, KeyError, ValueError, TypeError, AttributeError, ImportError):
        return False, None


def runtime_name(raw):
    """The headset app a player recognizes, from an OpenXR runtime's manifest name."""
    text = re.sub(r"\s*\(.*?\)", "", str(raw or "")).strip()
    squashed = re.sub(r"[^a-z]", "", text.lower())
    return next((name for key, name in RUNTIMES if key in squashed), text or "Headset app")


def version_text(version):
    """0.3.0-alpha.20261104 -> v0.3.0-alpha, 4 Nov 2026."""
    match = re.fullmatch(r"(.+?)[.-](20\d{6})", str(version or ""))
    if not match:
        return f"v{version}" if version else "Development build"
    try:
        date = datetime.strptime(match[2], "%Y%m%d")
    except ValueError:
        return f"v{match[1]}"
    return f"v{match[1]}, {date.day} {date:%b %Y}"


# Names the automatic spelling can't get right.
MAP_NAMES = {"KF-SantasWorkshop": "Santa's Workshop", "KF-KrampusLair": "Krampus Lair", "KF-ASHES": "Ashes",
             "KF-MinecraftBase_Winter": "Minecraft Base (Winter)", "KF-KF1-MountainPass-Night": "KF1 Mountain Pass (Night)",
             "KF-PowerCore_Holdout": "Powercore Holdout", "KF-City17": "City 17",
             "KF-Remilly_Test_Map": "Remilly's Test Map"}
SMALL_WORDS = {"of", "the", "and", "in", "on", "at", "to"}


def pretty_map(name):
    """KF-BurningParis -> Burning Paris; KF-Edge_Of_Reality -> Edge of Reality; KF-Deck17_V1 -> Deck 17 (v1)."""
    if name in MAP_NAMES:
        return MAP_NAMES[name]
    base = re.sub(r"[_-]?zfix$", "", name.removeprefix("KF-"), flags=re.I)
    words = re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[a-z]{2})(?=[0-9])", " ", base).replace("_", " ").replace("-", " ")
    words = " ".join(word.capitalize() if word.isupper() and word.isalpha() and len(word) > 3 else word
                     for word in words.split())
    parts = words.split()
    parts = [part.lower() if index and part.lower() in SMALL_WORDS else part for index, part in enumerate(parts)]
    if len(parts) > 1 and re.fullmatch(r"[vV]\d+", parts[-1]):
        parts[-1] = f"({parts[-1].lower()})"
    return re.sub(r"\s+", " ", " ".join(parts)).strip()


class Heading(str):
    """A list entry that only names the group of options below it."""


def map_choices(maps, stock=()):
    """[(map or Heading, label)]: Killing Floor 2's own maps, KF2-VR's practice range, then Workshop
    maps, each alphabetical. Every map offered is listed; none is hidden by its name (Kvasir94, 11-05)."""
    stock = set(stock)
    groups = {"stock": [], "mod": [], "workshop": []}
    for name in dict.fromkeys(maps):
        if name in MOD_MAPS:
            groups["mod"].append((name, MOD_MAPS[name]))
            continue
        groups["stock" if name in stock else "workshop"].append((name, pretty_map(name)))
    result = []
    for group, title in (("stock", "Killing Floor 2 maps"), ("mod", "KF2-VR maps"), ("workshop", "Workshop maps")):
        if groups[group]:
            # The list opens on a map, not a heading: the first group needs none.
            if result:
                result.append((Heading(title), title))
            result += sorted(groups[group], key=lambda item: item[1].casefold())
    return result


def map_label(saved):
    from workshop_map import MAP_NAME
    return pretty_map(MAP_NAME if getattr(saved, "test_map", False) else getattr(saved, "map", None) or "KF-BurningParis")


def where_text(setting):
    """Where a setting the launcher leaves out is changed: "In the in-game VR menu, Settings › Comfort"."""
    if setting.where == "game":
        return "In Killing Floor 2's own Options menu"
    category, _, group = (setting.menu or f"{setting.tab}/{setting.group}").partition("/")
    return f"In {model.VR_MENU}, {model.menu_path(category, group)}"


def parse_context(argv=None):
    parser = argparse.ArgumentParser(description="KF2-VR player window")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--initial-arguments", type=json.loads, default=[])
    parser.add_argument("--allow-stale", action="store_true")
    parser.add_argument("--stale", action="store_true")
    parser.add_argument("--developer", action="store_true", help="Show developer and test options")
    context = parser.parse_args(argv)
    if not isinstance(context.initial_arguments, list) or any(not isinstance(item, str) for item in context.initial_arguments):
        parser.error("--initial-arguments must be a JSON list of launch arguments")
    if context.initial_arguments and not context.workspace:
        parser.error("--initial-arguments requires --workspace")
    return context


def single_instance():
    """True when no other player window is open; the named mutex lives as long as this process."""
    try:
        kernel = ctypes.windll.kernel32
        kernel.CreateMutexW(None, False, "Local\\KF2VR-PlayerWindow")
        return kernel.GetLastError() != 183  # ERROR_ALREADY_EXISTS
    except (AttributeError, OSError):
        return True


def _preferences():
    from workshop_loadout import _read_preferences, profile_root
    return _read_preferences(Path(profile_root()) / "launcher.json")


def _update_preferences(values):
    from workshop_loadout import update_preferences
    update_preferences(values)


class SessionTracker:
    """One friends.py run: its process, its log and the events it has written so far."""

    def __init__(self, process, log, events_path, kind, title):
        self.process, self.log, self.events_path = process, Path(log), Path(events_path)
        self.kind, self.title = kind, title
        self.event_offset = 0
        self.phase = None
        self.error_code = self.error_message = None
        self.returncode = None
        self.download_log = None
        self.join_code = None  # the code, "none" when the host has no public address
        self.epic_options = None
        self.finished = False

    def remember(self, event):
        """Record one backend event; returns what changed for the page to show."""
        changed = set()
        if event.get("phase") in events.PHASE_TEXT:
            self.phase = event["phase"]
            changed.add("phase")
        if "download_log" in event:
            self.download_log = Path(str(event["download_log"]))
        if "join_code" in event and not self.join_code:
            code = event["join_code"]
            self.join_code = code if isinstance(code, str) and code.startswith("KF2VR1:") else "none"
            changed.add("join_code")
        if "epic_options" in event and not self.epic_options:
            self.epic_options = str(event["epic_options"])
            changed.add("epic_options")
        if "error" in event:
            self.error_code = str(event["error"])
            self.error_message = str(event.get("message", ""))
            changed.add("error")
        return changed

    def poll(self):
        """Read new events, then notice when the backend has exited; returns what changed."""
        changed = set()
        found, self.event_offset = events.read(self.events_path, self.event_offset)
        for event in found:
            changed |= self.remember(event)
        if not self.finished and self.process is not None and self.process.poll() is not None:
            self.returncode = self.process.returncode
            self.finished = True
            changed.add("finished")
        return changed

    def running(self):
        return not self.finished and self.process is not None and self.process.poll() is None

    # Before the game server starts nothing is deployed into the game folders, so the run can simply stop.
    PREPARING = (None, "checking", "server-install", "server-download")

    def preparing(self):
        """Still downloading or checking: nothing to tidy up yet, so closing the window can stop it."""
        return self.running() and self.phase in self.PREPARING

    def stop(self):
        """End this run and everything it started (the server installer and SteamCMD)."""
        if self.running():
            subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"], capture_output=True,
                           creationflags=NO_WINDOW)

    @property
    def succeeded(self):
        return self.finished and self.returncode == 0 and not self.error_code

    def log_text(self):
        try:
            return self.log.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def download_percent(self):
        """The server download's progress while it runs, else None."""
        if self.phase != "server-download" or not self.download_log or not self.running():
            return None
        try:
            with self.download_log.open("rb") as handle:
                handle.seek(max(0, self.download_log.stat().st_size - 8192))
                tail = handle.read().decode("utf-8", errors="replace")
        except OSError:
            return None
        percent = re.findall(r"progress: (\d+(?:\.\d+)?)", tail)
        return float(percent[-1]) if percent else None

    def steps(self):
        """[(phase, state)] for the step strip: state is done, active or waiting."""
        steps = STEPS.get(self.kind, STEPS["solo"])
        current = STEP_OF.get(self.phase, self.phase)
        reached = steps.index(current) if current in steps else -1
        result = []
        for index, step in enumerate(steps):
            done = index < reached or self.succeeded
            active = index == reached and not self.finished
            result.append((step, "done" if done else "active" if active else "waiting"))
        return result

    def guidance(self):
        return GUIDANCE.get(self.phase, events.PHASE_TEXT.get(self.phase, "Starting..."))

    def problem(self):
        reason = self.error_code if self.error_code not in (None, events.UNKNOWN) else self.error_message
        return friendly(reason)


class LauncherState:
    """Everything the window shows and does, minus the drawing."""

    def __init__(self, context=None):
        import friends
        from workshop_loadout import load_preferences
        self.context = context or argparse.Namespace(workspace=None, initial_arguments=[], allow_stale=False,
                                                     stale=False, developer=False, self_check=False)
        # Testing tools appear only in a checkout or when explicitly asked for,
        # and never in a player package, which leaves those tools out.
        self.developer = bool((getattr(self.context, "developer", False) or self.context.workspace)
                              and developer_tools_present())
        self.saved = friends.parse_options(self.context.initial_arguments or ["--host"])
        load_preferences(self.saved)
        release = ROOT / "release.json"
        manifest = json.loads(release.read_text(encoding="utf-8-sig")) if release.exists() else {}
        self.build = manifest.get("build_id", ROOT.name)
        self.version = manifest.get("version")
        self._probes = {}
        self.store = self.saved.store
        try:
            chosen = game_install.select_for_launch(store=self.saved.store, root=self.saved.game_root,
                                                    saved_root=game_folder(self.saved.store))
            self.store = chosen.store
        except (ValueError, OSError):
            pass
        self.vr = bool(self.saved.vr)
        self.frame_timings = bool(self.saved.frame_timings)
        self.record_motion = bool(self.saved.record_motion)
        self.highlight_events = bool(self.saved.promo_events)
        if self.store == "epic":
            self.epic_rules()
        self.settings_values = model.load(self.saved)
        self.kept_overrides = set(OVERRIDABLE)
        self.session = None
        self.onboarding = False
        self.setup_touched = set()
        self._default_values = None

    def epic_rules(self):
        """Epic is experimental Solo in VR: no desktop mode, no recording."""
        self.vr = True
        self.record_motion = False
        self.highlight_events = False

    # ----- cached probes ------------------------------------------------------
    def cached(self, key, seconds, compute):
        """A probe result reused for a few seconds, so moving between pages never waits on disk or processes."""
        hit = self._probes.get(key)
        now = time.monotonic()
        if hit and now - hit[0] < seconds:
            return hit[1]
        value = compute()
        self._probes[key] = (now, value)
        return value

    def forget(self, *prefixes):
        for key in [key for key in self._probes if not prefixes or key[0] in prefixes]:
            del self._probes[key]

    def headset(self):
        return self.cached(("headset",), 10, headset_status)

    # ----- game installation --------------------------------------------------
    def installs(self):
        def find():
            try:
                return game_install.discover()
            except OSError:
                return []
        return sorted(self.cached(("game", "installs"), 30, find), key=lambda i: (i.store != "steam", str(i.root)))

    def resolve_game(self):
        """(installation, problem) without asking: problem is None, "choose" (more than one) or "missing".

        Cached briefly: a saved folder is identified by hashing the game executable."""
        def find():
            try:
                install = game_install.select_for_launch(store=self.store, root=self.saved.game_root,
                                                         saved_root=game_folder(self.store))
                return install, None
            except (ValueError, OSError) as error:
                return None, "choose" if "Choose a Killing Floor" in str(error) else "missing"
        return self.cached(("game", self.store, str(self.saved.game_root)), 30, find)

    def use_install(self, install):
        """Remember one installation for this PC; Epic is VR Solo only."""
        self.forget("game")
        self.store = install.store
        self.saved.store = install.store
        self.saved.game_root = install.root
        machine_settings.save({"store": install.store, "game_root": str(install.root)})
        if self.onboarding:
            # machine.json alone marks a returning player; this one is still getting started.
            _update_preferences({"onboarding": True})
        if install.store == "epic":
            self.epic_rules()

    def check_folder(self, picked):
        """(installation, None) for a usable chosen folder, else (None, (title, text))."""
        if not (Path(picked) / "Binaries/Win64/KFGame.exe").exists():
            return None, ("Not that folder", "That folder doesn't contain Killing Floor 2. Look for the killingfloor2 "
                          "folder inside steamapps\\common or your Epic Games folder.")
        try:
            return game_install.select_for_launch(store="auto", root=Path(picked)), None
        except (ValueError, OSError):
            return None, ("Can't use this copy", "This copy of Killing Floor 2 doesn't match this KF2-VR version. "
                          "Let Steam or Epic finish updating it, or get the newest KF2-VR.")

    def game(self):
        """The game folder to launch, or None when the player still has to choose or find it."""
        install, _ = self.resolve_game()
        if install:
            self.store = install.store
            self.saved.game_root = install.root
            return install.root
        return None

    def server_installed(self):
        return (Path(self.saved.server_root) / "Binaries/Win64/KFServer.exe").is_file()

    def server_space(self):
        """(drive name, free GB) where the game server goes, or (drive, None) when it can't be read."""
        import shutil
        root = Path(self.saved.server_root)
        drive = root.drive or root.anchor or str(root)
        probe = next((folder for folder in (root, *root.parents) if folder.exists()), None)
        try:
            return drive, shutil.disk_usage(probe).free / 1e9 if probe else None
        except OSError:
            return drive, None

    def choose_server_folder(self, picked):
        """Host the game server in a folder the player picked: a folder that already holds a server is used as
        it is, otherwise a KF2VR-Server folder inside it. Returns None, or (title, text) when it can't be used."""
        picked = Path(picked)
        target = picked if (picked / "Binaries/Win64/KFServer.exe").is_file() or picked.name == "KF2VR-Server"             else picked / "KF2VR-Server"
        try:
            target.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            return "Couldn't use that folder", f"KF2-VR can't write to {picked}. Pick another folder. ({error.strerror})"
        machine_settings.save({"server_root": str(target)})
        self.saved.server_root = target
        self.forget("maps")
        return None

    def stock_maps(self, game):
        """Maps that ship with Killing Floor 2 itself (in the game's own folder)."""
        def find():
            folder = Path(game) / "KFGame/BrewedPC/Maps" if game else None
            return {p.stem for p in folder.rglob("KF-*.kfm")} if folder and folder.is_dir() else set()
        return self.cached(("stock", str(game)), 600, find)

    def maps(self, kind, game):
        """Installed maps for a match form; listing walks the game folder, so once per window is enough."""
        from launch_menu import installed_maps, installed_solo_maps
        solo = kind == "solo"
        return self.cached(("maps", solo, str(game), str(self.saved.server_root)), 600,
                           lambda: installed_solo_maps(game) if solo else installed_maps(game, self.saved.server_root))

    # ----- first launch and upgrades ---------------------------------------------
    def first_launch(self):
        """No player profile yet: a returning player (even from an older release) never sees onboarding."""
        import workshop_loadout
        profile = Path(workshop_loadout.profile_root())
        prefs = workshop_loadout._read_preferences(profile / "launcher.json")
        if prefs.get("welcome_seen") or prefs.get("last_session"):
            return False
        return bool(prefs.get("onboarding")) or not (profile / machine_settings.FILE).exists()

    def finish_onboarding(self):
        model.complete_first_time_setup()
        _update_preferences({"welcome_seen": True, "settings_note_seen": True})
        self.onboarding = False
        self.setup_touched = set()

    def upgrade_note_pending(self):
        """A returning player: never repeat first-time setup; say once that settings were reorganized."""
        if self.session_running() or getattr(self.context, "self_check", False):
            return False
        prefs = _preferences()
        if model.first_time_setup_pending():
            model.complete_first_time_setup()
        return not prefs.get("settings_note_seen")

    def dismiss_upgrade_note(self):
        _update_preferences({"settings_note_seen": True})

    def update_check_enabled(self):
        return _preferences().get("update_check", True) is True

    def set_update_check(self, enabled):
        _update_preferences({"update_check": bool(enabled)})

    def find_update(self):
        """(tag, url) of a newer public release, or None; network, so call it off the window's thread."""
        return launcher_updates.available_update(self.version or "", timeout=5, build=self.build) or None

    # ----- play -------------------------------------------------------------
    def last_kind(self):
        from workshop_loadout import last_session
        return "solo" if self.store == "epic" else last_session()

    def played_before(self):
        return bool(_preferences().get("last_session"))

    def refresh_player_preferences(self):
        if self.session_running():
            return
        import friends
        from workshop_loadout import load_preferences
        tokens = list(self.context.initial_arguments)
        excluded = {}
        for key in OVERRIDABLE:
            if key in self.kept_overrides:
                continue
            option = settings_registry.option(key)
            excluded[option.flag] = option.kind != "toggle"
            if option.kind == "toggle":
                excluded["--no-" + option.flag[2:]] = False
        flags = []
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if token in excluded:
                index += 2 if excluded[token] else 1
            else:
                flags.append(token)
                index += 1
        updated = friends.parse_options(flags or ["--" + self.last_kind()])
        load_preferences(updated)
        self.saved = updated
        self.settings_values = model.load(self.saved)

    def remembered_match(self, kind):
        remembered = _preferences().get(kind + "_match", {})
        return remembered if isinstance(remembered, dict) else {}

    def match_summary(self, kind):
        remembered = self.remembered_match(kind)
        name = remembered.get("map") or self.saved.map
        difficulty = remembered.get("difficulty", self.saved.difficulty)
        length = remembered.get("game_length", self.saved.game_length)
        place = pretty_map(name) if name else map_label(self.saved)
        return "  ·  ".join((place, DIFFICULTY_LABELS.get(difficulty, str(difficulty)),
                             LENGTH_SHORT.get(length, str(length)) + " length"))

    def graphics_summary(self):
        return model.graphics_summary(self.settings_values, self.vr)

    def match_defaults(self, kind, maps):
        """The form's starting values: the last match of this kind, then the saved choices."""
        from workshop_loadout import desktop_workshop_availability
        from workshop_map import MAP_NAME
        remembered = self.remembered_match(kind)
        current = remembered.get("map", MAP_NAME if self.saved.test_map else self.saved.map)
        values = {"map": current if current in maps else maps[0],
                  "difficulty": remembered.get("difficulty", self.saved.difficulty),
                  "game_length": remembered.get("game_length", self.saved.game_length)}
        spawns = {}
        for key, _, offered in SPAWN_FIELDS:
            spawns[key] = spawn_labels(key, offered, remembered.get(key, getattr(self.saved, key, None)))
        values["spawn_choices"] = spawns
        for key, (labels, value) in spawns.items():
            values[key] = value
        if kind == "host":
            name, password = host_form_identity(self.saved, host_identity())
            availability = desktop_workshop_availability(ROOT, self.saved.cache_root)
            values.update(server_name=name, password=password, availability=availability,
                          zed_grabs=getattr(self.saved, "zed_grabs", None) is not False,
                          gravity_grab=getattr(self.saved, "gravity_grab", None) is not False,
                          workshop_desktop=bool(getattr(self.saved, "workshop_desktop", False) and availability is not False),
                          mods=[key for key in self.saved.mods or []])
        values["local_test_control"] = bool(self.saved.local_test_control and kind == "solo" and self.vr_live())
        values["test_mode"] = bool(self.saved.test_mode)
        return values

    def remember_match(self, kind, form):
        """Save the form's choices as they are made (the same model as graphics); Quick start and the next visit use them."""
        from workshop_map import MAP_NAME
        if kind == "solo" and form.get("map") == MAP_NAME:
            return  # the test map is never remembered for Solo, as friends.py does
        match = {key: form[key] for key in ("map", "difficulty", "game_length") if key in form}
        match.update({key: int(form[key]) for key, _, _ in SPAWN_FIELDS if key in form})
        values = {kind + "_match": match}
        if kind == "host":
            # A greyed Desktop switch (this build is not the one on the Workshop) is not the player's choice:
            # keep the saved one, on by default, for the build that matches.
            keys = ("zed_grabs", "gravity_grab") + (("workshop_desktop",) if form.get("availability") is not False else ())
            values.update({key: form[key] for key in keys if key in form})
            if "mods" in form:
                values["mods"] = list(form["mods"])
        try:
            _update_preferences(values)
        except (OSError, ValueError):
            pass  # a damaged launcher.json is left for friends.py to report; the form still works

    def check_update(self):
        """("new", (tag, url)), ("current", None) or ("failed", None); network, so off the window's thread."""
        found = launcher_updates.latest_release(timeout=5)
        if not found:
            return "failed", None
        released, built = launcher_updates.stamp(found[0]), launcher_updates.stamp(self.build)
        if launcher_updates.newer(found[0], self.version or "") and not (released and built and released < built):
            return "new", found
        return "current", None

    def vr_live(self):
        return self.vr and self.store != "epic"

    @staticmethod
    def spawns_changed(form):
        return any(form.get(key) != settings_registry.option(key).default for key, _, _ in SPAWN_FIELDS)

    @staticmethod
    def patch_needed(form):
        """Why the Unofficial KF2 Patch must load: the mods picked, or Zed spawn changes; else ""."""
        from workshop_loadout import MODS
        if any(key != "ukfp" and key in form.get("mods", ()) for key in MODS):
            return "Needed by the mods you picked"
        if LauncherState.spawns_changed(form):
            return "Needed by your Zed spawn changes"
        return ""

    def host_problems(self, form):
        import friends
        name, secret = form.get("server_name", "").strip(), form.get("password", "").strip()
        return {"server_name": "" if re.fullmatch(friends.SERVER_NAME_PATTERN, name) else
                SERVER_NAME_MISSING if not name else SERVER_NAME_PROBLEM,
                "password": "" if not secret or re.fullmatch(r"[A-Za-z0-9_-]{1,64}", secret) else PASSWORD_PROBLEM}

    def match_arguments(self, kind, game, form):
        """friends.py arguments for the Solo or Host form, or raise ValueError(problems) when a field is wrong."""
        from workshop_loadout import MODS
        solo = kind == "solo"
        if form.get("local_test_control") and not (solo and self.vr):
            raise PermissionError("Local agent test control is available in Solo VR only.")
        arguments = ["--solo" if solo else "--host", "--vr" if self.vr else "--desktop",
                     "--game-root", str(game), "--map", form["map"],
                     "--difficulty", form["difficulty"], "--game-length", form["game_length"]]
        for key, _, _ in SPAWN_FIELDS:
            arguments += [settings_registry.option(key).flag, str(form[key])]
        if not solo:
            arguments.append("--no-inventory-focus")
            if form.get("availability") is not False:
                arguments.append("--workshop-desktop" if form.get("workshop_desktop") else "--no-workshop-desktop")
            for key in ("zed_grabs", "gravity_grab"):
                flag = key.replace("_", "-")
                arguments.append("--" + flag if form.get(key) else "--no-" + flag)
            problems = self.host_problems(form)
            if any(problems.values()):
                raise ValueError(problems)
            name, secret = form["server_name"].strip(), form.get("password", "").strip()
            arguments += ["--server-name", name]
            arguments += ["--no-open-server", "--password", secret] if secret else ["--open-server"]
            mods = set(form.get("mods", ()))
            if self.patch_needed(form):
                mods.add("ukfp")
            chosen = [key for key in MODS if key in mods]
            arguments += ["--mods", ",".join(chosen) or "none"]
        if form.get("local_test_control"):
            arguments.append("--local-test-control")
        if form.get("test_mode"):
            arguments.append("--test-mode")
        return arguments

    def quick_play_arguments(self, game):
        kind = self.last_kind()
        return ["--" + kind, "--vr" if self.vr else "--desktop", "--game-root", str(game)], \
            "Solo match" if kind == "solo" else "Hosting"

    @staticmethod
    def join_code_state(code, build):
        """("empty" | "ok" | "bad", what to tell the player) for a pasted join code."""
        text = re.sub(r"\s+", "", code or "")
        if not text:
            return "empty", ""
        try:
            from join_code import decode
            details = decode(text, build)
        except ValueError as error:
            if "different" in str(error):
                return "bad", "This code is from a different KF2-VR version. You and your host need the same version."
            # The code's own format stays out of what the player reads; it is checked silently.
            from join_code import PREFIX
            if not text.startswith(PREFIX):
                return "bad", "That doesn't look like a KF2-VR join code. Copy the whole code from your friend's message."
            return "bad", "That code is cut short or changed. Copy it again from your friend's message."
        mods = len(details["mods"])
        return "ok", "  ·  ".join((pretty_map(details["map"]), f"{mods} mods" if mods else "No mods",
                                   "Password protected" if details["password"] else "No password"))

    @staticmethod
    def split_address(address):
        """(host, port or None) from "host" or "host:port"; KF2's default game port is 7777."""
        text = address.strip()
        host, colon, port = text.rpartition(":")
        if colon and port.isdigit():
            return host, int(port)
        return text, None

    @classmethod
    def address_problems(cls, address, password):
        """{field: what's wrong} for the address form; empty when it can be joined."""
        problems = {}
        host, port = cls.split_address(address)
        text = address.strip()
        if ":" in text and port is None:
            problems["address"] = "After the colon put the port number, such as :7777, or leave it out."
        elif re.fullmatch(r"[0-9.]+", host):
            # All digits and dots: an IPv4 address, four numbers 0-255.
            parts = host.split(".")
            if len(parts) != 4 or not all(parts):
                problems["address"] = "An IP address has four numbers with dots between, such as 203.0.113.7."
            elif not all(int(part) <= 255 for part in parts):
                problems["address"] = "Each number of an IP address is 0 to 255."
        elif len(host) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part)
                                        for part in host.split(".")):
            problems["address"] = "Use an IP address or computer name, with an optional :port, and no spaces."
        if "address" not in problems and port is not None and not 1 <= port <= 65535:
            problems["address"] = "The port after the colon must be between 1 and 65535."
        if not re.fullmatch(PASSWORD_PATTERN, password.strip()):
            problems["password"] = "Use only letters, numbers, _ or -."
        return problems

    @classmethod
    def address_valid(cls, address, password):
        return bool(address.strip()) and not cls.address_problems(address, password)

    def join_arguments(self, game, method, code="", address="", password=""):
        """friends.py arguments for Join, or None when the chosen method isn't filled in."""
        arguments = ["--vr" if self.vr else "--desktop", "--game-root", str(game)]
        if method == "code":
            text = re.sub(r"\s+", "", code)
            if not text.startswith("KF2VR1:"):
                return None
            return arguments + ["--address", text]
        if not self.address_valid(address, password):
            return None
        host, port = self.split_address(address)
        arguments += ["--address", host, "--password", password.strip()]
        return arguments + (["--port", str(port)] if port is not None else [])

    # ----- settings -----------------------------------------------------------
    def defaults(self):
        if self._default_values is None:
            self._default_values = model.defaults()
        return self._default_values

    def persist(self, edits):
        """Save setting edits; returns (saved, problem) with problem "running" or an error message."""
        if self.session_running():
            return False, "running"
        try:
            model.save(edits)
        except (OSError, ValueError, KeyError) as error:
            return False, str(error)
        for key, value in edits.items():
            self.kept_overrides.discard(key)
            setting = model.BY_KEY[key]
            if setting.store == "graphics":
                self.kept_overrides.discard("vr_quality")
            if setting.store == "launcher":
                setattr(self.saved, key, not value if setting.invert else value)
        if "eye_render_percent" in edits:
            self.saved.eye_render_percent = None
        self.settings_values = model.load(self.saved)
        return True, None

    def apply_preset(self, preset, name):
        """Save one preset option; a graphics preset also becomes the saved launch quality."""
        saved, problem = self.persist(self.with_mirroring(model.preset_targets(preset)[name]))
        if not saved:
            return saved, problem
        if preset == "graphics_preset":
            tier = model.preset_option(preset, "label", name)["tier"]
            self.kept_overrides.discard("vr_quality")
            self.saved.vr_quality = tier
            self.saved.vr_quality_requested = None
            _update_preferences({"vr_quality": tier})
        return True, None

    def with_mirroring(self, edits):
        """A new dominant hand moves the movement and menu hands with it, unless the player arranged them by hand."""
        value = edits.get("PreferredWeaponHand")
        values = self.settings_values
        current = str(values["PreferredWeaponHand"])
        if value is not None and str(value) != current:
            standard = str(values["MovementHand"]) == str(1 - int(current)) and str(values["MenuHand"]) == current
            if standard:
                edits = dict(edits, MovementHand=str(1 - int(value)), MenuHand=str(value))
        return edits

    @staticmethod
    def value_text(setting, value):
        if setting.kind == "toggle":
            return "On" if value else "Off"
        if setting.kind == "choice":
            return model.labels(setting, value)[value]
        return model.number_display(setting, value) + setting.unit

    def preset_change_lines(self, preset, name):
        """What choosing a preset option would change, when it replaces values changed by hand; else []."""
        if model.preset_name(preset, self.settings_values) != "Custom":
            return []
        lines = []
        for key, value in model.preset_changes(preset, name, self.settings_values).items():
            setting = model.BY_KEY[key]
            new = model._matching_choice(setting, value) if setting.kind == "choice" else value
            lines.append(f"{setting.label}: {self.value_text(setting, self.settings_values[key])} → "
                         f"{self.value_text(setting, new)}")
        return lines

    def reset(self, category=None):
        return self.persist(model.defaults(category))

    def reset_note(self, category=None):
        if category:
            return model.CATEGORIES[category].get("reset_note", "")
        return "Your calibration, saved matches, game copy and host details are kept."

    # ----- first-time setup ---------------------------------------------------
    def card_value(self, card):
        """The card's current option: a preset name, or {setting key: stored value}."""
        if "preset" in card:
            return model.preset_name(card["preset"], self.settings_values)
        keys = [card["setting"]] if "setting" in card else card.get("settings", [])
        return {key: str(self.settings_values[key]) for key in keys}

    def recommended_edits(self, card):
        if "preset" in card:
            name = model.preset_recommended(card["preset"])
            return {} if model.preset_name(card["preset"], self.settings_values) == name else {"preset": name}
        wanted = {card["setting"]: card["recommended"]} if "setting" in card else card["recommended"]
        return {key: value for key, value in wanted.items() if str(self.settings_values.get(key)) != str(value)}

    def card_hint(self, card):
        """The one line under a card for its current choice."""
        values = self.settings_values
        if "preset" in card:
            current = model.preset_name(card["preset"], values)
            return model.preset_help(card["preset"], current) or \
                f"Custom (based on {model.preset_basis(card['preset'], values)})."
        lines = []
        for key in [card["setting"]] if "setting" in card else card.get("settings", []):
            setting = model.BY_KEY[key]
            if sorted(dict(setting.choices).values()) == ["Off", "On"]:
                # A switch is described the same way here as on its Settings page, whichever way it is set.
                lines.append(setting.help)
                continue
            hint = card.get("hints", {}).get(key, {}).get(str(values[key]))
            if hint and key == "bSnapTurn" and str(values[key]) == "True":
                hint = hint.replace("30°", f"{values.get('SnapTurnDegrees', '30')}°")
            if hint:
                lines.append(hint)
        return " ".join(lines)

    def choose_card_preset(self, card_id, preset, name):
        self.setup_touched.add(card_id)
        if preset == "graphics_preset":
            return self.apply_preset(preset, name)
        edits = model.preset_targets(preset)[name]
        if preset == "reload_mode" and not edits.get("bInteractiveReloads"):
            # A Button player is not asked about ammo rules and keeps Standard (R52).
            edits = dict(edits, **model.preset_targets("ammo_rules")[model.preset_recommended("ammo_rules")])
            self.setup_touched.discard("ammo_rules")
        return self.persist(self.with_mirroring(edits))

    def choose_card_setting(self, card_id, key, value):
        self.setup_touched.add(card_id)
        return self.persist(self.with_mirroring({key: value}))

    def unanswered_differing(self):
        """Cards not answered on this visit whose current choice isn't the recommended one."""
        return [card for card in model.FIRST_TIME_SETUP["cards"]
                if card["id"] not in self.setup_touched and card["id"] not in PERSONAL_CARDS
                and model.card_applies(card, self.settings_values) and self.recommended_edits(card)]

    def use_recommended(self):
        """Recommended choices for the cards not answered yet; answered cards are never changed."""
        edits, graphics = {}, None
        for card in self.unanswered_differing():
            if "preset" not in card:
                edits.update(self.recommended_edits(card))
            elif card["preset"] == "graphics_preset":
                graphics = model.preset_recommended("graphics_preset")
            else:
                edits.update(model.preset_targets(card["preset"])[model.preset_recommended(card["preset"])])
                if card["preset"] == "reload_mode" and "ammo_rules" not in self.setup_touched:
                    edits.update(model.preset_targets("ammo_rules")[model.preset_recommended("ammo_rules")])
        if edits:
            saved, problem = self.persist(self.with_mirroring(edits))
            if not saved:
                return saved, problem
        if graphics is not None:
            return self.apply_preset("graphics_preset", graphics)
        return True, None

    def complete_setup(self):
        self.setup_touched = set()
        if self.onboarding:
            self.finish_onboarding()
        else:
            model.complete_first_time_setup()

    # ----- launching ------------------------------------------------------------
    def session_running(self):
        """This window's session, or another KF2-VR session on this PC.

        friends.py holds the session mutex, but builds and dev fixtures share it,
        so a held (or access-denied, when elevated) mutex counts only while
        Killing Floor 2 itself is running.
        """
        if self.session is not None and self.session.running():
            return True
        return self.cached(("session",), 2, self._other_session_running)

    @staticmethod
    def _other_session_running():
        try:
            kernel = ctypes.windll.kernel32
            handle = kernel.OpenMutexW(0x00100000, False, "Local\\KF2VR_DevelopmentFixture")
            held = bool(handle) or kernel.GetLastError() == 5  # ERROR_ACCESS_DENIED
            if handle:
                kernel.CloseHandle(handle)
        except (AttributeError, OSError):
            return False
        if not held:
            return False
        try:
            listing = subprocess.run(["tasklist", "/FI", "IMAGENAME eq KFGame.exe", "/NH"], capture_output=True,
                                     text=True, timeout=5, creationflags=NO_WINDOW).stdout
        except (OSError, subprocess.SubprocessError):
            return True
        return "KFGame.exe" in listing

    def allow_workspace_launch(self, ask, alert):
        """A checkout launches only its selected, current package (or an older one the player accepts)."""
        if not self.context.workspace:
            return True
        from release_state import selected_release, verify_workspace
        try:
            package, manifest = selected_release(self.context.workspace)
            if package != ROOT.resolve():
                raise RuntimeError("The selected package changed while this window was open. Reopen Play-KF2VR.cmd.")
        except Exception as error:
            alert("Selected package changed", str(error))
            return False
        try:
            verify_workspace(self.context.workspace, manifest)
        except RuntimeError as error:
            if not self.context.allow_stale and not ask("Play this older build?",
                    "The selected package is older than the current source. Its files are intact.",
                    yes="Play older build", detail=str(error)):
                return False
        return True

    def override_arguments(self):
        """Command-line graphics choices this window was opened with, unless changed on the Settings page."""
        initial, result = list(self.context.initial_arguments), []
        for key in sorted(self.kept_overrides):
            option = settings_registry.option(key)
            for index, token in enumerate(initial):
                if option.kind == "toggle" and token in (option.flag, "--no-" + option.flag[2:]):
                    result.append(token)
                elif option.kind != "toggle" and token == option.flag and index + 1 < len(initial):
                    result += [token, initial[index + 1]]
        return result

    def launch(self, arguments, title):
        """Start friends.py with the window's own choices added; returns its SessionTracker."""
        arguments = self.override_arguments() + contextual_arguments(arguments, self.saved, self.context)
        arguments += ["--store", self.store]
        arguments.append("--record-motion" if self.vr and self.record_motion else "--no-record-motion")
        arguments.append("--promo-events" if self.vr and self.highlight_events else "--no-promo-events")
        if self.vr and self.frame_timings:
            arguments.append("--frame-timings")
        LOGS.mkdir(parents=True, exist_ok=True)
        stamp = f"{datetime.now():%Y%m%d-%H%M%S}"
        log = LOGS / f"launcher-{stamp}.txt"
        events_path = LOGS / f"launcher-{stamp}.events.jsonl"
        events_path.write_text("", encoding="utf-8")
        arguments += ["--events", str(events_path)]
        environment = dict(os.environ, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
        with log.open("wb") as output:
            process = subprocess.Popen([str(PYTHON), "-u", str(HERE / "friends.py"), *arguments],
                cwd=ROOT, env=environment, stdin=subprocess.DEVNULL, stdout=output,
                stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
        kind = ("epic" if self.store == "epic" else "solo" if "--solo" in arguments
                else "host" if "--host" in arguments else "join")
        self.session = SessionTracker(process, log, events_path, kind, title)
        self.forget("session")
        return self.session

    # ----- troubleshooting ----------------------------------------------------
    def send_logs(self, destination):
        """Gather a scrubbed log ZIP into the folder the player chose, copy it and show it; (title, text, detail, kind)."""
        from diagnostics import collect_logs
        try:
            target = collect_logs(ROOT, Path(destination))
        except Exception as error:
            return "Couldn't gather logs", str(error), None, "error"
        try:
            copied = subprocess.run(["powershell.exe", "-NoProfile", "-Command", "Set-Clipboard -LiteralPath $env:KF2VR_LOGS"],
                                    env=dict(os.environ, KF2VR_LOGS=str(target)), creationflags=NO_WINDOW,
                                    timeout=30).returncode == 0
        except (OSError, subprocess.SubprocessError):
            copied = False
        try:
            subprocess.Popen(["explorer.exe", "/select,", str(target)])
        except OSError:
            pass
        text = (f"Your logs are copied. {REPORT_WHERE}: click in the message box, press Ctrl+V, and say what you "
                "were doing when it went wrong." if copied else
                f"{REPORT_WHERE}: drag the highlighted file into your report and say what you were doing.")
        detail = (f"Saved as {target}; its folder just opened with the file selected. Personal paths, names, account IDs and "
                  "addresses are anonymized, and passwords and join codes are removed. Review the ZIP before sharing it.")
        return "Logs ready", text, detail, "info"

    def recover(self):
        """Put Killing Floor 2 back to normal; returns (title, text, detail, kind)."""
        import contextlib
        import io
        from recovery import recover_all
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                recover_all(ROOT)
        except Exception as error:
            return "Couldn't fix it yet", friendly(str(error)), None, "error"
        problems = [line for line in output.getvalue().splitlines() if "restored / already clean" not in line]
        if problems:
            return "Partly fixed", f"Some things couldn't be fixed automatically. Press {REPORT_BUTTON}.", \
                "\n".join(problems[:6]), "warn"
        return "All fixed", "Killing Floor 2 is back to normal.", None, "info"

