"""Shared player settings metadata, preset ownership and profile serialization.

Every setting, preset and page row comes from tools/settings-definition.json,
the one list the launcher, its tests and the headset menus agree on. VR
preferences go through vr_config; visual detail uses vr_graphics' allowlist;
stock profile projections queue edits for the original game's callbacks.
Old labels stay searchable as aliases.
"""
from dataclasses import dataclass
import json
import math
import re
from pathlib import Path

import settings_registry
import settings_graphics

DEFINITION_PATH = Path(__file__).resolve().parents[1] / "settings-definition.json"
DEFINITION = json.loads(DEFINITION_PATH.read_text(encoding="utf-8"))
# Where things are in the in-game VR menu, from one table (VRSessionUI's pages): the menu's name and
# each page's path. Definition text says {menu} and {path:Category/Group}, filled in here once.
VR_MENU = DEFINITION["vr_menu"]["name"]
MENU_PATHS = DEFINITION["vr_menu"]["paths"]


def menu_path(category, group=""):
    """ "Settings › Hands & Weapons › Customize › Aim & bullet path": a page's path in the in-game VR menu."""
    page = MENU_PATHS.get(category, "Settings › " + category)
    if not group:
        return page
    return MENU_PATHS.get(f"{category}/{group}", f"{page} › Customize › {group}")


def _fill(value):
    if isinstance(value, str):
        return re.sub(r"\{path:([^/}]+)(?:/([^}]+))?\}", lambda m: menu_path(m.group(1), m.group(2) or ""),
                      value.replace("{menu}", VR_MENU))
    if isinstance(value, list):
        return [_fill(item) for item in value]
    if isinstance(value, dict):
        return {key: _fill(item) if key != "vr_menu" else item for key, item in value.items()}
    return value


DEFINITION = _fill(DEFINITION)
CATEGORIES = {category["id"]: category for category in DEFINITION["categories"]}
TABS = tuple(CATEGORIES)
HANDS, SESSION = "KF2VR.VRHandsBridge", "KF2VR.VRSessionUI"
ASSIST = "KF2VR.VRWeaponAssistSettings"
FOCUS = "KF2VR.VRInventoryFocus"
SECTIONS = {"hands": HANDS, "session": SESSION, "assist": ASSIST, "focus": FOCUS, "audio": "KF2VR.VRPlayerAudio", "stock": "KF2VR.VRStockPreferences"}
SERVER_NOTE = DEFINITION["server_governed_note"]
GROUP_NOTES = DEFINITION["group_notes"]
FIRST_TIME_SETUP = DEFINITION["first_time_setup"]


@dataclass(frozen=True)
class Setting:
    key: str
    tab: str  # the definition's category
    group: str
    label: str
    help: str
    store: str  # launcher | hands | session | assist | focus | audio | stock | graphics
    kind: str = "toggle"  # toggle | choice | number
    choices: tuple = ()  # ((stored value, label), ...) for choice
    invert: bool = False  # toggle shown ON when the stored flag is False
    experimental: bool = False
    # Applies only while each (key, allowed values) holds; otherwise greyed with requires_reason.
    requires: tuple = ()
    requires_reason: str = ""
    minimum: float = 0
    maximum: float = 100
    increment: float = 1
    display_scale: float = 1
    unit: str = ""
    depth: str = "everyday"  # everyday | customize | setup
    owner: str = "player"  # preset id whose label a hand edit turns CUSTOM
    applies: str = "live"  # live | next_launch | launch_only
    server_governed: bool = False
    calibration: bool = False
    # Better set or calibrated in the headset (Kvasir94, 11-04): kept for saving,
    # import and resets, never shown in the launcher.
    headset_only: bool = False
    aliases: str = ""
    integer: bool = False
    # A short line for the selected option of a choice.
    choice_help: tuple = ()
    # Short forms of the options, for the one muted line naming the options not picked.
    choice_short: tuple = ()
    # Where a setting the launcher leaves out is changed: the in-game VR menu or the game's own Options.
    where: str = "headset"
    # Its VR menu page as "Category/Group" when that isn't its own category and group.
    menu: str = ""
    # The launcher tab it shows on, when not its category's (Movement hand sits under Dominant hand).
    launcher_tab: str = ""


def _on_off(value):
    return "True" if value else "False"


def _setting(entry):
    return Setting(
        key=entry["key"], tab=entry["category"], group=entry.get("group", ""), label=entry["label"], help=entry["help"],
        store=entry["store"], kind=entry.get("kind", "toggle"), choices=tuple(tuple(choice) for choice in entry.get("choices", ())),
        invert=entry.get("invert", False), experimental=entry.get("experimental", False),
        requires=tuple((key, tuple(allowed)) for key, allowed in entry.get("requires", ())),
        requires_reason=entry.get("requires_reason", ""), minimum=entry.get("min", 0), maximum=entry.get("max", 100),
        increment=entry.get("step", 1), display_scale=entry.get("scale", 1), unit=entry.get("unit", ""),
        depth=entry["depth"], owner=entry.get("owner", "player"), applies=entry.get("applies", "live"),
        server_governed=entry.get("server_governed", False),
        calibration=entry.get("calibration", False), aliases=" / ".join(entry.get("aliases", ())), integer=entry.get("integer", False),
        headset_only=entry.get("headset_only", False), choice_help=tuple(entry.get("choice_help", {}).items()),
        choice_short=tuple(entry.get("choice_short", {}).items()),
        where=entry.get("where", "headset"), menu=entry.get("menu", ""), launcher_tab=entry.get("launcher_tab", ""))


# Rows that are not saved values: style rows (presets), headset-only actions and launcher actions.
ROW_KINDS = ("preset", "headset", "action")
SETTINGS = tuple(_setting(entry) for entry in DEFINITION["settings"] if entry.get("kind") not in ROW_KINDS)
PAGE_ROWS = tuple(entry for entry in DEFINITION["settings"] if not entry.get("headset_only"))
BY_KEY = {setting.key: setting for setting in SETTINGS}


# Presets own only the keys their options set; labels are derived from values, never stale IDs.
PRESET_DEFS = DEFINITION["presets"]


def preset_targets(preset):
    """{option label: values it sets}. A graphics option also sets its settings_graphics tier."""
    result = {}
    for option in PRESET_DEFS[preset]["options"]:
        values = dict(settings_graphics.TIERS[option["tier"]]) if option.get("tier") else {}
        values.update(option["values"])
        result[option["label"]] = values
    return result


def preset_option(preset, field, value):
    """The option whose field (id, label, number) equals value."""
    return next(option for option in PRESET_DEFS[preset]["options"] if option.get(field) == value)


def preset_recommended(preset):
    if preset == "graphics_preset":
        return graphics_recommendation()[0]
    return preset_option(preset, "id", PRESET_DEFS[preset]["recommended"])["label"]


GPU_TIERS = ("Performance", "Balanced", "Quality")


def gpu_tier(name):
    """The graphics option a graphics card can run in VR (KF2 at headset resolution), or None when unknown."""
    text = name.lower()
    match = re.search(r"rtx\s*a?(\d{4})", text)
    if match:
        number = int(match.group(1))
        return "Quality" if number % 100 >= 70 and number >= 3000 else "Balanced"
    match = re.search(r"\brx\s*(\d{4})", text)
    if match:
        number = int(match.group(1))
        if number >= 6800 and number % 1000 >= 800 or number >= 9000:
            return "Quality"
        return "Balanced" if number >= 6600 and number % 1000 >= 600 else "Performance"
    match = re.search(r"gtx\s*(\d{3,4})", text)
    if match:
        return "Balanced" if int(match.group(1)) in (1070, 1080) else "Performance"
    if re.search(r"\barc\S*\s*[ab]\d{3}", text):
        return "Balanced"
    if re.search(r"intel|radeon\(tm\) graphics|vega", text):
        return "Performance"
    return None


_GRAPHICS_RECOMMENDATION = []


def graphics_recommendation():
    """(option, the graphics card it was picked for or None): the best card this PC has decides; with none
    recognised, Balanced (never a claim about a PC we couldn't read)."""
    if not _GRAPHICS_RECOMMENDATION:
        try:
            import diagnostics
            cards = [re.sub(r" driver [0-9.]+$", "", name) for name in diagnostics.hardware_context()["gpus"]]
        except Exception:
            cards = []
        rated = [(GPU_TIERS.index(tier), card) for card in cards if (tier := gpu_tier(card))]
        _GRAPHICS_RECOMMENDATION.append((GPU_TIERS[max(rated)[0]], max(rated)[1]) if rated else ("Balanced", None))
    return _GRAPHICS_RECOMMENDATION[0]


LOCOMOTION_PRESETS = preset_targets("locomotion")
# Reload mode (PHYSICAL_RELOAD_SPEC R41-R51): Button / Manual / Realistic, saved as
# ReloadPreset 0/1/2 (ids CLASSIC/INTERACTIVE/ADVANCED). Button leaves empty trigger
# and the two magazine options alone; hints, sprint and perk assist stay the player's.
# Ammo rules (R44, R52) is its own preset; neither sets the other.
RELOAD_PRESETS = preset_targets("reload_mode")
AMMO_PRESETS = preset_targets("ammo_rules")


def _same(left, right):
    return str(left).lower() == str(right).lower()


def preset_name(preset, values):
    """The option every one of whose values holds, else "Custom" (R51).

    This is the headset's rule: VRSessionUI.ReloadMatches (Button = RELOAD BY HAND
    and RACK A LOADED GUN off; Manual/Realistic = all five values), AmmoPresetIndex
    (all three rules off or on) and GripPresetIndex.
    """
    return next((name for name, target in preset_targets(preset).items()
                 if all(_same(values.get(key), value) for key, value in target.items())), "Custom")


def ammo_preset_name(values):
    return preset_name("ammo_rules", values)


def preset_basis(preset, values):
    """The option a CUSTOM style is based on: the one with the largest share of its values still holding."""
    targets = preset_targets(preset)
    current = preset_name(preset, values)
    if current != "Custom":
        return current
    score = lambda name: sum(_same(values.get(k), v) for k, v in targets[name].items()) / len(targets[name])
    return max(targets, key=score)


def preset_changes(preset, name, values):
    """{key: new value} for the values choosing this option would change."""
    return {key: value for key, value in preset_targets(preset)[name].items()
            if key in values and not _same(values[key], value)}


def changed_from_style(setting, values, default_values):
    """Whether a value differs from its style's option (preset-owned) or from the default."""
    if setting.key not in values:
        return False
    target = None
    if setting.owner in PRESET_DEFS:
        target = preset_targets(setting.owner)[preset_basis(setting.owner, values)].get(setting.key)
    if target is None:
        target = default_values.get(setting.key)
    if target is None:
        return False
    value = values[setting.key]
    if setting.kind == "number":
        try:
            return abs(float(value) - float(target)) > 1e-6
        except (TypeError, ValueError):
            return not _same(value, target)
    return not _same(value, target)


def requirement_text(setting, values):
    """Why a row that doesn't apply is greyed, or "" while it applies."""
    if visible(setting, values):
        return ""
    return setting.requires_reason or "Not available with the current settings"


def defaults(category=None):
    result = {}
    for setting in SETTINGS:
        if setting.calibration or (category and setting.tab != category): continue
        if setting.store == "graphics":
            value = "2" if setting.key == "Bloom" else settings_graphics.TIERS["quality"].get(setting.key, settings_graphics.FIELDS.get(setting.key, (None,"0"))[1])
        elif setting.store == "launcher": value = settings_registry.default(setting.key)
        elif setting.key == "eye_render_percent": value = "100"
        elif setting.key == "AimMode": value = aim_mode({})
        else: value = _ini_default(setting)
        if setting.kind == "toggle":
            value = value if isinstance(value, bool) else str(value).lower() == "true"
            value = not value if setting.invert else value
        elif setting.kind == "choice": value = _matching_choice(setting, value)
        result[setting.key] = value
    return result




def search(query):
    """Settings whose label, old names (aliases) or group hold every word; only when none do, their help.

    A category's own name or old names never match on their own, so a search for
    "reload" finds the reload settings, not every Hands & Weapons row. Help text is a fallback, so
    "aim" finds Aim assist and Bullet path, not Locomotion ("...to where you aim").
    """
    # Words match whole words or their plain endings: "turn" finds Turning, not Auto-return.
    patterns = _word_patterns(query)
    shown = [s for s in SETTINGS if s.depth != "setup" and not s.headset_only]
    # A row's own options count as its names: "snap" finds Turning (Snap turn).
    def named(s):
        return " ".join((s.label, s.aliases, s.group, *(name for _, name in s.choices))).casefold()
    def described(s):
        return " ".join((named(s), s.help, *(line for _, line in s.choice_help))).casefold()
    found = [s for s in shown if all(p.search(named(s)) for p in patterns)]
    if found:
        return found
    return [s for s in shown if all(p.search(described(s)) for p in patterns)]


def _word_patterns(query):
    """One pattern per word: the word (or its singular, "shadows" -> "shadow"), at a word start, with an
    optional plain ending (s, es, ing, ed, er)."""
    def stem(word):
        return word[:-1] if len(word) > 3 and word.endswith("s") and not word.endswith("ss") else word
    return [re.compile(r"(?<![a-z0-9])" + re.escape(stem(word)) + r"(?:s|es|ing|ed|er|ers)?(?![a-z0-9])")
            for word in query.casefold().split()]


def search_elsewhere(query):
    """Settings the launcher leaves out that match, so search can say where they are changed."""
    patterns = _word_patterns(query)
    def text(s):
        return " ".join((s.label, s.aliases, s.group)).casefold()
    return [s for s in SETTINGS if s.headset_only and not s.calibration and all(p.search(text(s)) for p in patterns)]


def preset_search(query):
    """Preset rows whose name, old names or option names hold every word."""
    words = query.casefold().split()
    found = []
    for preset, definition in PRESET_DEFS.items():
        if definition.get("row") is False:
            continue
        text = " ".join([definition["label"], *definition.get("aliases", ()), *preset_targets(preset)]).casefold()
        if all(word in text for word in words):
            found.append(preset)
    return found


# Pitch that goes with each named aim profile; a custom calibration keeps its own axes.
AIM_PITCH = {"Relaxed": "-20.6", "Neutral": "0.0", "Quest2": "-8.6"}
# Shown, never saved: the profile's axes were changed in CALIBRATION > GLOBAL WEAPON FIT.
CUSTOM_FIT = "custom:"


def section(store):
    return SECTIONS[store]


def aim_mode(hands):
    import vr_config
    defaults = vr_config.DEFAULTS[HANDS]
    on = lambda key: str(hands.get(key, defaults.get(key, "False"))).strip().lower() == "true"
    return "sight" if on("bSightPointAim") else "converge" if on("bSightLineConvergence") else "bore"


def _ini_default(setting):
    import vr_config
    defaults = vr_config.DEFAULTS.get(section(setting.store), {})
    if "." in setting.key:
        base,member=setting.key.split(".")
        return _component(defaults.get(base,""),member)
    if setting.key in defaults:
        return defaults[setting.key]
    return "False" if setting.kind == "toggle" else setting.choices[0][0]


def _component(raw, member):
    match=re.search(r"\b"+re.escape(member)+r"\s*=\s*([-+\deE.]+)",raw,re.I)
    try: number=float(match[1]) if match else 0.0
    except ValueError: number=0.0
    return format(number if math.isfinite(number) else 0,".9g")


def _matching_choice(setting, value):
    """The stored value as one of the setting's choices (INI numbers vary in spelling).

    A value outside the list (an older or hand-edited profile) is returned as is,
    so the page shows it rather than silently replacing it.
    """
    if setting.key == "WorldDropReturnPolicy":
        return "0" if str(value)=="0" else "2"
    for stored, _ in setting.choices:
        try:
            if float(stored) == float(value):
                return stored
        except (TypeError, ValueError):
            if str(stored).lower() == str(value).lower():
                return stored
    return value


def visible(setting, values):
    """Whether a setting applies under the other current values; greyed with its reason when it doesn't."""
    return all(values.get(key) in allowed for key, allowed in setting.requires)


def number_display(setting, value):
    return format(float(value) * setting.display_scale, ".9g")


def number_value(setting, displayed):
    try:
        number = float(displayed)
    except (TypeError, ValueError):
        number = math.nan
    if not math.isfinite(number) or not setting.minimum <= number <= setting.maximum or (setting.integer and not number.is_integer()):
        raise ValueError(f"{setting.label} must be between {setting.minimum:g} and {setting.maximum:g} {setting.unit}.")
    return format(number / setting.display_scale, ".9g")


def labels(setting, current):
    """The choice labels, plus the current value when it is not one of them."""
    result = dict(setting.choices)
    if current not in result:
        if str(current).startswith(CUSTOM_FIT):
            base = dict(setting.choices).get(str(current)[len(CUSTOM_FIT):], "a profile")
            result[current] = f"Custom fit (from {base})"
        else:
            result[current] = str(current)
    return result


def load(saved, profile_root=None):
    """Current values keyed by Setting.key: bools for toggles, choice values otherwise.

    saved is the launcher's resolved preferences (friends.parse_options plus
    workshop_loadout.load_preferences), so command-line overrides show here.
    """
    import vr_config
    from launch_support import read_ini
    root = Path(profile_root) if profile_root else vr_config.profile_root()
    path = root / "KFGame.ini"
    text = vr_config.apply_preferences("", read_ini(path) if path.exists() else "")
    ini = {name: vr_config.values(text, name) for name in SECTIONS.values()}
    result = {}
    graphics = settings_graphics.values(root, getattr(saved, "vr_quality", "quality"))
    for setting in SETTINGS:
        if setting.store == "graphics":
            raw = graphics[setting.key]
            result[setting.key] = raw.lower() == "true" if setting.kind == "toggle" else raw
            continue
        if setting.store == "launcher":
            value = getattr(saved, setting.key, None)
            if value is None:
                value = settings_registry.default(setting.key)
            result[setting.key] = (_matching_choice(setting, value) if setting.kind == "choice" else format(float(value),".9g") if setting.kind == "number" else ((not bool(value)) if setting.invert else bool(value)))
            continue
        if setting.key == "AimMode":
            result[setting.key] = aim_mode(ini[HANDS])
            continue
        raw = ini[section(setting.store)].get(setting.key, _ini_default(setting))
        if "." in setting.key:
            base,member=setting.key.split(".")
            raw=_component(ini[section(setting.store)].get(base,""),member)
        if setting.key == "eye_render_percent":
            raw = ini[SESSION].get("EyeRenderPercent", "100")
            if getattr(saved, "eye_render_percent", None) is not None:
                raw = str(saved.eye_render_percent)
        if setting.kind == "toggle":
            on = str(raw).strip().lower() == "true"
            result[setting.key] = (not on) if setting.invert else on
        elif setting.kind == "number":
            result[setting.key] = format(float(raw), ".9g")
        else:
            result[setting.key] = _matching_choice(setting, raw)
        if setting.key == "AimAssistPreset" and str(raw)=="2" and ini[ASSIST].get("bCustomAimCorrectionEnabled", "True").lower()=="false":
            result[setting.key]="0"
        if setting.key == "ActiveControllerFitProfile" and result[setting.key] in AIM_PITCH:
            hands = ini[HANDS]
            try:
                fitted = (abs(float(hands.get("FirearmAimPitchDegrees", AIM_PITCH[result[setting.key]]))
                              - float(AIM_PITCH[result[setting.key]])) < 0.05
                          and abs(float(hands.get("FirearmAimYawDegrees", "0"))) < 0.05
                          and abs(float(hands.get("FirearmAimRollDegrees", "0"))) < 0.05)
            except ValueError:
                fitted = True
            if not fitted:
                result[setting.key] = CUSTOM_FIT + result[setting.key]
    return result


def save(values, profile_root=None):
    """Write changed values to their stores. values holds only what the page edited."""
    import vr_config
    import workshop_loadout
    from launch_support import read_ini, set_ini
    root = Path(profile_root) if profile_root else vr_config.profile_root()
    # Validate numeric edits before writing either preference store.
    for key, value in values.items():
        setting = BY_KEY[key]
        if setting.kind == "number":
            number_value(setting, float(value) * setting.display_scale)
    launcher = {key: (not value) if BY_KEY[key].invert else value for key, value in values.items() if BY_KEY[key].store == "launcher"}
    if "dlss_sharpness" in launcher: launcher["dlss_sharpness"]=int(float(launcher["dlss_sharpness"]))
    if launcher:
        workshop_loadout.update_preferences(launcher, root if profile_root else None)
    graphics = {key: _on_off(value) if BY_KEY[key].kind == "toggle" else value for key,value in values.items() if BY_KEY[key].store == "graphics"}
    if graphics: settings_graphics.save(graphics, root)
    ini = {name: {} for name in SECTIONS.values()}
    for key, value in values.items():
        setting = BY_KEY[key]
        if setting.store in ("launcher", "graphics"):
            continue
        if setting.kind == "toggle":
            value = _on_off((not value) if setting.invert else value)
        if key == "AimMode":
            ini[HANDS].update(bSightPointAim=_on_off(value == "sight"), bSightLineConvergence=_on_off(value == "converge"))
            continue
        if "." in key:
            continue  # Serialized together below, preserving unedited vector members.
        name = "EyeRenderPercent" if key == "eye_render_percent" else key
        ini[section(setting.store)][name] = str(value)
    if "bZedGrabEnabled" in ini[HANDS]:
        # Same stamp the headset writes: an explicit choice, not a legacy seed.
        ini[HANDS]["ZedGrabSettingsRevision"] = "1"
    if "ActiveControllerFitProfile" in ini[HANDS]:
        # Choosing a named profile replaces a custom calibration's axes with that profile's.
        ini[HANDS].update(FirearmAimPitchDegrees=AIM_PITCH[ini[HANDS]["ActiveControllerFitProfile"]],
                          FirearmAimYawDegrees="0.0", FirearmAimRollDegrees="0.0")
    if not any(ini.values()) and not any("." in key for key in values):
        return
    root.mkdir(parents=True, exist_ok=True)
    path = root / "KFGame.ini"
    text = vr_config.apply_preferences("", read_ini(path) if path.exists() else "")
    for key,value in values.items():
        if "." not in key:continue
        setting=BY_KEY[key]
        base,member=key.split(".")
        dest=ini[section(setting.store)]
        raw=dest.get(base,vr_config.values(text,section(setting.store)).get(base,""))
        members=("Pitch","Yaw","Roll") if base=="WristwatchRotation" else ("X","Y","Z")
        parts={axis:_component(raw,axis) for axis in members}
        parts[member]=str(round(float(value))) if base=="WristwatchRotation" else str(value)
        dest[base]="("+",".join(axis+"="+parts[axis] for axis in members)+")"
    if ini[ASSIST]:
        if ini[ASSIST].get("AimAssistPreset")=="2" and "bCustomAimCorrectionEnabled" not in ini[ASSIST]:
            ini[ASSIST]["bCustomAimCorrectionEnabled"]="True"
        assist = {**vr_config.values(text, ASSIST), **ini[ASSIST]}
        vr_config.normalize_aim_range(assist, ini[ASSIST])
        ini[ASSIST].update({key: assist[key] for key in
                           ("CustomAimCorrectionMinRangeMeters", "CustomAimCorrectionMaxRangeMeters")})
        ini[ASSIST]["AimAssistSettingsRevision"] = "1"
    if ini.get("KF2VR.VRPlayerAudio"):
        audio = ini["KF2VR.VRPlayerAudio"]
        pending = int(vr_config.values(text, "KF2VR.VRPlayerAudio").get("PendingMask", "0"))
        for index,key in enumerate(("Master","Effects","Dialogue","Music","VoiceChat","MusicVocals","ReducedChatter")):
            if key in audio: pending |= 1 << index
        audio["PendingMask"] = str(pending)
    if ini.get("KF2VR.VRStockPreferences"):
        stock = ini["KF2VR.VRStockPreferences"]
        pending = int(vr_config.values(text,"KF2VR.VRStockPreferences").get("PendingMask","0"))
        for index,key in enumerate(("GoreIntensity","KillTicker","BossHealthBar","FriendlyIndicatorScale","ClassicColors","HeadshotEffects","ClotGrabTurn")):
            if key in stock: pending |= 1 << index
        stock["PendingMask"] = str(pending)
    for name, changes in ini.items():
        if changes:
            text = set_ini(text, name, changes)
    _write_profile(path, text)


def _write_profile(path, text):
    import vr_config
    text = vr_config.apply_preferences(text)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(text, encoding="utf-16")
    temporary.replace(path)


def _profile_text(root):
    import vr_config
    from launch_support import read_ini
    path = root / "KFGame.ini"
    return vr_config.apply_preferences("", read_ini(path) if path.exists() else "")


def first_time_setup_pending(profile_root=None):
    """First-time setup has not been offered yet, here or in the headset (VRSessionUI.QuickSetupRevision)."""
    import vr_config
    root = Path(profile_root) if profile_root else vr_config.profile_root()
    return vr_config.values(_profile_text(root), SESSION).get("QuickSetupRevision", "0") == "0"


def complete_first_time_setup(profile_root=None):
    """Mark first-time setup offered, so the headset does not offer it again."""
    import vr_config
    from launch_support import set_ini
    root = Path(profile_root) if profile_root else vr_config.profile_root()
    root.mkdir(parents=True, exist_ok=True)
    _write_profile(root / "KFGame.ini", set_ini(_profile_text(root), SESSION, {"QuickSetupRevision": "1"}))


def choice_help(setting, value):
    """The selected option's own line, or ""."""
    return dict(setting.choice_help).get(str(value), "")


def option_lines(setting):
    """["Smooth: Walk with the stick.", ...]: what every option does, picked or not, when each has a line;
    else [] (the setting's help then says it). Never only on hover."""
    lines = dict(setting.choice_help)
    if setting.kind != "choice" or not setting.choices or not all(stored in lines for stored, _ in setting.choices):
        return []
    return [f"{name}: {lines[stored]}" for stored, name in setting.choices]


def option_summary(setting, value):
    """(the picked option's line, "Other — short · Other — short" or ""), for a choice whose every option has
    a line; else ("", ""). The second part only where option names don't explain themselves."""
    lines, shorts = dict(setting.choice_help), dict(setting.choice_short)
    if not option_lines(setting):
        return "", ""
    others = " · ".join(f"{name} — {shorts[stored]}" for stored, name in setting.choices
                        if stored != str(value) and stored in shorts)
    return lines.get(str(value), ""), others


def preset_summary(preset, values):
    """(the picked option's line, the other options' short forms or "") for a preset."""
    current = preset_name(preset, values)
    options = PRESET_DEFS[preset]["options"]
    others = " · ".join(f"{option['label']} — {option['short']}" for option in options
                        if option["label"] != current and option.get("short"))
    return preset_help(preset, current), others


def preset_option_lines(preset):
    """What every option of a preset does: ["Button: Press a button, as in the normal game.", ...]."""
    return [f"{option['label']}: {option['help']}" for option in PRESET_DEFS[preset]["options"] if option.get("help")]


def preset_help(preset, name):
    """One line on what a preset option does; for Custom, the option it is based on."""
    try:
        return preset_option(preset, "label", name).get("help", "")
    except StopIteration:
        return ""


def preset_applies(preset, values):
    """Whether a preset has any effect under the other current values (Ammo rules needs Manual reloading)."""
    return all(values.get(key) in tuple(allowed) for key, allowed in PRESET_DEFS[preset].get("requires", ()))


def card_applies(card, values):
    """First-time setup asks Ammo rules only after Manual or Realistic reloads (R52)."""
    return all(values.get(key) in tuple(allowed) for key, allowed in card.get("requires", ()))


def graphics_summary(values, vr=True):
    """One short line for the match pages: the graphics the next launch uses."""
    if not vr:
        return "Graphics: the game's own options"
    name = preset_name("graphics_preset", values)
    if name == "Custom":
        name = f"Custom (based on {preset_basis('graphics_preset', values)})"
    return f"Graphics: {name}"
