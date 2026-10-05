# Building KF2-VR from source

The public source export is for code review and development. It is not a
self-contained playable release or a one-command clean build. The build uses
locally installed game/SDK data and generated asset inputs that are deliberately
excluded from the source export. To play, download the complete playable ZIP
from [GitHub Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).
The launcher can be audited and assembled independently of the game/VR assets.

## Audit and build the launcher

The complete shipped launcher source is public. It uses Python's standard library,
Tkinter and Windows APIs; there is no separate private launcher project or pip
dependency. The PowerShell artwork is embedded in the GUI source.

| Files | Responsibility |
| --- | --- |
| `tools/multiplayer/launcher_gui.py`, `friends.py` | Player window, game discovery, Solo/Host/Join and session cleanup |
| `tools/multiplayer/package.py` (`LAUNCHER_MODULES`) | Exact shipped module inventory and portable entry-point checks |
| `tools/multiplayer/session.py`, `native_fixture.py`, `release_state.py`, `recovery.py`, `watchdog.py` | Deployment validation, process ownership, recovery and release integrity |
| `tools/multiplayer/diagnostics.py`, `vr_config.py`, `desktop_settings.py`, `workshop_loadout.py` | Local report sanitization and preference/content handling |
| `tools/install-multiplayer-server.ps1`, `tools/multiplayer/dependencies.py`, `tools/dependency-pins.json` | Explicit server bootstrap and SHA-256-checked vendor downloads |
| `tools/play-main.ps1`, `tools/play-gui.ps1`, `Play-KF2VR.cmd` | Development-checkout entry points; the portable ZIP uses the Python GUI |

On Windows x64, install Python with Tkinter for running source tests. From a clean
public checkout, run:

```powershell
python -m unittest discover -s tools/multiplayer -p 'test_*.py' -q
python tools/multiplayer/build_launcher.py --output build/launcher-audit
build/launcher-audit/app/runtime/python.exe -B build/launcher-audit/app/tools/multiplayer/launcher_gui.py --self-check
```

Choose a new output folder for each build; existing folders are never overwritten.
The builder downloads CPython 3.14.3's official Windows embeddable ZIP and its
official Tcl/Tk MSI component from the exact URLs in `tools/dependency-pins.json`.
Both cached and downloaded archives must match their SHA-256 pins before extraction.
Cache them under `build/multiplayer/` with the filenames in that JSON for an offline
build. The MSI is extracted with `msiexec /a /qn` into a temporary directory; it is
not installed. Python/Tk and their licenses remain local to the output folder.
No SDK, game files, Steam login, personal profile or authoring scene is required.

This produces **a launcher audit build**, with `Start KF2-VR.cmd`, declared launcher
sources, defaults, runtime, licenses and a relative-file hash inventory in
`app/launcher-build.json`. It runs the existing portable help/UI checks outside
the checkout with a temporary preference directory. These checks start no game,
server, Workshop downloads or synthetic gameplay. Bytecode caches are suppressed
so absolute build paths do not enter the assembled kit.

The audit build omits playable DLLs, game packages and `release.json`; use it to
inspect or change the UI, not to launch the mod or replace files in a release.
Full playable packaging still requires the matching compiled inputs below.
Do not bypass integrity or game-compatibility checks when integrating changes.
Local game discovery reads Steam/OpenXR registry paths. Actual play deploys the
mod temporarily and maintains recovery records; hosting can explicitly download
the server from Valve, and selected Workshop content can download through Steam.
**Save logs for a bug report** creates sanitized local copies for user review;
it does not upload them automatically. Review those paths and controls in the
source when auditing safety; public source and passing tests are not a blanket
security guarantee.

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
the exact current VR art from a clean public checkout remains unfinished work.

### Closing the full-mod build gaps

The following work is still required before advertising a reproducible full-mod
build. It does not block the independent launcher build above.

1. Pin the supported extractor and PSK/Blender importer versions and document the
   exact source packages, object names and commands for exporting the KF2 hand rig
   and stock reload/weapon inputs from the builder's own supported Steam game/SDK.
   Generate outputs locally; do not commit extracted game packages or caches.
2. Inspect the current `KF2VR-Horzine-Hands.blend` scene and its linked/packed source
   textures for personal metadata, external paths and provenance. Publish only
   reviewed authored inputs whose distribution is permitted, or supply an authored
   replacement and regeneration recipe. The current stock-hand cutter does not
   recreate the authored scene. No such scene/textures are included today.
3. Document the hand/watch/export staging sequence and revision parameters,
   followed by reload mesh generation, SDK import and `build-hand-assets.ps1`.
   Generated mesh hashes/build receipts should come from each local build rather
   than copied private machine records. RAVEN-7 rig/grip generation needs this skin.
4. Document legitimate local Portal/Source/Engineer source requirements and
   extraction/import commands, or decouple optional packages from the default
   script compile. Launching with optional gameplay OFF currently leaves compile
   dependencies in place. Review custom installation-path support separately.
5. Build from a clean public checkout using only the documented supported tools
   and locally owned game/SDK inputs, then run the existing CPU/launcher/package
   gate. Record remaining gaps here; retain headset and real online acceptance.
   Publish future playable changes as a new release without replacing old ZIPs
   or moving their tags.
