# Killing Floor 2 VR

A fan-made PCVR adaptation of Killing Floor 2 for Windows, with Steam support
and experimental Epic Solo VR.
Tracked hands, independently held weapons, physical melee, VR menus and wrist
readouts run through a native OpenXR/D3D11 adapter and UnrealScript packages.
KF2-VR is unaffiliated with Tripwire Interactive.

Made by Kvasir94 and optimumbox.

## Play the mod

**Download:** [KF2VR-Multiplayer-v0.3.0-alpha.20261105-054158.zip](https://github.com/Kvasir94/Killing-Floor-2-VR/releases/download/v0.3.0-alpha.20261105/KF2VR-Multiplayer-v0.3.0-alpha.20261105-054158.zip)
(release [v0.3.0-alpha.20261105](https://github.com/Kvasir94/Killing-Floor-2-VR/releases/tag/v0.3.0-alpha.20261105), build 054158).

1. You need Windows 10 or 11, your own Killing Floor 2 on Steam, and your
   headset's PC app (SteamVR, Quest Link / Air Link, Virtual Desktop or
   similar). Desktop play works without a headset. Epic is experimental Solo
   VR only.
2. Extract the whole ZIP into a new folder. Open Killing Floor 2 from Steam
   once, then quit it.
3. Open **Start KF2-VR**. The first time, it finds your game and asks a few
   setup questions; the recommended choices are fine.
4. Press **Quick start** for a solo match, or **Host a game** / **Join a
   friend**. Everyone in a match needs this same version. The first time you
   host, KF2-VR downloads the free game server (about 9 GB); friends outside
   your home network need UDP 7777 and 27015 forwarded to you.

Start with [READ ME FIRST](docs/public-alpha/READ-ME-FIRST.txt), then the
[player guide](docs/PLAYER-GUIDE.md), [quick controls](docs/public-alpha/CONTROLS-CARD.txt)
and [release notes](docs/public-alpha/RELEASE-NOTES-DRAFT.md) (what's new since
v0.5.2 and known issues).

**Bugs:** in the launcher, **Help > Save logs for a bug report** makes a ZIP of
anonymized logs (check it before sharing), and **Help > Report a bug** opens the
KF2-VR thread on the Flat2VR Discord. You can also use
[GitHub Issues](https://github.com/Kvasir94/Killing-Floor-2-VR/issues). After a crash, quit KF2 and use **Help >
Repair after a crash**.

**VAC is off:** KF2-VR only plays Solo and VAC-off servers. The adapter loads as
`dinput8.dll` with MinHook, which some antivirus tools flag; the source is here
to review.

**Hands disclaimer.** The playable ZIP ships the KF2VR hands package (gloves,
wristwatch and wrists), which is derived from Killing Floor 2's first-person
arms. Its redistribution clearance is unresolved; it is included for this
alpha, and its rights remain with their owners. The source archive does not
contain it.

Other downloads on the release page: a **LinuxKit** for experimental
Steam/Proton desktop joining ([Linux setup](docs/LINUX-DESKTOP.md)), an
**Epic-Desktop-Pack** for experimental Epic desktop joining ([Epic desktop
setup](docs/EPIC-DESKTOP.md)), the matching **source ZIP** and
**SHA256SUMS.txt**. Desktop friends without a headset can also get the mod from
Steam Workshop item
[3817663661](https://steamcommunity.com/sharedfiles/filedetails/?id=3817663661)
when it matches this version.

## Current source status

This source snapshot integrates OptimumBox's `v0.5.2-alpha.20261014`
and distribution source through `68932aef5ee76b2bcc834eed4d2f3275ea4d6995` with retained local interaction,
rendering and launcher choices. His reload, multiplayer, interaction, camera,
rendering, launcher and desktop-companion contributions are credited in
[CREDITS](CREDITS.md). Release `v0.3.0-alpha.20261105` is build 054158 from this source, with
matching credits and notices. Its tag pins the release source; main can contain
later documentation updates. Earlier releases and their tags stay available.

The source includes one-hand and paired hip reloads, sender-timed remote poses,
walking with the weapon wheel open, fixed boss-introduction views, level
spectator views, authored grenade grips and incoming wristwatch chat. Reloads
offer three styles, Button, Manual and Realistic, plus a separate Ammo rules
choice. Breacher development is frozen and the release omits its optional
content; the Portal Gun and Zed Defense have been removed. See [provenance](docs/PROVENANCE.md) for attribution.

## Build and contribute

Public source: [Kvasir94/Killing-Floor-2-VR](https://github.com/Kvasir94/Killing-Floor-2-VR).
To obtain the source:

```powershell
git clone https://github.com/Kvasir94/Killing-Floor-2-VR.git
cd Killing-Floor-2-VR
```

The source is for review and development. Building a playable candidate requires
your own supported KF2/SDK installation, Windows build tools and Blender. The source build extracts needed game inputs locally and regenerates
its glove/watch, reload props and weapon art; generated outputs stay excluded.
This route does not recreate the released hand-art revision or ZIP bytes.
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
