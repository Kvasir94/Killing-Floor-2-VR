# Killing Floor 2 VR

A fan-made PCVR adaptation of the Steam Windows build of Killing Floor 2.
Tracked hands, independently held weapons, physical melee, VR menus and wrist
readouts run through a native OpenXR/D3D11 adapter and UnrealScript packages.
KF2-VR is unaffiliated with Tripwire Interactive.

## Play the mod

Public playable alpha downloads are on [GitHub Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).
For [the first public alpha](https://github.com/Kvasir94/Killing-Floor-2-VR/releases/tag/v0.1.0-alpha.20261005),
choose **KF2VR-Multiplayer-20261005-162042.zip** to play Solo, Host or Join.
The **KF2VR-Source-20261005-190136-afd65184d77c.zip** and GitHub's automatic
**Source code** archives are for development; they are not playable packages.
Use the release notes for checksums, game compatibility and known limitations.
The first playable ZIP retains its original private-alpha labels and metadata;
the release makes those same bytes publicly available. Its source snapshot is
newer than the playable build. Existing release ZIPs and tags remain unchanged;
future playable updates receive a new version and release notes.

Extract the whole playable ZIP into a fresh folder, leave `app` intact,
connect your headset and activate its OpenXR runtime, then open
**Start KF2-VR**. Start with **Play solo**; Host and Join also offer VR or Desktop.
Keep the launcher open until KF2 exits and cleanup finishes.

You need your own Steam KF2 on Windows 10/11; Epic is unsupported. Start ordinary
KF2 once before first setup. Each ZIP targets one exact game executable and
refuses mismatches after updates. Python and launcher runtimes are bundled;
Steam supplies the game's normal prerequisites. Solo/Join need no dedicated
server; first hosting downloads the free server (about 32 GB). Internet hosts
forward UDP 7777/27015. Share join codes privately because they include passwords.

Solo has had the most developer headset testing, using Quest over Link.
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
may need removal. Use the Discord thread where the public release was shared,
as described in the release notes.
After interruption, quit KF2 and use **Fix a stuck session** before changing or
deleting that release folder. Never mix DLLs or bypass game/package checks.

## Build and contribute

Public source: [Kvasir94/Killing-Floor-2-VR](https://github.com/Kvasir94/Killing-Floor-2-VR).
To obtain the source:

```powershell
git clone https://github.com/Kvasir94/Killing-Floor-2-VR.git
cd Killing-Floor-2-VR
```

The source is for review and development. It is not a self-contained playable
release: current builds require locally installed game/SDK data and excluded
generated asset inputs and a missing authored hand scene.
**The launcher can be audited and built independently**, without KF2, the SDK
or private art; see [launcher source and build](docs/BUILDING.md#audit-and-build-the-launcher).
See [BUILDING](docs/BUILDING.md) for native/full-mod prerequisites,
commands and exact limitations; [CONTRIBUTING](CONTRIBUTING.md) has issue guidance.
[Public source updates](docs/PUBLISHING.md) explains how to keep private development
history separate and apply reviewed future exports as new public commits.

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
Valve assets retain their owners' terms. The public source export omits Git
history, local data, game/derived binary packages and assets with unresolved
provenance. The public playable ZIP is a separate artifact that includes
game-derived packages; its redistribution review remains unresolved, as disclosed
in the release notes. Public availability does not establish rights clearance.
See [PROVENANCE](docs/PROVENANCE.md)
and [dependency pins](third_party/VERSIONS.md).
