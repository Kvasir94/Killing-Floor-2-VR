"""Compose registrations and English text in an isolated combined snapshot."""
from pathlib import Path
import argparse
import configparser
import re

from prepare_portal_runtime import integrate as integrate_portal
from prepare_source_runtime import integrate as integrate_source

ROOT = Path(__file__).resolve().parents[1]
CATALOGS = (
    "project/source-weapons/Localization/INT/KF2VR.int",
    "script/EngineerStaging/Localization/INT/KF2VR.int",
    "project/portal-gun/Localization/INT/KF2VR.int",
)


def merge_catalogs(snapshot):
    sections = {}
    for relative in CATALOGS:
        parser = configparser.RawConfigParser(strict=True, delimiters=("=",))
        parser.optionxform = str
        parser.read_string((ROOT / relative).read_text(encoding="utf-8-sig"))
        if parser.defaults():
            raise ValueError(f"Unexpected global localization defaults: {relative}")
        for section in parser.sections():
            label, values = sections.setdefault(section.casefold(), (section, {}))
            for key, value in parser.items(section, raw=True):
                existing = values.get(key.casefold())
                if existing and existing[1] != value:
                    raise ValueError(f"Conflicting localization {label}.{key} in {relative}")
                values[key.casefold()] = (key, value)
    output = snapshot / "Localization/INT/KF2VR.int"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n\n".join(
        f"[{label}]\n" + "\n".join(f"{key}={value}" for key, value in values.values())
        for label, values in sections.values()
    ) + "\n", encoding="utf-8")
    print(f"Merged {len(CATALOGS)} catalogs into {len(sections)} localization sections")


def integrate(snapshot, enable_portals=False):
    snapshot = Path(snapshot).resolve()
    if not snapshot.is_relative_to((ROOT / "build/combined-script-runs").resolve()) or snapshot.name != "KF2VR":
        raise ValueError("Combined integration requires build/combined-script-runs/.../KF2VR")
    classes = snapshot / "Classes"
    for name in ("VRTrackedWeapon", "VRTrackedPresentation", "VREngineerMutator", "VRPortedTraderRegistry"):
        if not (classes / f"{name}.uc").is_file():
            raise ValueError(f"Missing combined runtime class: {name}")
    if enable_portals:
        integrate_portal(snapshot)  # Includes Source's declarative registration.
    else:
        integrate_source(snapshot)
    registry = classes / "VRPortedTraderRegistry.uc"
    text = registry.read_text()
    entry = '"KF2VR.VRWeapDef_PortalGun"'
    defaults = list(re.finditer(r'^\s*DefinitionPaths\((\d+)\)=(.*)$', text, re.M))
    indices = [int(match[1]) for match in defaults]
    if not defaults or len(set(indices)) != len(indices):
        raise ValueError("Missing or duplicate ported trader definition slots")
    if enable_portals and not any(match[2].strip().casefold() == entry.casefold() for match in defaults):
        end = defaults[-1].end()
        text = text[:end] + f"\n    DefinitionPaths({max(indices) + 1})={entry}" + text[end:]
        registry.write_text(text)
    # Engineer's kit grants register the five tool profiles on the root bridge.
    # Its mutator owns the trader integration; no bridge patch is applied here.
    merge_catalogs(snapshot)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--enable-portals", action="store_true")
    args = parser.parse_args()
    integrate(args.snapshot, args.enable_portals)
