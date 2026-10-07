"""Persist only the player's edits to the nine VR-safe stock quality rows.

Launch presets and comfort overrides are applied before this module. A session
snapshot distinguishes subsequent edits from launch defaults. Display geometry,
connection settings and whole Engine sections never enter this profile.
"""
import json
import math
from pathlib import Path
import re

from session import read_ini, set_ini
from vr_config import profile_root, section_body

PROFILE_FILE = "vr-graphics.json"
SNAPSHOT_FILE = "VRGraphicsLaunch.json"
SCHEMA = 1


def scalar_rules(kind, names, lo=0, hi=0):
    return {name: (kind, lo, hi) for name in names.split()}


# Keys written by VRGraphicsMenu's stock quality setters. Keep unrelated
# native options out even when they happen to be in the same INI section.
SYSTEM = {
    **scalar_rules("bool", "AllowLightFunctions DisableCanBecomeDynamicWakeup "
                   "AllowSubsurfaceScattering ShouldCorpseCollideWithDead "
                   "ShouldCorpseCollideWithLiving ShouldCorpseCollideWithDeadAfterSleep "
                   "Distortion FilteredDistortion DropParticleDistortion AllowSecondaryBloodEffects "
                   "bAllowWholeSceneDominantShadows bOverrideMapWholeSceneDominantShadowSetting "
                   "DynamicShadows AllowPerObjectShadows AllowForegroundPreshadows Bloom "
                   "LightCones bAllowLightShafts"),
    **scalar_rules("int", "DetailMode SkeletalMeshLODBias ParticleLODBias DistanceFogQuality BloomQuality", 0, 4),
    **scalar_rules("int", "MaxWholeSceneDominantShadowResolution MaxShadowResolution "
                   "ShadowFadeResolution MinShadowResolution", 0, 8192),
    **scalar_rules("int", "MaxAnisotropy", 1, 16),
    **scalar_rules("float", "MakeDynamicCollisionThreshold", 0, 10000),
    **scalar_rules("float", "KinematicUpdateDistFactorScale ShadowTexelsPerPixel GlobalShadowDistanceScale", 0, 16),
}
TEXTURE_MEMBERS = {
    "LODBias": ("int", -4, 16),
    "MinMagFilter": ("enum", ("point", "linear", "aniso"), None),
    "MipFilter": ("enum", ("point", "linear"), None),
}
TEXTURE_GROUPS = tuple("TEXTUREGROUP_" + group for group in (
    "UI", "UIWithMips", "UIStreamable", "Shadowmap", "Character", "CharacterNormalMap",
    "CharacterSpecular", "Creature", "CreatureNormalMap", "CreatureSpecular", "Cosmetic",
    "CosmeticNormalMap", "CosmeticSpecular", "Weapon", "WeaponNormalMap", "WeaponSpecular",
    "Weapon3rd", "Weapon3rdNormalMap", "Weapon3rdSpecular", "World", "WorldNormalMap",
    "WorldSpecular", "Effects", "EffectsNotFiltered"))

# These stock classes all save their graphics settings to Game.ini. Effects
# quality is not just ParticleLODBias: lights, gore and emitter limits matter.
SCRIPT = {
    "Engine.WorldInfo": {
        **scalar_rules("float", "DestructionLifetimeScale EmitterPoolScale", 0, 16),
        **scalar_rules("bool", "bAllowExplosionLights"),
        **scalar_rules("int", "MaxExplosionDecals", 0, 4096),
    },
    "KFGame.KFMuzzleFlash": scalar_rules("float", "ShellEjectLifetime", 0, 120),
    "KFGame.KFSprayActor": scalar_rules("bool", "bAllowSprayLights"),
    "KFGame.KFPawn": scalar_rules("bool", "bAllowFootstepSounds bAllowRagdollAndGoreOnDeadBodies bAllowAlwaysOnPhysics"),
    "KFGame.KFWeap_FlameBase": scalar_rules("bool", "bArePilotLightsAllowed"),
    "KFGame.KFImpactEffectManager": scalar_rules("int", "MaxImpactEffectDecals", 0, 4096),
    "KFGame.KFGoreManager": {
        **scalar_rules("bool", "bAllowBloodSplatterDecals"),
        **scalar_rules("float", "GoreFXLifetimeMultiplier", 0, 16),
        **scalar_rules("int", "MaxBloodEffects MaxGoreEffects MaxPersistentSplatsPerFrame "
                       "MaxBodyWoundDecals MaxDeadBodies", 0, 4096),
    },
}
FILES = {"KFSystemSettings.ini": {"SystemSettings": SYSTEM}, "KFGame.ini": SCRIPT}
PAIRS = re.compile(r"(?m)^[ \t]*([A-Za-z][A-Za-z0-9_]*)[ \t]*=([^\r\n]*)")


def normalized(value, rule):
    if not isinstance(value, str) or len(value) > 64:
        return None
    value = value.strip()
    kind, lo, hi = rule
    if kind == "bool":
        return {"true": "True", "false": "False"}.get(value.lower())
    if kind == "enum":
        return value.lower() if value.lower() in lo else None
    try:
        number = float(value)
    except ValueError:
        return None
    if not math.isfinite(number) or not lo <= number <= hi:
        return None
    if kind == "int":
        return str(int(number)) if number.is_integer() else None
    return format(number, ".9g")


def texture_members(value):
    if not isinstance(value, str) or len(value) > 2048:
        return {}
    value = value.strip()
    if not value.startswith("(") or not value.endswith(")"):
        return {}
    parts = {}
    for item in value[1:-1].split(","):
        key, separator, content = item.partition("=")
        key = key.strip().lower()
        if not separator or key in parts:
            return {}
        parts[key] = content.strip()
    return parts


def clean_values(data):
    """Validate both disk profiles and snapshots against the same allowlist."""
    result = {}
    if not isinstance(data, dict):
        return result
    for filename, sections in FILES.items():
        source = data.get(filename, {})
        if not isinstance(source, dict):
            continue
        for section, rules in sections.items():
            source_section = source.get(section, {})
            if not isinstance(source_section, dict):
                continue
            selected = {}
            for key, rule in rules.items():
                value = normalized(source_section.get(key), rule)
                if value is not None:
                    selected[key] = value
            if filename == "KFSystemSettings.ini":
                for key in TEXTURE_GROUPS:
                    members = source_section.get(key)
                    if not isinstance(members, dict):
                        continue
                    safe = {name: value for name, rule in TEXTURE_MEMBERS.items()
                            if (value := normalized(members.get(name), rule)) is not None}
                    if safe:
                        selected[key] = safe
            if selected:
                result.setdefault(filename, {})[section] = selected
    return result


def capture(configs):
    values = {}
    for filename, sections in FILES.items():
        path = Path(configs) / filename
        if not path.exists():
            continue
        text = read_ini(path)
        for section in sections:
            source = {key.lower(): value for key, value in PAIRS.findall(section_body(text, section))}
            selected = {key: source.get(key.lower()) for key in sections[section]}
            if filename == "KFSystemSettings.ini":
                for key in TEXTURE_GROUPS:
                    members = texture_members(source.get(key.lower()))
                    selected[key] = {name: members.get(name.lower()) for name in TEXTURE_MEMBERS}
            values.setdefault(filename, {})[section] = selected
    return clean_values(values)


def read_record(path):
    try:
        if path.stat().st_size > 128 * 1024:
            return {}
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return {}
    return record if isinstance(record, dict) and record.get("schema") == SCHEMA else {}


def write_record(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(record, indent=2), encoding="utf-8")
    temporary.replace(path)


def apply(configs, root=None, *, reset=False):
    """Apply saved quality edits after defaults, then snapshot launch state.

    An explicit launcher preset discards old custom edits only after a real
    session exports; PrepareOnly never alters the player's saved profile.
    """
    configs = Path(configs)
    saved = {} if reset else clean_values(read_record((root or profile_root()) / PROFILE_FILE).get("values"))
    for filename, sections in saved.items():
        path = configs / filename
        text = read_ini(path) if path.exists() else ""
        for section, selected in sections.items():
            edits = dict(selected)
            existing = {key.lower(): value for key, value in PAIRS.findall(section_body(text, section))}
            for key in TEXTURE_GROUPS:
                if key not in edits:
                    continue
                members = texture_members(existing.get(key.lower()))
                # The runtime's texture size/mip policy remains in the new
                # session. Persist only LOD bias and filtering subfields.
                if not members:
                    del edits[key]
                    continue
                members.update({name.lower(): value for name, value in edits[key].items()})
                edits[key] = "(" + ",".join(f"{name}={value}" for name, value in members.items()) + ")"
            if edits:
                text = set_ini(text, section, edits)
        path.write_text(text, encoding="utf-16")
    write_record(configs / SNAPSHOT_FILE, {"schema": SCHEMA, "reset": bool(reset), "values": capture(configs)})


def export(configs, root=None):
    """Retain only allowed values changed since this session's launch."""
    configs = Path(configs)
    snapshot = read_record(configs / SNAPSHOT_FILE)
    if not snapshot:
        return  # No launch snapshot: never mistake defaults for player edits.
    directory = root or profile_root()
    saved = {} if snapshot.get("reset") else clean_values(read_record(directory / PROFILE_FILE).get("values"))
    before, after = clean_values(snapshot.get("values")), capture(configs)
    for filename, sections in after.items():
        for section, selected in sections.items():
            previous = before.get(filename, {}).get(section, {})
            for key, value in selected.items():
                if isinstance(value, dict):
                    original = previous.get(key, {})
                    changed = {name: item for name, item in value.items() if item != original.get(name)}
                    if changed:
                        saved.setdefault(filename, {}).setdefault(section, {}).setdefault(key, {}).update(changed)
                elif value != previous.get(key):
                    saved.setdefault(filename, {}).setdefault(section, {})[key] = value
    write_record(directory / PROFILE_FILE, {"schema": SCHEMA, "values": saved})
