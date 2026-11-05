"""Shared playable preferences; only approved VR values cross session boundaries."""
import json
import stable_features
import os
from pathlib import Path
import re

DEFAULTS = json.loads((Path(__file__).resolve().parents[1] / "vr-defaults.json").read_text())
ALIASES = {"KF2VR.VRHandsBridge": "KF2VRNetClient.KF2VRNetHandsBridge",
           "KF2VR.VRSessionUI": "KF2VRNetClient.KF2VRNetSessionUI"}
POSITIVE = {"RequestedDlssMode": (0,6), "DlssSharpness": (0,100), "GrenadeZoneScale": (.5,1.5), "AmmoPouchScale": (.5,1.5), "GoreIntensity": (0,2), "FriendlyIndicatorScale": (.25,1), "HapticStrength": (0, 1), "Master": (0,100), "Effects": (0,100), "Dialogue": (0,100), "Music": (0,100), "VoiceChat": (0,100), "PendingMask": (0,127), "LastMicMode": (1,2), "FocusSimulationSpeed": (.05,1), "SpatialMenuDistance": (0.6, 3), "SpatialMenuScale": (0.5, 1.5),
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
            "WorldDropReturnPolicy": (0, 2), "WorldDropReturnSeconds": (1, 300),
            "ReloadPreset": (0, 3), "AimAssistMode": (0, 2), "AimAssistPreset": (0, 2),
            "AimAssistSettingsRevision": (0, 2147483647),
            "CustomAimCorrectionStrength": (0, 1), "CustomAimCorrectionTolerance": (0, 1),
            "CustomAimCorrectionMinRangeMeters": (0, 100), "CustomAimCorrectionMaxRangeMeters": (0, 100),
            "AmmoRuleSettingsRevision": (0, 2147483647),
            "ZedGrabSettingsRevision": (0, 2147483647),
            "MagazineReleaseSettingsRevision": (0, 2147483647),
            "ReloadStyleAlignmentRevision": (0, 2147483647),
            "QuickSetupRevision": (0, 2147483647), "TrainingRevision": (0, 2147483647), "SmoothTurnRevision": (0, 2147483647),
            # Teleport tuning, with the same bounds the script validator applies
            # to the live values, so a hand-edited or stale profile cannot seed
            # a range or a recharge the game would silently reject anyway.
            "LocomotionMode": (0, 1), "TeleportRange": (200, 2000),
            "TeleportSustainedSpeed": (200, 800), "TeleportMinCooldown": (1, 2),
            "TeleportMaxCooldown": (1, 4), "TeleportAscentLimit": (70, 1200),
            "TeleportDescentLimit": (100, 2000), "TeleportNavRadius": (50, 1000),
            "BlinkOutSeconds": (0, 0.5), "BlinkInSeconds": (0, 0.5), "BlinkScale": (0, 1)}


# Keys a profile may carry but must not override; see merged().
SHIPPED_TUNING = ("TeleportRange", "TeleportSustainedSpeed", "TeleportMinCooldown", "TeleportMaxCooldown", "bWorldWeaponDrops")

# Profiles written before revision 2 never held an in-game choice: -NOINI kept
# the player's SaveConfig off disk, so export copied launch values back. Their
# MovementHand=1 is a stale seed, not a preference, and is reset to the shipped
# left hand once. Later profiles carry the stamp and are trusted as saved.
PROFILE_SECTION = "KF2VR.Profile"
PROFILE_REVISION = 2
LEGACY_RESET = {"KF2VR.VRHandsBridge": ("MovementHand",)}
AMMO_OPTIONS = ("bKeepChamberedRound", "bLoseReloadAmmo", "bRecoverMagazineAmmo")
PARKED_FLAGS = ("bExperimentalStandingHolds",)


def profile_revision(text):
    try:
        return int(values(text, PROFILE_SECTION).get("Revision", "0"))
    except ValueError:
        return 0


def stamp_revision(text):
    from launch_support import set_ini
    return set_ini(text, PROFILE_SECTION, {"Revision": str(PROFILE_REVISION)})


def profile_root():
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "KF2VR/Profile"


KEYS = re.compile(r"(?m)^[ \t]*([A-Za-z][A-Za-z0-9_]*)[ \t]*=[ \t]*([^\r\n]*)")
PREFERENCE_NAMES = {key.lower(): key for defaults in DEFAULTS.values() for key in defaults}
PREFERENCE_NAMES["revision"] = "Revision"


def section_body(text, section):
    match = re.search(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\n]*\n(.*?)(?=^[ \t]*\[|\Z)", text)
    return match[1] if match else ""


def values(text, section):
    return {PREFERENCE_NAMES.get(key.lower(), key): value
            for key, value in KEYS.findall(section_body(text, section))}


# Everything the section holds, not only the keys with a shipped default: a
# preference the player set in the headset is theirs whether or not this file
# has an opinion about it. Keep repeats until merged() knows which keys are
# scalars: SelectorFavorites and BodySlotOffsets need every array element.
def items(text, section):
    found = {}
    for key, value in KEYS.findall(section_body(text, section)):
        key = PREFERENCE_NAMES.get(key.lower(), key)
        if key in found:
            existing = found[key]
            found[key] = (existing if isinstance(existing, list) else [existing]) + [value]
        else:
            found[key] = value
    return found


def normalized(key, value, default):
    value = value.strip()
    # A missing/malformed placement discriminator must never reinterpret a
    # stored mesh-pivot calibration as a visible-centre offset.
    if key == "bChestGrenadeCentered":
        return "True" if str(value).strip().lower() == "true" else "False"
    if key in POSITIVE:
        try:
            lo, hi = POSITIVE[key]
            if not lo <= float(value) <= hi:
                return default
            if key in ("EyeRenderPercent", "MenuHand", "MovementHand", "PreferredWeaponHand",
                       "MenuBackdropMode", "LocomotionMode", "WorldDropReturnPolicy",
                       "AmmoRuleSettingsRevision", "ZedGrabSettingsRevision", "MagazineReleaseSettingsRevision", "ReloadStyleAlignmentRevision", "ReloadPreset", "AimAssistMode",
                       "AimAssistPreset", "AimAssistSettingsRevision", "QuickSetupRevision", "TrainingRevision", "SmoothTurnRevision") and not float(value).is_integer():
                return default
        except (TypeError, ValueError):
            return default
    if default.lower() in ("true", "false") and value.lower() not in ("true", "false"):
        return default
    if key in ("EyeRenderPercent", "WorldDropReturnPolicy", "AmmoRuleSettingsRevision", "ZedGrabSettingsRevision", "MagazineReleaseSettingsRevision", "ReloadStyleAlignmentRevision", "ReloadPreset", "AimAssistMode", "AimAssistPreset", "AimAssistSettingsRevision", "QuickSetupRevision", "TrainingRevision", "SmoothTurnRevision"):
        return str(int(float(value)))
    return value


# Defaults first, then what the session already had, then what the profile
# saved: the player's last choice wins, a key nobody has an opinion about is
# carried through untouched, and only keys with a shipped default are checked
# against their range.
# Written by the launcher at each launch for display only; never carried in the profile.
TRANSIENT = ("launchgraphicssummary", "launcheffectssummary", "launchdlssmode")


def diagnostic(key):
    lowered = key.lower()
    if lowered in TRANSIENT:
        return True
    # SaveConfig writes every config property, so capture switches reach the
    # session file too (bBreakActionCapture, bUsabilityCapture).
    return "diagnostic" in lowered or lowered.endswith(("replay", "probe", "capture"))


def migrated_ammo(source, legacy="True", previous=None):
    """Migrate explicit source values before freshly seeded defaults hide them."""
    source = dict(source)
    try:
        revision = int(source.get("AmmoRuleSettingsRevision", "0"))
    except (TypeError, ValueError):
        revision = 0
    if revision >= 1 or not ("bRealisticAmmo" in source or any(key in source for key in AMMO_OPTIONS)):
        return source
    bundled = "bRealisticAmmo" in source
    legacy = str(source.get("bRealisticAmmo", legacy)).strip().lower()
    inherited = "False" if legacy == "false" else "True"
    for key in AMMO_OPTIONS:
        source.setdefault(key, inherited if bundled or previous is None else previous.get(key, inherited))
    source["AmmoRuleSettingsRevision"] = "1"
    return source


def migrated_magazine_release(source):
    """NEW MAG RELEASES OLD became on by default (Kvasir94, 11-03, #157): a
    choice saved before that revision is flipped on once; later ones stay."""
    source = dict(source)
    try:
        revision = int(source.get("MagazineReleaseSettingsRevision", "0"))
    except (TypeError, ValueError):
        revision = 0
    if revision >= 1 or "bGrabReleasesMagazine" not in source:
        return source
    source["bGrabReleasesMagazine"] = "True"
    source["MagazineReleaseSettingsRevision"] = "1"
    return source


def migrated_reload_style(source, previous):
    """The reload styles now also set NEW MAG RELEASES OLD and X / A EJECTS
    FULL MAG (PHYSICAL_RELOAD_SPEC R43, R47, R48). A profile saved before that
    is aligned once to the style its working switches read: Interactive gets
    NEW MAG on and full-mag eject off, Advanced the reverse. Classic and
    Custom are untouched; later choices are kept."""
    source = dict(source)
    try:
        revision = int(source.get("ReloadStyleAlignmentRevision", "0"))
    except (TypeError, ValueError):
        revision = 0
    switches = ("bInteractiveReloads", "bFreeWeaponCycling", "bEmptyTriggerReloads")
    if revision >= 1 or not any(key in source for key in switches):
        return source
    on = {key: str(source.get(key, previous.get(key, "False"))).strip().lower() == "true" for key in switches}
    if on["bInteractiveReloads"] and on["bFreeWeaponCycling"] != on["bEmptyTriggerReloads"]:
        advanced = on["bFreeWeaponCycling"]
        source["bGrabReleasesMagazine"] = "False" if advanced else "True"
        source["bAllowFullMagazineEject"] = "True" if advanced else "False"
    source["ReloadStyleAlignmentRevision"] = "1"
    return source


# The shipped chest grenade zone of 10-25 sat too high: large grenades such as
# the Gunslinger's nail bomb were in the player's face (playtest 011320). A
# profile still holding that exact centred default takes the current one; any
# other saved or calibrated offset is the player's own and is kept.
WITHDRAWN_CHEST_GRENADE = (10.5, 9.5, 13.5)


def migrated_chest_grenade(source, defaults):
    offset = source.get("ChestGrenadeOffset")
    if offset is None or str(source.get("bChestGrenadeCentered", "")).strip().lower() != "true":
        return source
    try:
        parts = dict(part.split("=", 1) for part in str(offset).strip().strip("()").split(","))
        saved = tuple(float(parts[axis]) for axis in "XYZ")
    except (KeyError, ValueError):
        return source
    if saved != WITHDRAWN_CHEST_GRENADE:
        return source
    source = dict(source)
    source["ChestGrenadeOffset"] = defaults["ChestGrenadeOffset"]
    return source


def migrated_smooth_turn(source):
    """Smooth turn's default went from 75% to 100% (Kvasir94, 11-05). A profile
    saved before that holds 75% only because the old default was written out,
    so it moves once; a choice made after the revision stays."""
    source = dict(source)
    try:
        revision = int(source.get("SmoothTurnRevision", "0"))
    except (TypeError, ValueError):
        revision = 0
    if revision >= 1 or "SmoothTurnScale" not in source:
        return source
    try:
        if abs(float(source["SmoothTurnScale"]) - 0.75) < 0.001:
            source["SmoothTurnScale"] = "1.00"
    except (TypeError, ValueError):
        pass
    source["SmoothTurnRevision"] = "1"
    return source


def migrated_aim_assist(source):
    """Upgrade an explicit old choice before seeded presets can obscure it."""
    source = dict(source)
    if int(source.get("AimAssistSettingsRevision", "0")) >= 1:
        return source
    if "AimAssistPreset" in source:
        source["AimAssistSettingsRevision"] = "1"
    elif "AimAssistMode" in source:
        mode = source["AimAssistMode"]
        source["AimAssistPreset"] = {"0": "1", "1": "2", "2": "0"}[mode]
        if mode == "1":
            source.setdefault("CustomAimCorrectionMaxRangeMeters", "25.0")
        source["AimAssistSettingsRevision"] = "1"
    return source


def normalize_aim_range(selected, changed=()):
    """Clamp the edited bound; malformed pairs loaded together clamp minimum."""
    minimum, maximum = "CustomAimCorrectionMinRangeMeters", "CustomAimCorrectionMaxRangeMeters"
    if float(selected[minimum]) > float(selected[maximum]):
        key, other = (maximum, minimum) if maximum in changed and minimum not in changed else (minimum, maximum)
        selected[key] = selected[other]
    return selected


def merged(defaults, *sources):
    selected = dict(defaults)
    for source in sources:
        # Match Unreal's case-insensitive scalar keys and last-value wins rule.
        # Unknown repeated settings remain arrays (favorites, fit profiles, etc.).
        checked = {}
        for key, value in source.items():
            key = PREFERENCE_NAMES.get(key.lower(), key)
            if key in defaults:
                if isinstance(value, list):
                    value = value[-1] if value else ""
                value = normalized(key, str(value), defaults[key])
            checked[key] = value
        source = checked
        if "AimAssistPreset" in defaults:
            source = migrated_aim_assist(source)
        if "bZedGrabEnabled" in defaults:
            # INI names are case insensitive. Keep the saved choice even
            # without a revision stamp; absence uses the shared ON default.
            canonical = {"bzedgrabenabled": "bZedGrabEnabled",
                         "zedgrabsettingsrevision": "ZedGrabSettingsRevision"}
            source = {canonical.get(key.lower(), key): value for key, value in source.items()}
            if "bZedGrabEnabled" in source:
                choice = source["bZedGrabEnabled"]
                if isinstance(choice, list):
                    choice = choice[-1] if choice else ""
                choice = str(choice).strip()
                source["bZedGrabEnabled"] = choice.capitalize() if choice.lower() in ("true", "false") else choice
        if "MagazineReleaseSettingsRevision" in defaults:
            source = migrated_magazine_release(source)
        if "ReloadStyleAlignmentRevision" in defaults:
            source = migrated_reload_style(source, selected)
        if all(key in defaults for key in AMMO_OPTIONS):
            source = migrated_ammo(source, selected.get("bRealisticAmmo", "True"), selected)
        if "ChestGrenadeOffset" in defaults:
            source = migrated_chest_grenade(source, defaults)
        if "SmoothTurnRevision" in defaults:
            source = migrated_smooth_turn(source)
        # A diagnostic switch is not a preference. It belongs to the fixture
        # that set it for one run, and a profile that learned it would quietly
        # turn the player's next ordinary session into a diagnostic one.
        selected.update({key: value for key, value in source.items()
                         if key in defaults or not diagnostic(key)})
        if "AimAssistPreset" in defaults:
            normalize_aim_range(selected, source)
        # Offset and interpretation belong to the same source. An old saved
        # offset overrides any centre-mode seed from an earlier/default source.
        if "ChestGrenadeOffset" in source and "bChestGrenadeCentered" not in source:
            selected["bChestGrenadeCentered"] = "False"
    # Teleport reach and recharge are shipped tuning, never a preference (no
    # menu sets them). A saved value is always an older preset -- the 650 UU
    # sprint-parity hop outlived three retunes this way -- so it never wins.
    # World drops also ignore the False value forced by withdrawn builds;
    # player sharing and return preferences remain independent.
    selected.update({key: defaults[key] for key in SHIPPED_TUNING if key in defaults})
    for key, value in list(selected.items()):
        default = defaults.get(key)
        if default is not None and not isinstance(value, list):
            selected[key] = normalized(key, value, default)
    if "LocalMutators" in selected and not stable_features.experimental_content_enabled():
        selected["LocalMutators"] = stable_features.filter_mutators(selected["LocalMutators"])
    if "bWorldWeaponDrops" in defaults:
        # INI names are case insensitive. Discard alternate spellings before
        # writing one canonical disabled value, including repeated old keys.
        parked = {key.lower() for key in PARKED_FLAGS}
        selected = {key: value for key, value in selected.items() if key.lower() not in parked}
        selected.update(dict.fromkeys(PARKED_FLAGS, "False"))
    return selected


def preference_items(text, section):
    # Some older network profiles contain only the subclass section.
    if section in ALIASES and not section_body(text, section):
        return items(text, ALIASES[section])
    return items(text, section)


def apply_preferences(text, saved="", *, eye_percent=None):
    from launch_support import set_ini
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
        selected = session_values if section == session_section else merged(defaults, preference_items(text, section), preference_items(saved, section))
        if legacy:
            selected.update({key: defaults[key] for key in LEGACY_RESET.get(section, ())})
        if section == hand_section:
            # Compatibility values for the no-session native fallback and old
            # recorded fixtures. The session is the persisted editor owner.
            selected.update({key: session_values[key] for key in placement})
        if section.endswith("VRSessionUI") and eye_percent is not None:
            selected["EyeRenderPercent"] = str(eye_percent)
        text = set_ini(text, section, selected)
        if section in ALIASES:
            text = set_ini(text, ALIASES[section], selected)
    return stamp_revision(text)


def import_preferences(config_root, *, persistent=True, eye_percent=None, root=None):
    from launch_support import read_ini, set_ini
    path = Path(config_root) / "KFGame.ini"
    saved_path = (root or profile_root()) / "KFGame.ini"
    saved = read_ini(saved_path) if persistent and saved_path.exists() else ""
    text = apply_preferences(read_ini(path) if path.exists() else "", saved, eye_percent=eye_percent)
    for section in ("KF2VR.VRHandsBridge", ALIASES["KF2VR.VRHandsBridge"]):
        text = set_ini(text,section,{"bAllowOtherWeaponPickup":"False", "bBoxingGloves":"False", "bSuperStrength":"False"})
    path.write_text(text, encoding="utf-16")
    (Path(config_root) / BASELINE).write_text(json.dumps({section: items(text, section) for section in ALIASES}),
                                              encoding="utf-8")
    return int(values(text, "KF2VR.VRSessionUI")["EyeRenderPercent"])


def export_session_preferences(record, root=None):
    """Export a started player's settings once, independently of DLL cleanup."""
    if record.get("preferences_saved"):
        return
    driver = next((role for role in record.get("roles", []) if role.get("role") == "driver"), None)
    if not driver or not driver.get("pid"):
        return
    if record.get("vr"):
        export_preferences(Path(driver["config_root"]), root=root,
                           network=record.get("session_mode") != "solo")
    elif record.get("vr") is False and record.get("user_config_root"):
        from desktop_settings import export
        export(Path(driver["config_root"]), Path(record["user_config_root"]), root=root)
    else:
        return
    record["preferences_saved"] = True


BASELINE = "KF2VR-preference-baseline.json"


# Solo writes the base sections and Host/Join the network subclass sections;
# import gives both the same launch values and records them. A key the
# session's own mode changed wins; otherwise a change made in the other mode
# (Solo inside a Host/Join process) is kept too.
def exported_section(defaults, saved, text, section, network, launched=None):
    own = ALIASES.get(section, section) if network else section
    selected = merged(defaults, items(saved, section), items(text, own))
    if section not in ALIASES or not launched or section not in launched:
        return selected
    other = section if network else ALIASES[section]
    baseline = merged(defaults, items(saved, section), launched[section])
    for key, value in merged(defaults, items(saved, section), items(text, other)).items():
        if value != baseline.get(key) and selected.get(key) == baseline.get(key):
            selected[key] = value
    return selected


def launched_preferences(config_root):
    try:
        return json.loads((Path(config_root) / BASELINE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def export_preferences(config_root, root=None, *, network=True):
    from launch_support import read_ini, set_ini
    source = Path(config_root) / "KFGame.ini"
    if not source.exists():
        return
    directory = root or profile_root()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "KFGame.ini"
    result = read_ini(target) if target.exists() else ""
    text = read_ini(source)
    launched = launched_preferences(config_root)
    selected_session = exported_section(DEFAULTS["KF2VR.VRSessionUI"], result, text, "KF2VR.VRSessionUI", network, launched)
    for section, defaults in DEFAULTS.items():
        selected = exported_section(defaults, result, text, section, network, launched)
        if section == "KF2VR.VRHandsBridge":
            selected.update({key: selected_session[key] for key in ("SpatialMenuDistance", "SpatialMenuHeight", "SpatialMenuScale")})
        result = set_ini(result, section, selected)
        if section in ALIASES:
            result = set_ini(result, ALIASES[section], selected)
    result = stamp_revision(result)
    temporary = target.with_suffix(".ini.tmp")
    temporary.write_text(result, encoding="utf-16")
    temporary.replace(target)
    import vr_graphics
    vr_graphics.export(config_root, root=root)
    # Requested mode can be pending while the current XR session keeps its active mode.
    from workshop_loadout import update_preferences
    import settings_registry
    update_preferences({"dlss": settings_registry.DLSS_MODES[int(float(selected_session["RequestedDlssMode"]))],
                        "dlss_sharpness":int(float(selected_session["DlssSharpness"])),
                        "hide_bile_lens":selected_session["bBileSplatter"].lower() != "true",
                        "hide_blood_lens":selected_session["bBloodSplatter"].lower() != "true"}, directory)
