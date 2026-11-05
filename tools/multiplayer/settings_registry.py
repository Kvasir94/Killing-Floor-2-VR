"""Every launcher option, defined once.

The packaged command line (friends.py), the saved-preference defaults
(workshop_loadout.py) and the repository launcher's -Help all read this table,
so a flag, its shipped default and its description cannot drift apart.

store:      where a chosen value is remembered -- "launcher" (Profile/launcher.json),
            "vr-ini" (the in-headset preferences in Profile/KFGame.ini), "machine"
            (this PC's Profile/machine.json, which survives new releases) or None
            (this launch only).
stability:  "stable", "experimental", "developer" (testing tools; not player
            facing) or "hidden" (a compatibility alias left out of help).
ps:         the Play-KF2VR.cmd switch, or None when only the packaged CLI has it.
            Options with no flag exist only in the repository launcher.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys

CATEGORIES = ("Session", "Match", "Hosting", "Graphics", "Content", "Installation", "Developer")


@dataclass(frozen=True)
class Option:
    dest: str
    kind: str  # switch | toggle | choice | int | text | path | list
    category: str
    help: str
    flag: str | None = None
    ps: str | None = None
    choices: tuple = ()
    ps_values: tuple = ()
    lower: bool = False
    default: object = None
    minimum: int | None = None
    maximum: int | None = None
    store: str | None = None
    modes: str = ""
    stability: str = "stable"
    metavar: str | None = None

    @property
    def remembered(self):
        return self.store is not None


def _option(dest, kind, category, help, **fields):
    flag = fields.pop("flag", "--" + dest.replace("_", "-"))
    return Option(dest, kind, category, help, flag=flag, **fields)


def _shell(ps, category, help, **fields):
    """A Play-KF2VR.cmd switch that the packaged launcher does not take."""
    return Option(ps.lower(), "switch", category, help, flag=None, ps=ps, **fields)


DIFFICULTIES = ("normal", "hard", "suicidal", "hellonearth")
GAME_LENGTHS = ("short", "medium", "long")
VR_QUALITIES = ("quality", "balanced", "performance")
# Index order is the saved RequestedDlssMode; "auto" was appended so older
# profiles keep their meaning.
DLSS_MODES = ("off", "dlaa", "quality", "balanced", "performance", "ultraperformance", "auto")
FLEX_MODES = ("off", "gibs", "fluids")
STORES = ("auto", "steam", "epic")
HEADSET_PRESETS = ("quest2", "quest3", "quest3s", "index", "high-resolution")
DEFAULT_SERVER_NAME = "KF2-VR Server"

# Packaged CLI order; friends.py --help lists options in this order.
OPTIONS = (
    _option("host", "switch", "Session", "Host a dedicated server on this PC and join it", default=False),
    _option("solo", "switch", "Session", "True single-player match on this PC: no dedicated server, network or replication",
            ps="Solo", default=False),
    _option("menu", "switch", "Session", "Review the match selections in a text menu before launching; requires --host or --solo",
            ps="Menu", default=False),
    _option("map", "text", "Match", "Installed KF- map name; requires --host or --solo",
            ps="Map", default="KF-BurningParis", store="launcher"),
    _option("difficulty", "choice", "Match", "Match difficulty; requires --host or --solo",
            ps="Difficulty", choices=DIFFICULTIES, ps_values=("Normal", "Hard", "Suicidal", "HellOnEarth"),
            lower=True, default="normal", store="launcher"),
    _option("game_length", "choice", "Match", "Short 4, medium 7 or long 10 waves, then the boss; requires --host or --solo",
            ps="GameLength", choices=GAME_LENGTHS, ps_values=("Short", "Medium", "Long"),
            lower=True, default="medium", store="launcher"),
    _option("max_zeds", "int", "Match", "Most zeds alive at once, 1-128; 0 keeps stock (10-32 by difficulty and players). "
            "Applied through the Unofficial KF2 Patch's settings, which this turns on (Solo needs it installed); "
            "requires --host or --solo",
            ps="MaxZeds", minimum=0, maximum=128, default=0, store="launcher"),
    _option("wave_zeds_percent", "int", "Match", "Zeds per wave as a percent of stock's own total, which already scales with "
            "wave, players and difficulty; 100 is stock; requires --host or --solo",
            ps="WaveZedsPercent", minimum=10, maximum=500, default=100, store="launcher"),
    _option("spawn_rate_percent", "int", "Match", "How often zed squads spawn, in percent; 100 is stock, 200 twice as often; "
            "requires --host or --solo",
            ps="SpawnRatePercent", minimum=25, maximum=500, default=100, store="launcher"),
    _option("test_map", "switch", "Match", "Remilly test map: --host, or explicit --solo --store steam using the verified existing cache only",
            ps="TestMap", default=False),
    _option("test_mode", "switch", "Match", "UNRANKED test mode: change perk at any time, even mid-wave; each switch "
            "replaces the inventory with every weapon of that perk. The server applies it; this launch only",
            ps="TestMode", default=False, stability="developer"),
    _option("vr", "switch", "Session", "Play in the headset this session; without --vr or --desktop Host/Solo use the saved play mode",
            ps="Vr", default=True, store="launcher"),
    _option("desktop", "switch", "Session", "Play on the flat screen this session; without --vr or --desktop Host/Solo use the saved play mode",
            ps="Desktop", default=False),
    _option("mods", "list", "Content", "Comma-separated ukfp,friendlyhud,yas,aal,cvc,lti, 'legacy' for all, or 'none'",
            ps="Mods", default=(), store="launcher", modes="Host"),
    _option("damage_popups", "toggle", "Content", "Allow Unofficial Patch damage popups in Desktop sessions; VR always hides the flat overlay",
            ps="DamagePopups", default=True, store="launcher", modes="Host"),
    _option("inventory_focus", "toggle", "Content", "Shared slowdown while a VR player holds the weapon selector",
            ps="InventoryFocus", default=False, store="launcher", modes="Host", stability="hidden"),
    _option("test_map_players", "int", "Content", "Remilly Unofficial Patch scaling: 0 actual players, 6 faked players",
            ps="TestMapPlayers", choices=(0, 6), default=6, store="launcher", modes="Host"),
    _option("headset_preset", "choice", "Graphics", "Sets the graphics preset and render scale for a headset model; both are "
            "saved like any other choice, and an explicit quality or scale wins",
            ps="HeadsetPreset", choices=HEADSET_PRESETS, modes="VR", stability="hidden"),
    _option("vr_quality", "choice", "Graphics", "Headset graphics preset",
            ps="VrQuality", choices=VR_QUALITIES, default="quality", store="launcher", modes="VR"),
    _option("eye_render_percent", "int", "Graphics", "Headset render scale per eye, in percent; also in the headset under VR SETTINGS > GRAPHICS",
            ps="EyeRenderPercent", minimum=50, maximum=100, default=100, store="vr-ini", modes="VR"),
    _option("frame_timings", "switch", "Developer", "Log CPU stage and GPU frame times to native.log every 5 s (low overhead)",
            ps="FrameTimings", default=False, modes="VR", stability="developer"),
    _option("promo_events", "toggle", "Developer", "Log highlight hit/kill events and F9 video sync marks",
            ps="HighlightEvents", default=False, modes="live VR", stability="developer"),
    _option("record_motion", "toggle", "Developer", "Record player headset, controllers, input and presentation locally",
            ps="RecordMotion", default=False, modes="live VR", stability="developer"),
    _option("flex", "choice", "Graphics", "NVIDIA FleX gore: off, gibs, or gibs and fluids",
            ps="Flex", choices=FLEX_MODES, ps_values=("Off", "Gibs", "Fluids"), default="off", store="launcher", stability="hidden"),
    _option("dlss", "choice", "Graphics", "NVIDIA DLSS for the headset image; needs a DLSS-enabled package",
            ps="Dlss", choices=DLSS_MODES, default="auto", store="launcher", modes="VR"),
    _option("hide_bile_lens", "toggle", "Graphics", "Skip the Bloat bile screen splatter particles, a large GPU cost",
            default=True, store="launcher", modes="VR"),
    _option("hide_blood_lens", "toggle", "Graphics", "Skip the on-screen blood splatter when hit; the red damage tint stays",
            ps="HideBloodLens", default=True, store="launcher", modes="VR"),
    _option("dlss_sharpness", "int", "Graphics", "Sharpening after DLSS, 0 (off) to 100",
            ps="DlssSharpness", minimum=0, maximum=100, default=50, store="launcher", modes="VR"),
    _option("hbao", "toggle", "Graphics", "HBAO+ ambient occlusion",
            ps="Hbao", default=True, store="launcher", modes="VR"),
    _option("reflections", "toggle", "Graphics", "Screen-space reflections",
            ps="Reflections", default=True, store="launcher", modes="VR"),
    # No render-mode options: VR always uses the separate render thread and,
    # single-pass stereo, on Steam and Epic (Kvasir94, 11-05, #200). See friends.py.
    _option("server_name", "text", "Hosting", "Name shown in the server browser",
            default=DEFAULT_SERVER_NAME, store="machine", modes="Host"),
    _option("open_server", "toggle", "Hosting", "Host without a server password: anyone who reaches the server can join",
            default=False, store="launcher", modes="Host"),
    _option("workshop_desktop", "toggle", "Hosting", "Desktop players with plain KF2 download the mod from its Steam Workshop "
            "item when they join; requires exactly matching published packages",
            default=True, store="launcher", modes="Host"),
    _option("zed_grabs", "toggle", "Hosting", "Zed grabs: VR players can grab and throw Zeds on this server",
            ps="ZedGrabs", default=True, store="launcher", modes="Host"),
    _option("gravity_grab", "toggle", "Hosting", "Gravity grab: VR players can pull guns, magazines and pickups to the hand on this server",
            ps="GravityGrab", default=True, store="launcher", modes="Host"),
    _option("replay_teammate", "switch", "Developer", "Host a visual test with one separate native controller replay client",
            default=False, stability="developer"),
    _option("replay_match", "switch", "Developer", "Keep normal enemy waves in the replay test (default: quiet inspection)",
            default=False, stability="developer"),
    _option("avatar_preview", "switch", "Developer", "Host a quiet solo rig preview with a separate recorded-pose teammate; add --vr for a headset",
            default=False, stability="developer"),
    _option("locomotion_preview", "switch", "Developer", "Desktop camera on a real remote pawn cycling idle, roomscale and stick walking; no headset needed",
            ps="LocomotionPreview", default=False, stability="developer"),
    _option("address", "text", "Session", "Join: host address or the complete KF2VR1 join code (the code supplies connection settings)"),
    _option("share_address", "text", "Hosting", "Address placed in the join code; defaults to the public IP reported by the server",
            modes="Host"),
    _option("password", "text", "Session", "Join: server password. Host: server password, remembered on this PC",
            store="machine"),
    _option("game_root", "path", "Installation", "Killing Floor 2 installation folder",
            ps="GameRoot", store="machine"),
    _option("store", "choice", "Installation", "Game store; Auto uses the only installation or the last folder used",
            ps="Store", choices=STORES, ps_values=("Auto", "Steam", "Epic"), default="auto"),
    _option("recover_epic", "switch", "Installation", "Restore a verified owned Epic deployment after KF2 exits", default=False),
    _option("server_root", "path", "Installation", "Dedicated server folder"),
    _option("cache_root", "path", "Installation", "Workshop download cache"),
    _option("port", "int", "Hosting", "Game port", minimum=1, maximum=65535, default=7777, modes="Host"),
    _option("query_port", "int", "Hosting", "Steam query port", minimum=1024, maximum=65000, default=27015, modes="Host"),
    _option("prepare_only", "switch", "Developer", "Verify package, source and configuration; start no game processes",
            ps="PrepareOnly", default=False, stability="developer"),
    _option("duration", "int", "Developer", "Bounded developer launch in seconds; ordinary play has no limit",
            minimum=5, maximum=7200, stability="developer"),
    _option("local_test_control", "switch", "Developer", "UNRANKED local agent control and test capacity bypass",
            ps="LocalTestControl", default=False, modes="Solo VR", stability="developer"),
    _option("local_test_diagnostic", "switch", "Developer", "Explicit Solo live-XR diagnostic: neutral physical input, F10 abort, fixed Deadbolt and Ripcord cases",
            default=False, modes="Solo VR", stability="developer"),
    _option("events", "path", "Developer", "Write structured progress events (JSON lines) for the player window",
            stability="hidden"),
    # Repository launcher only.
    _shell("Gui", "Session", "Open the player window to review or change the choices first (the default with no arguments)"),
    _shell("DevGui", "Session", "Compatibility alias for -Gui", stability="hidden"),
    _shell("PromoEvents", "Developer", "Shortcut for -HighlightEvents On", stability="developer"),
    _shell("AllowStale", "Developer", "Play the selected build despite source changes; package integrity is still checked",
           stability="developer"),
    _shell("Help", "Session", "Show this list"),
)

BY_DEST = {option.dest: option for option in OPTIONS}

POWERSHELL_NOTES = """\
Double-click with no arguments opens the player window. Every remembered choice
starts from the last one used. Explicit arguments launch directly; add -Gui for
the window, or -Menu for the text menu in this console, to review them first.
Without -Solo the launcher hosts a dedicated server on this PC and joins it.
Epic currently supports experimental Solo VR only: -Store Epic -Solo -Vr, then
paste the generated session line into Epic Launch Options and click Launch there.
Full reference, join commands and test handoff: PLAY-MULTIPLAYER.md"""


def option(dest):
    return BY_DEST[dest]


def default(dest):
    value = BY_DEST[dest].default
    return list(value) if isinstance(value, tuple) else value


def _value_text(option, value):
    if isinstance(value, bool):
        return "on" if value else "off"
    if isinstance(value, (tuple, list)):
        return ",".join(value) or "none"
    if option.ps_values and value in option.choices:
        return option.ps_values[option.choices.index(value)]
    return str(value)


def facts(option):
    """Generated suffix: persistence, shipped default and modes."""
    parts = []
    if option.stability == "experimental":
        parts.append("experimental")
    if option.remembered:
        parts.append("saved")
    elif option.dest == "headset_preset":
        parts.append("its results are saved")
    elif option.kind != "switch" or option.default:
        parts.append("this launch only")
    if option.default is not None and not (option.kind == "switch" and option.default is False):
        parts.append(("initially " if option.remembered else "default ") + _value_text(option, option.default))
    if option.modes:
        parts.append(option.modes)
    return "; ".join(parts)


def described(option):
    suffix = facts(option)
    return option.help + (f" ({suffix})" if suffix else "")


def _bounded(option):
    def parse(value):
        number = int(value)
        if not option.minimum <= number <= option.maximum:
            raise argparse.ArgumentTypeError(f"must be an integer from {option.minimum} to {option.maximum}")
        return number
    parse.__name__ = "integer"
    return parse


def add_arguments(parser, *, types=None, defaults=None, only=None):
    """Add registry options to an argparse parser.

    types: dest -> converter for options whose parsing lives with its data
    (mods, eye render percent). defaults: dest -> runtime default (paths
    beside the extracted release). Remembered options default to None so the
    profile can tell an explicit choice from an omitted one.
    """
    types, defaults = types or {}, defaults or {}
    for option in OPTIONS:
        if option.flag is None or (only is not None and option.dest not in only):
            continue
        keywords = {"dest": option.dest,
                    "help": argparse.SUPPRESS if option.stability == "hidden" else described(option)}
        if option.metavar:
            keywords["metavar"] = option.metavar
        unset = None if option.remembered else option.default
        if option.kind == "switch":
            keywords.update(action="store_true", default=bool(option.default) if not option.remembered else False)
        elif option.kind == "toggle":
            keywords.update(action=argparse.BooleanOptionalAction, default=unset)
        else:
            keywords["default"] = defaults.get(option.dest, None if option.kind in ("list",) else unset)
            if option.kind == "choice":
                keywords["choices"] = option.choices
                if option.lower:
                    keywords["type"] = str.lower
            elif option.kind == "int":
                keywords["type"] = _bounded(option) if option.minimum is not None else int
                if option.choices:
                    keywords["choices"] = option.choices
            elif option.kind == "path":
                keywords["type"] = Path
            if option.dest in types:
                keywords["type"] = types[option.dest]
        parser.add_argument(option.flag, **keywords)
    return parser


def powershell_help():
    lines = ["Play-KF2VR.cmd [switches]", "", POWERSHELL_NOTES]
    for category in CATEGORIES:
        rows = [o for o in OPTIONS if o.ps and o.category == category and o.stability != "hidden"]
        if not rows:
            continue
        lines += ["", category.upper()]
        for option in rows:
            if option.kind == "toggle":
                syntax = f"-{option.ps} On|Off"
            elif option.kind == "choice":
                syntax = f"-{option.ps} " + "|".join(option.ps_values or option.choices)
            elif option.kind == "int" and option.choices:
                syntax = f"-{option.ps} " + "|".join(map(str, option.choices))
            elif option.kind == "int":
                syntax = f"-{option.ps} {option.minimum}..{option.maximum}"
            elif option.kind in ("text", "path", "list"):
                syntax = f"-{option.ps} <{option.dest.replace('_', '-')}>"
            else:
                syntax = f"-{option.ps}"
            lines.append(f"  {syntax}")
            lines.append(f"      {described(option)}")
    return "\n".join(lines)


def markdown_reference():
    """docs/LAUNCHER_SWITCHES.md: every visible option, generated from this table."""
    rows = ["# Launcher switches", "",
            "Generated by `python tools/multiplayer/settings_registry.py --markdown > docs/LAUNCHER_SWITCHES.md`;",
            "edit `tools/multiplayer/settings_registry.py`, not this file. Constraints, examples and",
            "behaviour notes are in [PLAY-MULTIPLAYER.md](../PLAY-MULTIPLAYER.md#main-launcher-switches).", ""]
    for category in CATEGORIES:
        options = [o for o in OPTIONS if o.category == category and o.stability != "hidden"]
        if not options:
            continue
        rows += [f"## {category}", "", "| Play-KF2VR.cmd | Packaged CLI | Saved | Default | Applies to | Description |",
                 "| --- | --- | --- | --- | --- | --- |"]
        for option in options:
            ps = f"`-{option.ps}`" if option.ps else ""
            flag = f"`{option.flag}`" if option.flag else ""
            saved = {"launcher": "launcher.json", "vr-ini": "headset profile", "machine": "machine.json"}.get(option.store, "")
            default = _value_text(option, option.default) if option.default is not None and not (
                option.kind == "switch" and option.default is False) else ""
            notes = option.help + (" *(experimental)*" if option.stability == "experimental" else "") + (
                " *(developer)*" if option.stability == "developer" else "")
            rows.append(f"| {ps} | {flag} | {saved} | {default} | {option.modes} | {notes.replace('|', '/')} |")
        rows.append("")
    return "\n".join(rows)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Print the launcher option reference")
    parser.add_argument("--powershell-help", action="store_true", help="Play-KF2VR.cmd -Help text")
    parser.add_argument("--markdown", action="store_true", help="docs/LAUNCHER_SWITCHES.md")
    args = parser.parse_args(argv)
    if args.powershell_help:
        print(powershell_help())
        return 0
    if args.markdown:
        print(markdown_reference())
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
