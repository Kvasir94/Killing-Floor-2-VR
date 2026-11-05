"""Read-only Steam-to-Epic map of the single-pass stereo and DLSS object-motion
functions (docs/re/EPIC_SINGLE_PASS.md). Reuses epic_binary_map's normalized
whole-body matcher; never launches or patches the game.

Usage: python tools/re/epic_single_pass_map.py STEAM_EXE EPIC_EXE --output OUT.json
"""
import argparse, hashlib, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import epic_binary_map as m
from pe import PE

SINGLE_PASS = {
    # Hooks installed by Adapter.cpp when -kf2vr-single-pass is on.
    "RenderScene": 0x90ef10, "RenderLighting": 0x911620, "InitViews": 0x909480,
    "BeginOcclusionTests": 0x902560, "ViewConstants": 0xcd61d0, "FlareOcclusion": 0x2a50f0,
    "RhiClear": 0xcb60e0, "SsrCompute": 0x3605d0, "Quad": 0x8e1bb0,
    "ShadowProjection": 0x935340, "HbaoRhi": 0xcd03b0,
    # Engine steps HookInitViews calls directly for the paired-view visibility path.
    "Visibility": 0x36b490, "ViewSetup": 0x360a30, "SortTranslucency": 0x950320,
    "FamilyStep904df0": 0x904df0, "LightGate8f95e0": 0x8f95e0,
    "PerLightVisibility": 0x949970, "FinishInitViews": 0x8c2a20,
    # Multiview lighting evidence (audit_multiview_lighting.py).
    "PreferredLighting": 0x322430, "BasePass": 0x90f900, "AlternativeLighting": 0x8ca3e0,
}
OBJECT_MOTION = {
    "RenderVelocities": 0x94d240, "PrimeVelocities": 0x94b270, "BeginVelocities": 0x91be70,
    "VelocityScale": 0x94e140, "TileMaxBlur": 0x34a3c0, "LegacyBlur": 0x34ad20,
}
# HiZ (0x1ec2398) is read by neither group; these Steam functions reference it.
HIZ_XREFS = {"HiZXref315af0": 0x315af0, "HiZXref327370": 0x327370, "HiZXref67bb20": 0x67bb20}
GLOBALS = {"HiZ": 0x1ec2398, "ViewGateOff": 0x1fbafec, "ViewGateOn": 0x1ec2388,
           "ForegroundFlag": 0x2225590, "Rhi": 0x21f6ed0}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("steam", type=Path); p.add_argument("epic", type=Path)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    s, e = PE(str(a.steam)), PE(str(a.epic))
    if [hashlib.sha256(x.data).hexdigest().upper() for x in (s, e)] != m.PINS:
        p.error("Expected the exact pinned Steam and Epic binaries")
    m.FUNCTIONS = {**SINGLE_PASS, **OBJECT_MOTION, **HIZ_XREFS}
    r = m.analyze(s, e)
    refs = r["reference_candidates"]
    r["globals"] = {n: dict(steam=hex(v), epic=refs.get(hex(v))) for n, v in GLOBALS.items()}
    a.output.write_text(json.dumps(r, indent=1), encoding="utf-8")
    for f in r["functions"]:
        full = [c["rva"] for c in f.get("candidates", []) if c["full_normalized_match"]]
        print(f"{f['name']:22} {f['steam_rva']:>9} -> {full}")
    for n, g in r["globals"].items(): print(f"{n:22} {g['steam']:>9} -> {g['epic']}")


if __name__ == "__main__":
    main()
