"""Compose registrations and English text in an isolated combined snapshot."""
from pathlib import Path
import argparse
import configparser

from prepare_source_runtime import integrate as integrate_source

ROOT = Path(__file__).resolve().parents[1]
CATALOGS = (
    "project/source-weapons/Localization/INT/KF2VR.int",
    "script/EngineerStaging/Localization/INT/KF2VR.int",
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


def integrate(snapshot):
    snapshot = Path(snapshot).resolve()
    if not snapshot.is_relative_to((ROOT / "build/combined-script-runs").resolve()) or snapshot.name != "KF2VR":
        raise ValueError("Combined integration requires build/combined-script-runs/.../KF2VR")
    classes = snapshot / "Classes"
    for name in ("VRTrackedWeapon", "VRTrackedPresentation", "VREngineerMutator", "VRPortedTraderRegistry"):
        if not (classes / f"{name}.uc").is_file():
            raise ValueError(f"Missing combined runtime class: {name}")
    integrate_source(snapshot)
    # Engineer's kit grants register the five tool profiles on the root bridge.
    # Its mutator owns the trader integration; no bridge patch is applied here.
    merge_catalogs(snapshot)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    integrate(args.snapshot)
