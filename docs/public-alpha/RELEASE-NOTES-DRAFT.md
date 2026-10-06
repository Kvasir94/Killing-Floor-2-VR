# Public alpha - release notes

This is an early PCVR fan adaptation of Killing Floor 2 for Windows.
It is unaffiliated with Tripwire Interactive. Download complete playable ZIPs
from [GitHub Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).
Use this ZIP's build ID and store support, rather than an older release's notes.

Read the launcher build ID and `app/release.json` for the exact version,
source commit, protocol and supported game-executable hash. All players in a
Steam multiplayer session need the same ZIP and their own Steam copy of KF2.
Epic is an experimental Solo VR option in the same player launcher; Host, Join,
Desktop and cross-store online play are unavailable. Its official launcher
handles authentication through a manual session Launch Options paste.
Extract each update into a fresh folder and keep the previous ZIP for rollback.

## Included behavior and defaults

- Shared Steam/Epic detection and selection, with exact executable gates and
  temporary native deployment/recovery. Epic opens the stock frontend and
  carries Solo VR options through isolated INIs; headset retesting is pending.
- Localized VR Use/hold prompts and an optional physical-stock aim setting
  retaining support grip/recoil while the primary controller aims. Both await
  headset feedback. Support-hand aim remains enabled by default.
- Steam retains motion recording/highlight logging. Epic disables both because
  their configuration is not integrated into its native session handoff.

- Steam Solo, Host and Join in VR or Desktop, with a portable launcher and recovery.
  First hosting downloads the separate free dedicated server (about 32 GB).
- Tracked hands, independent weapons, motion melee, VR menus and wrist readouts.
  Start with Performance graphics at 75% render scale and Button reload mode.
  Saved preferences override fresh defaults.
- Optional Physical and Physical + Pump reload modes. Holsters, threaded
  rendering and optional content start OFF. Solo Zed grabbing starts ON;
  experimental multiplayer grabbing starts OFF and follows the host.
- Wheel choices confirm when trigger is released. Syringe selection is on the
  wheel or by double-tapping an already empty hand; there is no wrist pouch.
  Chest grenades use an empty hand and held grip; release grip to throw/drop.
- Optional Portal Gun is Solo-only and initially disabled. Its see-through
  views require threaded rendering OFF. Optional Breacher is experimental.
- Save logs for a bug report produces a local sanitized report ZIP. Nothing
  uploads automatically. See the controls guide and quick card for bindings.

## Known bugs and incomplete features

Earlier reports do not establish that every issue occurs in this exact ZIP.
Please include its build ID when reporting a recurrence.

- **Stoner 63A:** reported quarter-turn/sideways firing remains unresolved.
  Avoid it for the baseline match; report barrel, laser, tracer or impact disagreement.
- **Weapon wheel:** icons are visible in the current desktop check and the
  developer reports them working. Report blank/text/wrong silhouettes if they
  recur, especially after buying a weapon. Arsenal-wide headset coverage is not claimed.
- **Physical reloads:** M32 manual reload was reported absent; the observed
  Crossboom loads arrows automatically. HX25 insertion, closure and fit need
  feedback after its carry and two-hand brace corrections. M79/HX25 deliberate
  reload requests now survive shot recovery; physical opening/insertion/closure
  still need headset feedback. Select Button mode if physical reloads block play.
- **Lever rifles:** primary-hand release to drive the lever while the support
  hand anchors the rifle is missing. Off-hand cycling exists, but its proposed
  workaround has not been headset-confirmed and does not satisfy the requested
  interaction. This remains a handling blocker.
- **Epic:** experimental; overall headset acceptance remains incomplete.
  Earlier testing confirmed partial controller/gameplay functionality including
  Outpost, 1858/Deagle tracking and trader access. The current menu-first startup
  and final ZIP have not had a headset retest. Host/Join/Desktop and cross-store
  online play are unavailable.
- **Earlier fit reports:** SCAR magazine rotation, HMTech-501 magazine offset,
  Blunderbuss reload difficulty and FAL glove appearance.
- **Combat and networking:** crowded/grabbed retaliation, melee contacts,
  hosted body/grab stability, remote gestures and map travel need wider feedback.
  Multiplayer grabs initially remain OFF.
- **Coverage:** other headsets, larger player counts, sustained performance and
  complete matches are not comprehensively verified. Prior developer headset,
  hosted-server and install/recovery testing does not establish runtime acceptance
  of this final ZIP. Quest over Link is the primary developer setup.
- **Progression:** custom multiplayer does not promise ordinary perk XP/ranked
  progression. Practice and God Mode make the session unranked.

Implemented corrections awaiting headset feedback include Minigun insertion,
HMTech-401 charging-action contact, MG3 seating and bore alignment, HX25 carry
contact and receiver bracing, M79/HX25 recovery reload intent, M79 opening
and spent-shell display, FAMAS aim, Gravity Imploder carry, RPG insertion guides,
pouch-counter orientation and Seeker/Locust duplicate markers. These are
corrections to retest, not an arsenal-wide acceptance claim.

## Report and recover

Click **Save logs for a bug report** in the launcher. The ZIP appears beside
**Start KF2-VR**. Report copies replace recognized personal paths, known names,
account IDs, addresses and emails with aliases; passwords, recognized tokens
and join codes are removed. Original files remain local; configs, deployment
backups and crash dumps are excluded. Review the ZIP before sharing because
free-form text can contain other personal details. Keep raw logs/configs/dumps,
passwords and join codes private. Post public reports in
[GitHub Issues](https://github.com/Kvasir94/Killing-Floor-2-VR/issues); keep
sensitive details private.

Include build ID, Solo/Host/Join and VR/Desktop, map/perk/character/weapon,
headset/runtime/GPU, relevant options, last action, expected/actual result and
repeat steps. For reloads include normal/elite, empty/tactical and left/right hand.
For network issues identify which player saw it and whether they were outside
the host's network. The bundled FEEDBACK-QUESTIONS guide suggests useful feedback.

Keep the launcher open until cleanup finishes. After interruption, quit KF2
and use **Fix a stuck session** before deleting that folder or changing releases.
Never mix DLLs between releases or bypass a game/package mismatch. After cleanup,
ordinary KF2 can be started from your store.

Playable packages include KF2/Valve-derived assets whose rights remain with
their respective owners. Redistribution clearance is unresolved; public availability
does not establish clearance. Source archives exclude these binary packages and
require local game/SDK inputs to build. See the included third-party notices.
