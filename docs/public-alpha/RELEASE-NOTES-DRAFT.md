# Private invited alpha — release notes

This is an early PCVR fan adaptation of Steam Killing Floor 2 for Windows.
It is unaffiliated with Tripwire Interactive. The developer supplies invited
testers with the download; this document does not
announce a public playable release.

Read the launcher build ID and `app/release.json` for the exact version,
source commit, protocol and supported game-executable hash. All players in a
session need the same ZIP and their own Steam copy of KF2. Epic is unsupported.
Extract each update into a fresh folder and keep the previous ZIP for rollback.

## Included behavior and defaults

- Solo, Host and Join in VR or Desktop, with a portable launcher and recovery.
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
- **Earlier fit reports:** SCAR magazine rotation, HMTech-501 magazine offset,
  Blunderbuss reload difficulty and FAL glove appearance.
- **Combat and networking:** crowded/grabbed retaliation, melee contacts,
  hosted body/grab stability, remote gestures and map travel need wider feedback.
  Multiplayer grabs initially remain OFF.
- **Coverage:** other headsets, larger player counts, sustained performance and
  complete matches are not comprehensively verified. Prior developer headset,
  hosted-server and install/recovery testing supports this private invitation;
  this is not a new claim of complete acceptance on the final ZIP.
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
passwords and join codes private. Post bug reports in Discord.
Contact the maintainer privately on Discord if needed.

Include build ID, Solo/Host/Join and VR/Desktop, map/perk/character/weapon,
headset/runtime/GPU, relevant options, last action, expected/actual result and
repeat steps. For reloads include normal/elite, empty/tactical and left/right hand.
For network issues identify which player saw it and whether they were outside
the host's network. The bundled FEEDBACK-QUESTIONS guide suggests useful feedback.

Keep the launcher open until cleanup finishes. After interruption, quit KF2
and use **Fix a stuck session** before deleting that folder or changing releases.
Never mix DLLs between releases or bypass a game/package mismatch. After cleanup,
ordinary KF2 can be started from Steam.

This private package includes locally derived assets. Redistribution review
remains deferred for the private test; no public distribution clearance is
claimed. The public source export excludes game/derived binary asset packages
and is a separate deliverable. See the included third-party notices.
