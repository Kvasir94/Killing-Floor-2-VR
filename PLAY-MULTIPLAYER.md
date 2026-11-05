# Launch options and multiplayer

Players open **Start KF2-VR** in the extracted ZIP; from a source checkout,
**Play-KF2VR.cmd** opens the selected package's player window. The window finds
Steam and Epic installations, runs a short first-time setup, and offers **Quick
start**, **Solo match**, **Host a game** and **Join a friend**, in VR or on the
desktop. Steam supports Solo, Host and Join; Epic is experimental Solo VR only,
started through Launch Options pasted into the official Epic launcher (see the
[player guide](docs/PLAYER-GUIDE.md)).

Solo needs no server download. The first Host downloads the free KF2 dedicated
server (about 9 GB, 32 GB installed) into `KF2-VR Data` on the drive that holds
KF2. A blank Host password makes the server open. Joiners need neither the
server nor port forwarding; internet hosts forward UDP 7777 and 27015.

Everything the window does is also available as `Play-KF2VR.cmd` switches,
listed below. Choices made in the window or with switches are saved per PC in
`%LOCALAPPDATA%\KF2VR\Profile`; explicit switches win for that launch.

## Main launcher switches

All public switches for Play-KF2VR.cmd / tools/play-main.ps1 are listed here.
docs/LAUNCHER_SWITCHES.md is the generated one-table-per-category
reference from the settings registry (saved store, default and packaged flag for each).
PowerShell's standard common parameters are also available.

`-Help` prints a list generated from
[tools/multiplayer/settings_registry.py](tools/multiplayer/settings_registry.py), the single
definition of every launcher option, its shipped default and whether it is saved;
the packaged `friends.py --help` comes from the same table.

| Switch | Default | Purpose and constraints | Example |
| --- | --- | --- | --- |
| `-Gui` | On for a double-click/no-argument CMD launch; otherwise off | Graphical selections before launch, including the explicit consent when source is newer than the selected package. Also works with TestMap and PrepareOnly. | `./Play-KF2VR.cmd -Gui -Difficulty Hard` |
| `-RecordMotion` | Off; this launch only | On/Off. Live VR player motion, input and presentation clips; no synthetic playback, video or audio. | `./Play-KF2VR.cmd -Gui -Vr -RecordMotion On` |
| `-HighlightEvents` | Off; this launch only | On/Off. Live VR highlight events and F9 video sync marks. `-PromoEvents` also enables it. | `./Play-KF2VR.cmd -Gui -Vr -HighlightEvents On` |
| `-Vr` | Saved play mode; initially VR | Headset play for this session regardless of the saved mode. Rejects a combined Desktop request. | `./Play-KF2VR.cmd -Vr` |
| `-Desktop` | Saved play mode; initially VR | Same selected package, stock desktop controls; works with Solo or Host. Rejects explicit VR quality/scale. | `./Play-KF2VR.cmd -Desktop` |
| `-LocomotionPreview` | Off | Desktop inspection of the actual remote pawn; alternates roomscale and stick walking with idle pauses. No headset needed. Rejects Solo, Vr, Gui, Menu and TestMap. | `./Play-KF2VR.cmd -LocomotionPreview` |
| `-Solo` | Off (host); the window remembers the last kind | Standalone match from the selected package; no dedicated server installation or network needed. Shares saved mode, graphics, eye scale and match options, menus, PrepareOnly and AllowStale with Host. Installed client maps, including downloaded Steam Workshop and user-cache maps, plus explicit Steam cached Remilly as described below. Installed custom content is mounted read-only for the session. Rejects explicit TestMapPlayers and InventoryFocus On. Ignores mods. | `./Play-KF2VR.cmd -Solo -Vr -Map KF-Outpost -Difficulty Hard` |
| `-TestMap` | Off (Burning Paris) | Remilly's Workshop map. Host downloads if needed. Explicit `-Solo -Store Steam` uses only the verified existing cache, without download or map copy. | `./Play-KF2VR.cmd -Solo -Vr -Store Steam -TestMap` |
| `-Menu` | Off | Text menu in the console instead of the window; same selections before launch, including play-anyway/quit when source is newer than the selected package. Also works with PrepareOnly. | `./Play-KF2VR.cmd -Menu -Difficulty Hard` |
| `-TestMode` | Off; never saved | UNRANKED. Perk changes take effect at any time, even mid-wave, from the stock perk menu; each switch strips the inventory (healer and welder stay) and grants every weapon of the new perk, and every spawn gets the full arsenal. Server-side, so it works in Solo, on the host and for players joining it. Combine with `-TestMap` or `-Map`. Play-KF2VR-TestMode.cmd opens the window with it on. | `./Play-KF2VR.cmd -TestMode -TestMap` |
| `-Map` | Saved; initially KF-BurningParis | KF- map name. Host offers common installed maps, installed custom maps, Remilly and managed Workshop maps; Solo offers installed client, Workshop-cache and user-cache maps. Companion packages in a selected custom map’s content folder are mounted for both local client and host. An unavailable saved hosted map falls back to the first installed Solo map; an explicit unsupported Solo map fails. No extension/path/URL options. Rejects a conflicting TestMap selection. | `./Play-KF2VR.cmd -Map KF-TF2_Upward` |
| `-Difficulty` | Saved; initially Normal | Normal, Hard, Suicidal, HellOnEarth. | `./Play-KF2VR.cmd -Difficulty Suicidal` |
| `-GameLength` | Saved; initially Medium | Short (4 waves), Medium (7), Long (10), then boss. | `./Play-KF2VR.cmd -Map KF-Outpost -Difficulty Hard -GameLength Long` |
| `-MaxZeds` | Saved per Host/Solo; initially 0 (stock) | Most zeds alive at once, 1-128; 0 keeps stock (10-32 by difficulty and living players). Turns on UKFP. See [Zed spawn overrides](#zed-spawn-overrides). | `./Play-KF2VR.cmd -MaxZeds 48` |
| `-WaveZedsPercent` | Saved per Host/Solo; initially 100 (stock) | 10-500: zeds per normal wave as a percent of stock's own total, which already scales with wave, players and difficulty. | `./Play-KF2VR.cmd -WaveZedsPercent 150` |
| `-SpawnRatePercent` | Saved per Host/Solo; initially 100 (stock) | 25-500: how often zed squads spawn; 200 is twice as often. | `./Play-KF2VR.cmd -MaxZeds 64 -SpawnRatePercent 200` |
| `-Mods` | Saved VR selection; initially `none`. Use `legacy` for the UKFP preset. Desktop starts with none. | Comma-separated catalog keys, `none`, or `legacy`. Selecting a dependency feature also enables UKFP. Normal VR host launches/preparations save the selection across releases. | `./Play-KF2VR.cmd -Mods ukfp,yas` |
| `-DamagePopups` | Saved Desktop preference; initially On | On/Off for Desktop with UKFP. In VR, native 3D world-space damage numbers (`VRDamagePopups`) are rendered over Zeds' heads with stereoscopic depth instead of UKFP's flat overlay. | `./Play-KF2VR.cmd -Desktop -Mods ukfp -DamagePopups On` |
| `-ZedGrabs` | Saved Host choice; initially On | On/Off. Host only: lets VR players on this server grab and throw Zeds (`?VRMultiplayerGrabs=1`/`0`). Each player's own Zed grab setting still applies; rejected with `-Solo` (use the headset or launcher setting). | `./Play-KF2VR.cmd -ZedGrabs Off` |
| `-GravityGrab` | Saved Host choice; initially On | On/Off. Host only: lets VR players on this server gravity-grab guns, magazines and pickups (`?VRGravityPull=1`/`0`). Rejected with `-Solo`. | `./Play-KF2VR.cmd -GravityGrab Off` |
| `-TestMapPlayers` | Saved; initially 6 | Host only: 0 for actual players, 6 for UKFP faked-player scaling on Remilly only. Effective only with UKFP selected. | `./Play-KF2VR.cmd -TestMap -TestMapPlayers 6` |
| `-InventoryFocus` | Retired compatibility input | Multiplayer slowdown is unavailable. Solo slowdown is Comfort's **Weapon wheel slow-mo**. | Omit |
| `-Dlss` | Saved; initially `auto` | `auto`, `off`, `dlaa`, `quality`, `balanced`, `performance`, `ultraperformance`. VR only. `auto` runs Quality where DLSS starts and ordinary rendering on other GPUs; an explicit mode needs a DLSS-enabled package and compatible NVIDIA runtime. Omit to retain the saved choice, or explicitly select `off` to restore ordinary rendering. | `./Play-KF2VR.cmd -Solo -Vr -Dlss quality` |
| `-DlssSharpness` | Saved; initially 50 | Integer 0-100; VR only. Zero disables sharpening. Omit to retain the saved value. | `./Play-KF2VR.cmd -Solo -Vr -Dlss quality -DlssSharpness 0` |
| `-Hbao` | Saved; initially On (Quality) | On/Off. VR screen-space ambient occlusion. | `./Play-KF2VR.cmd -Solo -Vr -Hbao On` |
| `-Reflections` | Saved; initially On (Quality) | On/Off. VR screen-space reflections. | `./Play-KF2VR.cmd -Solo -Vr -Reflections On` |
| `-Flex` | Retired compatibility input | Ignored. FleX stays disabled, including for old saved On choices. | Omit |
| `-HideBloodLens` | Saved; initially On | On/Off. Suppress blood lens splatter in VR; independent of Bloat bile. | `./Play-KF2VR.cmd -Solo -Vr -HideBloodLens Off` |
| `-EyeRenderPercent` | Saved value; initially 100 | Integer 50-100, per-eye width/height scale. Explicit value overrides saved scale. VR only. | `./Play-KF2VR.cmd -EyeRenderPercent 75` |
| `-HeadsetPreset` | Retired compatibility input | No longer changes quality or render scale. Use independent Graphics controls. | Omit |
| `-VrQuality` | Saved; initially `quality` | `quality`, `balanced`, `performance`. Session preset, separate from eye scale. VR only. | `./Play-KF2VR.cmd -VrQuality performance` |
| `-PrepareOnly` | Off | Verify and prepare isolated configs; no game/server processes or DLL deployment. Remilly must be cached; other Workshop content can be imported from existing Steam downloads. Missing downloads fail before launch. | `./Play-KF2VR.cmd -PrepareOnly` |
| `-AllowStale` | Off | Allow the selected package to differ from current repo source, with a visible warning. Still verifies the manifest and every packaged file; does not rebuild, select a different release, or permit damaged packages. Works with Menu, TestMap and PrepareOnly. | `./Play-KF2VR.cmd -AllowStale -Menu` |
| `-GameRoot` | Saved installation, then store detection | Matching, fingerprinted Steam/Epic KF2 installation; an explicit folder must match the chosen store. | `./Play-KF2VR.cmd -GameRoot 'E:\SteamLibrary\steamapps\common\killingfloor2'` |
| `-Store` | `Auto` | `Auto`, `Steam`, `Epic`. Auto uses the sole installation or last valid folder. Epic requires Solo VR and official-launcher options; Host/Join/Desktop/recording/test control are unavailable. | `./Play-KF2VR.cmd -Store Epic -Solo -Vr` |
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

## Zed spawn overrides

Three optional choices change the horde: **Max zeds alive**, **Zeds per wave**
and **Spawn rate**, in the Host and Solo windows' Match section, under **Z** in the `-Menu`
text menu, or with `-MaxZeds`, `-WaveZedsPercent` and `-SpawnRatePercent`
(packaged CLI: `--max-zeds`, `--wave-zeds-percent`, `--spawn-rate-percent`).
They need Host or Solo and are remembered separately for each. At the stock values
(0, 100, 100) the launcher does not turn UKFP on, and Solo stays a stock ranked
game with no mutator.

- Stock KF2 has no setting for any of them. Host writes them to the server's
  Unofficial KF2 Patch settings (`MaxMonsters`, `WaveCountMultiplier`,
  `SpawnRateMultiplier` in its per-session `KFUnofficialPatch.ini`) and turns
  UKFP on, as its dependent mods do. Players who join get UKFP like any hosted mod.
- Solo with any override loads only UKFP (none of its dependent mods) and writes
  the same settings into the game's own per-session `KFUnofficialPatch.ini`; the
  match is then no longer a stock ranked one. Solo never downloads UKFP: it must be
  subscribed in Steam or already in the launcher's Workshop cache (hosting once
  caches it). Otherwise the launch stops with an error naming Workshop item 2875147606.
- Epic Solo opens the stock menu, so these choices do not apply there.
- Large hordes cost frame time in VR; raise them gradually.

How stock decides these numbers: docs/re/ZED_SPAWN_PIPELINE.md.

## Test map

`-TestMap` selects **KF-Remilly_Test_Map**, Workshop item **1337395223**.
The opt-in VR sandbox candidate adds **Practice and Tools > Remilly Sandbox /
Unranked / No XP**. Once this candidate is built and packaged, the local route is
`Play-KF2VR.cmd -Solo -Vr -Store Steam -TestMap` (add `-PrepareOnly` for isolated
configuration preparation without starting the game). This explicit command
uses the existing verified Workshop cache, with no server, credentials, map
copy, download, or changes to the original map. Missing, corrupt or changed
cache content fails. The accepted SHA-256 is
`CC427E7689C9E60EAD3486F5320B210C021CCA82C2D778DD1B1B2408E390FE14`.
This first route is command-line only; the Solo GUI map list is unchanged.

Start a normal Survival wave, open the sandbox panel, then deliberately select
**Start / Accept No XP**. Solo uses stock local cheat/unranked handling; startup
does not enable cheats. The explicit test-map selection does not replace the
saved ordinary map choice. Hosted sandbox actions still require authenticated
server admin authority and are deferred for ordinary headset-only use. Until
the candidate is packaged and selected, the current release keeps its existing
Remilly behavior.

The sandbox uses the original map unchanged, credited to **remi**, creator of
[Test Map For Remilly](https://steamcommunity.com/sharedfiles/filedetails/?id=1337395223).
No editable-source link or adaptation licence was found on its Workshop page;
no map modification or redistribution is included. Its world buttons remain
as supplied. Use the tracked VR panel for refilling money, opening the trader,
granting an authored VR weapon, selecting an exact zed type/count, and clearing
targets. Counts are 1–6, bosses one per press, with at most 12 live practice
targets. Repeating a selected type/count after Clear gives a manual combat
comparison; this is not a performance measurement or automated benchmark.

Money refills while active. Trader access uses the existing inventory/preflight
path while waves are suspended and world time/combat continue. The armory lists
authored VR profiles, **not every installed weapon**: missing classes and optional
test content can be refused. DLC
availability and complete current-weapon coverage are not yet verified. The
23-type zed selector omits Versus, Mixer, friendly-test, boss-subspawn and
event-specific variants; boss behavior is untested. Clear removes sandbox
targets and the practice patient, not arbitrary map-button spawns. End restores
saved money, carry limit, trader flag and god mode, and removes directly granted
actors; bought or map-granted inventory is not rolled back. The session remains
unranked: disconnect and start a fresh normal session for normal play. No sandbox
setting is written to the user profile. SDK compilation and headset validation
are still required; the original map has not been recooked.

At the September 19, 2026 lookup its **24,867 subscriptions** were the most among
the established test maps compared: Remilly, SomeTestMap v2/v3 and TestingMapRedux.
The map itself has no custom game/mutator requirement. The author's optional
six-player HP command uses Controlled Difficulty Legacy and DamageDisplay.
[Workshop source](https://steamcommunity.com/sharedfiles/filedetails/?id=1337395223).

The old SomeTestMap v3 URL selected STM.SomeTestMap and STM3.STM3, bypassing the
VR game/controller. Existing maps/cache are preserved. Hidden SteamCMD downloads
Remilly into the cache; the launcher checks its Unreal package header, supplies
explicit client/server content paths, and hashes it into the session receipt.
Download/preparation does not prove in-game loading; the smoke's test-map variant
checks the server's advertised map at runtime.

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
at the stock hit-effect point (above the Zed when unavailable), with stereoscopic
depth and the patch's damage colors and two-second lifetime. VR damage numbers
are enabled by default (`bDamagePopups=True`) and can be changed in
**VR SETTINGS > HUD AND READOUTS > DAMAGE POPUPS**. The Desktop UKFP launcher
preference remains separate. Parameters are verified
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
./app/runtime/python.exe app/tools/multiplayer/friends.py --host --vr --server-name "Our KF2-VR game" --open-server
./app/runtime/python.exe app/tools/multiplayer/friends.py --desktop --address 192.168.1.20 --password ""
./app/runtime/python.exe app/tools/multiplayer/friends.py --help
```

All public packaged CLI switches:

| Switch | Default | Purpose and constraints |
| --- | --- | --- |
| `--host` | Off (join) | Start local dedicated server and join 127.0.0.1. |
| `--menu` | Off | Interactive host menu; requires host and rejects replay/preview modes. |
| `--map` | Saved; initially KF-BurningParis | Installed map name; requires host. KF-Remilly_Test_Map also selects the managed Workshop download. |
| `--difficulty` | Saved; initially normal | normal, hard, suicidal, hellonearth; requires host. |
| `--game-length` | Saved; initially medium | short (4), medium (7), long (10 waves), then boss; requires host or solo. |
| `--inventory-focus` / `--no-inventory-focus` | Saved; initially Off | Host-only experimental shared slowdown while a VR wheel is open. Applies to all participants and yields to Zed Time. Enable or disable explicitly; joins may omit it or use `--no-inventory-focus`. |
| `--vr` | Off (desktop) for a join; a host with neither flag uses the saved play mode, initially VR | Live headset adapter. |
| `--desktop` | Off | Flat screen for this session, overriding the saved play mode. Rejects explicit VR quality/scale. |
| `--mods` | Saved VR selection; initially none, optional legacy preset | Comma-separated catalog keys, `none`, or `legacy`. UKFP dependencies are installed automatically. Join selections preload content; the remote host controls mutators. |
| `--damage-popups` / `--no-damage-popups` | Saved Desktop preference, initially on | UKFP server permission/local display for Desktop sessions. VR suppresses the flat overlay even when the preference is on. Requires UKFP selected. |
| `--test-map-players` | Saved, initially 6 | 0/6; requires host. Applied only to Remilly with UKFP. |
| `--test-map` | Off | Remilly; requires host and rejects replay/preview modes. |
| `--headset-preset` | None | Provisional quest2/quest3/quest3s/index/high-resolution bundle; explicit quality/scale wins. Resulting settings remembered; VR only. |
| `--vr-quality` | Saved; initially quality | quality/balanced/performance; rejected with `--desktop`. |
| `--eye-render-percent` | Saved value, initially 100 | Integer 50-100; requires VR, overrides saved scale. |
| `--hbao` / `--no-hbao` | Saved; initially On (Quality) | Enable or disable screen-space ambient occlusion in VR. |
| `--reflections` / `--no-reflections` | Saved; initially On (Quality) | Enable or disable screen-space reflections in VR. |
| `--flex {off,gibs,fluids}` | Saved; initially Off | Personal FleX gore for VR and Desktop, Solo/Host/Join. `fluids` means Gibs and Fluids. VR uses the experimental portable solver by default. |
| `--hide-blood-lens` / `--no-hide-blood-lens` | Saved; initially On | Hide blood lens splatter in VR. Does not alter damage or bile suppression. |
| `--frame-timings` | Off | VR only. Writes CPU stage and GPU frame times to the session's native.log every 5 s; low overhead. Without it the adapter still logs a lite `FramePacing` line every 5 s (present intervals: mean, p50/p95/p99, frames over 11.1 and 8.3 ms) from one clock read per frame, and the launcher records the game's peak working set; both feed the Save-logs summary. Packaged menu: Troubleshooting > Performance log. Main launcher: `-FrameTimings`. |
| `--address` | Prompt for join code or saved address | Paste the complete `KF2VR1:` code to apply the host's address, password, game/query ports, map and mods, overriding local connection/content choices. Requires the same build. Also accepts hostname/IP without port or URL. Hosting uses 127.0.0.1. |
| `--share-address` | Public IPv4 reported by the host server | Host only. Override the address in the join code for LAN/VPN/custom hostname; no port or URL. Example: `--host --share-address 192.168.1.20`. |
| `--password` | Protected host: saved/generated; join: prompt | Up to 64 letters, digits, underscore or hyphen. An empty join password selects a passwordless server; use `--open-server` to host without a password. |
| `--server-name` | Saved per extracted release; initially `KF2-VR Server` | Host only. Browser name, 1-48 letters, digits, spaces or `. , ' ! & ( ) + _ -`. |
| `--open-server` / `--no-open-server` | Saved; initially Off | Host only. On hosts without a password; anyone who reaches the server can join. Off restores the saved password or generates one. An open session retains the protected password for later use. |
| `--workshop-desktop` / `--no-workshop-desktop` | Saved; initially On | Host only, Steam. Offer core content from Workshop item 3817663661 to stock desktop players only when every published package exactly matches this release. On a mismatch or unreachable Workshop item, Host prints why and continues with Workshop delivery off for that session (the saved choice is kept); desktop players then need the matching ZIP. `--no-workshop-desktop` skips the check. Published scripts are never mounted over local scripts. |
| `--zed-grabs` / `--no-zed-grabs` | Saved; initially On | Host only. Lets VR players on this server grab and throw Zeds; the Host URL carries `?VRMultiplayerGrabs=1` or `0`. Launcher: Host page, Extras, **Zed grabs**. |
| `--gravity-grab` / `--no-gravity-grab` | Saved; initially On | Host only. Lets VR players on this server gravity-grab guns, magazines and pickups; the Host URL carries `?VRGravityPull=1` or `0`. Launcher: Host page, Extras, **Gravity grab**. |
| `--game-root` | Saved install, Steam lookup, then prompt | Folder containing matching KFGame.exe. |
| `--server-root` | `KF2-VR Data\KF2VR-Server` at the KF2 drive root (an existing one beside the release is kept) | Dedicated server; main launcher overrides with repo server. |
| `--cache-root` | `KF2-VR Data\KF2VR-Cache` at the KF2 drive root (an existing one beside the release is kept) | Workshop cache; main launcher overrides with repo cache. |
| `--port` | 7777 | Game UDP, 1-65535; distinct from query/client ports. Client offsets +10 and replay +20. |
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
F8 toggles third-person inspection in normal VR play. See
avatar preview for its separate camera mode.

LAN friends use the host's LAN address; WAN hosting may need existing port
forwarding or a gaming VPN. The launcher does not change firewall/router rules.
It verifies a VAC-off KF2 server with the requested password state before connecting. Local
multi-instance tests do not validate a second Steam account or WAN conditions.

## Portable package and recovery

Download a playable ZIP from [Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases)
and extract it into a new folder. Open **Start KF2-VR**; the ZIP includes its Python
runtime and mod packages. Solo needs no dedicated-server download. Host uses the
separate free server; Join needs the host's complete join code and the
same ZIP. Share the code privately. Internet hosts forward UDP 7777/27015 and allow
KFServer through Windows Firewall; joiners need neither port forwarding nor a server.

Keep the launcher open until cleanup completes. After interruption, quit KF2 and
use **Help > Repair after a crash** before deleting the folder or changing releases. Recovery
preserves unknown/changed files. Never mix DLLs or bypass package/game hash checks.
**Save logs for a bug report** creates sanitized local copies; nothing uploads
automatically. Review the ZIP before sharing and keep raw logs/configs/dumps private.
See [controls and troubleshooting](docs/VR_CONTROLS.md),
[feedback](CONTRIBUTING.md) and [optional Breacher](docs/public-alpha/BREACHER.md).

### Experimental headset graphics and physical stocks

Portable Solo/Host/Join options `--dlss {off,dlaa,quality,balanced,performance,ultraperformance}` (default Off) and `--dlss-sharpness 0..100` (default 0) save personal graphics preferences. Non-Off DLSS requires VR and an RTX-compatible driver/runtime. Example: `runtime\python.exe tools\multiplayer\friends.py --solo --vr --dlss quality --dlss-sharpness 0`. Use `--dlss off` to restore ordinary rendering. These are portable CLI options; the root launcher exposes them through its player window.

VR hides Bloat bile lens splatter by default. `--no-hide-bile-lens` restores it; damage and poison gameplay remain. Steam and Epic Solo support these choices; Epic remains Solo-only. DLSS failure withholds that pair, then returns to ordinary sizing; normal frames keep no backup images. DLSS remains experimental and needs headset/online acceptance.

An acquired firearm support grip remains owned across distance drift while the
physical grip is held and tracking is valid, in ordinary two-hand aiming and
**Physical stock - gun hand aims**. Tracking loss suspends support accuracy;
grip release/stow remain available. Melee and pump/carry exceptions retain
their existing rules.
