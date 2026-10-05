# Building KF2-VR from source

The public source export is for code review and development. It is not a
self-contained playable release or a one-command clean build. The build uses
locally installed game/SDK data and generated asset inputs that are deliberately
excluded from the source export. Use an invited playable ZIP for the alpha.

## Native adapter and CPU tests

Use Windows x64, Visual Studio with the C++ desktop tools/Windows SDK and MASM,
CMake 3.24 or later, PowerShell and Python. Place the pinned OpenXR SDK under
`third_party/openxr-sdk` as described in [dependency pins](../third_party/VERSIONS.md). The curated
export includes the small pinned MinHook/HDE source snapshot with its licence
under `third_party/minhook`. OpenVR is optional for xrprobe.
Keep upstream licences. Do not substitute different dependency bytes silently.

From a Visual Studio x64 developer shell:

```powershell
cmake -S . -B build/native -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
```

The embedded bell WAVs are included with their CC0 provenance notice. The
current RAVEN-7 generated material atlas is also included. No game-derived mesh/package is included.

Without MinHook/OpenXR, CMake skips the adapter DLL and still builds eligible
CPU tests. Passing those tests does not mean the adapter DLL was built.

## Scripts, assets and playable packaging

Install your own Steam KF2 and KF2 SDK. The build scripts compare game/editor
hashes with `docs/intake/install_manifest.json`; this source targets Steam game
build **13316885** (KFGame.exe file version **1.0.8767.0**) and Steam SDK build
**13316905**, with the exact executable hashes in that file. A different game update
requires a compatibility update, not bypassing the check.

The current tools use example installation defaults such as
`D:\SteamLibrary\steamapps\common\killingfloor2`. Supply `-GameRoot` on the
individual script builders where available. The aggregate builder does not
forward a GameRoot override; inspect its component parameters for a custom
installation. It also expects CMake in its standard Windows install location.

Playable builds need Blender (current tools expect Blender 5.2 at its standard
Windows location), the applicable PSK import tooling, local game extracts,
floating-hand/watch/reload mesh inputs and receipts, and Portal/Source/Engineer
asset packages and receipts used by the combined script build. These are not
included. Asset tools
under `tools/` describe the generation/import steps; this export does not
claim that a fresh clone can reconstruct the current private art automatically.

Once local prerequisites and generated inputs exist, close KF2/editor/server and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/build-kf2vr.ps1
```

This builds affected assets/native/scripts, runs the fast CPU/launcher gate,
packages the results and selects `build/multiplayer/current-release.json`.
Builds run sequentially under a shared mutex. Preserve previous release folders,
server/Workshop caches and user data. Launch with `Play-KF2VR.cmd` and keep the
launcher open for cleanup. See [launch options](../PLAY-MULTIPLAYER.md).

For launcher/package checks without a game session:

```powershell
python -m unittest discover -s tools/multiplayer -p 'test_*.py' -q
```

Headset play and real online testing establish behavior. Do not start runtime
automation as a routine build step; repository rules are in [AGENTS](../AGENTS.md).

## Exact remaining asset inputs

| Input / location | Existing route | Default build dependency / status |
| --- | --- | --- |
| `extract/arms-audit/CHR_1P_Arms_MESH/SkeletalMesh3/Wep_1stP_Naked_Hands_Rig.psk` | Locally export the KF2 naked-hand rig; `tools/generate_floating_hands.py` can cut it and write PSK/FBX | Game-derived; an exact clean extraction recipe/tool pin is not supplied here |
| Current `KF2VR-Horzine-Hands.blend` authoring scene and source textures | `tools/export_reference_hands.py`, then `tools/stage_watch_candidate.py` and the relevant hand tools | Current private hand art depends on this ignored scene; missing public authoring input, not automatically reconstructed by the older stock-hand cutter |
| `build/hand-meshes/VRFloatingHands.psk`, `.fbx`, `VRFloatingHands.json`, wristwatch mesh, hand/watch textures | Above export plus `tools/generate_wristwatch.py`; receipts checked by `tools/script-sources.ps1` | Required by default hand build; generated output intentionally excluded |
| Reload meshes/stock weapon extracts and `build/hand-meshes/` props | `tools/generate_reload_props.py`, `tools/reload_sound_map.py`, `tools/build-reload-assets.ps1` | Required by default hand build despite Physical reloads being OFF at runtime; local game-derived inputs |
| `build/hand-assets/KF2VRHands.upk` and `build.json` | `tools/build-hand-assets.ps1` | Required for the current VR script compile/package; generated game-derived package |
| `build/portal-assets/KF2VRPortal.upk` and `build.json` | `tools/extract_portal_assets.py`, `tools/prepare_portal_asset_config.py`, `tools/build-portal-assets.ps1` | Portal play is optional, but current IncludeVRClient compile copies/requires this package; Valve-derived inputs remain local |
| Source/Engineer packages and receipts for combined optional content | `tools/extract_source_weapons.py`, `tools/build-source-assets.ps1`, `tools/extract_engineer_assets.py`, `tools/build-engineer-assets.ps1` | Needed by the combined content/art path, not by native-only compilation; runtime features remain optional |
| RAVEN-7 meshes and textures | Included `assets/weapons/raven7/material-atlas-v2.png`; `tools/raven7_model.py`, `tools/raven7_rig.py`, `tools/raven7_grip.py`, `tools/generate_tomahawk.py` | Generators/atlas included; rig/grip generation still depends on the floating-hand skin above |

`tools/build-multiplayer-scripts.ps1` without `-IncludeVRClient` builds only
KF2VRNet source. It does not produce the shared VR client or a playable ZIP.
There is no current documented switch in `tools/build-kf2vr.ps1` that removes
these art dependencies and still builds the complete default VR package.
Turning optional gameplay OFF at launch does not remove compile-time asset needs.
Native-only review/build is the usable independent path above. Reconstructing
the exact private VR art from a clean public checkout remains unfinished work.
