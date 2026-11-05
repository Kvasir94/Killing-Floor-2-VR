# KF2 VR release candidate - release notes

Made by Kvasir94 and optimumbox.

This is an early PCVR fan adaptation of Killing Floor 2 for Windows. It is
unaffiliated with Tripwire Interactive, NVIDIA, Valve or Epic Games. Download
complete playable ZIPs from
[GitHub Releases](https://github.com/Kvasir94/Killing-Floor-2-VR/releases).

**What these notes compare.** Most players are on optimumbox's public
**v0.5.2** (`v0.5.2-alpha.20261014`, source commit `b45ff53`). This release
candidate is `v0.3.0-alpha.20261105`, build `KF2VR-Multiplayer-20261105-054158`
from source commit `e8f19c3b`. Everything below is the difference
between those two builds. The launcher shows the build ID (also in
`app/release.json`). Extract each update into a fresh folder and keep the
previous ZIP for rollback.

## Compatibility

- **Everyone in a match needs this build.** Its game packages and network
  protocol changed, so a v0.5.2 player cannot join a server running this build,
  and this build cannot join a v0.5.2 server.
- **Steam is the supported store** for VR Solo, Host and Join. Epic remains an
  experimental Solo VR option, as in v0.5.2; Epic hosting, joining and
  cross-store play are not supported.
- **Steam Workshop:** the KF2VR Workshop item (3817663661) will be replaced by
  this build, so desktop players subscribed to it get this build once it is
  updated. Check that the build ID matches before joining a match.

## At a glance

- Physical reloads now cover almost every gun, with three reload styles and a
  separate AMMO RULES choice. New profiles start on **Button** reloads, which
  play like v0.5.2's default.
- Guns, magazines and pickups can be gravity-grabbed, dropped, thrown and
  caught; thrown guns hurt Zeds.
- Zed grabbing and throwing is allowed on every KF2-VR host, and kills with
  fists and body slams count as a "Bare hands" weapon.
- A new launcher window and matching headset settings, with a short
  first-time setup.
- DLSS is on by default (Auto) on NVIDIA RTX cards, with sharper hands and
  guns in motion.
- A bundled VR Range map for Solo practice.

## Reloads

**Reload styles** replace v0.5.2's RELOAD MODE (BUTTON / PHYSICAL /
PHYSICAL + PUMP), in the headset under Settings > Hands & Weapons or in the
launcher. MANUAL PUMP is folded into RELOAD BY HAND.

- **Button**, the default for new profiles: X / A or an empty trigger
  runs the stock reload, as in v0.5.2.
- **Manual**: reload by hand and cycle pumps, levers and bolts
  by hand between shots. An empty trigger starts the reload like X / A, and
  grabbing a new magazine releases the old one.
- **Realistic**: everything in Manual, plus you can rack a gun that
  is already loaded (the round it throws out is lost). An empty trigger clicks,
  the old magazine must come out by hand, and X / A can eject a full
  magazine.
- Changing any of these settings by hand shows the style as **CUSTOM**.

**AMMO RULES** (used only when reloading by hand): **Standard** (the default)
keeps stock ammunition counting. **Realistic** turns on three rules together:
a tactical reload keeps the round in the chamber (shown as +1 on the
readouts), rounds left in a dropped magazine are lost, and a dropped
magazine's rounds go back to your reserve when you pick it up. Any other mix
reads **Custom**.

**What reloading by hand covers now** (v0.5.2 had magazines, MG3 belt seating,
lever support, revolver speedloaders and hip reloads):

- **Magazine guns:** seat magazines in the well, rack slides and charging
  handles by hand (or against your chest, or on the other gun), release locked
  slides on slide pistols with X / A, and top up a 14 + 1 gun.
- **Belt-fed guns:** a loose belt that hangs and follows the hand, feed covers
  you grab, hold and slap shut, and the box that slides onto its mount.
- **Pump, lever and bolt actions:** deliberate strokes, levers that lock open
  on an empty tube, M99 and Mosin bolts at their real handles, Mosin stripper
  clips, and a support-hand pump on the FAMAS shotgun.
- **Break actions and revolvers:** tilt or tap to eject cases and live rounds
  (they slide out of their own chambers), hinged revolver cylinders open on
  X / A and close with a tap against your chest or the other gun, or a
  one-hand flick at the hip, swing-out cylinders tilt to empty, and break
  actions load several shells at once.
- **Dropped cylinders** from the 1858, Spitfire and Winterbite can be picked up
  like magazines.
- **Bow and crossbow:** nock an arrow from the side or nearby and draw the
  Compound Bow with the string hand; cock the crossbow forward and back by hand.
- **Launchers and specials:** the M32 cylinder shuts with a flick or a palm
  slap; HX25 and HRG Scorcher open, twist and tilt out their case; the HRG
  Head Hunter reloads on its stock side handle; the Beluga and Seal Squeal
  charging handles are hand-pumped; underbarrel launchers have their own
  physical reload, separate from the main gun's.
- **Blast Brawlers** fire per glove with loaded punches; an X / A tap reloads
  and a hold raises the guard. The Husk Cannon, Vampire and Brawlers keep
  button reloads in every style.
- **Hip reloads** extend to every one-handed gun with a hip loader when the
  other hand is busy. The loader glides from the pouch to the hip and back,
  and paired pistols hip-reload together, online too.
- **Busy-hand X / A:** with the other hand full, X / A does the whole reload
  and follows the AMMO RULES (it keeps the chambered round and drops the old
  magazine when those rules are on).
- **Feedback:** stock-styled part glows show the next step, sounds and haptics
  play at each mechanical stage, scopes stay live during reloads, ammo
  readouts show blocked feeds, and the empty-pouch ring follows the belt.
- **Loose rounds** on the ground fade after 30 seconds (the newest dozen
  stay); spent cases clear after 10 seconds. Scoop a pile in one grip, or
  gravity-pull a pile together.
- **New reload settings:** RELOAD BY HAND (now also covers cycling pumps and
  bolts), RACK A LOADED GUN, EMPTY TRIGGER RELOADS, NEW MAG RELEASES OLD,
  X / A EJECTS FULL MAG, RELOAD HINTS and SPRINT WHILE RELOADING (on).

## Weapons

- **Aiming:** guns aim from their measured sight line (all 101 stock sight
  profiles) and the final muzzle. New profiles use sight-point aim; v0.5.2
  converged on a point 20 m out.
- **Aim assistance** (HEADSHOT HELP in the headset): Off, Standard (the
  default) or Custom. It only uses
  stock near-headshot correction; recoil, spread and the camera are unchanged.
- **Gun angle:** Relaxed wrist (the default) or Straight (v0.5.2's default).
- **Laser:** a smaller default dot that stays readable on bright surfaces and
  at distance, with a player-chosen colour and look.
- **Rail Gun** starts in manual lock-on.
- Equipped weapon skins now show on split pistols and on other players' guns.
- Fire-mode changes give a distinct haptic pulse and work while sprinting.
- **Fixes:** the flamethrower spray starts at the muzzle online; the G18,
  Medic Rifle grenade launcher and Teslauncher fire after a physical reload;
  the C4 purchase delivers its charges; the Rhino aims from the gun and ejects
  when empty; the Doomstick no longer opens itself after the last shell;
  Hunting Shotgun cases leave the barrels; the HMTech-501 stops ejecting
  cosmetic grenades when empty.

## Interaction

- **Gravity grab** (on by default): point at a gun, magazine, ammo or other
  pickup and flick to pull it to the hand. Full or uncarriable targets explain
  why they cannot be taken. It is a player setting, and every KF2-VR host
  allows it.
- **Dropping, throwing and catching:** guns drop and throw in their
  first-person frame with real inertia and the body's walking speed, and can be
  caught with either hand. Thrown guns hit Zeds with blade or blunt damage, and
  thrown magazines make Zeds flinch. Catches, drops and impacts have their own
  sounds.
- **Recovering dropped guns:** dropped guns stay yours. AUTO RETURN brings them
  back after 5 seconds, or grab them by hand or with gravity.
- **Dropped magazines** can be picked up to return their rounds to the reserve
  (with the AMMO RULES), and a held magazine returns on pouch contact.
- **Support carry:** carry the gun in the support hand and regrip with the
  original hand.
- **Weapon wheel:** each pistol of a pair is its own entry, and guns in the air
  or on the ground appear on the wheel.
- **Quick heal:** tap or hold the heal button. The wheel's DROP menu can toss
  dosh.
- **Door welder:** a grabbable blue welder hologram at doors, and a stereo weld
  status panel instead of the flat door HUD.
- The chest grenade zone moves to the upper right of the chest, and
  Demolitionist dynamite and EMP grenades sit there too.

## Melee and Zed grabs

- **Zed grabbing and throwing** and the gravity grab are on by default, in
  Solo and online. Each player can turn them off for themselves, and a host can
  turn either off for everyone with the Host page's **Zed grabs** and **Gravity
  grab** switches. v0.5.2's off-by-default `-MultiplayerGrabs` switch is gone. Thrown Zeds and corpses carry weight by
  the piece you hold.
- **Bare hands:** kills with fists, gloves, shoves and body slams are credited
  to a "Bare hands" weapon. Fists break glass and other breakables.
- **Tomahawk recall** makes a small return sweep and tugs whatever it is stuck
  in.
- **B&S2 MELEE** (a new setting, off by default): weapon weight and edge
  alignment, parries, stab-and-stick, pommel hits, palm shoves, weapons that
  stop at walls, grapple hand poses and texture haptics.
- Bash damage scales with contact speed; ordinary fists are capped at stock
  bash damage.

## Hands and avatars

- **The KF2 hands package ships with the release** (gloves, wristwatch and
  scarred wrists), with grip and reload poses sampled from the stock
  first-person rigs. Like the rest of the playable package it contains
  KF2-derived assets; see the disclaimer at the end.
- Authored grips for every grenade type, and reworked support-hand fit on the
  AK12 and Tommy Gun.
- Other players see your carried ammo, gun mechanisms and physical reloads,
  your support hand on the gun's support grip, and a head-tracked flashlight.
- Hands stay visible at steep angles.

## HUD and visuals

- Wave, boss and priority notices show their full text in the headset; the
  flat stock banners stay out of view.
- Objective markers, larger damage numbers (now off by default; first-time
  setup asks), pouch cards that read on Quest 2,
  and interaction prompts that name VR controls.
- **Removed from the HUD:** the floating top session panel (the wristwatch
  shows the same information) and the Rack 'Em Up streak counter (its sound
  still marks each tier).
- **Glow colours:** ammo hints and action hints have separate, player-chosen
  colours. Floor ammo flashes green; blue pickup rings only show where useful.
- The VR menu and loading view are restyled and play the stock menu and
  loading movies.

## Rendering and performance

- **DLSS defaults to Auto:** Quality on an NVIDIA RTX card, ordinary rendering
  on any other GPU (v0.5.2 defaulted DLSS off). VR Settings > Graphics shows
  which one is running.
- DLSS now gets real per-object motion from the game, including the held gun,
  so hands and guns blur and smear less.
- Reflections no longer show stale images behind your hands and guns.
- Motion blur draws only if you choose cinematic blur.
- NVIDIA GeForce Experience settings no longer change the game, and the
  launcher's PhysX level is kept.
- **Single-pass stereo and a separate render thread are always on** (Steam
  and Epic) for performance; they are no longer options.
- **Fixes:** a twice-a-second movement hitch, a crash with a very large
  inventory, and crashes when recalling or catching a dropped gun.

## Settings, launcher and menus

- **New launcher window.** First launch finds your game, checks your headset
  app and asks a few setup questions (hand, seated, movement, grip, reloads,
  graphics, damage numbers). Then **Quick start** or **Play again** starts your
  usual match, with **Solo match**, **Host a game** and **Join a friend** for
  changes. Join takes a join code or an address with any port.
- **Settings** use the same pages in the launcher and the headset: **Comfort**,
  **Hands & Weapons**, **Graphics & HUD** and **Audio**. Each starts with its
  presets, settings that don't apply are hidden, and search finds older names.
  Calibration, fit and feel tuning live in the headset menu. They replace
  v0.5.2's VR SETTINGS, GAME SETTINGS, PRACTICE AND TOOLS, CALIBRATION and
  EXPERIMENTAL MULTIPLAYER GRABBING pages.
- **Help** has Repair after a crash, Save logs for a bug report and Report a
  bug, which opens the KF2-VR thread on the Flat2VR Discord.
- **Stock game options in VR:** gore level (with corrected labels), kill
  ticker, boss health bar, HUD colours, headshot effects and Clot grab turn.
- **FUN & CHEATS** menu: Boxing Gloves, Super Strength (both start off each
  session), VR practice and the Remilly sandbox (unranked, no XP).
- Grenades always use the authored hand pose.
- **Audio** page: master, effects, dialogue, music and voice volumes, music
  vocals, reduced chatter, and a microphone mode (open mic or push-to-talk)
  with a mute you can reach from the wheel.
- **Solo weapon-wheel slowdown** (on, 20% world speed) while choosing a weapon.
- **Maps:** installed Workshop and cache maps are offered in the launcher. The
  bundled **VR Range** is a Solo map for practice with live targets.
- **Hosting:** Max Zeds, Zeds per wave and spawn rate overrides for Solo or
  Host (they turn on the Unofficial KF2 Patch to apply them), and the
  dedicated server now installs in a KF2-VR Data folder on
  the KF2 drive (about 9 GB to download, 32 GB installed), resumes failed
  downloads, stops if you close the launcher during the download, and reuses
  a server this PC already has.

## Multiplayer and dedicated servers

- Perk XP earned on a KF2-VR dedicated host is saved; ordinary VR Solo stays
  ranked.
- Thrown and dropped guns, magazines, gravity pulls and Zed grabs each have
  their own host-checked channel.
- **Fixes:** dual 9mm and Deagle reloads online, 9mm and M14 reloads on a
  dedicated host, the Doshinegun's online reload, knife releases, walking
  throws, pouch returns from above, one lost reply freezing every gun, a slow
  trader, the welder offer for joining players, and a dedicated host
  re-sending inventory when it changes.

## Install and packaging

- The ZIP adds the VR Range map, a player guide, DLSS, Linux and Epic desktop
  guides, and licence notices for DLSS, AMD CAS and the ranked patch. A
  matching Linux kit and Epic desktop pack are published beside it.
- Developer and diagnostic tools are no longer in the player ZIP, and the
  launcher shows no developer options.
- The Steam Workshop setup now runs from the shipped launcher per Steam account
  and can be undone, instead of v0.5.2's separate setup script.

## Changed from v0.5.2

Things a v0.5.2 player will notice on a fresh profile; saved choices are kept.

| Setting | v0.5.2 | This build |
| --- | --- | --- |
| Reloads | BUTTON reload mode | Button |
| Stick crouch | On | Off |
| Smooth turn speed | 50% | 100%, now a fixed 120 degrees a second; a profile saved at 75% moves to 100% once (snap turn of 30 degrees stays the default) |
| Game length | Short | Medium |
| Headset graphics preset | Performance | Quality (render scale stays 100%) |
| DLSS | Off, sharpness 0 | Auto, sharpness 50 |
| Desktop Workshop joins (Host) | Off | On; off for that session if the published Workshop item does not match your build |
| Aiming | Sight line converged at 20 m | Sight point |
| Gun angle | Straight, 0 degrees | Relaxed wrist, -20.6 degrees |
| Gravity grab | Not in v0.5.2 | On |
| Online Zed grabs | Host option, off | On; the host can turn it off |
| Single-pass stereo and render thread | Options, off | Always on |
| Damage numbers | On | Off (first-time setup asks) |

Motion blur, depth of field, film grain, lens flares and on-screen bile and
blood splatter are off; gore stays at High.

## Removed

- **Portal content** (the Portal Gun and its art, launcher option and
  switches) and native portal capture.
- The **Breacher** launcher option; Breacher stays parked in the source.
- **Body holsters** and their setting.
- The host option to slow everyone's world while a VR player holds the weapon
  wheel (Solo keeps its own slowdown).
- The single-pass stereo and threaded rendering options (both always on now).
- The Grenade hand pose choice.
- NVIDIA FleX gore choices (FleX stays off).
- The floating top HUD panel (see HUD).

## Changed launch switches

Saved launch lines that pass `-MultiplayerGrabs`, `-PortalGun`, `-Breacher`
or `-SinglePass` now fail with an unknown-switch error. `-InventoryFocus` and `-Flex` are
still accepted but have no effect. New switches: `-Dlss`,
`-DlssSharpness`, `-Hbao`, `-Reflections`, `-HideBloodLens`, `-ZedGrabs`,
`-GravityGrab`, `-MaxZeds`, `-WaveZedsPercent` and `-SpawnRatePercent`. See
PLAY-MULTIPLAYER.md for the full table.

## Known issues

Please include the build ID when you report one of these.

- **Hands can look see-through** against busy backgrounds, most visible with
  HBAO+ or reflections on.
- **Image blur and reflections:** the image can blur when the headset moves,
  and floor reflections can shift or vanish with head movement.
- **Online:** the shooting range controls are incomplete; a joining player can
  miss the trader trigger or the welder offer; the in-game vote panel cannot
  be clicked.
- **Menus:** square artifacts or bands can appear; Start Solo Match on the
  Remilly test map can do nothing; fitting holsters in calibration says to
  turn on BODY HOLSTERS, a setting that no longer exists.
- **Reloads still being checked in the headset:** chest racks should follow
  the rack travel; Button reloads should always start the stock reload on an
  empty trigger; the reload styles and AMMO RULES should set NEW MAG RELEASES
  OLD, X / A EJECTS FULL MAG and KEEP CHAMBERED ROUND exactly as described
  above; X / A should close an action only where the real gun has a release.
  Some guns may not behave as described yet.
- **Reload rough edges:** a mixed grip does not release the
  trigger hand; lever rifles, the bow, the crossbow, the M99, the 1858 and the
  SW500 have open reports.
- **Interaction:** gravity-grabbed guns can show a purple-and-white texture,
  and some guns you cannot carry are still targeted.
- **The first-launch VR Training** is not in this release.
- **Coverage:** other headsets, larger player counts, long sessions and the
  full weapon list are not comprehensively tested.
- **Progression:** KF2-VR servers are custom VAC-off servers, separate from
  official ranked play.

## Report and recover

Click **Help > Save logs for a bug report** in the launcher. The ZIP appears beside
**Start KF2-VR**. Report copies replace recognized personal paths, known names,
account IDs, addresses and emails with aliases; passwords, recognized tokens
and join codes are removed. Original files remain local; configs, deployment
backups and crash dumps are excluded. Review the ZIP before sharing because
free-form text can contain other personal details. Keep raw logs/configs/dumps,
passwords and join codes private. Post bug reports in the KF2-VR thread on the
Flat2VR Discord (**Help > Report a bug**) or in
[GitHub Issues](https://github.com/Kvasir94/Killing-Floor-2-VR/issues); keep
sensitive details private.

Include build ID, Solo/Host/Join and VR/Desktop, map/perk/character/weapon,
headset/runtime/GPU, relevant options, last action, expected/actual result and
repeat steps. For reloads include the reload style, normal/elite,
empty/tactical and left/right hand. For network issues identify which player
saw it and whether they were outside the host's network. The bundled
FEEDBACK-QUESTIONS guide suggests useful feedback.

Keep the launcher open until cleanup finishes. After interruption, quit KF2
and use **Help > Repair after a crash** before deleting that folder or changing releases.
Never mix DLLs between releases or bypass a game/package mismatch. After cleanup,
ordinary KF2 can be started from your store.

Playable packages include KF2/Valve-derived assets whose rights remain with
their respective owners. Redistribution clearance is unresolved; public availability
does not establish clearance. Source archives exclude these binary packages and
require local game/SDK inputs to build. Original contributions are MIT-licensed;
Made by Kvasir94 and optimumbox. NVIDIA's DLSS runtime and other bundled
components keep their own notices. See
the included third-party notices and [credits](../../CREDITS.md).
