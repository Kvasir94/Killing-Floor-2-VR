# Launch options and multiplayer

The player window detects completed Steam and Epic installations and displays
the available stores. Auto selects a sole installation or the last valid folder
used in this extracted release; with multiple installations and no valid saved
folder, choose Steam or Epic explicitly. A manually located exact build remains
usable without a store manifest. Missing saved folders fall back to discovery;
an explicit store choice never falls back to another store. Exact executable
hashes are checked before any native deployment. Use `-Store Auto|Steam|Epic`
and `-GameRoot` for the same selection on the command line.

Epic offers experimental Solo VR through manually pasted session Launch Options
in the official Epic launcher. Host, Join, Desktop, motion recording and highlight
logging are unavailable. Steam offers Solo/Host/Join in VR or Desktop. Epic's
current menu-first route still needs headset feedback; earlier partial gameplay
checks do not establish overall acceptance.

From the repository root on **main**, Double-click **Play-KF2VR.cmd** to open the launcher window.
Pick VR or desktop, map, difficulty, match length, mods and optional VR graphics/scale,
then press Play to host a dedicated server and join it. Keep Steam running, connect the headset/controllers, and select
your OpenXR runtime first. Choose a perk and Ready. Keep the launcher open until
you close KF2 so it can restore temporary DLLs and save VR preferences.

The Session page's first choice sets the kind of match:

- **HOST ON THIS PC** starts the dedicated server on this PC and joins it: the
  multiplayer path, with replication. Friends can join. Everything below
  describes this mode.
- **TRUE SOLO** is a standalone single-player match: stock Survival with the
  VR mutators, no server, no network and no replication. Use it to test
  features without replication involved. It runs the same selected package as Host
  (`build/multiplayer/current-release.json`),
  plays only the stock maps installed in the game's `BrewedPC`, and ignores mods
  and the inventory slowdown. The last kind chosen is remembered in
  **%LOCALAPPDATA%/KF2VR/Profile/session-type.txt**.

In a headset session, **LOCAL MATCH** on the VR menu starts the same kind of
standalone match. It cycles through every installed Survival map with MAP and
PREVIOUS MAP.

The window groups the same choices as the text menu onto three pages - Session
(play mode, map, difficulty, match length), Headset (VR graphics, render scale,
the experimental inventory slowdown) and Mods - with the current selection
always shown beside the artwork. The text menu is still there under `-Menu`,
for a console session or a machine without a desktop.

Its artwork is the player's own installed game, read at run time and never
copied into this repository or a release package: the Wallpaper folder, the
official logo from the local Steam library cache, and optional locally extracted HUD artwork. Each is optional and the window draws its own equivalent when a
file is missing.

For the test map, double-click **[Play-KF2VR-TestMap.cmd](Play-KF2VR-TestMap.cmd)**.
It opens the same window with Remilly already selected and accepts the same
additional options, such as `-Desktop` or `-EyeRenderPercent 75`.
Explicit command-line arguments launch directly; add `-Gui` to review/change
those initial choices in the window, or `-Menu` for the text menu. Quit leaves
without starting a game.

Ordinary launcher selections are remembered. Local agent test control is always OFF unless explicitly selected for this launch. Play mode, map, difficulty, match
length, VR graphics, the experimental inventory slowdown, mods, damage popups
and test-map scaling are saved to
**%LOCALAPPDATA%/KF2VR/Profile/launcher.json** on each host launch. Solo saves the
common mode/map/difficulty/length/graphics choices without overwriting hosted
mods, popups, scaling, slowdown or grabbing preferences. The next launch starts
from those choices; headset render scale is saved with the in-headset
preferences instead. The packaged launcher's Play solo / Host > Headset and
Settings > Comfort and graphics both label this **Render scale**. They edit the
same setting as in-game VR Controls > Graphics; choosing **Keep my last setting**
on the launch page uses that saved value. A switch given on the command line overrides the saved
value for that launch and is then itself remembered.

The launcher uses **build/multiplayer/current-release.json** and prints the
release name. It verifies package hashes and build/runtime source fingerprints.
Offline multiplayer test edits do not invalidate the playable package. If a
build/runtime source changed after packaging, the menu offers **1. Play this build
anyway (allow stale)** or **Q / Enter. Quit** before the game options. Double-click
either CMD shortcut and tick **Play this older build anyway** in the window;
the console menu uses option 1. Solo and Host have the same freshness gate. This choice
applies to that launch. Direct launches without a menu still stop by default;
use `-AllowStale` to override them. The override warns about source
differences and still checks package integrity. Old releases stay intact.
Build current source with **tools/build-kf2vr.ps1**. Compilation and fast CPU checks do
not establish headset acceptance.

## Local agent test control (Solo VR, default OFF)

In the portable **Start KF2-VR** window, choose **VR headset**, then **Play solo**
and check **Local agent test control (Solo VR only; this launch)**. The checkbox
starts OFF on every form and is disabled for Host and Desktop. It applies only
to this launch and is never saved. The development launcher's **TEST CONTROL**
page exposes the same option. The command-line equivalent is
`Play-KF2VR.cmd -Solo -Vr -LocalTestControl`; `-LocalTestControl` is the explicit opt-in switch. Preparing does not enable control.
Hosted LAN and joined-server control are not implemented in this version; the
checkbox is disabled for those modes and the command line refuses them.

The owned mod marks this explicit session **UNRANKED**, without enabling the
cheat manager. Grants may exceed normal carry capacity; the full calculated
weight is reported and the stock byte weight display saturates at 255. Existing
weapons are no-ops and are never refilled. Give-all uses the installed authored
VR profile registry, resolves full class paths, and reports missing classes as
an error. Paired wrappers are recognized as existing inventory; their normal
VR hand runtime creates them. Optional perk filters use the catalog's perk
class names and do not change the player's perk.

The session ID is in the prepared driver role's `local_test_control` metadata.
Use the selected package's `tools/multiplayer/local_test_control.py` to request
`status`, `catalog`, `give-all`, `give-one`, `spawn-zeds`, or `disable`:

```powershell
python tools/multiplayer/local_test_control.py --session <launch-session-id> --player 0 status
python tools/multiplayer/local_test_control.py --session <launch-session-id> --player <reported-id> catalog
python tools/multiplayer/local_test_control.py --session <launch-session-id> --player <reported-id> give-all
python tools/multiplayer/local_test_control.py --session <launch-session-id> --player <reported-id> --argument scrake --count 2 spawn-zeds
python tools/multiplayer/local_test_control.py --session <launch-session-id> --player <reported-id> disable
```

Every request has a unique action ID and a final result receipt. A timeout is
indeterminate: inspect that ID's receipt and audit, and never resend it with a
new ID. Reusing an ID for a different request is rejected. Commands use a local
session folder under the game's temporary directory; there is no listener or
general console execution. Limits are two accepted commands per second, one
grant/spawn per game-thread timer callback, at most six zeds per request, twelve
live test zeds, 256 actions, and a thirty-minute session. Spawned zeds attack and
can damage the player. No god mode, wave reset, refill, or clear command is
provided. Disable cancels queued work and retains granted inventory and zeds;
the match stays unranked. Restart without the checkbox for ordinary play.

## Main launcher switches

All public switches for Play-KF2VR.cmd / tools/play-main.ps1 are listed here.
PowerShell's standard common parameters are also available.

| Switch | Default | Purpose and constraints | Example |
| --- | --- | --- | --- |
| `-Gui` | On for a double-click/no-argument CMD launch; otherwise off | Graphical selections before launch, including the explicit consent when source is newer than the selected package. Also works with TestMap and PrepareOnly. | `./Play-KF2VR.cmd -Gui -Difficulty Hard` |
| `-Vr` | Saved play mode; initially VR | Headset play for this session regardless of the saved mode. Rejects a combined Desktop request. | `./Play-KF2VR.cmd -Vr` |
| `-Desktop` | Saved play mode; initially VR | Same selected package, stock desktop controls; works with Solo or Host. Rejects explicit VR quality/scale. | `./Play-KF2VR.cmd -Desktop` |
| `-LocomotionPreview` | Off | Desktop inspection of the actual remote pawn; alternates roomscale and stick walking with idle pauses. No headset needed. Rejects Solo, Vr, Gui, Menu and TestMap. | `./Play-KF2VR.cmd -LocomotionPreview` |
| `-Solo` | Off (host); the window remembers the last kind | Standalone match from the selected package; no dedicated server installation or network needed. Shares saved mode, graphics, eye scale and match options, menus, PrepareOnly and AllowStale with Host. Installed client maps only; rejects Remilly/Workshop maps, TestMap, explicit TestMapPlayers, InventoryFocus On and MultiplayerGrabs On. Ignores mods. | `./Play-KF2VR.cmd -Solo -Vr -Map KF-Outpost -Difficulty Hard` |
| `-TestMap` | Off (Burning Paris) | Remilly's Workshop map with the normal VR game/controller. Downloads if needed. | `./Play-KF2VR.cmd -TestMap` |
| `-Menu` | Off | Text menu in the console instead of the window; same selections before launch, including play-anyway/quit when source is newer than the selected package. Also works with PrepareOnly. | `./Play-KF2VR.cmd -Menu -Difficulty Hard` |
| `-Map` | Saved; initially KF-BurningParis | KF- map name. Host offers common installed maps, Remilly and managed Workshop maps; Solo offers installed client maps only. An unavailable saved hosted map falls back to the first installed Solo map; an explicit unsupported Solo map fails. No extension/path/URL options. Rejects a conflicting TestMap selection. | `./Play-KF2VR.cmd -Map KF-TF2_Upward` |
| `-Difficulty` | Saved; initially Normal | Normal, Hard, Suicidal, HellOnEarth. | `./Play-KF2VR.cmd -Difficulty Suicidal` |
| `-GameLength` | Saved; initially Short | Short (4 waves), Medium (7), Long (10), then boss. | `./Play-KF2VR.cmd -Map KF-Outpost -Difficulty Hard -GameLength Long` |
| `-Mods` | Saved VR selection; initially `none`. Use `legacy` for the UKFP preset. Desktop starts with none. | Comma-separated catalog keys, `none`, or `legacy`. Selecting a dependency feature also enables UKFP. Normal VR host launches/preparations save the selection across releases. | `./Play-KF2VR.cmd -Mods ukfp,yas` |
| `-DamagePopups` | Saved Desktop preference; initially On | On/Off for Desktop with UKFP. In VR, native 3D world-space damage numbers (`VRDamagePopups`) are rendered over Zeds' heads with stereoscopic depth instead of UKFP's flat overlay. | `./Play-KF2VR.cmd -Desktop -Mods ukfp -DamagePopups On` |
| `-TestMapPlayers` | Saved; initially 6 | Host only: 0 for actual players, 6 for UKFP faked-player scaling on Remilly only. Effective only with UKFP selected. | `./Play-KF2VR.cmd -TestMap -TestMapPlayers 6` |
| `-InventoryFocus` | Saved; initially Off | On/Off. Experimental host-controlled shared slowdown while a VR wheel is open. Applies to all participants, yields to Zed Time, and is available to VR or Desktop hosts. | `./Play-KF2VR.cmd -InventoryFocus On` |
| `-MultiplayerGrabs` | Saved; initially Off | On/Off. Experimental host setting followed by every VR player. Solo keeps its separate ordinary grabbing setting; On is incompatible with Solo. | `./Play-KF2VR.cmd -MultiplayerGrabs On` |
| `-PortalGun` | Saved; initially Off | On/Off. Solo only: offers the experimental Portal Gun at the trader. Portals are local-only, so Host/Join never offer the gun and the switch is rejected there. See-through portals need the default one-thread renderer; with `-ThreadedRender` the portal shows its flat colour fill. | `./Play-KF2VR.cmd -Solo -Vr -PortalGun On` |
| `-EyeRenderPercent` | Saved value; initially 75 | Integer 50-100, per-eye width/height scale. Explicit value overrides saved scale. VR only. | `./Play-KF2VR.cmd -EyeRenderPercent 75` |
| `-HeadsetPreset` | None | Provisional `quest2`, `quest3`, `quest3s`, `index`, `high-resolution` graphics/eye-scale bundle. Explicit quality/scale wins; resulting settings remembered. VR only. | `./Play-KF2VR.cmd -Vr -HeadsetPreset quest2` |
| `-VrQuality` | Saved; initially `performance` | `quality`, `balanced`, `performance`. Session preset, separate from eye scale. VR only. | `./Play-KF2VR.cmd -VrQuality performance` |
| `-ThreadedRender` | Saved; initially Off | On/Off. Experimental, VR only. Runs without `-onethread`: UE3's render thread draws one frame while the game ticks the next. The portal gun's see-through view works only one-threaded (Off); with On its portals keep their flat colour fill. A checkbox on the Headset page of both launcher windows. | `./Play-KF2VR.cmd -Vr -ThreadedRender On` |
| `-PrepareOnly` | Off | Verify and prepare isolated configs; no game/server processes or DLL deployment. Remilly must be cached; other Workshop content can be imported from existing Steam downloads. Missing downloads fail before launch. | `./Play-KF2VR.cmd -PrepareOnly` |
| `-AllowStale` | Off | Allow the selected package to differ from current repo source, with a visible warning. Still verifies the manifest and every packaged file; does not rebuild, select a different release, or permit damaged packages. Works with Menu, TestMap and PrepareOnly. | `./Play-KF2VR.cmd -AllowStale -Menu` |
| `-GameRoot` | `D:\SteamLibrary\steamapps\common\killingfloor2` | Matching, fingerprinted KF2 installation. | `./Play-KF2VR.cmd -GameRoot 'E:\SteamLibrary\steamapps\common\killingfloor2'` |
| `-FrameTimings` | Off | VR performance log in the session native.log; same as packaged `--frame-timings`. | `./Play-KF2VR.cmd -Vr -FrameTimings` |
| `-LocalTestControl` | Off, this launch only | Solo VR developer controls; makes the session unranked, never saved; rejects Host/Desktop. | `./Play-KF2VR.cmd -Solo -Vr -LocalTestControl` |
| `-Help` | Off | Print usage without requiring an installed/selected build. | `./Play-KF2VR.cmd -Help` |

Host server: **build/multiplayer/server** (install using tools/install-multiplayer-server.ps1).
Solo does not require that installation; the window remains usable without it.
Workshop cache: **build/workshop-cache**. Logs/copied configs:
**selected release/sessions/**. Original KF2 user config is preserved. Do not
overlap another KF2/editor/fixture session.

Desktop sessions play with the player's own KF2 settings: resolution/window mode,
controls, sensitivity, graphics, voice chat and the stock screenshot/save
locations come from their normal KF2 config (only connection settings such as
VAC, password and content paths are managed). Settings changed in-game during a
desktop session are saved to **%LOCALAPPDATA%/KF2VR/Profile/desktop-settings.json**
and carried into the next desktop session; changing the same setting later in
stock KF2 takes precedence. VR sessions keep their fixed 1280x720 mirror window.
Voice (Vivox) is always initialised for player clients, VR and desktop: KF2's
Steam lobby code crashes at the menu without it.

## In-headset settings

Open the VR menu with the controller Menu button or the two-stick click chord.
Choose **VR SETTINGS > GRAPHICS**. **RENDER SCALE -** and **RENDER SCALE +**
change it by 5 points within 50-100; they stop at the limits. The applied percentage and
per-eye dimensions appear below it. It applies during play and is saved for the
next launch. Stock desktop screen percentage is separate.

**VR SETTINGS > LOCOMOTION AND COMFORT** contains movement hand/direction,
**MOVEMENT: SMOOTH / TELEPORT**, snap/smooth turning, snap angle, smooth
sensitivity and stick crouch. Movement-stick click requests sprint in Smooth mode.
**INTERACTION** contains dominant hand, transfer/brace and support grip, reload mode
and holsters. **MENU AND INTERFACE** sets pointer/panel placement and recenter;
**CALIBRATION** sets weapon fit, captured height and chest zones.
Initial values are **30-degree snap** and **50% smooth sensitivity**; old zero values
are repaired. Solo/network defaults come from **tools/vr-defaults.json**.
In-headset control and calibration preferences persist in
**%LOCALAPPDATA%/KF2VR/Profile/KFGame.ini**, including ones with no shipped
default, such as aim fit, hand calibration and selector favourites. Diagnostic,
probe, replay and capture flags are deliberately not preferences and never cross
into the profile or back out of it. Player changes are written to session copies and the VR sections are saved
back into the profile after exit. The original stock KF2 config stays intact.
Profiles carry `[KF2VR.Profile] Revision=2`. A profile written before that could
never hold an in-game choice, so its stale `MovementHand=1` is reset once to the
shipped left hand; a later right-hand choice is saved normally.

Changes to the nine in-game quality rows (environment, character, effects,
texture quality/filtering, shadows, bloom, volumetric lighting and light shafts)
are saved separately in **%LOCALAPPDATA%/KF2VR/Profile/vr-graphics.json** after
the game exits. Solo, Host and Join use those same choices, including experimental
Epic Solo, across extracted packages. Only supported quality values changed during
play are saved; display dimensions, connection settings and comfort overrides
are excluded. Leave **Graphics > Keep my last settings** selected to retain them.
Choosing a quality preset, `-VrQuality` / `--vr-quality`, or a headset preset
explicitly starts that preset without older custom quality edits; after playing,
subsequent launches retain any new edits. `-PrepareOnly` changes no saved graphics
profile. For example, `./Play-KF2VR.cmd -Solo -Vr` keeps the last settings;
`./Play-KF2VR.cmd -Solo -Vr -VrQuality performance` starts Performance again.

Every session copy of KFEngine.ini (hosted server, player client, replay teammate)
raises KF2's network rate caps to 40000 bytes/s: `[IpDrv.TcpNetDriver]
MaxClientRate` and `MaxInternetClientRate` (stock 15000/10000) on the server side,
`[Engine.Player] ConfiguredInternetSpeed` and `ConfiguredLanSpeed` (stock
10000/20000) on the client side. Six VR players' pose streams need roughly
15-22 kB/s per client. A client joining a server the launcher did not configure
is still held to that server's caps. Above 10000 a stock client also sends
movement updates up to twice as often.

All VR quality tiers disable desktop frame smoothing, VSync, blur/DoF, temporal
and post-process AA, AO/HBAO, screen-space reflections, lens flares and grain.
`quality` keeps stock detail/shadows; `balanced` reduces draw distance and shadow
filter work; `performance` also reduces mesh/particle detail and disables dynamic
and light-environment shadows and static decals. VR comfort status indicators
come from VRComfortEffects and the stereo renderer independently of those
desktop effect switches. The opt-in headset bundles start Quest 2/3/3S at
`performance` / 75%, Index at `balanced` / 100%, and higher-resolution PCVR
(such as Reverb G2 or Vive Pro 2) at `performance` / 65%. These are provisional
PC workload starting points, with no measured device guarantee. They change
neither runtime refresh nor Quest streaming resolution/bitrate. The default
remains saved graphics, initially `performance` / 75%; the bundle name is not
remembered, so later in-headset changes are retained. Adjust these starting points to your headset and PC.

## Test map

`-TestMap` selects **KF-Remilly_Test_Map**, Workshop item **1337395223**.
The map itself has no custom game/mutator requirement. The author's optional
six-player HP command uses Controlled Difficulty Legacy and DamageDisplay.
[Workshop source](https://steamcommunity.com/sharedfiles/filedetails/?id=1337395223).

Hidden SteamCMD downloads
Remilly into the cache; the launcher checks its Unreal package header, supplies
explicit client/server content paths, and hashes it into the session receipt.

With UKFP selected, Remilly receives `?FakePlayers=6` by default, while ordinary
maps receive `?FakePlayers=0`. UKFP fakes the player count for health and other
difficulty/population calculations; it is broader than CD's individual HP flags.
The game remains `KF2VRNet.KF2VRNetGame`. No undocumented test-map menu is added.

## Workshop mods and maps

Launcher option **8. Mods** toggles UKFP and its optional dependency features,
damage popups (Desktop only) and Remilly scaling. Choices persist in
**%LOCALAPPDATA%/KF2VR/Profile/launcher.json** across rebuilt releases. Disabling
UKFP disables these features; its required files are still installed whenever
UKFP is selected, even if an optional feature is off. Desktop mode can explicitly
select the same mods. Diagnostic replay/preview modes keep their existing
unmodded content contract and reject explicit mod feature options.

| Key | Workshop item | UKFP loader option |
| --- | --- | --- |
| ukfp | [Unofficial KF2 Patch](https://steamcommunity.com/sharedfiles/filedetails/?id=2875147606) | `?Mutator=UnofficialKFPatch.UKFPMutator` |
| friendlyhud | [FriendlyHUD](https://steamcommunity.com/sharedfiles/filedetails/?id=1819268190) | `?LoadFHUD=1` |
| yas | [Yet Another Scoreboard](https://steamcommunity.com/sharedfiles/filedetails/?id=2521826524) | `?LoadYAS=1` |
| aal | [Admin Auto Login](https://steamcommunity.com/sharedfiles/filedetails/?id=2848836389) | `?LoadAAL=1` |
| cvc | [Controlled Vote Collector](https://steamcommunity.com/sharedfiles/filedetails/?id=2847465899) | `?LoadCVC=1` |
| lti | [Looted Trader Inventory](https://steamcommunity.com/sharedfiles/filedetails/?id=2864857909) | `?LoadLTI=1` |

The launcher uses the patch's own loader order, sets disabled features to `0`,
and sets `?LoadFHUDExt=0` to avoid replacing the selected FriendlyHUD loader.
`?UnsuppressLogs=1` preserves diagnostic logs. In Desktop sessions,
`?AllowDamagePopups=1` enables UKFP's built-in damage display and the local
`bDisableDamagePopups` is set false. In VR, UKFP's flat screen-space overlay remains
suppressed to prevent binocular splitting; instead, KF2-VR provides native 3D
world-space damage numbers (`VRDamagePopups`) rendered as billboard quads in `SDPG_World`
directly over Zeds' heads with full stereoscopic depth, binocular disparity, and natural
parallax. VR damage numbers are enabled by default (`bDamagePopups=True`) and can be
configured in the launcher GUI. Parameters are verified
against the author's [guide](https://github.com/ForrestMarkX/UKF2P/blob/main/UKFPGuide.txt)
and [loader source](https://github.com/ForrestMarkX/UKF2P/blob/main/Src/UnofficialKFPatch_Proxy/Classes/UKFPMutator.uc).

The host activates mutators. Clients preload the same required packages and
receive the host's replicated features; adding a mutator to a join URL does not
activate it on a remote server. Hosts and friends should select the matching
loadout; remote hosts retain authority over damage tracking and fake players.

Each selected item is imported from Steam's Workshop downloads, or downloaded
with hidden SteamCMD when absent. The launcher checks required package names,
Unreal headers and hashes, and stages content in **build/workshop-cache**.
Both roles use those same files through explicit package/localization paths.
Server configs list the Workshop IDs under
`[OnlineSubsystemSteamworks.KFWorkshopSteamworks]`; both roles put
`OnlineSubsystemSteamworks.SteamWorkshopDownload` first in `DownloadManagers`.
A changed cache fails before launching instead of mixing versions. If staged files
are missing but the local Steam copy exactly matches the cache receipt, the
launcher restores that staged entry before continuing.

Custom INIs use KF2's `-CONFIGSUBDIR=KF2VR/<session>/<role>` in new subdirectories
under the relevant install/user Config folders. Original base INIs stay intact.
YAS/CVC receive the guides' `Version=0` first-run seed. New AAL/LTI configs use
their current version-2 defaults with empty admin/removal lists, avoiding example
admin identities and LTI's example dual-9mm removal. Existing server custom
settings are preserved. Every session records the exact paths and hashes in
`run.json`; its atomic updates tolerate short-lived watchdog file locks. Preparing
configs is not proof of engine loading or VR compatibility.

| Map selector name | Workshop item |
| --- | --- |
| KF-TF2_Upward | [Upward](https://steamcommunity.com/sharedfiles/filedetails/?id=3295814646) |
| KF-Edge_Of_Reality | [Edge of Reality](https://steamcommunity.com/sharedfiles/filedetails/?id=1150705478) |
| KF-TF2_Gorge | [Gorge](https://steamcommunity.com/sharedfiles/filedetails/?id=3274600667) |
| KF-TF2_Harvest | [Harvest](https://steamcommunity.com/sharedfiles/filedetails/?id=1300634093) |
| KF-MountainPass_zfix | [Mountain Pass](https://steamcommunity.com/sharedfiles/filedetails/?id=857015700) |
| KF-BikiniAtoll | [Bikini Atoll](https://steamcommunity.com/sharedfiles/filedetails/?id=643383080) |

```powershell
./Play-KF2VR.cmd -Menu -TestMap
./Play-KF2VR.cmd -Map KF-TF2_Gorge -Mods ukfp,yas -DamagePopups On
./Play-KF2VR.cmd -Mods none
```

## Packaged host/join CLI

From an extracted ZIP the release lives in `app/`; the player window runs:

```powershell
./app/runtime/python.exe app/tools/multiplayer/friends.py --host --vr
./app/runtime/python.exe app/tools/multiplayer/friends.py --vr --address 192.168.1.20 --password example
./app/runtime/python.exe app/tools/multiplayer/friends.py --help
```

All public packaged CLI switches:

| Switch | Default | Purpose and constraints |
| --- | --- | --- |
| `--solo` | Off | Standalone Survival with VR mutators; no server download. Rejects hosted/test-map/mod-only choices. |
| `--multiplayer-grabs` / `--no-multiplayer-grabs` | Saved; initially Off | Host setting followed by all VR players; ordinary Solo retains its separate grab preference. |
| `--breacher` / `--no-breacher` | Saved; initially Off | Requires a matching package that includes the optional Breacher content. |
| `--local-test-control` | Off, this launch only | Solo VR developer controls; unranked, never saved; rejects Host/Desktop. |
| `--host` | Off (join) | Start local dedicated server and join 127.0.0.1. |
| `--menu` | Off | Interactive host menu; requires host and rejects replay/preview modes. |
| `--map` | Saved; initially KF-BurningParis | Installed map name; requires host. KF-Remilly_Test_Map also selects the managed Workshop download. |
| `--difficulty` | Saved; initially normal | normal, hard, suicidal, hellonearth; requires host. |
| `--game-length` | Saved; initially short | short (4), medium (7), long (10 waves), then boss; requires host. |
| `--inventory-focus` / `--no-inventory-focus` | Saved; initially Off | Host-only experimental shared slowdown while a VR wheel is open. Applies to all participants and yields to Zed Time. Enable or disable explicitly; joins may omit it or use `--no-inventory-focus`. |
| `--portal-gun` / `--no-portal-gun` | Saved; initially Off | Solo only: offer the experimental Portal Gun at the trader. Rejected with `--host` or a join; portals are local-only. |
| `--vr` | Off (desktop) for a join; a host with neither flag uses the saved play mode, initially VR | Live headset adapter. |
| `--desktop` | Off | Flat screen for this session, overriding the saved play mode. Rejects explicit VR quality/scale. |
| `--mods` | Saved VR selection; initially none, optional legacy preset | Comma-separated catalog keys, `none`, or `legacy`. UKFP dependencies are installed automatically. Join selections preload content; the remote host controls mutators. |
| `--damage-popups` / `--no-damage-popups` | Saved Desktop preference, initially on | UKFP server permission/local display for Desktop sessions. VR suppresses the flat overlay even when the preference is on. Requires UKFP selected. |
| `--test-map-players` | Saved, initially 6 | 0/6; requires host. Applied only to Remilly with UKFP. |
| `--test-map` | Off | Remilly; requires host and rejects replay/preview modes. |
| `--headset-preset` | None | Provisional quest2/quest3/quest3s/index/high-resolution bundle; explicit quality/scale wins. Resulting settings remembered; VR only. |
| `--vr-quality` | Saved; initially performance | quality/balanced/performance; rejected with `--desktop`. |
| `--eye-render-percent` | Saved value, initially 75 | Integer 50-100; requires VR, overrides saved scale. |
| `--frame-timings` | Off | VR only. Writes CPU stage and GPU frame times to the session's native.log every 5 s; low overhead. Without it the adapter still logs a lite `FramePacing` line every 5 s (present intervals: mean, p50/p95/p99, frames over 11.1 and 8.3 ms) from one clock read per frame, and the launcher records the game's peak working set; both feed the Save-logs summary. Packaged menu: Troubleshooting > Performance log. Main launcher: `-FrameTimings`. |
| `--threaded-render` / `--no-threaded-render` | Saved; initially Off | Experimental, VR only. Replaces `-onethread` with UE3's render thread, so game and render work overlap. The portal gun's see-through view works only one-threaded; with threaded rendering its portals show a flat fill. With `--frame-timings`, the logged stages are the render thread's only: compare frame intervals, not busy ms. Main launcher: `-ThreadedRender On`. |
| `--address` | Prompt for join code or saved address | Paste the complete `KF2VR1:` code to apply the host's address, password, game/query ports, map and mods, overriding local connection/content choices. Requires the same build. Also accepts hostname/IP without port or URL. Hosting uses 127.0.0.1. |
| `--share-address` | Public IPv4 reported by the host server | Host only. Override the address in the join code for LAN/VPN/custom hostname; no port or URL. Example: `--host --share-address 192.168.1.20`. |
| `--password` | Host: saved/generated; join: prompt | 1-64 letters, digits, underscore or hyphen. |
| `--game-root` | Saved install, Steam lookup, then prompt | Folder containing matching KFGame.exe. |
| `--server-root` | Release parent / KF2VR-Server | Dedicated server; main launcher overrides with repo server. |
| `--cache-root` | Release parent / KF2VR-Cache | Workshop cache; main launcher overrides with repo cache. |
| `--port` | 7777 | Game UDP, 1024-65000; distinct from query/client ports. Client offsets +10 and replay +20. |
| `--query-port` | 27015 | Query UDP; same range and offset constraints. |
| `--prepare-only` | Off | Prepare/check without game processes; selected test map must already be cached. |
| `--duration` | Unlimited | Bounded developer session, 5–7200 seconds after startup; unattended launches hidden. |
| `--replay-teammate` | Off | Host a separate recorded-input client; requires host. Quiet and auto-Ready by default; adds GPU load. Uses shipped controls independently of your saved preferences, with stick movement and no injected room movement. The replay needs no headset or OpenXR runtime. |
| `--replay-match` | Off | Retain enemy waves; requires replay teammate. |
| `--avatar-preview` | Off | Quiet body inspection; requires host, implies replay teammate, rejects replay-match. Add VR for headset inspection. |
| `--locomotion-preview` | Off | Requires host; implies desktop and replay teammate. Observe the actual remote pawn in a repeating 32-second cycle: 4s idle, 8s roomscale, 4s idle, 8s stick walking, 8s idle. Rejects VR, avatar-preview, replay-match, mods and test-map. No headset/runtime required. |
| `--help` | Off | Print CLI help and exit. |

For networked leg-animation inspection, run `Play-KF2VR.cmd -LocomotionPreview`.
The visible desktop camera follows the real replicated pawn; the replay client
and server run hidden. Roomscale uses the existing swept network movement path;
stick walking uses native input dispatch. Phase labels appear in game messages.
Close the visible game to stop all three processes. Add `-PrepareOnly` to prepare
without launching; this mode cannot be combined with Solo, VR, Gui, Menu or TestMap.

Examples: `--host --vr --test-map`, `--host --vr --eye-render-percent 75`,
`--host --vr --inventory-focus`,
`--host --replay-teammate --replay-match`, `--host --avatar-preview`.
F8 toggles third-person inspection in normal VR play.

LAN friends use the host's LAN address; WAN hosting may need existing port
forwarding or a gaming VPN. The launcher does not change firewall/router rules.
It verifies a password-protected, VAC-off KF2 server before connecting. Local
multi-instance tests do not validate a second Steam account or WAN conditions.

## Portable package and recovery

Download a playable ZIP from [Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases)
and extract it into a new folder. Open **Start KF2-VR**; the ZIP includes its Python
runtime and mod packages. Solo needs no dedicated-server download. Host uses the
separate free server; Join needs the host's complete password-bearing code and the
same ZIP. Share the code privately. Internet hosts forward UDP 7777/27015 and allow
KFServer through Windows Firewall; joiners need neither port forwarding nor a server.

Keep the launcher open until cleanup completes. After interruption, quit KF2 and
use **Fix a stuck session** before deleting the folder or changing releases. Recovery
preserves unknown/changed files. Never mix DLLs or bypass package/game hash checks.
**Save logs for a bug report** creates sanitized local copies; nothing uploads
automatically. Review the ZIP before sharing and keep raw logs/configs/dumps private.
See [controls and troubleshooting](docs/VR_CONTROLS.md),
[feedback](CONTRIBUTING.md) and [optional Breacher](docs/public-alpha/BREACHER.md).

### Experimental headset graphics and physical stocks

Portable Solo/Host/Join options `--dlss {off,dlaa,quality,balanced,performance,ultraperformance}` (default Off) and `--dlss-sharpness 0..100` (default 0) save personal graphics preferences. Non-Off DLSS requires VR and an RTX-compatible driver/runtime. Example: `runtime\python.exe tools\multiplayer\friends.py --solo --vr --dlss quality --dlss-sharpness 0`. Use `--dlss off` to restore ordinary rendering. These are portable CLI options; the root launcher exposes them through its player window.

VR hides Bloat bile lens splatter by default. `--no-hide-bile-lens` restores it; damage and poison gameplay remain. Steam and Epic Solo support these choices; Epic remains Solo-only. DLSS failure selects complete ordinary images for both eyes, then returns to ordinary sizing. DLSS remains experimental and needs headset/online acceptance.

With **Physical stock - gun hand aims**, a firearm's acquired support grip remains owned across distance drift while the physical grip is held and tracking is valid. Ordinary two-hand aiming still releases at the existing distance; tracking loss suspends support accuracy, and grip release/stow remain available. Melee and pump/carry exceptions retain their existing rules.

## Current startup, progression and graphics

Ordinary launches do not request cheats or restore Godmode. Solo forces normal play; saved Admin Auto Login automatic-cheats settings are disabled in isolated session copies, with originals preserved. Explicit later Practice remains available with its warning. The pre-play warning distinguishes VAC status from XP eligibility. The disabled VAC control reflects unsupported secure injected VR; VAC does not guarantee ordinary perk XP. Custom modes/mods and Practice can prevent progression.

Experimental DLSS options are `--dlss off|dlaa|quality|balanced|performance|ultraperformance` with `--dlss-sharpness 0` through `100`; Off/0 are fresh defaults. Non-Off requires VR and NVIDIA RTX hardware with a compatible driver. The portable Solo/Host/Join graphics controls keep these personal settings; Epic carries the same typed Solo graphics options. `--hide-bile-lens` is initially on for VR; use `--no-hide-bile-lens` to restore the stock splatter. See [DLSS](docs/DLSS.md).
