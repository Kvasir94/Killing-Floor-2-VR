# KF2-VR credits

## OptimumBox

This project integrates and adapts contributions from
[OptimumBox's Killing-Floor-2-VR fork](https://github.com/optimumbox/Killing-Floor-2-VR).
The current integration baseline is
[v0.5.0-alpha.20261011](https://github.com/optimumbox/Killing-Floor-2-VR/releases/tag/v0.5.0-alpha.20261011),
commit `e35ec355ae951dda72ee80b20cb1cef12345b9ac`.

Credit covers his improvements across the mod, including:

| Area | Integrated or adapted contributions |
| --- | --- |
| Rendering | DLSS/DLAA integration, CAS sharpening, single-pass stereo, visibility/effect handling and threaded HUD recovery work |
| Reloads | Hip reloads for paired and eligible one-handed guns, magazine reloads, revolver/cylinder loading and closure, stock automatic dual-revolver reload routing and inspection recovery |
| Multiplayer | 120 Hz sender-timed pose updates and corresponding host/network settings |
| Interaction and controls | Firearm support retention, both-hand pouch behavior and pouch/rack reach, movement-wheel controls with walking and welder priority, authored grenade grips |
| Cameras and diagnostics | Fixed boss-introduction viewpoint, level death/spectator views and blocked-trigger diagnostics |
| Launcher | Player-window layout, wording, controls and fresh-profile defaults, including 100% render scale and blank-password public hosting |
| Desktop companions | Steam/Proton Linux joining helper and manual Epic desktop package workflow |

The earlier DLSS/physical-stock integration credits OptimumBox commit
`e080bc0e1e1a56e3de61498634f40ca2c29692ed`; the single-pass contribution is also
identified in [DLSS documentation](docs/DLSS.md). Donor commits record
**Claude Opus 5.5** co-author attribution, which is retained here.

Local integration retains shared-ammo authority and recovery safeguards,
jump/haptic/sight tuning and selected graphics defaults. The exact owned-texture
threaded HUD adaptation combines the donor recovery behavior with local resource
ownership checks. These local adaptations do not replace the upstream credit.
Source integration and offline checks do not establish headset or online parity.

## Project and dependencies

KF2-VR's original development and local integration are maintained by
[Kvasir94](https://github.com/Kvasir94). Original contributions use the
[MIT licence](LICENSE); the donor copyright and permission notice are retained.

Killing Floor 2 and its game content belong to their respective rights holders.
OpenXR/Khronos, MinHook/HDE, Python/Tcl/Tk/Microsoft components, NVIDIA DLSS,
AMD FidelityFX CAS and the CC0 bell sound retain their own credits and licences.
See [provenance](docs/PROVENANCE.md), [third-party notices](docs/public-alpha/THIRD-PARTY-NOTICES.txt)
and [dependency pins](third_party/VERSIONS.md) for the exact sources and notices.
