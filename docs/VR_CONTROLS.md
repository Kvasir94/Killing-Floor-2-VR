# KF2-VR controls and tips

Use the build ID shown by your launcher when reporting issues.
Existing saved settings can override launcher defaults.

## Player guide and tips

Start the extracted ZIP with **Start KF2-VR**. Pick **VR headset** or
**Desktop - no headset**, then **Play solo**, **Host a game** or **Join a friend**.
Solo/Host have a **Start** button after their options; Join uses **Paste code**
then **Join**. In the lobby choose a perk and Ready. Keep the launcher open for
cleanup when the game exits. Start ordinary KF2 from your store once before first setup,
and activate your headset software's OpenXR runtime for VR. The package must
match the exact installed Steam or Epic KF2 executable. Epic is experimental
Solo VR only, using session Launch Options pasted into the official Epic launcher.
Host/Join/Desktop and recording are unavailable for Epic; see READ ME FIRST.

Button names below refer to physical controllers, not keyboard keys. Touch has
X/Y on the left and A/B on the right: X/A are the lower action buttons, Y/B the
upper inventory buttons. Index uses A/B on each hand for those same actions;
use the centred two-stick-click chord for the VR menu because its system button
is reserved. The OpenXR binding suggestions also include Vive trackpad and WMR
stick/grip/menu actions, but do not supply their lower/upper face-button actions.
Do not assume complete wheel/reload support on those controllers or a simple
select-only controller. Validate the available runtime bindings before claiming
support. Changing movement/dominant hand does not swap physical X/Y/A/B labels.

For a fresh profile: left stick moves relative to the head, right stick turns,
30-degree snap turn is ON, click-to-sprint is used, and down-stick crouch is ON.
The weapon hand defaults right; menu pointer defaults right. Performance / 75%
render scale is the launcher starting point. Button reloads, latched transfer/
brace grip, held support grip and support-hand gun aiming are defaults. Physical reloads/manual pump,
body holsters, threaded rendering, Portal/Breacher content and host inventory
slowdown start OFF. Solo Zed grabs start ON; experimental multiplayer grabs
start OFF and follow the host. Saved preferences override starting defaults.

**Fast equipment reminders**

- Hold that hand's Y/B for 250 ms, then release: its wheel stays open. Point or
  move the same controller to highlight a sector, squeeze **and release** its
  trigger to confirm. The stick does not select an icon. Y/B cancels; a trigger
  click with nothing highlighted also cancels. Return that stick to centre
  before expecting movement/turning after closing the wheel.
- Single-tap Y/B recalls that hand's previous item, or opens it if no distinct
  previous item exists. Double-tap stows an occupied hand. Double-tap an already
  empty hand to draw the syringe; alternatively choose it on the wheel. There
  is no active wrist/forearm syringe pouch and no automatic grip-release return.
- With the syringe equipped, bring that hand near the upper chest below the
  head and pull trigger for self-healing. The automatic self-heal zone is within
  32 UU of a point 35 UU below the head. Outside that zone trigger uses the
  teammate-heal action along the syringe aim; X/A plus a fresh trigger also
  requests its secondary/self-heal action. Stow or swap when finished.
- For a chest grenade, first empty a hand and release support grip. Bring its
  palm to the visible grenade, squeeze and **hold grip**, swing, then release
  grip to throw. Trigger does not throw it. A release at rest drops it; a
  very short grab or invalid tracking can cancel without spending ammunition.
- For two-hand support, squeeze at the gun's support contact. The default is
  hold-to-support; release or leave the contact to detach. Weapons stay equipped
  when fingers relax. To transfer primary ownership, use a support-only carry
  after the old primary is stowed, move to the primary grip and pull trigger;
  that pull claims the item and a fresh pull fires. It is not an unconditional
  swap while the other hand remains primary.
- Optional holsters: **VR SETTINGS > INTERACTION > BODY HOLSTERS**. Two shoulder
  positions hold long guns, two hip positions hold compatible one-hand items.
  Arrive at a compatible slot and freshly squeeze grip to stow; an empty hand
  squeezes a filled slot to draw. Release support and settle before stowing.
  Syringe and welder are excluded. **HOLSTER FIT** calibrates the hip slots.
- Dosh remains the stock toss action, not a hip-wallet grab: keyboard **B** on
  the default desktop layout. VR controller B still controls right-hand inventory.
- Y/B beside that controller's temple toggles the flashlight instead of swapping.
  The non-movement-stick click offers the welder near a closed/broken door; it
  always equips the right hand. Trigger welds, A plus trigger unwelds; click
  again or walk away to return the previous right-hand item.

**Comfort, menus and practice**

Movement-stick click latches sprint while deflected; centre it or crouch to end
the request. Fire/draw/reload can pause sprint. On the turn stick, push mostly
up/down to the outer rim for jump/crouch; up stands from a latched stick crouch
before jumping. Physical crouch uses the captured height baseline. For teleport,
select **VR SETTINGS > LOCOMOTION AND COMFORT > MOVEMENT: TELEPORT**: deflect
the movement stick, aim that controller's arc, and **return to centre to commit**
a valid destination. Click that stick to cancel without teleporting. Keep the
turn stick for facing; arrival-facing is a separate optional preference.

Menu button toggles the VR menu. Alternatively centre both sticks, release both
triggers, and hold both stick clicks for 0.6 s with tracking valid. The current
menu pauses a living Solo match when it can acquire pause ownership; online
matches continue. Use the pointer hand and trigger for menu targets. Press/release
the same target for +/- changes. Calibration tile editors use hand movement and
a trigger click; changes auto-save. **RESUME GAME** returns to play; finish or
cancel stock popups first. Before Ready, choose **PERKS / READY**; the scoreboard
requires an in-match score widget. Walk into the trader pod to use its stock
menu in VR. The root also has perks/skills, game settings, local-match/server-
leave controls, practice/tools and Quit.

Use **CALIBRATION** directly from the root VR menu, or **VR SETTINGS > CALIBRATION**,
for global weapon fit/profile reset, standing/
seated baseline and chest-zone capture/reset. **MENU AND INTERFACE** sets pointer
hand, panel placement and recenter. **HUD AND READOUTS** adjusts ammo/top-HUD
placement, watch/readouts, damage popups, laser pointer and reload hints. **GRAPHICS**
adjusts render scale and supported quality/lighting; locked VR effects are status
rows. Capture your actual posture; recentering and seated play do not turn on
teleport. **RESET PROFILE FIT** uses the selected Neutral/Relaxed-wrist/Legacy fit.

**PRACTICE AND TOOLS** opens calibration, practice, its armory and healing patient.
Solo armory can add/equip registered items; network armory equips owned items.
Network practice requires sole-player/admin permission. Practice suspends waves,
refills ammo and enables invulnerability; **END PRACTICE** ends it, while closing
the panel alone does not. Practice/God Mode leaves that session unranked.
The wheel's **+** submenu exposes Drop, God Mode and Back; Drop follows stock
item restrictions. It does not grant an unowned weapon.

**Combat and special items**

Aim/fire each hand independently. X/A short tap reloads on release; hold changes
a persistent mode where supported, or combine it with a fresh same-hand trigger
for secondary fire. Release a previously held trigger before requesting a secondary.
Use **VR SETTINGS > INTERACTION > RELOAD MODE** to cycle **BUTTON > PHYSICAL >
PHYSICAL + PUMP**. Unsupported weapons retain their normal path. In physical
reloads, follow the active ammo/action hint: off-hand trigger takes and carries
ammo, seated contact credits it, and the action must be completed where required.
X/A can release a supported locked slide after seating. Guidance and detailed
per-family actions are below; coverage is not arsenal-wide headset acceptance.

Empty clenched hands punch by swinging; grip plus held trigger charges that
fist. Spend the charge with a punch while still holding; release/open/stow cancels.
Raise both empty clenched fists to guard/parry; lower/re-raise to rearm. Melee
weapons and gun bashes use motion contacts. Supported two-hand melee guards use
a braced weapon across the body; button-guard profiles use X/A, and their
heavy/secondary action uses X/A plus a fresh trigger where supported. Physical
melee does not universally use trigger for an ordinary swing. Ion Thruster's
quick X/A asks for its charged ultimate. Keep weapon-specific firing actions.

An empty hand grips a nearby eligible Zed/body to hold it where allowed; keep
grip held, then release to drop/throw. That hand is occupied, the other can act.
Multiplayer grabbing permission belongs to the host. Multiplayer empty hands
can fist-bump (clenched) or high-five (open) a teammate; gestures are always on,
with participants' haptics and shared effects. These still need real-player
acceptance and have no dedicated controller switch.

C4/Sentinel/Bombardier: equip, hold trigger, swing and release trigger to throw
or place; X/A plus trigger invokes detonation. RAVEN-7: hold trigger to prepare,
swing and release to throw; a fresh airborne trigger hold suspends it and
release recalls, while a resting axe recalls on the new press. Fresh grip is
a recall shortcut. Portal Gun, when offered in Solo: trigger places blue,
X/A plus trigger places orange, quick X/A dismisses portals. Threaded rendering
must be OFF for portal see-through views. Ported tools route their secondary
intent through X/A plus trigger; their separate content guides describe special
stock actions. Optional Breacher controls are in the bundled BREACHER guide.

**Friends, desktop and recovery**

Host/Join can each use VR or Desktop. First hosting downloads a separate server
(about 32 GB). Allow KFServer through Windows Firewall and forward UDP 7777/27015
for internet friends. Host **Copy code** generates a password-bearing `KF2VR1:`
code; share it privately. Friends **Paste code > Join** with the same package;
they need no server download or port forwarding. Use VAC-off sessions supplied
by the launcher. Lobby Ready, real-WAN reachability and online voice must be
checked with the partner; custom multiplayer does not promise normal progression.

Desktop uses the player's stock KF2 bindings. With the installed game's default
keyboard layout: WASD move, mouse aims, left mouse fires, right mouse toggles
sights, middle mouse changes fire mode, R reloads, G throws grenade, Q quick-heals,
V bashes, E/Enter interacts, F toggles flashlight, Shift sprints, Space jumps,
C toggles crouch, wheel cycles weapons, 1-4 select groups, Backspace drops the
weapon, B tosses dosh, Escape opens menus, Tab shows scores, T/Y open public/team
chat, Z opens voice commands, Caps Lock is push-to-talk, F1/F2 vote, and X toggles
friendly UI. Saved custom bindings take precedence. Desktop stock gamepad mapping
also remains available: left stick walks, its click runs/crouches through stock
GamepadSprint; right stick aims, its click bashes; A jumps/votes Yes, B interacts/
votes No; X tap reloads and hold quick-heals; Y tap switches per the stock last/
cycle preference and hold opens its selector. RT fires, LT sights, LB grenades,
RB uses stock fire-mode/secondary behavior (or drops a permitted weapon with
the stock selector open). Start opens the menu, Back holds scores. In ordinary
play D-pad left opens voice commands, right tosses dosh, down toggles flashlight,
up switches to/from healer; with the stock weapon menu open left/right/down/up
choose groups 0/1/2/3. While spectating, left/right change player and down changes
camera. Saved settings and game state can change stock behavior. The VR controller chord
does not replace these desktop controls. There is no dedicated VR-controller push-to-talk binding
in the current action set; do not confuse the inventory buttons with voice.

Keep the launcher until cleanup completes. After interruption use **Fix a stuck
session** before deleting that folder, changing releases or playing ordinary KF2.
Extract updates into fresh folders; finish cleanup before reopening an older ZIP.
Never combine release DLLs. **Save logs for a bug report** creates a ZIP beside
Start KF2-VR; nothing uploads automatically. The launcher's collector anonymizes
recognized paths, known usernames/player names, account IDs, network addresses
and emails in report copies; passwords, recognized tokens and join codes are
removed. Original logs stay unchanged; configs and crash dumps are excluded.
Review any report
ZIP for other personal details in free-form text, share sensitive reports privately,
and include build ID (`app/release.json`), mode/map/weapon, headset/runtime/GPU,
options, expected/actual result and repeat steps. Keep raw logs/configs/dumps private.

Useful troubleshooting: release triggers after a menu/tracking interruption;
re-centre a wheel's stick before moving; empty both primary/support occupancy
before taking a chest grenade; try ordinary Button reload mode if an optional
physical mechanism blocks play; retain normal/elite, empty/tactical and handedness
in a reload report. Do not bypass a game/package mismatch or assume a compiled
candidate passed headset acceptance.

Solo Zed grabbing remains ON by default (`bZedGrabEnabled`) with an ordinary
ON/OFF preference under the game menus. Multiplayer grabbing is the host's
launch setting (OFF by default) and applies to every player; **Experimental**
shows it read-only. A one-player host is still multiplayer. Living Zeds, corpses,
gibs and their hold/swing/smash/throw interactions follow the same mode policy.
Loss of permission or context cancels owned holds without a throw. Fists,
charged fists, bashing, utility gestures and weapon/support grips remain available.

New profiles use neutral aim; Settings exposes **Relaxed-wrist fit (Arizona Sunshine 2,
-20.6 degrees)** and **Legacy Quest 2 fit (-8.6 degrees)**.
Existing fit values survive. The Advanced Hand / Holster Calibration panel still
owns detailed aim-fit adjustment. The portable ZIP contains a standalone quickstart.


The multiplayer mod lets VR players hold two different owned
supported weapons, with independent triggers and A/X reloads. An empty hand can
support the other gun. Desktop players retain stock weapon handling. Supported
stock pairs use shared solo/network conversion; live acceptance remains pending.
Physical melee, punching and charged fists remain core in solo and multiplayer. Inventory Focus also has
an experimental host-controlled online mode, Off by default (launcher option 7).
When enabled, a latched open wheel requests shared slowdown; confirming or
cancelling the wheel clears that request. Tap quick-swap stays at normal speed.

Each primary weapon has a compact world-space magazine readout just beside its
gun. It shows the current magazine and spare ammunition, with a small fill bar and an
explicit reload or empty state when applicable. It is local-only, follows the
actual held weapon, and hides when that hand or its tracking context is unavailable.
A muted `AUTO`, `SEMI`, or `BURST` badge appears only when the selected fire
mode is relevant, leaving the readout otherwise focused on ammunition.

## Default Quest / Touch layout

RAVEN-7 tomahawk (Berserker trader, VR only): draw into either hand and swing to
strike. Hold trigger to prepare, swing and release trigger to throw. A still-hand
release keeps it. With its slot selected, a fresh grip requests recall; a fresh
trigger hold suspends an airborne axe and release recalls it. A resting/embedded
axe recalls on the fresh press. You can throw, switch away, then draw the same
slot to recall. Behavior, tuning and pending acceptance.

| Input | Action |
|---|---|
| Movement stick (left by default) | Move; deflection alone does not start sprint |
| Movement-stick click | Latch sprint while the movement stick is deflected in any direction; in teleport mode, cancel the arc. It lasts until the stick returns to centre or you crouch; firing, reloading and drawing only pause it, and it resumes about 0.35 s after both triggers are released and the weapons allow sprint. KF2 still sets the speed for each direction |
| Non-movement stick left/right | Turn |
| Non-movement stick up | Jump at the outer rim (magnitude ≥ 0.95), mostly upward; returns to centre before the next jump. While a stick crouch is latched, up stands instead of jumping |
| Non-movement stick down | Toggle crouch at the outer rim, for seated or mobility-limited play: stock crouch with the view lowered as on flat. Up or a sprint click stands. VR SETTINGS > LOCOMOTION AND COMFORT > STICK CROUCH turns it off (default on) |
| Physical lowering | Stock crouch (bonuses, speed, capsule) after calibrated height threshold and dwell; the view is not lowered again, only the real head drop shows |
| Y / B, single tap (240 ms double-tap window) | Quick-swap the left / right hand's exact previous weapon, or stow to an open hand when no distinct previous weapon exists; cancel while open |
| Y / B, double tap | Stow/open only that controller's hand through the inventory ownership path; carried weapons and previous-item history remain available; empty hands still punch and charge fists. A hand that is already open draws the syringe instead (refused if the other hand holds it) |
| Y / B pressed with that hand beside the head | Toggle the flashlight (head lamp), whatever either hand holds. The hand must be within 20 UU of the head and not in front of the face, so a raised pistol still quick-swaps; the press never opens the wheel |
| Y / B, hold 250 ms then release | Open spatial inventory for that same hand; it stays open. The opening hand's stick is idle while it is open; the other stick keeps its locomotion role |
| Point or move the opening controller toward an icon, then squeeze and release its trigger | Equip into that same hand on release and close the wheel automatically; stick tilt never highlights a sector |
| Trigger with the hand back at the centre (nothing highlighted), or Y / B while the wheel is open | Cancel |
| Wheel > + (DROP / GOD MODE) > DROP | Throw that hand's item as the stock pickup a teammate can collect. Stock rules apply: the knife, 9mm backup, welder and VR pair members cannot be dropped |
| >> sector + trigger click (only with more than eight carried items) | Cycle carried-weapon pages and keep the wheel open |
| Grip | Hold support contact while squeezed by default; primary stays equipped. Emptying a primary uses OPEN HAND or double-tap Y/B. Body zones override a nearby Zed grab; a valid support contact wins before optional body-slot/chest-grenade arbitration. No active wrist syringe or hip wallet |
| Draw syringe from wheel, or double-tap Y/B on an already empty hand | Syringe remains equipped until stowed/switched. Trigger with the hand near the upper chest (32 UU around a point 35 UU below the head) self-heals; outside that zone trigger uses teammate healing along its aim. X/A plus a fresh trigger invokes its secondary/self-heal action |
| Empty hand: grip the visible chest grenade, swing, release grip | Hold-to-carry even with latched primary grip. Grip release throws/drops; trigger does not. Invalid/very short sampling can cancel without spending a grenade |
| Empty hand: grip near a Zed, corpse or gib | Zed grab (`bZedGrabEnabled`, on by default in Solo): hold-only even under toggle grip. Release drops it; release while moving throws it. Bosses never; large Zeds only when eligible. Chest grenade and optional body zones take priority over nearby Zed grabs. The holding hand runs nothing else; multiplayer follows the host |
| Support-only carry with no current primary, hand at the primary grip + trigger | Promote that hand to primary; the claiming pull does not fire. This is not a swap while the other hand remains primary |
| X / A, tap and release | Reload left / right item immediately on release |
| X / A, hold | Change one persistent firing mode, or prepare that hand's temporary secondary modifier; see Weapons |
| X / A + that hand's fresh trigger pull | Secondary fire for a secondary-action weapon. Single-shot secondaries (e.g. the double-barrel shotguns) need a fresh pull per shot; continuous ones fire while held |
| Non-movement stick click | Door context action: next to a closed or broken door, draw the welder into the right hand; click again to put it away. Does nothing elsewhere. Suppressed while a wheel is open. There is no stick bash; bash physically |
| Trigger | Operate that hand's item; an open empty hand interacts. Syringe self-heal uses the upper-chest zone described above |
| Empty hand: clenched grip + hold trigger | Charge that fist (red glow, rising haptics); punch while still holding to spend it. Replaces interact while clenched, including a partial analog squeeze |
| Menu button, or both stick clicks held 0.6 s | Toggle and recentre the VR menu (stock UI floats inside). The chord needs both sticks centred, both triggers released and both hands tracked |

During play, stock game-menu panels also show **RESUME GAME** in the lower-right corner. Select it with the pointer trigger to return to the match; popups must be finished or cancelled first.

Weapons stay held after the fingers relax. The radial is anchored when opened,
80 UU ahead, 20 UU below eye level and 12 UU toward its own side (38 UU when
both wheels are open, side by side). It follows player translation without
following hand tremor or head turns. The wheel has at most ten equal sectors:
OPEN HAND (top), up to eight carried items, then the + sector (DROP / GOD MODE / BACK). Only with nine
or more carried items does it page: seven items per page plus a fixed
`>> PAGE n/N` sector, and every page keeps all ten sectors so OPEN HAND, NEXT
and + never move (a short last page leaves its spare sectors empty).
The stock start (perk weapon, 9mm, knife, syringe; the welder is door-only)
plus four purchases fits one page.

Order follows KF2's own `InventoryGroup`: primary, then secondary, then melee
weapons, then the backup 9mm/knife (`bIsBackupWeapon`), then equipment such as
the syringe. The forearm pouch is inactive. Within a group, acquisition
order is kept, so new purchases append to their group. `SelectorFavorites`
lead. Nothing is hidden or removed: every owned, supported item stays on the
wheel. Converted pairs occupy one choice, ranked as the stock dual; drawing
resolves the opening hand's existing member or an available member, retaining
exact magazines. Unowned items disappear. Stock silhouettes stay prominent and
shrink only as far as needed to keep ten apart; only the highlighted choice
shows its name and exact ammunition, on a red spray slash. An item held by the
other hand is dimmed and marked HELD.

Each gun has a spray-painted ammo bar: magazine plus reserve over the most it
can carry (stock `GetTotalAmmoAmount` / `GetMaxAmmoAmount`), with a tick at one
magazine's worth. It is off-white, amber below 25%, and an empty gun shows a
hollow red bar marked EMPTY with its silhouette faded. The syringe's bar is its
heal charge in blue; melee and the open hand have none.

The wheel bursts out of the opening controller in 0.2 s, overshoots and settles
at its anchor, throwing a red spray ring; the hovered item pops as it is
highlighted; a click that closes the wheel collapses it back into the hand in
0.14 s. All of it runs on real time, so Zed Time does not slow it. A cancel by
Y/B closes it at once.

Selection is by the controller only; the thumbstick never highlights a sector.
Moving and pointing drive one cursor in the wheel plane, measured from the
controller's pose when the wheel opened (not from the rendered wheel): hand
travel plus the change in pointing direction taken at a 40 UU lever, so about
10 degrees of wrist tilt equals 7 UU of travel and the two add together. Only
the cursor's direction picks the sector; every sector is an equal wedge from
the centre outward, with no outer or depth limit, so reaching toward the wheel
keeps the choice. The cursor enters a sector beyond 7 UU and clears only back
inside 4.5 UU. A highlighted sector holds until the cursor is a quarter sector
(at most ten degrees) into its neighbour. The cursor is smoothed over 35 ms of
real time, a red pip on the wheel shows its exact direction, and each change
pulses lightly. Once the trigger passes 30% of its travel the cursor holds, so
the pull cannot tip the choice; release confirms, with distinct confirmation
haptics. A trigger held on entry cannot equip or fire. Trigger with nothing
highlighted and Y/B cancel; page/settings navigation keeps the selector open.
The owning stick is captured and does nothing while its wheel is open, and it
must return to neutral before resuming movement or turning. (Stick-tilt
selection is not supported.)

Single-tap Y/B waits 240 ms to distinguish a double tap without performing an
intermediate swap. A second held press opens the wheel; it does not first empty
the hand. Tracking/menu loss clears pending gestures. Temple flashlight presses
remain a separate consumed gesture. Settings still use their calibration editor;
inventory selection never shows both hands in columns.

## Weapons

For a physical gun stock, select **VR SETTINGS > INTERACTION > SUPPORT HAND
AIMS GUN: OFF**. The primary controller owns firearm aim and placement while
the support grip retains its usual braced spread/recoil benefits. This saves
across Solo/multiplayer (`bDisableSupportHandAim=True`). ON remains the default.
The support hand must still reach the authored contact. This option does not
calibrate stock mount spacing or change two-hand melee. Headset feedback is pending.

Pistols and revolvers can be braced with an empty hand: bring it to the firing
hand at the grip and squeeze grip. The support hand uses the weapon's authored
KF2 pose, mirrored when the left hand is primary. The 1858, Flare and Winterbite
borrow the stock 9mm support pose fitted to their firing wrist, since their own
idle/ADS off-hand poses are for hammer fanning. The primary controller alone
sets aim direction; moving the support hand never steers a pistol. Unbraced
shots use stock hip-fire spread and recoil. Valid bracing uses stock ADS spread
and recoil, without zoom or a sight animation. Release grip or move away to
detach; lost tracking removes the bonus immediately. Two separately held
pistols each use hip handling. These rules are shared by solo and multiplayer,
including converted stock-pair members. The HX25 uses the same brace and handling
policy, with its own authored receiver contact.

| Item | X / A hold |
|---|---|
| AR-15 | One persistent change: BURST / SEMI |
| SCAR-H, MP7, AA12, FN FAL, SA80, P90, Kriss, Glock 18c, MKb.42, Mac 10 | One persistent change: AUTO / SEMI |
| AK-12, Helios Rifle | One persistent change: AUTO / BURST |
| HRG Disrupter | One persistent change: SEMI / CHARGED (stock toggle; refused or reverted when ammo is short) |
| MG3 Shredder | One persistent change: AUTO / SPREAD (stock toggle; spread shots cost 3 rounds) |
| Seeker Six | One persistent change: SINGLE / LOCK-ON; in LOCK-ON, point the barrel at Zeds to lock them, then fire one rocket per lock |
| HRG Tommy Boom | One persistent change: AUTO / SEMI |
| HRG Blast Brawlers | Block/parry (button-driven melee); tap reloads shells; trigger attack fires the blast while loaded, reloads when empty |
| Frost Fang | Temporary modifier: pull the trigger while held for the stock stab; tap reloads. Trigger fires the shotgun; swing the blade physically and brace with both hands across the chest to block |
| VLAD-1000 | One persistent change: SPREAD / SINGLE nail |
| Doomstick | Temporary secondary modifier: pull the trigger while held to fire every loaded barrel |
| S12 Shockgun | Temporary secondary modifier for the shock attachment |
| FAMAS Masterkey | Temporary secondary modifier: pull the trigger while held to fire the underslung shotgun; tap reloads the rifle, or the shotgun when the rifle is full |
| HRG Incendiary Rifle | Temporary secondary modifier: pull the trigger while held to fire the incendiary grenade |
| HRG Dragonsblaze | Temporary secondary modifier: pull the trigger while held for the wide-spread shot |
| Thermite Bore | Temporary secondary modifier: pull the trigger while held to detonate stuck rounds |
| Seal Squeal | Temporary secondary modifier: pull the trigger while held to detonate stuck harpoons |
| HRG Crossboom | Temporary secondary modifier: pull the trigger while held to fire the delayed-detonation bolt |
| Hunting shotgun, HRG Kaboomstick | Temporary secondary modifier: pull the same hand's trigger while held to fire both barrels |
| Blunderbuss, HRG Scorcher | Temporary secondary modifier for the stock secondary shot |
| Microwave Gun | Temporary secondary modifier: pull the trigger while held for the stock microwave blast |
| Gravity Imploder | Temporary secondary modifier: pull the trigger while held for the stock implosion shot |
| M16 M203 | Temporary secondary modifier: pull the trigger while held to fire the grenade |
| MP5RAS, UMP | One persistent change: AUTO / BURST |
| Tommy Gun, G36C, Riot Shield Glock | One persistent change: AUTO / SEMI |
| HRG Nailgun | One persistent change: SPREAD / SINGLE nail |
| HRG Stunner | Temporary secondary modifier for the stock secondary shot |
| HRG Bastion | Deploys or stows the barrier shield (stock action); the trigger always fires the rifle |
| HMTech-501, HRG Healthrower, HRG Vampire, Mine Reconstructor | Temporary secondary modifier for the stock healing secondary |
| Freezethrower, HRG Arc Generator, HRG Teslauncher | Temporary secondary modifier for the stock secondary |
| Killerwatt | One persistent change: AUTO / CHARGE; in CHARGE, hold the trigger to charge and release to fire |
| HRG Locust | One persistent change: SINGLE / LOCK-ON; in LOCK-ON, point the barrel at Zeds to lock them |
| Doshinegun | One persistent change: AUTO / SEMI |
| C4, HRG Bombardier, Sentinel | Temporary secondary modifier: pull the trigger while held to detonate. The trigger alone throws physically; see Deployables |
| Rail Gun | One persistent change: AUTO / MANUAL; AUTO counts as sighted, so it locks a Zed's weak spot and fires at the lock as in stock |
| Mosin Nagant | Block/parry (stock); pull the trigger while held for the stock bayonet bash; the trigger alone fires |
| HRG Head Hunter | Temporary secondary modifier: pull the trigger while held to fire the head-inflating dart |
| Compound Bow | One persistent change: SHARP / CRYO arrows (stock toggle, with its cryo glow); hold the trigger to draw, release to loose |
| HRG Beluga Beat | Temporary secondary modifier: pull the trigger while held for the stock fully charged sonic blast |
| Corrupter Carbine | Temporary secondary modifier: pull the trigger while held to fire the parasite seed |
| Medic pistol, HMTech-101/201/301/401, Hemogoblin, HRG Incision, syringe | Temporary secondary modifier; pull the same hand's trigger while held |
| Tracked Source / Engineer tools | Temporary held secondary intent through the existing tool interface |
| Portal Gun (experimental solo) | Tap X/A to close both portals; trigger places blue, X/A plus fresh trigger places orange through the tracked-tool secondary route. Portals stay open when the gun is holstered |
| Item with no secondary classification | No hold action; a quick tap still reloads when supported |

Pressing X/A starts a pending gesture. A short release reloads immediately; it
does not wait for the 250 ms hold threshold. Holding it changes a supported
persistent mode once, or primes a temporary secondary modifier without firing.
A fresh same-hand trigger pull while the modifier is held uses secondary fire
immediately, including when both inputs arrive in one sample. Releasing X/A
stops an active secondary and never falls through to primary fire. A held
trigger before X/A does not become secondary; release and pull again. Attempted
hold actions, including refused ones, do not reload on release.

Modes belong to the exact weapon and survive reload, stow and handoff. The HUD
shows the selected mode. A hold does not repeat a mode change. Mode changes
during firing, a held trigger, or stock non-active states are refused with a
soft haptic pulse. Each lower button only controls its own hand.

Button-driven non-physical melee is the explicit exception: trigger light
attack, X/A hold block/parry, X/A plus a fresh trigger pull heavy attack.
Pulverizer and other physical/ammo melee retain their profile-specific reload
and physical-action handling. Physical gun bashing and physical reloads are
not introduced by these bindings.

## Physical melee swings

Ordinary non-firearm melee swings no longer start a competing stock light/heavy
animation on the trigger. The moving damaging span activates contact, including
rotating tips, and sweeps between frames. Per-swing hit limits, settle/recovery,
wall checks and stock weapon damage/effects still apply. Legitimate explosive,
firearm and secondary trigger actions remain. Hooks and uppercuts use the same
closed-fist motion gates as straight punches, without a controller-forward test.
Being grappled does not disable melee; holding a Zed occupies only that hand.
The Blast Brawlers retain their trigger-operated, ammo-consuming shotgun
sequence alongside untriggered physical punches. A quick X/A tap asks the Ion
Thruster for its stock charged ultimate; the stock charge gate remains authoritative.

Static Strikers and Blast Brawlers register each moving gauntlet independently.
Opening the opposite hand with its B/Y double tap or OPEN HAND sector removes
that glove while retaining the primary gauntlet. It stays a real free hand for
punches, charged fists and equipment; clenching does not silently re-equip it.
Explicitly selecting/drawing the gauntlet weapon again restores both gloves
where the other hand is available. A second item or world grab occupies its own
hand and suppresses the corresponding gauntlet.


Every melee weapon swings physically, as the Pulverizer: a tracked swing of
the striking head hits what it sweeps, and a fast swing is a heavy attack.
Speeds match the fists, measured at the weapon head: a swing starts at 180 uu/s,
turns heavy at 550 uu/s (450 with both hands on the weapon) and reaches full
heavy force at 1.5x that (`VRPhysicalMelee`). Ordinary physical melee is motion-
driven; trigger remains for profile-specific firearm/explosive actions. Two-handed weapons block with the physical chest guard below;
one-handed weapons (knives, tomahawks, the Bone Crusher, the Static Strikers
and HRG Blast Brawlers) keep the X/A button block. Melee guns (Mosin,
Eviscerator, Frost Fang, Bladed Pistol) keep the trigger for the gun, and their
blade contacts use the stock bash damage (the Eviscerator's heavy swing is its
chainsaw; the Bladed Pistol's is its forward blade's dismembering slash).

## Melee block and parry

Button melee blocks as soon as X/A is pressed, with a firm pulse on that hand;
the parry window is 450 ms from the press (stock KF2 used the brace
animation's length). Pulverizer and Frost Fang guard physically: grip with both
hands and hold the shaft across your body, level or diagonal, anywhere from
the belly to just above eye level. Keep your hands still for about 55 ms to
raise it (a firm pulse on both hands); the parry window is 550 ms. A held
guard tolerates a push into the blow. It never renews the parry while you
hold it still. A short re-brace (push, then settle) re-opens it once the
previous window has closed. A successful parry gives a strong 120 ms pulse; a
block gives a shorter, softer one, alongside the stock sound and particle.
Stock rules still apply: the attacker must be within 85° of where you face,
only bludgeon/slash damage and grabs can be blocked, and releasing a button
block starts a 500 ms cooldown. A grab is blocked by whichever held melee item
is actually blocking, in either hand. As a network client, the server keeps
stock parry timing and grab checks; the feedback pulses still arrive.

## Physical punches and gun bashes

A clenched empty hand punches and a held firearm bashes when swung hard enough;
every enemy the stroke passes through is struck once, and only world geometry stops
it. A punch ends when the fist comes back against the way it was thrown, so each
jab of a combo is its own stroke; motion back toward the body never starts one.
Recovery (about 0.2 s) follows a stroke that struck something; a stroke that
hit nothing re-arms at once. Resting against a Zed or tracking jitter does not
repeat damage. A fist that reaches into a Zed's collision cylinder while moving
into it -- a Zed pressed against you, grabbing or crowding -- lands on the hit
zone nearest the knuckle, where rays starting inside its body see nothing. A
single impossible hand sample (a shove or hit moving the pawn and hands on
different ticks) re-seeds tracking instead of demanding the fist be held still.
Each stroke logs `KF2VR_MELEE kind=fist hand= reason= ... contact= near=`
(`near` is the closest gap to a live enemy's cylinder, negative inside), and a
fast clenched swing that could not start one logs `reason=unready`.

A punch lands by knuckle speed: 15 damage for a slow tap up to 45 for a full
swing (250-750 uu/s), with knockback scaling to match. From 60% of that range
upward it uses `VRDT_FistDamageHeavy`, which staggers; slower punches
(`VRDT_FistDamage`) only flinch. Tuning lives in `VRPhysicalFist`
defaultproperties. A landed hit is a sharp haptic spike followed by a body that
grows with the punch (longer on a stagger, parry or kill); fists on walls play the
stock blunt melee world impact. A punch whooshes as it travels (the Blast Brawlers
swing sounds, heavy past the stagger speed) and a Zed hit cracks
(`Play_Hammer_Impact_Flesh`); both play for the local player only. The drawn fist
stops at what it struck for 80 ms and eases back onto the tracked hand over 100
ms; contacts always use the tracked hand. An upward punch lifts its knockback and
a killing blow's ragdoll launch, and fist kills throw bodies harder than before.

Helpless Zeds take more: a punch into a Zed held by either hand does 1.5x (the
holding hand feels the blow), and a hammer fist driven down into a Zed that is
held, knocked down or ragdolled does 2x, capped at 100 bare-handed.

Parry: a punch that lands on a Zed mid-swing or reaching to grab parries it the
stock way (stumble, or the Berserker knockdown) when strong enough: a light
punch parries Clots, Crawlers, Stalkers, Sirens, Gorefasts and Husks, a heavy
punch also Bloats; Scrakes, Fleshpounds and bosses resist. Fist guard: bring both
clenched empty fists up in front of your face and hold them still; raising the
guard opens a 0.45 s window in which any Zed within reach, facing you and in an
interruptible attack, is parried (up to Bloats). Holding the guard does not renew
the window; lower and raise it again (0.35 s re-arm). The guard parries only; it
does not block damage. Parries crack with `Play_Parry_Wood` and a strong pulse in
both hands. Tuning lives in `VRFistGuard` defaultproperties.

Hit-stop: a Zed struck by a fist, a held body or a thrown body briefly plays
its animation at 5% (about 60-110 ms for punches by speed, 150 ms charged, 70 ms
for body impacts), so it sticks on the blow. Only the victim's animation slows;
its movement and AI, the player, camera and world keep real time, and every
player in a co-op game sees the same thing. Turn it off with `bMeleeHitStop=False` under
`[KF2VR.VRHandsBridge]` in KFGame.ini; durations live in `VRHitStop`
defaultproperties. Ragdolled and dead bodies are never slowed.

Melee weapons and gun bashes keep their stock damage, light/heavy modes and perk
bonuses, and multiply damage and knockback by swing speed within a mode: a light
swing does 0.8x at its slowest up to 1.0x at the heavy threshold, a heavy swing
1.0x up to 1.3x, and a gun bash 0.8x up to 1.25x (`VRMeleeScale`).

Your hands also feel what happens to you: a jolt in both hands when you take
damage (stronger for bigger hits, armor included), a slow heartbeat below 30%
health that quickens as it falls, and a swell when Zed Time starts. The shot
that empties a firearm's magazine ends in one long full-strength pulse (1.0 for
0.3 s) in the firing hand, so an empty gun is felt before it is seen.

Charged punch: hold the trigger of a clenched empty hand for 1.25 s, then punch
while still holding. The first enemy hit that can react takes 100 damage; small
and medium Zeds (including Siren, Husk and Bloat) are knocked down and back
through the stock knockdown affliction, and a large Zed hit in the head is
stunned for its stock stun duration. A large Zed's body, or a Zed already
knocked down, ragdolled or stunned, takes a normal punch and the fist stays
charged. Releasing the trigger, opening the hand, picking something up or dying
cancels the charge; being grabbed does not. Spending it starts a 12 s cooldown
shared by both fists, and the trigger must be released and pressed again to
charge afterwards; normal punches and bashes stay available. When the cooldown
ends both controllers tick and each empty fist flashes red briefly. In
multiplayer, teammates see a fully charged fist glow on your avatar. Tuning lives
in `VRFistCharge` defaultproperties (`ChargeTime`, `Cooldown`, `ChargedDamage`,
damage types and glow) and the `VRDT_ChargedFist*` damage types (affliction
powers).

## Door welding

The welder is not on the wheel. Within about 190 UU of a closed or broken door,
facing it, a small world-space prompt appears in front of the door offering
the welder on the non-movement stick click. The welder goes into the right hand; the
trigger welds (or repairs a broken door) and A + trigger unwelds. Click again to
put it away; walking away from every door for 2 s with the trigger released
also returns the right hand's previous weapon. While you weld, and whenever you
look straight at a welded door within about 480 UU, the prompt shows the door's
integrity as a bar and percentage. The welder is held like a one-handed pistol
grip from its own authored idle pose, with the controller aim correction and
the pointing beam of a sidearm; the weld is traced along the tool's aim. Its
charge shows on the per-hand readout. Tuning lives in `VRDoorWelding`
defaultproperties (`OfferRange`, `LookRange`, `ReturnDelay`).

## Dosh

The physical hip wallet is inactive; its preserved class is not instantiated.
Use KF2's stock TossMoney action (keyboard B in the installed default desktop
layout, or your customized binding). VR controller B is inventory, not a money
gesture. Do not look for a hip wad or assume its old flick/stagger mechanics
are live.

## Trader

In VR the shop list offers only weapons that have an authored VR profile, plus
stock duals that convert into paired members on pickup (`VRWeaponPair.Families`).
Ported items stay listed. Desktop players and server-side purchases keep the
stock catalog. Each trader visit logs the hidden classes as
`KF2VR_TRADER hidden=N of=M items=...`.

## Preferences

The standalone and multiplayer launch preparation seed missing preferences under
`[KF2VR.VRHandsBridge]`, preserving existing explicit settings. The network bridge
forces independent hands for live XR.

```ini
bIndependentHands=True
bToggleGrip=True
bHoldSupportGrip=True
bAutoSprint=False
MovementHand=0
PreferredWeaponHand=1
bControllerRelativeMovement=False
bBodySlotsEnabled=False
bWeaponAmmoReadouts=True
WeaponAmmoReadoutScale=1.0
WeaponAmmoReadoutForward=0.0
WeaponAmmoReadoutHeight=0.0
```

Hands are 0=left, 1=right; movement defaults to the left hand. A pre-revision-2
profile (saved before in-game settings persisted) has its stale `MovementHand`
reset to left once. MovementHand selects movement; the other stick
selects turn/jump and the door-welder offer. The movement click sprints in smooth
mode and cancels the arc in teleport mode. Y/B always select their own hand;
the welder always draws into the right hand. `PreferredWeaponHand` is labelled
**DOMINANT HAND**: it affects default/adopted weapon choices and HUD placement,
without remapping Y/B. The inactive syringe pocket/dosh wallet do not provide
current gestures. The legacy `bAutoSprint`
value has no runtime consumer and is no longer offered in the menu. Head-relative movement
is the default; controller-relative movement is optional. bToggleGrip governs primary holding, while bHoldSupportGrip
independently selects continuous support grip. Moving outside the support
contact range still detaches it without stowing the primary.

The optional `SelectorFavorites` config array contains weapon class names in
preferred order. Owned matching actors always lead the wheel in that order,
ahead of the inventory-group order. The array does not grant weapons.

## Interactive reloads

Optional, off by default: VR SETTINGS > INTERACTION > **RELOAD MODE** cycles
**BUTTON > PHYSICAL > PHYSICAL + PUMP**. The underlying preferences remain
`bInteractiveReloads` and `bManualPump`; selecting Button keeps the stored pump
choice, while selecting Physical explicitly uses automatic pumping.
Under **HUD AND READOUTS**, **RELOAD HINTS** controls the guidance rings and
insertion ghost, defaults ON, and remembers your choice across Solo/Join. It
becomes adjustable while interactive reloads are enabled. Turning hints off
keeps the physical pouch, ammunition, hand motion, assistance and haptics.
Coverage extends beyond the initial pistol/shotgun/AK-12/SA80 set through the
current reload catalog. Supported mechanisms vary by exact weapon; unsupported
items retain their stock button path. Per-family mechanisms are described below. No hidden unlock is required;
Button reloads remain available when a physical mechanism blocks play.
For magazine guns and the MB500, missing assets or unusable stock reload motion keep the
ordinary reload before any magazine is hidden or timer is paused.

- X/A (or an empty auto-reload) starts the stock reload and the magazine drops
  out. So does pinching the off-hand trigger at the ammo pouch while the gun
  can reload: the old magazine drops and the new one (or a shell) is already in
  the hand. The gun stays where you hold it for the whole reload; the stock
  animation no longer turns it.
- The stock animation plays up to the moment it would insert the new magazine
  or shell and holds there; no replacement shows in the gun. The gun's own
  magazine, or a shell, waits in the ammo pouch at the front of the off-side
  hip inside a blue ring. Hold the off-hand trigger there to take it: the hand
  grips it the way the stock reload's hand does. A blue ring marks the magazine
  well or the shotgun's loading port. As you approach, the ammunition and posed
  hand ease into the stock insertion position and angle, then moving closer
  advances the ammunition and original KF2 wrist/finger motion along the stock
  path into the gun. The hand blends into the acquired grip and returns to
  tracking after release without keeping the input grab alive. Pulling back
  reverses that motion until it seats; moving away fades the alignment out.
  Approach from the entry side with the prop roughly aligned. After alignment
  and at least 25% insertion, releasing the trigger lets the prop settle home;
  earlier release drops it. A ghost shows the entry angle, and each next-action
  ring has a fresh 0.75 s delay unless the hand is already nearby.
  The shotgun takes one shell per step.
- A reload that started empty pauses once more at an amber ring: pinch the
  slide or bolt with the off-hand trigger (or grab it), pull it fully back and let go,
  or pump the fore-end back and forward with the hand gripping it. The pump
  requires a nearly full rearward pull followed by a nearly full forward return
  while held, both after shots and during loading. The fore-end follows the hand
  continuously; letting go abandons that stroke.
  A latched support grip works in both hold and toggle modes. The action moves
  with the hand; an abandoned stroke springs it back. The magazine guns use
  their own sampled action travel and stock action grip, and their top-ups need
  no extra rack. Instead of racking, a magazine gun's slide or bolt can be
  dropped home with the gun hand's X/A (a slide release, as in Arizona
  Sunshine 2) once the new magazine is seated; X/A does nothing else while
  that reload owns the gun. Acquiring that action grip releases ordinary support to avoid
  fighting two-hand aiming; the pump retains its support grip.
  Tracking jumps or a long frame gap cancel the stroke before release can
  complete it. A required pump stays pending after cancellation.
- The 9mm, M1911, Desert Eagle and HMTech-101 lock their slide back when run
  dry and keep it locked through the reload: the seated magazine does not
  close it. Pull the locked slide a little further back and let go, or press
  the gun hand's X/A. X/A before the magazine is seated only ticks. If the
  reload is interrupted after the magazine went in (weapon swap, grenade,
  bash), the gun keeps the locked slide and will not fire until X/A or a
  free-hand pull-and-release frees it. Once the steps are done the gun fires
  at once.
- Guidance is contextual, as in Arizona Sunshine 2: on the magazine guns the
  part to use next (magazine, grip/magwell or slide) glows amber only if you
  pause on it for 0.75 s, and stops as soon as you do it; the shotguns keep
  rings. Pulling the trigger twice on a gun
  that cannot fire shows the current step immediately.
- Letting go of the trigger away from the gun drops what the hand held; take
  another. Firing still interrupts a shotgun reload, as in stock.
- ON + MANUAL PUMP: after every shot the pump shotgun will not fire until you
  pump the fore-end back and forward. The support hand on the fore-end just
  moves; a free off hand can pinch (trigger) or grab (grip) it. The fore-end
  and bolt move with the hand, and a trigger press before the pump gives a
  faint click and no shot. An empty gun still dry-fires into the auto-reload,
  and a completed reload rack chambers a round. Swapping/stowing the gun or
  interrupting a reload keeps the pending stroke; a held-open pump also blocks
  fire. Tracking or input loss cancels the gesture and requires a fresh release.

Seating has a stronger click in the inserting hand and a softer one in the gun
hand. Approach ticks resist boundary tremor; internal stock timer pauses do not
buzz. The magazine guns reuse their stock mechanical sounds at physical
ejection, insertion and slide/bolt contacts when the guarded audio session is
available. The pump shotgun's shell-insert sounds follow contact and seating,
and its reload pump stroke sounds at the rear stop and return. The hunting
shotgun sounds, extracts and smokes as it opens, clicks each shell in and
snaps on closure.

For the hunting shotgun, tap the gun hand's X/A to open, or hold the off-hand
trigger near the fore-end and move the special grip down to break it open.
Take and seat shells individually at the marked chamber. After all requested
shells are in, trigger-grip the fore-end and lift it closed, or flick the gun
toward the open barrels to snap it shut. Both fire modes wait for closure.
Full guns and guns without reserve can also be opened and closed for inspection.
Opening a loaded gun for inspection does not spend or grant ammunition.

The stock reload keeps its perk-scaled speed for every part it plays; faster
reload skills also widen insertion assistance.

## Teleport locomotion

The complete older teleport preset (1350 UU, 1690 UU/s, 0.25–0.80 s) upgrades
to the longer-hop defaults on launch, including unmanaged Solo configurations.
An individually customized range is retained; server recharge bounds still apply.

**MOVEMENT: SMOOTH / TELEPORT** is under VR SETTINGS > LOCOMOTION AND COMFORT.
Smooth is the default and is the stick walk this port has always had.

In teleport mode the movement stick stops walking. Deflect it past the same dead
zone to raise an arc from the movement hand; returning it to centre commits a
valid destination. Click that stick to cancel without committing. The turn stick keeps
turning throughout, so the destination and the facing you arrive with stay
separate choices. The weapon hand never aims the arc and never puts the gun
down.

A destination has to be somewhere a pawn your size could stand, on KF2's own
walkable graph, in sight of your head and inside the configured range. An
invalid arc greys out and drops its marker rather than turning red, because the
weapon laser already owns red. A teleport is refused visibly, with one haptic
pulse, while a zed has hold of you, while you are not walking, and until the
recharge elapses. The recharge has a 1.0 second minimum and uses distance / 800 UU/s, up to 2.50
seconds. A level full-range jump is about 18 m with a 2.25 second recharge.

Raising the movement hand pushes the landing out smoothly; there is no pitch at
which it jumps. Pointed about 40 degrees down it is a one-metre step, a level
hand lands about 12 m away, and from about 25 degrees up it holds the full
18 m. Indoors a raised arc that meets the ceiling is thrown flat under it
instead of dropping at the contact. Aiming past a ledge, into a pit, onto
clutter or out of sight does not refuse: the marker slides back along the arc to
the farthest spot that is legal. The arc only greys out when nothing along it
is. The drawn curve is always the path the teleport follows. If a relaxed grip
lands shorter than you want, raise `TeleportAimPitch` (degrees, -30 to 45),
which shifts the whole curve.

The blink is a fade to black scaled by the distance moved. Its settings live in
the same `[KF2VR.VRHandsBridge]` block. Reach and recharge (`TeleportRange`
1800 UU, `TeleportSustainedSpeed` 800 UU/s, 1.0-2.5 s) are shipped tuning, not
preferences: the launcher rewrites them and the game ignores them in the ini.

```ini
LocomotionMode=0
TeleportRange=1800.0
TeleportSustainedSpeed=800.0
TeleportMinCooldown=1.0
TeleportMaxCooldown=2.50
TeleportAscentLimit=400.0
TeleportDescentLimit=700.0
TeleportNavRadius=250.0
bTeleportArrivalFacing=False
TeleportAimPitch=0.0
BlinkOutSeconds=0.08
BlinkInSeconds=0.12
BlinkScale=1.0
```

`BlinkScale=0` removes the fade entirely for players who prefer an instant cut.


## Optional body holsters

`bBodySlotsEnabled=True` enables two long-gun and two sidearm positions.
Their labels appear only while a hand approaches; no prototype cards remain
visible during combat. A fresh grip stows the held compatible weapon or draws
the exact slotted actor. Ownership still passes through `VRHandInventory`.
The default leaves these optional holsters disabled. Syringe and welder are
excluded; draw the syringe from the wheel or an already empty hand's double tap.

Holsters and the chest grenade share one body frame, rebuilt
every frame from the head pose with no deadzone or catch-up, so a slot is
always where it was the last time you reached for it. It hangs from a neck
point 15 UU below the eyes along the head's own up axis, so looking down does
not slide anchors forward, and its facing holds when looking straight down.
The placement follows Arizona Sunshine 2.

Slots capture within 20 UU. An empty hand only answers to a filled slot, and a
stow squeeze during a fast swing (over 200 UU/s) is refused. Where anchors
overlap, the nearest usable one wins; a valid weapon support contact takes
priority. `BodyHolsterOffsets` holds five body-frame vectors: indices 0–3 are
shoulder and hip holsters, and index 4 is reserved. Defaults from the neck
point are long guns `(0, +/-20, -2)` and sidearms `(9, +/-38, -55)`. A legacy
`BodySlotOffsets` (head minus 42 UU) keeps its old level-head placement until
HOLSTER FIT replaces it.

Holsters do not create ammunition or change stock reload timings or inventory weight.

## VR Calibration & Practice Mode (In-VR)

Access the in-VR calibration interface from VR SETTINGS > CALIBRATION or
PRACTICE AND TOOLS > CALIBRATION in the VR menu. HUD AND READOUTS
also links directly to the readout and top-HUD editors. Console command
`mutate VRCalibrate` remains available.
No mutate commands are required during normal headset play.

### Calibration Pages

1. **Page 1: Weapon Fit & Downrange Preview**
   - **PITCH / YAW / ROLL**: Stepped angle adjustments (+/- 1 degree, clamped to [-80, +80])
     synchronized across active weapon presenters.
   - **RESET PROFILE FIT**: Restores the selected Neutral, Relaxed-wrist or Legacy
     fit rather than imposing the old Quest pitch on every profile.
   - **TARGET DISTANCE**: Cycles the UI's 5m / 10m / 20m labels (250 / 500 / 1000 UU) with 3D
     bullseye preview and active weapon bore sightlines rendered downrange.
   - **PLAYER / HUD**: Navigates to player baseline and HUD calibration.
   - **MENU PLACEMENT**: Navigates to spatial menu geometry adjustments.

2. **Page 2: Player Baseline & Wrist Inspection Calibration**
   - **CAPTURE STANDING / SEATED**: Requests native OpenXR baseline capture and
     remembers the posture. Standing, on a runtime with a STAGE (floor) space,
     puts your real floor on the pawn's floor so the view stands at your real
     eye height (at most 12 cm above or 40 cm below the 1.54 m pawn eye).
     Seated keeps the fixed 1.54 m pawn eye; crouch with the stick.
   - **RECENTER**: Requests immediate native view recentering.
   - **HAND FIT**: Opens wrist/controller fit; its subtitle reports current height
     drop and baseline. **PAWN CROUCH: YES/NO** is the current status tile, not a
     separate crouch-toggle binding. ALIGN MARKERS shows the debugging geometry.
   - **WRIST INSPECTION PREVIEW**: Closes the selector for eight seconds so the
     real native wrist reveal detector can run, then reopens with which wrists
     it detected. Lower the hand and turn the palm toward your gaze.
   - **CHEST ZONE HERE**: Moves the chest grenade to the current palm.
   - **ALIGN MARKERS**: Draws the OpenXR grip origin (yellow), the wrist the game uses with its aim axes (cyan, red forward, green up), the drawn wrist (magenta), reload targets and the grenade sphere. Touch the controllers together to judge the hand fit.
   - **HAND FIT** (the left tile of the drop row; its subtitle keeps the drop and base heights): nudges where the drawn wrist sits relative to the controller in 0.5 UU steps, back/forward, inward/outward and down/up, mirrored for the left hand, with the markers on while the page is open. RESET HAND FIT returns to the profile's measured offset.
   - **HOLSTER FIT**: Closes the menu; rest both hands at your hips for half a
     second (8-second window). Sets both sidearm holsters there, mirrored.

3. **Page 3: Spatial Menu Placement**
   - **DISTANCE / HEIGHT / SCALE**: Stepped adjustments (distance 0.6-3.0m, height
     -0.8-0.5m, scale 0.5-1.5) with live 3D 16:9 boundary preview in world space.
   - **WEAPON READOUT**: The right-hand tile opens the compact per-gun readout settings.
     The left-hand tile remains **RESET MENU FIT**.
   - **RESET DEFAULTS**: Restores default placement (1.5m distance, 0m height, 1.0 scale).
   - Each edit saves through the session UI, the same geometry owner as
     MENU AND INTERFACE > PANEL PLACEMENT. Legacy bridge-only calibration is
     migrated once when the session geometry is still at defaults.

4. **Weapon Readout**
   - Toggle its visibility, adjust scale (50-200%), and move it forward/back or
     up/down by 1 Unreal unit per step (each offset clamped to -12..12).
   - The plate is sized to be read at arm's length: the magazine count and the
     fire mode (AUTO / SEMI / BURST) are both large enough without raising the
     gun to your face. Push scale past 100% if you want it larger still.
   - **RESET READOUT** restores the discreet default; **BACK (AUTO-SAVED)**
     returns to spatial-menu placement. Edits and resets save immediately.

5. **Top HUD and hand fit**
   - **TOP HUD** on the readout page opens **SOFT ANCHOR / SCREEN-STABLE** follow,
     distance, height and scale, with **RESET TOP HUD / RECENTER TOP HUD** and
     **CLOSE (AUTO-SAVED) / BACK TO READOUT**.
   - **HAND FIT** opens **BACK/FORWARD**, **INWARD/OUTWARD** and **DOWN/UP**
     wrist-offset nudges, **RESET HAND FIT / ALIGN MARKERS**, live offset values
     and **CLOSE (AUTO-SAVED) / BACK (AUTO-SAVED)**. The same setting is mirrored
     for the other hand; no controller face buttons are remapped.

### Practice Mode & Armory

- **Startup**: PRACTICE AND TOOLS > OPEN / START VR PRACTICE starts/opens a range
  during a normal Survival wave. The ordinary wheel's + submenu is Drop/God Mode/
  Back, not a practice launcher. Practice
  suspends waves, enables invulnerability, refills ammunition and spawns targets.
  HEALING PATIENT creates the injured patient for syringe/medic darts.
- **Range panel**: SPAWN DUMMY / SPAWN MIXED HORDE, HEALING PATIENT / RESET PATIENT,
  CLEAR ALL / RESET RANGE, ARMORY / REFILL AMMO, CALIBRATION / END PRACTICE,
  TAKING DAMAGE YES/NO / WEAPON SELECTOR. Clear All also removes the patient;
  Reset Range restores its opening state. The damage toggle supports guard/parry work.
- **Armory Integration**: Solo can add/equip registered weapons into either hand.
  Network armory is **EQUIP OWNED LEFT / RIGHT**; acquire the weapon normally
  first. Refill and range actions use server commands. Server practice requires
  being the sole player or an admin; a denied request reports its reason.
  PREV/NEXT WEAPON browses profiles, the item row reports ownership/loading,
  REFILL AMMO replenishes, and CLOSE/BACK returns without ending practice.
- **Exit**: END PRACTICE resumes ordinary waves and restores prior invulnerability;
  this session remains unranked. Closing the panel alone does not end practice.
- **Controls Safety**: Exiting calibration via **CLOSE (AUTO-SAVED)** or center dead zone
  disarms controller triggers for one tick to prevent accidental firing or interaction.


## Chest grenade

The perk grenade rides the upper chest where Arizona Sunshine 2 hangs its chest
slot (the flashlight's): 11.6 cm forward, 4.4 cm right of centre and 15.7 cm
below the neck pivot, in the shared body frame. With a hand empty and the
selector closed, bring its palm to the grenade and squeeze; hold, then release
to throw after sufficient valid samples. Grab and cancellation consume no
ammunition. Tracking/context loss, recenter or opening the selector cancels the
held preview. There is no selector fallback throw.

The slot and held preview keep authored size except for the EMP, whose display
is reduced to the standard frag's measured length. Gameplay remains stock. The slot shows the
perk's own grenade whenever another remains; grabbing the last one clears it,
cancelling restores it without a debit, and a perk change re-templates it.

A squeeze with the palm centre (the OpenXR grip origin) within 12 UU of the
visible grenade centre takes it, with no dwell. An optional body slot may also
answer; the shared grip arbiter selects the usable target. There is no live
syringe-pocket target. Entering the
sphere pulses the reaching hand; a 16 UU exit radius keeps the boundary from
chattering. A squeeze within 20 UU that is refused (out of grenades, no perk
grenade, no owned stock owner, or just outside) pulses weaker and longer than a
grab. Losing a held grenade to tracking, a hitch, recenter or the selector
pulses a distinct cancel cue.

Calibration page 2 **CHEST ZONE HERE** moves the grenade to the current palm;
the session menu's chest reset puts it back at the AS2 spot.

Every stock perk grenade template draws one mesh particle in local space at the
component origin at StartSize 1. The cooked StaticMesh bounds give these
visible centres above the origin: nail bomb 17.3 UU, dynamite 2.4, EMP 1.9,
Molotov 1.8; frag, HE, medic, freeze and flashbang are within 1 UU and treated
as centred, as is any unknown grenade. The grab sphere is centred on the visible
grenade, and the held body puts that same centre in the fist.

The held preview is the perk grenade's own `ProjFlightTemplate`, which carries the
grenade body as a mesh emitter. It is absolute and driven from script, so it sets
`bUpdateComponentInTick` and pushes its transform every tick; a stock flight effect
instead rides its projectile's movement.

Both modes launch the current perk's gameplay projectile from the releasing hand
with measured velocity, subtracting pawn displacement. Authority applies a smooth
strength gain from 1x at rest to 2.8x at 400 UU/s hand speed, capped at the stock
base grenade launch speed of 2500 UU/s. Zero motion remains a drop; gentle
underhand tosses stay short, while faster swings gain distance. Looking elsewhere does not
steer the throw. The server validates a reliable, deduplicated release request in
network play; no client-only gameplay projectile or stock animation throw is issued.
A successful spawn consumes one grenade. Coherent server acknowledgement/count
keeps a pending last grenade reserved until the result arrives. Missing tracking,
stale samples, implausible motion or a blocked release cancel safely. Live timing,
size, perk effects and cancellation still need the manual headset check.

## Deployables

C4, the Sentinel and the HRG Bombardier are thrown like the chest grenade,
with the trigger standing in for grip because grip already holds the item:
squeeze the trigger, swing, and let go. The release launches the stock charge
or drone from the hand at its measured velocity (same assistance curve as the
grenade, capped at each item's stock speed: 1200 UU/s for C4, 1350 for the
drones); letting go at rest places it at the hand, and a C4 charge sticks
wherever it lands. There is no stock throw animation and no view-aimed
fallback. A tap too short to sample, a selector opening, tracking loss or
switching weapons cancels with no ammunition spent. The next charge is ready
one second later (stock `ConsumeSpareAmmoDelay`); an early, empty or refused
squeeze gives the weak refusal pulse. A drone at its limit is replaced only
once the previous one has deployed, as in stock. X/A + trigger still
detonates. The server validates and spawns the throw in network play
(`ServerThrowDeployable`, shared `VRDeployableThrow`); every accepted throw
logs `KF2VR_DEPLOYABLE throw`.

## In-game VR settings

Open the VR menu with Menu/the two-stick click chord. The root has Resume/Perks,
Perks and Skills, Scoreboard, VR Settings, Game Settings, Practice and Tools,
Local Match/Leave Server, and Quit. A network match keeps running while its menu
is open. Match controls explicitly confirm leaving a server to start Solo;
Choose Map lists installed Survival maps in pages. Back returns to the page you
came from; Back/Cancel do not write settings.

| VR Settings page | Options |
| --- | --- |
| Locomotion and Comfort | Smooth/teleport, movement hand/direction, snap/smooth turning, +/- snap angle or smooth sensitivity, teleport blink |
| Interaction | Dominant hand, primary/support grip, Solo grabbing, supported reload/manual pump switches, body holsters, melee hit-stop, experimental multiplayer grabbing and read-only host status |
| Menu and Interface | Pointer hand, panel placement, game-menu backdrop, recenter/current-height capture |
| HUD and Readouts | Weapon readout visibility/fit, top HUD fit/follow, wristwatch HUD, damage popups, reload hints and wrist inspection preview |
| Graphics | +/- render scale, applied per-eye dimensions, game quality, lighting and gamma; locked VR effects are status text |
| Calibration | Global weapon fit/profile reset, current-height capture, chest-zone capture/reset and wrist inspection |

Preferences apply and save immediately. Calibration/readout editors need a living
match and open on the pointer hand: physically move that hand across their
two-column tiles, then click its trigger. The selector opens after native menu
input cleanup; a failed or timed-out handoff restores the shell.
Fit edits affect all firearms. Standing and seated capture both recapture the
current physical height; they do not select a separate locomotion mode. Recapture
reports completion or tracking failure.

For laser collision diagnosis, open **VR SETTINGS > CALIBRATION > HEIGHT /
CHEST ZONE / WRIST HUD TEST** and switch **ALIGN MARKERS** on. While markers
are enabled, each visible weapon laser records a `KF2VR_LASER_TRACE` sample
in the game log at most once per second. Each sample names the hit actor/component and
their owners, with ray start/end and contact coordinates. `phase=first` is
the original hit; `phase=resolved` appears only after HUD filtering. Portal
rays also record `segment=exit`. These diagnostics do not change collision.
Switch **ALIGN MARKERS** off when finished, then use the launcher's **Save logs
for a bug report** button and report the approximate time of the bad laser hit.

Smooth-turn sensitivity is 10–200%. Above 100%, partial stick input reaches the
game's maximum turn rate earlier; it does not raise that maximum.

Panel placement has one owner, `[KF2VR.VRSessionUI]` (network alias
`[KF2VRNetClient.KF2VRNetSessionUI]`): distance 0.6–3 m, height -0.8–0.5 m,
size 50–150%, with +/- and reset. The legacy bridge fields are compatibility
mirrors. **GAME-MENU BACKDROP** selects VR Studio or Live World for stock panels;
the settings shell always uses Studio.

Render scale is 50–100% with separate 5-point decrease/increase actions and no
wrap. The applied row displays native dimensions or waits for headset data.
Stock Options > Graphics redirects to this VR page. Editable quality options
cover environment, characters, effects, textures/filtering, shadows, bloom,
volumetric lighting and light shafts. Non-texture edits use narrow system-setting
writes and native/script readback. Texture controls select stock grouped presets;
filter changes refuse nonuniform texture LOD biases rather than flattening them.
Blur, DOF, post-process AA, AO/HBAO, reflections, VSync, grain and lens flares
remain off; variable frame rate stays on. These fields are displayed as locked
status, not selectable settings. Quality changes report readback mismatches.
The VR shell opens only at session entry or through its explicit menu control;
death, boss-kill/end-of-game cinematics and other game camera takeovers do not
open it. Stock game UI floats as a spatial panel within the grounded VR Studio
environment, eliminating disorienting contrary-parallax level motion.
Solo and network launchers share tools/vr-defaults.json. The multiplayer launcher
persists approved preferences in %LOCALAPPDATA%/KF2VR/Profile/KFGame.ini.
See [all launcher switches](../PLAY-MULTIPLAYER.md) for explicit scale overrides.
Report headset readability, control feel and online issues with your build ID.

### Current settings controls

Numeric turn and panel-placement settings show one value with separate `-` and
`+` pointer targets. Press and release the same target to change it. Reload Mode
cycles Button, Physical, Physical + Pump; existing saved combinations are read
without migration. Turning physical reloads off keeps the stored pump preference;
choosing Physical explicitly selects automatic pumping. Unsupported weapons keep
their normal reload path.

Transfer / Brace Grip describes the existing grip preference, not automatic
primary-weapon dropping. Weapons stay equipped until switched or dropped; Support
Grip and optional Body Holsters remain separate. Scoreboard is unavailable before
a valid in-match score widget exists. Damage Popups can be toggled live; hosted
client per-hit delivery remains unverified. Bone Crusher reserves its shield hand:
conflicting draws are refused with the existing feedback, never automatic drops.
SG500 pump travel follows the authored shot/reload stroke at the current weapon
scale, with 1:1 controller travel. A held pump support grip stays attached during
fast or sideways strokes; release the grip normally to let go. The HZ12 reload
uses the same 1:1 stroke and retained support grip. Hunting single shells align along their long axis; rolling a shell around
that axis does not block insertion. Its orientation ghost appears on shell pickup
when reload hints are enabled. Fast insertions can cross the guide mouth between
tracked samples, including the short ordinary shell insertion path. SG500/M4
first shells use an earlier stock carry grip before the port animation lets go.

BoneCrusher has an independent physical shield strike in its free opposite hand;
conflicting inventory, carry, reload and grab interactions disable that strike.
Fast cylindrical-shell approaches may acquire when their valid tracked path crosses
the guide mouth, rather than requiring a frame exactly at the mouth. Tomahawk
generic air whooshes are suppressed; contact and throw/recall cues remain.
