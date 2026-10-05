"""Shared playable preferences; only approved VR values cross session boundaries."""
import json
import os
from pathlib import Path
import re

DEFAULTS = json.loads((Path(__file__).resolve().parents[1] / "vr-defaults.json").read_text())
ALIASES = {"KF2VR.VRHandsBridge": "KF2VRNetClient.KF2VRNetHandsBridge",
           "KF2VR.VRSessionUI": "KF2VRNetClient.KF2VRNetSessionUI"}
POSITIVE = {"SpatialMenuDistance": (0.6, 3), "SpatialMenuScale": (0.5, 1.5),
            "SpatialMenuHeight": (-0.8, 0.5),
            "MenuHand": (0, 1), "MovementHand": (0, 1), "PreferredWeaponHand": (0, 1),
            "TopHudFollowMode": (0, 1), "TopHudDistance": (1.1, 2.5),
            "TopHudHeight": (0.12, 0.75), "TopHudScale": (0.65, 1.6),
            "TopHudYawDeadZoneDegrees": (0, 35), "TopHudPitchDeadZoneDegrees": (0, 25),
            "TopHudTranslationDeadZone": (0, 0.4), "TopHudDetailLookDegrees": (5, 30),
            "WeaponAmmoReadoutScale": (0.5, 2.0),
            "WeaponAmmoReadoutForward": (-12, 12), "WeaponAmmoReadoutHeight": (-12, 12),
            "SnapTurnDegrees": (15, 90), "SmoothTurnScale": (0.1, 2),
            "EyeRenderPercent": (50, 100), "MenuBackdropMode": (0, 1),
            # Teleport tuning, with the same bounds the script validator applies
            # to the live values, so a hand-edited or stale profile cannot seed
            # a range or a recharge the game would silently reject anyway.
            "LocomotionMode": (0, 1), "TeleportRange": (200, 2000),
            "TeleportSustainedSpeed": (200, 800), "TeleportMinCooldown": (1, 2),
            "TeleportMaxCooldown": (1, 4), "TeleportAscentLimit": (70, 1200),
            "TeleportDescentLimit": (100, 2000), "TeleportNavRadius": (50, 1000),
            "BlinkOutSeconds": (0, 0.5), "BlinkInSeconds": (0, 0.5), "BlinkScale": (0, 1)}


# Keys a profile may carry but must not override; see merged().
SHIPPED_TUNING = ("TeleportRange", "TeleportSustainedSpeed", "TeleportMinCooldown", "TeleportMaxCooldown")

# Profiles written before revision 2 never held an in-game choice: -NOINI kept
# the player's SaveConfig off disk, so export copied launch values back. Their
# MovementHand=1 is a stale seed, not a preference, and is reset to the shipped
# left hand once. Later profiles carry the stamp and are trusted as saved.
PROFILE_SECTION = "KF2VR.Profile"
PROFILE_REVISION = 2
LEGACY_RESET = {"KF2VR.VRHandsBridge": ("MovementHand",)}


def profile_revision(text):
    try:
        return int(values(text, PROFILE_SECTION).get("Revision", "0"))
    except ValueError:
        return 0


def stamp_revision(text):
    from session import set_ini
    return set_ini(text, PROFILE_SECTION, {"Revision": str(PROFILE_REVISION)})


def profile_root():
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "KF2VR/Profile"


KEYS = re.compile(r"(?m)^([A-Za-z][A-Za-z0-9_]*)=([^\r\n]*)")


def section_body(text, section):
    match = re.search(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\n]*\n(.*?)(?=^[ \t]*\[|\Z)", text)
    return match[1] if match else ""


def values(text, section):
    return dict(KEYS.findall(section_body(text, section)))


# Everything the section holds, not only the keys with a shipped default: a
# preference the player set in the headset is theirs whether or not this file
# has an opinion about it. Repeated keys are arrays -- SelectorFavorites and
# BodySlotOffsets are written one line per element -- and have to stay lists so
# a whole array survives the round trip rather than collapsing to its last line.
def items(text, section):
    found = {}
    for key, value in KEYS.findall(section_body(text, section)):
        if key in found:
            existing = found[key]
            found[key] = (existing if isinstance(existing, list) else [existing]) + [value]
        else:
            found[key] = value
    return found


def normalized(key, value, default):
    if key in POSITIVE:
        try:
            lo, hi = POSITIVE[key]
            if not lo <= float(value) <= hi:
                return default
            if key in ("EyeRenderPercent", "MenuHand", "MovementHand", "PreferredWeaponHand",
                       "MenuBackdropMode", "LocomotionMode") and not float(value).is_integer():
                return default
        except (TypeError, ValueError):
            return default
    if default.lower() in ("true", "false") and value.lower() not in ("true", "false"):
        return default
    if key == "EyeRenderPercent":
        return str(int(float(value)))
    # Upgrade only the previous shipped chest default; keep personal calibration.
    if key == "ChestGrenadeOffset" and value.replace(" ", "").lower() in (
            "(x=12,y=0,z=0)", "(x=10,y=-18,z=-6)", "(x=10,y=-18,z=-29)", "(x=20,y=-16,z=-8)",
            "(x=10,y=-20,z=-18)"):
        return default
    return value


# Defaults first, then what the session already had, then what the profile
# saved: the player's last choice wins, a key nobody has an opinion about is
# carried through untouched, and only keys with a shipped default are checked
# against their range.
def diagnostic(key):
    lowered = key.lower()
    # SaveConfig writes every config property, so capture switches reach the
    # session file too (bBreakActionCapture, bUsabilityCapture).
    return "diagnostic" in lowered or lowered.endswith(("replay", "probe", "capture"))


def merged(defaults, *sources):
    selected = dict(defaults)
    for source in sources:
        # A diagnostic switch is not a preference. It belongs to the fixture
        # that set it for one run, and a profile that learned it would quietly
        # turn the player's next ordinary session into a diagnostic one.
        selected.update({key: value for key, value in source.items()
                         if key in defaults or not diagnostic(key)})
    # Teleport reach and recharge are shipped tuning, never a preference (no
    # menu sets them). A saved value is always an older preset -- the 650 UU
    # sprint-parity hop outlived three retunes this way -- so it never wins.
    selected.update({key: defaults[key] for key in SHIPPED_TUNING if key in defaults})
    for key, value in list(selected.items()):
        default = defaults.get(key)
        if default is not None and not isinstance(value, list):
            selected[key] = normalized(key, value, default)
    return selected


def apply_preferences(text, saved="", *, eye_percent=None):
    from session import set_ini
    session_section = "KF2VR.VRSessionUI"
    hand_section = "KF2VR.VRHandsBridge"
    placement = ("SpatialMenuDistance", "SpatialMenuHeight", "SpatialMenuScale")
    session_values = merged(DEFAULTS[session_section], items(text, session_section), items(saved, session_section))
    # Older calibration stored geometry on the bridge. Upgrade it once only if
    # the session still has shipped geometry; a customized session wins.
    existing_session = {**values(text, session_section), **values(saved, session_section)}
    if "MenuPlacementRevision" not in existing_session:
        try:
            is_default = all(float(session_values[k]) == float(DEFAULTS[session_section][k]) for k in placement)
        except (TypeError, ValueError):
            is_default = False
        if is_default:
            old_hand = {**values(text, hand_section), **values(saved, hand_section)}
            for key in placement:
                if key in old_hand:
                    session_values[key] = normalized(key, old_hand[key], DEFAULTS[session_section][key])
    session_values["MenuPlacementRevision"] = "1"
    legacy = bool(saved.strip()) and profile_revision(saved) < PROFILE_REVISION
    for section, defaults in DEFAULTS.items():
        selected = session_values if section == session_section else merged(defaults, items(text, section), items(saved, section))
        if legacy:
            selected.update({key: defaults[key] for key in LEGACY_RESET.get(section, ())})
        if section == hand_section:
            # Compatibility values for the no-session native fallback and old
            # recorded fixtures. The session is the persisted editor owner.
            selected.update({key: session_values[key] for key in placement})
        if section.endswith("VRSessionUI") and eye_percent is not None:
            selected["EyeRenderPercent"] = str(eye_percent)
        text = set_ini(text, section, selected)
        text = set_ini(text, ALIASES[section], selected)
    return stamp_revision(text)


def import_preferences(config_root, *, persistent=True, eye_percent=None, root=None):
    from session import read_ini
    path = Path(config_root) / "KFGame.ini"
    saved_path = (root or profile_root()) / "KFGame.ini"
    saved = read_ini(saved_path) if persistent and saved_path.exists() else ""
    text = apply_preferences(read_ini(path) if path.exists() else "", saved, eye_percent=eye_percent)
    path.write_text(text, encoding="utf-16")
    return int(values(text, "KF2VR.VRSessionUI")["EyeRenderPercent"])


def export_preferences(config_root, root=None, *, network=True):
    from session import read_ini, set_ini
    source = Path(config_root) / "KFGame.ini"
    if not source.exists():
        return
    directory = root or profile_root()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "KFGame.ini"
    result = read_ini(target) if target.exists() else ""
    text = read_ini(source)
    selected_session = merged(DEFAULTS["KF2VR.VRSessionUI"], items(result, "KF2VR.VRSessionUI"),
                              items(text, ALIASES["KF2VR.VRSessionUI"] if network else "KF2VR.VRSessionUI"))
    for section, defaults in DEFAULTS.items():
        selected = merged(defaults, items(result, section), items(text, ALIASES[section] if network else section))
        if section == "KF2VR.VRHandsBridge":
            selected.update({key: selected_session[key] for key in ("SpatialMenuDistance", "SpatialMenuHeight", "SpatialMenuScale")})
        result = set_ini(result, section, selected)
        result = set_ini(result, ALIASES[section], selected)
    result = stamp_revision(result)
    temporary = target.with_suffix(".ini.tmp")
    temporary.write_text(result, encoding="utf-16")
    temporary.replace(target)
