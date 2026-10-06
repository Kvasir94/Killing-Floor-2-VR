"""Export only the KF2 rig/skin inputs needed by the mod from a local installation."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from generate_reload_props import DEFAULT_RIGS, RIDING_ROUNDS, WHOLE_MESH_PROPS

ROOT = Path(__file__).resolve().parents[1]
UMODEL_SHA256 = "13502E5A4D8F6B5F32252AFEBD6360F7302CCFACCF6B8DDA65BEFF0BE2D364A0"
HAND_RIG = "extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk"
SKIN_TEXTURES = tuple("extract/hands-materials/CHR_1P_Arms_TEX/Texture2D/" + name + ".tga"
                      for name in ("Wep_1stPersonHands_Male_D", "Wep_1stPersonHands_Male_N"))
MACE_INPUTS = (
    "build/blunt-maceandshield-audit/export/WEP_1P_Shield_Melee_MESH/SkeletalMesh3/Wep_1stP_Shield_Melee_Rig.psk",
    "build/blunt-maceandshield-audit/export/WEP_1P_Shield_Melee_ANIM/AnimSet/Wep_1stP_Shield_Melee_Anim.psa",
)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def export_inputs(game_root, umodel, *, root=ROOT):
    root, game_root, umodel = Path(root).resolve(), Path(game_root).resolve(), Path(umodel).resolve()
    pin = json.loads((root / "docs/intake/install_manifest.json").read_text(encoding="utf-8-sig"))
    if sha256(game_root / "Binaries/Win64/KFGame.exe") != pin["binaries"]["game"]["sha256"].upper():
        raise ValueError("Game executable differs from the supported build; extraction refused.")
    if sha256(umodel) != UMODEL_SHA256:
        raise ValueError("UModel executable differs from the documented build pin.")
    brewed = game_root / "KFGame/BrewedPC"
    if not brewed.is_dir():
        raise ValueError("KFGame/BrewedPC is missing from the game installation.")
    reload_extras = tuple(sorted({spec[key] for spec in RIDING_ROUNDS.values()
                                 for key in ('psa', 'mesh') if key in spec}))
    destinations = tuple(dict.fromkeys(tuple(DEFAULT_RIGS) + (HAND_RIG,) + SKIN_TEXTURES +
                                      MACE_INPUTS + reload_extras + tuple(WHOLE_MESH_PROPS.values())))
    for name in destinations:
        if not (root / name).resolve().is_relative_to(root):
            raise ValueError("Asset destination escapes the checkout.")
    # A fresh scratch export avoids merging user caches or copying whole packages.
    scratch_root = root / "build/kf2-build-extract"
    scratch_root.mkdir(parents=True, exist_ok=True)
    previous = {}
    previous_path = scratch_root / "inputs.json"
    if previous_path.exists():
        previous = json.loads(previous_path.read_text(encoding='utf-8'))
        if previous.get('game_sha256') != pin['binaries']['game']['sha256'].upper() or previous.get('umodel_sha256') != UMODEL_SHA256:
            previous = {}
    hashes = {}
    with tempfile.TemporaryDirectory(dir=scratch_root, prefix="export-") as temporary:
        scratch = Path(temporary)
        for name in destinations:
            target = root / name
            if target.is_file() and previous.get('files_sha256', {}).get(name) == sha256(target):
                hashes[name] = sha256(target)
                continue
            path = Path(name)
            package, kind = path.parts[-3:-1]
            filters = {"Texture2D": ["-noanim", "-nomesh"],
                       "SkeletalMesh3": ["-noanim", "-notex"],
                       "AnimSet": ["-nomesh", "-notex"]}[kind]
            arguments = [str(umodel), "-export", "-nostat", *filters,
                         "-out=" + str(scratch), "-path=" + str(brewed), package, path.stem]
            result = subprocess.run(arguments, cwd=scratch, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            exported = scratch / package / kind / path.name
            if result.returncode or not exported.is_file():
                raise RuntimeError("UModel did not export " + package + "." + path.stem + "\n" + result.stdout[-2000:])
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and sha256(target) != sha256(exported):
                raise RuntimeError("Existing input differs; preserve it and use a clean checkout: " + name)
            if not target.exists():
                shutil.copy2(exported, target)
            hashes[name] = sha256(target)
            print("Exported", package + "." + path.stem, flush=True)
    record = {"schema": "kf2vr/local-build-extract/1", "umodel_sha256": UMODEL_SHA256,
              "game_sha256": pin["binaries"]["game"]["sha256"].upper(), "files_sha256": hashes}
    (scratch_root / "inputs.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-root", type=Path, required=True)
    parser.add_argument("--umodel", type=Path, required=True, help="Pinned UE Viewer executable; see BUILDING")
    args = parser.parse_args(argv)
    record = export_inputs(args.game_root, args.umodel)
    print("Local build inputs ready:", len(record["files_sha256"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
