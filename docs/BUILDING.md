# Building KF2-VR from source

The public source export is for code review and development. It is not a
self-contained playable release. The full source builder uses your own installed
game/SDK data and generates asset inputs locally; those inputs are deliberately
excluded from the source export. To play, download the complete playable ZIP
from [GitHub Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).
The launcher can be audited and assembled independently of the game/VR assets.

## Audit and build the launcher

The complete shipped launcher source is public. It uses Python's standard library,
Tkinter and Windows APIs; its source and module inventory are included here. The PowerShell artwork is embedded in the GUI source.

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
This launcher audit route requires no game/SDK or Steam login.

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
Local game discovery reads Steam library manifests/registry paths and Epic
completed-install manifests; OpenXR runtime discovery reads its registry path. Actual play deploys the
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

The adapter and shared launcher recognize exact Steam and Epic executable hashes
in `tools/multiplayer/game_install.py`. Epic runtime support is experimental Solo
VR through its official launcher; there is no Epic SDK build route. Compile the
shared script packages with the supported Steam SDK below. Epic limits and manual
Launch Options cleanup are in [READ ME FIRST](public-alpha/READ-ME-FIRST.txt).

Install your own Steam KF2 and KF2 SDK. The build scripts compare game/editor
hashes with `docs/intake/install_manifest.json`; this source targets Steam game
build **13316885** (KFGame.exe file version **1.0.8767.0**) and Steam SDK build
**13316905**, with the exact executable hashes in that file. A different game update
requires a compatibility update, not bypassing the check.

Use `tools/build-from-source.ps1` in a fresh checkout for a separate playable
candidate. It accepts installation/tool paths and never selects or replaces an
existing release. Install Blender **5.2.1 LTS**, Python with Tkinter, Git, CMake
and Visual Studio's C++ desktop tools/Windows SDK and MASM. Windows supplies the
Arial/Bahnschrift/Consolas fonts used by the procedural watch artwork. You also
need your own Portal 2 installation: the current VR script compile references
Portal assets even when Portal gameplay is OFF. Source/Engineer assets belong
to separate optional content builders and are not required by this default route.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/build-from-source.ps1 `
  -GameRoot 'C:\Games\KillingFloor2' `
  -Portal2Root 'C:\Games\Portal 2' `
  -Blender 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe'
```

Supply `-Python` and `-CMake` for nonstandard tool locations. Close KF2, its
editor and dedicated servers before building. The builder validates game/SDK
executable hashes, fetches pinned public dependencies, extracts only required
KF2/Portal inputs, generates hand/watch/reload/RAVEN-7/Portal art, imports packages
through the SDK, builds native/scripts, runs the fast CPU/launcher gate and
packages with `--no-select`. Logs and outputs stay under ignored `build/` and
`extract/`; installed game content and user profiles remain untouched. Blender
uses factory preferences and pinned addon source, not a global addon installation
or a saved authoring scene. An idle Blender UI can remain open.

The builder prints the candidate folder and ZIP paths. Extract that ZIP into a
fresh folder and open **Start KF2-VR**. The development CMD launcher needs a
selected package; this source builder deliberately does not select one.

Dependency URLs, commits and archive SHA-256 pins are in
`tools/art-dependency-pins.json`. `tools/prepare_art_dependencies.py` verifies
downloaded/cached PSK importer 9.1.3, its Python format library, UModel and SDL
before use, and requires clean exact-pinned SourceIO/OpenXR Git checkouts.
`tools/extract_kf2_build_assets.py` derives the narrow package/object inventory
from the public reload generators, records local input hashes, and refuses
conflicting existing extracts. UModel is a pinned historical executable from its
author's public repository; its digest is the checked file pin, not a vendor
signature. These tools/downloads and extracted game data are not source-export
assets. Retain their upstream licences locally.

The procedural hand/watch route uses authored revision 59 from public generator
source. It creates an authoring scene locally, skins it to the locally extracted
KF2 rig, then bakes and exports it. The first public alpha used a later
hand-art revision. A source-built candidate therefore differs in art and build
metadata; this recipe does not promise a byte-identical recreation of that ZIP.
Check a source-built candidate in a headset before relying on its gameplay.

For subsequent development builds with prepared inputs and the default installation,
close KF2/editor/server and run:

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

## Full build inputs

| Input / location | Existing route | Default build dependency / status |
| --- | --- | --- |
| KF2 hand rig, skin textures and stock reload/weapon inputs | `tools/extract_kf2_build_assets.py` with pinned UModel | Extracted from the builder's supported installed KF2; no whole game packages are copied into source |
| Authored hand/watch scene | `tools/generate_public_hands.py` through `tools/blender_build_runner.py` | Created from public procedural source and local rig/textures; no ignored developer scene or cache required |
| `build/hand-meshes/VRFloatingHands.psk`, `.fbx`, `VRFloatingHands.json`, wristwatch mesh, hand/watch textures | Above export plus `tools/generate_wristwatch.py`; receipts checked by `tools/script-sources.ps1` | Required by default hand build; generated output intentionally excluded |
| Reload meshes/stock weapon extracts and `build/hand-meshes/` props | `tools/generate_reload_props.py` | Required by default hand build despite Physical reloads being OFF at runtime; the sound mapping source is already included |
| `build/hand-assets/KF2VRHands.upk` and `build.json` | `tools/build-hand-assets.ps1` | Required for the current VR script compile/package; generated game-derived package |
| `build/portal-assets/KF2VRPortal.upk` and `build.json` | `tools/extract_portal_assets.py`, `tools/build_portal_meshes.py`, `tools/prepare_portal_asset_config.py`, `tools/build-portal-assets.ps1` | Local Portal 2 and pinned SourceIO; current IncludeVRClient compile requires this package; Valve-derived inputs remain local |
| Source/Engineer packages and receipts for separate optional content | `tools/extract_source_weapons.py`, `tools/build-source-assets.ps1`, `tools/extract_engineer_assets.py`, `tools/build-engineer-assets.ps1` | Separate optional content route, outside `build-from-source.ps1` and the default aggregate build |
| RAVEN-7 meshes and textures | Included `assets/weapons/raven7/material-atlas-v2.png`; `tools/raven7_model.py`, `tools/raven7_rig.py`, `tools/raven7_grip.py`, `tools/generate_tomahawk.py` | Generators/atlas included; rig/grip generation still depends on the floating-hand skin above |

`tools/build-multiplayer-scripts.ps1` without `-IncludeVRClient` builds only
KF2VRNet source. It does not produce the shared VR client or a playable ZIP.
There is no current documented switch in `tools/build-kf2vr.ps1` that removes
these art dependencies and still builds the complete default VR package.
Turning optional gameplay OFF at launch does not remove compile-time asset needs.
The source builder above supplies the default art dependencies locally. Exact
recreation of the first alpha's later hand-art revision remains outside this route.

### Closing the full-mod build gaps

Future work is to remove the mandatory Portal 2 prerequisite by separating its
optional compile-time content, and to provide reviewed authored inputs or a
public procedural recipe for the first alpha's exact later hand-art revision.
Headset and real online sessions remain the acceptance checks for source-built
candidates.

Experimental DLSS builds: review `third_party/NVIDIA-DLSS-LICENSE.txt`, run `tools/fetch-ngx.ps1`, then `tools/build-kf2vr.ps1 -NoSelect -Dlss`. Without `-Dlss`, no NGX SDK/runtime is required. CPU DLSS math checks run in either build. See `docs/DLSS.md` for limitations and publication obligations.

## Optional experimental DLSS build

The default SDK-free adapter uses the Off stub. For the optional DLSS-enabled build, fetch the official pinned SDK with `tools/fetch-ngx.ps1`, then use `tools/build-kf2vr.ps1 -NoSelect -Dlss`. `tools/ngx-pins.json` pins the SDK commit, consumed files and runtime. NVIDIA SDK/runtime binaries are not included in this source export. Retain the NVIDIA and AMD licence files. Public distribution requires resolving the publication obligations described in [DLSS](DLSS.md); a successful build or bundled notice does not resolve them.
