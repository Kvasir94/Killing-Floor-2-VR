"""Register Source items in an isolated build snapshot using generic VR hooks."""
from pathlib import Path
import argparse
import json
import re

ROOT = Path(__file__).resolve().parents[1]


def append_defaults(text, field, entries):
    """Allocate from the snapshot's actual defaults, including other overlays."""
    matches = list(re.finditer(rf"^\s*{field}\((\d+)\)=(.*)$", text, re.M))
    indices = [int(match.group(1)) for match in matches]
    if not matches or len(indices) != len(set(indices)):
        raise ValueError(f"Missing or duplicate {field} defaults in snapshot")
    normalize = lambda value: re.sub(r"\s+", "", value).casefold()
    existing = [normalize(match.group(2)) for match in matches]
    additions = []
    for entry in entries:
        normalized = normalize(entry)
        identity = re.search(r"(?:weaponclassname=|class')([a-z0-9_]+)", normalized)
        if identity is None:
            raise ValueError(f"Missing class identity in {field}: {entry}")
        same_class = [value for value in existing if re.search(
            rf"(?:weaponclassname=|class'){re.escape(identity.group(1))}(?:[,)'\s]|$)", value)]
        if same_class:
            if same_class != [normalized]:
                raise ValueError(f"Conflicting {field} entry for {identity.group(1)}")
            continue
        additions.append(entry)
        existing.append(normalized)
    if not additions:
        return text
    next_index = max(indices) + 1
    block = "".join(f"\n    {field}({next_index + i})={entry}" for i, entry in enumerate(additions))
    end = matches[-1].end()
    return text[:end] + block + text[end:]


def integrate(snapshot):
    """Source, Portal and combined builders share this registration step.

    Never patch tracking, input or rendering branches in VRHandsBridge. Those
    call VRTrackedWeapon/VRTrackedPresentation; Source classes own behavior.
    """
    snapshot = Path(snapshot).resolve()
    if not snapshot.is_relative_to((ROOT / "build").resolve()) or snapshot.name != "KF2VR":
        raise ValueError("Source integration requires an isolated build/.../KF2VR snapshot")
    classes = snapshot / "Classes"
    manifest = json.loads((ROOT / "project/source-weapons/parked-integration.json").read_text(encoding="utf-8-sig"))
    if manifest["schema"] != "kf2vr-source-integration-v2":
        raise ValueError("Unsupported Source integration manifest")
    for name in manifest["required_interfaces"]:
        if not (classes / f"{name}.uc").is_file():
            raise ValueError(f"The shared runtime is missing {name}; wait for its complete source boundary")
    bridge_path = classes / "VRHandsBridge.uc"
    loadout_path = classes / "VRStarterLoadout.uc"
    bridge = bridge_path.read_text()
    loadout = loadout_path.read_text()
    for callback in ("ConfigureTrackedPresentation", "UpdateTrackedPresentation", "UpdateTrackedInput", "CancelTrackedInput"):
        if f".{callback}(" not in bridge:
            raise ValueError(f"Shared bridge is missing the generic {callback} callback")
    bridge = append_defaults(bridge, "WeaponProfiles", manifest["weapon_profiles"])
    loadout = append_defaults(loadout, "Definitions", manifest["starter_definitions"])
    marker = 'phase=source-weapon-skipped reason=assets-not-built'
    if marker not in loadout:
        anchor = "    if (WeaponClass == None) { bFailed = true; return false; }\n"
        if loadout.count(anchor) != 1:
            raise ValueError("Starter class-resolution guard changed")
        guard = '''    if (ClassIsChildOf(WeaponClass, class'VRSourceWeapon')
        && DynamicLoadObject(WeaponClass.default.FirstPersonMeshName, class'SkeletalMesh', true) == None)
    {
        `log("KF2VR_DEMO phase=source-weapon-skipped reason=assets-not-built weapon=" $ WeaponClass);
        ++NextDefinition;
        return false;
    }
'''
        loadout = loadout.replace(anchor, anchor + guard, 1)
    bridge_path.write_text(bridge)
    loadout_path.write_text(loadout)
    print("Registered Source profiles and starter definitions in", snapshot)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    integrate(parser.parse_args().snapshot)
