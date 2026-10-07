# Killing Floor 2 VR

A fan-made PCVR adaptation of Killing Floor 2 for Windows, with Steam support
and experimental Epic Solo VR.
Tracked hands, independently held weapons, physical melee, VR menus and wrist
readouts run through a native OpenXR/D3D11 adapter and UnrealScript packages.
KF2-VR is unaffiliated with Tripwire Interactive.

## Play the mod

Public playable alpha downloads are on [GitHub Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).
Choose the complete **KF2VR-Multiplayer-*.zip** attached to the release you
want to play. The separate **KF2VR-Source-*.zip** and GitHub's automatic
**Source code** archives are for development. See that release's notes and
`app/release.json` for checksums, supported stores/builds and limitations.
The older October 5 alpha is Steam-only; Steam/Epic support requires a newer
release explicitly listing both stores. Existing release ZIPs and tags stay intact.

Extract the whole playable ZIP into a fresh folder, leave `app` intact,
connect your headset and activate its OpenXR runtime, then open
**Start KF2-VR**. Auto selects a sole installation or the last valid folder
used in that extracted release. With both stores installed, choose the store
you want. Steam offers Solo/Host/Join in VR or Desktop; Epic offers Solo VR only.
Keep the launcher open until KF2 exits and cleanup finishes.

You need your own Steam or Epic KF2 on Windows 10/11. Start ordinary
KF2 once before first setup. Exact game-executable hashes are checked before
deployment; updates require a compatible release. Python and launcher runtimes
are bundled; the store supplies the game's normal prerequisites. Solo/Join need no dedicated
server; first hosting downloads the free server (about 32 GB). Internet hosts
forward UDP 7777/27015. Share join codes privately because they include passwords.

Epic requires copying generated session Launch Options into the official Epic
launcher, then launching there. Remove that line and restore your previous options
after quitting. Host/Join/Desktop, cross-store online play and recording are disabled.
The current Epic menu-first route has not passed overall headset acceptance;
earlier tests confirmed only partial controller/gameplay functionality.

Steam Solo has had the most developer headset testing, using Quest over Link.
The developer has also tested remote joining of a hosted server and
install/recovery. This is an early alpha; broader hardware, complete matches,
remote gestures, travel and arsenal coverage need feedback. Defaults are
Performance graphics, 75% render scale and Button reloads. Saved preferences win.

Begin with [READ ME FIRST](docs/public-alpha/READ-ME-FIRST.txt), the
[quick controls card](docs/public-alpha/CONTROLS-CARD.txt) and
[full controls guide](docs/VR_CONTROLS.md). See [known issues](docs/public-alpha/RELEASE-NOTES-DRAFT.md)
and [feedback questions](docs/public-alpha/FEEDBACK-QUESTIONS.md).

For reports, use **Save logs for a bug report**. It creates a local ZIP of
sanitized report copies; originals remain local and nothing uploads automatically.
Review the ZIP before sharing: unrecognized personal details in free-form text
may need removal. Use [GitHub Issues](https://github.com/Kvasir94/Killing-Floor-2-VR/issues)
for public bug reports; keep sensitive details private.
After interruption, quit KF2 and use **Fix a stuck session** before changing or
deleting that release folder. Never mix DLLs or bypass game/package checks.

## Build and contribute

Public source: [Kvasir94/Killing-Floor-2-VR](https://github.com/Kvasir94/Killing-Floor-2-VR).
To obtain the source:

```powershell
git clone https://github.com/Kvasir94/Killing-Floor-2-VR.git
cd Killing-Floor-2-VR
```

The source is for review and development. Building a playable candidate requires
your own supported KF2/SDK and Portal 2 installations, Windows build tools and
Blender. The source build extracts needed game inputs locally and regenerates
its glove/watch, reload props and weapon art; generated outputs stay excluded.
This route does not recreate the first alpha's exact hand-art revision or ZIP bytes.
**The launcher can be audited and built independently**, without KF2, the SDK
or authored game art; see [launcher source and build](docs/BUILDING.md#audit-and-build-the-launcher).
See [BUILDING](docs/BUILDING.md) for native/full-mod prerequisites,
commands and exact limitations; [CONTRIBUTING](CONTRIBUTING.md) has issue guidance.

| Path | Purpose |
| --- | --- |
| native/ | x64 game adapter, OpenXR/D3D11 backend and CPU tests |
| script/ | Shared VR gameplay, presentation and multiplayer transport |
| tools/ | Build, package, launcher and asset tools |
| project/, staging/ | Optional/deferred source inputs used by some tools |
| third_party/ | Dependency pins; upstream SDKs are fetched separately |
| build/ | Ignored generated artifacts, caches and immutable playable releases |

The local checkout launches through `Play-KF2VR.cmd` and selects
`build/multiplayer/current-release.json`. Build with `tools/build-kf2vr.ps1`
after preparing prerequisites; see [launch options](PLAY-MULTIPLAYER.md).
Read [AGENTS](AGENTS.md) for shared repository workflow and permitted tests.
Much of the implementation was written using AI coding agents under developer
direction and then tried in a headset; source review and specific bug reports
are welcome.

## Safety and licences

Use Solo or the launcher's VAC-off custom servers. The launcher refuses a server
that reports VAC enabled. Avoid VAC-secured servers; this is not a guarantee
from Valve or Tripwire. Custom multiplayer does not promise ordinary ranked XP.

The adapter uses `dinput8.dll` and MinHook to integrate with the game. Hooking
can trigger antivirus heuristics. Review/build the source if needed; the launcher
restores its temporary game-folder deployment when cleanup completes.

[MIT](LICENSE) covers original KF2-VR contributions. Game, SDK, Workshop and
Valve assets retain their owners' terms. Source archives omit local data, game-derived binary packages and assets
with unresolved provenance. The public playable ZIP is a separate artifact that includes
game-derived packages; its redistribution review remains unresolved, as disclosed
in the release notes. Public availability does not establish rights clearance.
See [PROVENANCE](docs/PROVENANCE.md)
and [dependency pins](third_party/VERSIONS.md).

## October 7 handling and graphics update

See the [release notes](docs/public-alpha/RELEASE-NOTES-DRAFT.md) for exact MG3 and retained-chamber coverage, loading-hand and grenade-grip corrections, belt visuals, seated calibration and experimental DLSS. DLSS starts Off and requires NVIDIA RTX hardware; see [DLSS](docs/DLSS.md) for limitations and publication obligations. Ordinary startup disables saved Admin Auto Login automatic cheats in isolated session copies. VAC status is separate from XP eligibility; secure injected VR is unsupported. Final headset and real online acceptance remain pending.
