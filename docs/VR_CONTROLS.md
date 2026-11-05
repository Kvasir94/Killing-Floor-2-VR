# KF2-VR controls and tips

Use the build ID shown by your launcher when reporting issues.
Existing saved settings can override launcher defaults.
World-weapon throwing/pickup/sharing, gun gravity pull and world recall use the
shared Solo/online ownership path when world drops are enabled. Owner pickup
permissions and recall settings still apply. Local component toss/catch keeps
the same owned inventory actor.
Zed/body grab and release-to-throw work in Solo and online for hosts and joining
VR players through **Settings > Weapons & Interactions > Advanced > Zed Grab / Throw**,
default ON. Online servers allow grabs by default and can explicitly disable them.
Squeeze an empty hand near an eligible Zed/body; release grip to throw. Standing
holds and other experimental interactions are not required. Detached local gibs
remain local physics rather than replicated shared objects.
Explicit saved ON or OFF choices remain in effect, including older profiles.
Standing holds remain parked. Blade & Sorcery-style melee is the separate
**B&S2 Melee** setting, default OFF; off restores the plain melee behavior.
Normal grip controls, stock weapon pickups/drops, existing melee guards,
inventory stowing and ammunition recovery remain available. In continuous-held
mode (TRANSFER / BRACE GRIP: HELD), deliberately release a held weapon to toss it.
An ordinary draw requires grip to stay held. Quick swapping back to a weapon
is the exception: it stays equipped until the first grip squeeze, after which
release works normally. Invalid tracking never counts as a release.
Squeeze a free hand near the airborne weapon to catch, including the other hand.
Valid support and pump zones can catch into support carry; the trigger grip
catches into the normal firing hold. Regrip the trigger to use a support catch.
A fresh open-then-squeeze is required; an occupied/reloading hand cannot catch.
Misses return after the existing delay (five seconds when unset). Ownership,
magazine/chamber ammunition and attachments stay on the same item. Local tosses
cannot damage, impale, become shared pickups or create death loot.
The airborne copy preserves the weapon's current mechanism pose. Tossing still
interrupts unpaid reload work; catching keeps paid ammunition and outstanding
action debt on the original weapon.

Each gun has its own authored mass, balance and rotational inertia for local
tosses in solo and multiplayer. Compact pistols flip readily; long or heavy guns
resist end-over-end flicks and rotate around their balance point. All use the
same gravity. Catches attach firmly to the hand immediately, with stronger
haptic impacts for heavier guns or faster motion relative to the catching hand.
Moving with the gun softens the catch. Release, catch and ground contact reuse
the gun's original handling sounds where available, with shared stock rattles as
fallbacks and material sounds on ground impacts. There are no air sounds or
catch settling animations. These are physical handling estimates, not inventory
carry-weight values or exact manufacturer specifications.

## Player guide and tips

Start the extracted ZIP with **Start KF2-VR**. Pick **VR headset** or
**Desktop - no headset**, then **Play solo**, **Host a game** or **Join a friend**.
Solo/Host have a **Start** button after their options; Join uses **Paste code**
then **Join**. In the lobby choose a perk and Ready. Keep the launcher open for
cleanup when the game exits. Start ordinary Steam KF2 once before first setup,
and activate your headset software's OpenXR runtime for VR. The package must
match the installed Steam KF2 executable; Epic is unsupported.

Button names below refer to physical controllers, not keyboard keys. Touch has
X/Y on the left and A/B on the right: X/A are the lower action buttons, Y/B the
upper inventory buttons. Index uses A/B on each hand for those same actions;
hold its right trackpad press for 0.6 s with the right trigger released to open
the VR menu, or use the centred two-stick-click chord. Its system button is
reserved. The OpenXR binding suggestions also include Vive trackpad and WMR
stick/grip/menu actions, but do not supply their lower/upper face-button actions.
Do not assume complete wheel/reload support on those controllers or a simple
select-only controller. Validate the available runtime bindings before claiming
support. Changing movement/dominant hand does not swap physical X/Y/A/B labels.

For a fresh profile: left stick moves relative to the head, right stick turns,
30-degree snap turn is ON, click-to-sprint is used, and down-stick crouch is OFF.
The weapon hand defaults right; menu pointer defaults right. The Quality preset /
100% render scale is the launcher starting point. Button reloads, latched transfer/
brace grip, held support grip and support-hand gun aiming are defaults. Physical
reloads/manual pump and host inventory slowdown start OFF; single-pass stereo and
the separate render thread are always on, not options. Zed grabs default ON in Solo and online when no valid choice is saved,
and world weapon drops are ON. Other saved preferences override starting defaults.

**Fast equipment reminders**

- Hold that hand's Y/B for 250 ms, then release: its wheel stays open. Point or
  move the same controller to highlight a sector, squeeze **and release** its
  trigger to confirm. The stick does not select an icon. Y/B cancels; a trigger
  click with nothing highlighted also cancels. After closing the turn-hand
  wheel, centre its stick before turning/jumping. Smooth walking remains
  available with the movement-hand wheel open; teleport is blocked while open.
- Single-tap Y/B recalls that hand's previous item, or opens it if no distinct
  previous item exists. Double-tap stows an occupied hand. Double-tap an already
  empty hand to draw the syringe; alternatively choose it on the wheel.
  **Quick heal:** tap Y/B, then press it again and hold: the syringe draws into
  that hand from any state, and a single tap afterwards returns the previous
  item. There is no active wrist/forearm syringe pouch.
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
  hold-to-support; release grip to detach. Primary holding stays latched by
  default. With **ALLOW SUPPORT-HAND CARRY** enabled, squeeze and release the
  primary grip while the other hand remains braced. The foregrip then carries
  the gun without firing. The original hand can work its action or squeeze at
  the primary contact to regrip; firing requires a fresh trigger pull. Releasing
  the final support grip safely stows the gun in inventory.
- Body holsters and HOLSTER FIT are withdrawn. Saved holster settings and
  offsets are retained but inactive; use the weapon wheel to equip and stow.
- Dosh: open a wheel, choose **DROP**, then **DROP DOSH**. Each click tosses one
  stock wad from that hand forward along its aim; the wheel stays open for more.
- Y/B beside that controller's temple toggles the flashlight instead of swapping.
  A fresh grip squeeze there also toggles it when that hand is empty and free;
  release the grip before toggling again. Body items and occupied hands keep
  their existing actions.
  The non-movement-stick click closes an open movement-hand wheel. If neither
  wheel is open, it offers the welder near a closed/broken door; elsewhere it
  opens the movement-hand wheel. Near such a door a blue welder hologram also
  floats in front of it: squeeze grip on it with a free hand to take the
  welder, trigger welds, X/A plus trigger unwelds, and letting go of grip puts
  it back. The stick-click welder goes to the right hand until clicked again or
  walked away from. Point/move the wheel controller and
  release its trigger to select; stick tilt does not select a sector.

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
triggers, and hold both stick clicks for 0.6 s with tracking valid. Index also
accepts a 0.6 s right trackpad press with its trigger released; a held control
on entry or after tracking loss needs a release before it can toggle. The current
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
seated baseline and chest-zone capture/reset. Two aim options live there too.
**GRENADE GRIP** defaults to the authored stock grip; select **TRACKED CURL**
there to use live fingers instead. This applies to the nine stock grenades.
Boss introductions use a fixed nearby viewpoint with a blink on entry and
exit; the viewpoint does not move your pawn. Death and spectator views remain level.
**AIM MODE** on CALIBRATION picks where shots go. **CONVERGE 20M**
directs each firearm's shot from the muzzle onto its sight line at 20 m. **BORE**
fires straight out of the barrel. **SIGHT POINT** (the default) traces the sight line and turns the shot, its tracer and
any Zed Time projectile from the muzzle onto the traced target; the laser points
there too. It traces up to 50 m and uses a minimum target
distance of 1 m. Single bead/pin sights
use a bore-parallel reference; the bow follows its current drawn arrow. Tools
without an aiming sight keep their bore aim. **MENU AND INTERFACE** sets pointer
hand, panel placement and recenter. **HUD AND READOUTS** adjusts ammo/top-HUD
placement, watch/readouts, damage popups, laser pointer and reload hints.
**AIM ASSISTANCE** under **GUN HOLDING** offers **MOUSE & KEYBOARD** (shot
correction Off), **GAMEPAD** (stock shot correction), and **CUSTOM** (adjustable
correction and range). Gamepad is the default. This is separate from the
calibrated sight/convergence aim mode.
**LASER ORIGIN** under **HUD AND READOUTS** selects the **MODELED EMITTER**
(default) or **BORE**. Weapons without an authored emitter use the bore fallback.
Both settings are also available in the desktop launcher and persist across
Solo and multiplayer. An open break-action barrel carries its laser with it.
Pouch and ordinary rack reach use the donor's 18 UU and 16 UU distances.
The MP7 also accepts a palm on its handle. Saved pouch fit and insertion
distance stay available and unchanged respectively. **GRAPHICS**
adjusts render scale and supported quality/lighting; locked VR effects are status
rows. Capture your actual posture; recentering and seated play do not turn on
teleport. **RESET PROFILE FIT** uses the selected Neutral/Relaxed-wrist/Legacy fit.

**PRACTICE AND TOOLS** opens calibration, practice, its armory and healing patient.
Solo armory can add/equip registered items; network armory equips owned items.
Network practice requires sole-player/admin permission. Practice suspends waves,
refills ammo and enables invulnerability; **END PRACTICE** ends it, while closing
the panel alone does not. Practice/God Mode leaves that session unranked.
The wheel's **DROP** sector opens Drop weapon, Drop dosh and Back; weapon drops
follow stock item restrictions. It does not grant an unowned weapon.

**Combat and special items**

Aim/fire each hand independently. X/A short tap reloads on release; hold changes
a persistent mode where supported, or combine it with a fresh same-hand trigger
for secondary fire. Release a previously held trigger before requesting a secondary.
Use **VR SETTINGS > INTERACTION > RELOADS > RELOAD MODE** to cycle **BUTTON > PHYSICAL >
PHYSICAL + PUMP**. Unsupported weapons retain their normal path. In physical
reloads, follow the active ammo/action hint: off-hand trigger takes and carries
ammo, seated contact credits it, and the action must be completed where required.
X/A can release a supported locked slide after seating. **RELOADS > X / A EJECTS
FULL MAG** optionally permits removal of a full magazine through the same
physical ammo rules; it defaults OFF and requires physical reloads.
Guidance and detailed
per-family actions are below; coverage is not arsenal-wide headset acceptance.

Empty clenched hands punch by swinging; grip plus held trigger charges that
fist. Spend the charge with a punch while still holding; release/open/stow cancels.
Raise both empty clenched fists to guard/parry; lower/re-raise to rearm. Melee
weapons and gun bashes use motion contacts. Supported two-hand melee guards use
a braced weapon across the body; button-guard profiles use X/A, and their
heavy/secondary action uses X/A plus a fresh trigger where supported. Physical
melee does not universally use trigger for an ordinary swing. Ion Thruster's
quick X/A asks for its charged ultimate. Keep weapon-specific firing actions.

With the solo grab option enabled, an empty hand grips a nearby eligible Zed/body; keep
grip held, then release to drop/throw. That hand is occupied, the other can act.
The independent Zed Grab / Throw option also works online when the server allows
it; multiplayer empty hands
can fist-bump (clenched) or high-five (open) a teammate; gestures are always on,
with participants' haptics and shared effects. These still need real-player
acceptance and have no dedicated controller switch.

C4/Sentinel/Bombardier: equip, hold trigger, swing and release trigger to throw
or place; X/A plus trigger invokes detonation. RAVEN-7: hold trigger to prepare,
swing and release to throw; a fresh airborne trigger hold suspends it and
release recalls, while a resting axe recalls on the new press. Fresh grip is
a recall shortcut. Ported tools route their secondary
intent through X/A plus trigger; their separate content guides describe special
stock actions. Breacher is parked and omitted from this stable
candidate. Its launcher controls and enable overrides are unavailable.
Standing holds stay parked; impaling and contact blocking come only with B&S2 Melee on; the
separate grab option only enables the existing eligible Zed/body route in Solo and online.

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
| Non-movement stick up | Jump at the outer rim (magnitude ≥ 0.95), within 40° of up; that whole upward arc excludes turning, including the push toward the rim. Returns to centre before the next jump. While a stick crouch is latched, up stands instead of jumping |
| Non-movement stick down | Toggle crouch at the outer rim, for seated or mobility-limited play: stock crouch with the view lowered as on flat. Up or a sprint click stands. VR SETTINGS > LOCOMOTION AND COMFORT > STICK CROUCH turns it off (default on) |
| Physical lowering | Stock crouch (bonuses, speed, capsule) after calibrated height threshold and dwell; the view is not lowered again, only the real head drop shows |
| Y / B tap, then press again and hold 250 ms | Quick heal: draw the syringe into that hand from any state; a later single tap returns the previous item |
| Y / B, single tap (240 ms double-tap window) | Quick-swap the left / right hand's exact previous weapon, or stow to an open hand when no distinct previous weapon exists; cancel while open |
| Y / B, double tap | Stow/open only that controller's hand through the inventory ownership path; carried weapons and previous-item history remain available; empty hands still punch and charge fists. A hand that is already open draws the syringe instead (refused if the other hand holds it) |
| Y / B pressed with that hand beside the head | Toggle the flashlight (head lamp), whatever either hand holds. The hand must be within 20 UU of the head and not in front of the face, so a raised pistol still quick-swaps; the press never opens the wheel |
| Empty, free hand: fresh grip squeeze beside the head | Toggle the flashlight using the same temple zone. Release before another toggle; reloads, held items, transfers and body contacts keep their ownership |
| Y / B, hold 250 ms then release | Open spatial inventory for that same hand; it stays open. The opening hand's stick is idle while it is open; the other stick keeps its locomotion role |
| Point or move the opening controller toward an icon, then squeeze and release its trigger | Equip into that same hand on release and close the wheel automatically; stick tilt never highlights a sector |
| Trigger with the hand back at the centre (nothing highlighted), or Y / B while the wheel is open | Cancel |
| Wheel > DROP > DROP (weapon) | Throw that hand's item as the stock pickup a teammate can collect. Stock rules apply: the knife, 9mm backup, welder and VR pair members cannot be dropped |
| Wheel > DROP > DROP DOSH | Toss one stock wad (stock amount and debit) from that hand's palm forward along its aim; the wheel stays open for repeated tosses |
| >> sector + trigger click (only with more than eight carried items) | Cycle carried-weapon pages and keep the wheel open |
| Grip | Hold support contact while squeezed by default; primary stays equipped. Emptying a primary uses OPEN HAND or double-tap Y/B. A valid support contact takes priority over a chest grenade; body holsters remain inactive. No active wrist syringe or hip wallet |
| Draw syringe from wheel, or double-tap Y/B on an already empty hand | Syringe remains equipped until stowed/switched. Trigger with the hand near the upper chest (32 UU around a point 35 UU below the head) self-heals; outside that zone trigger uses teammate healing along its aim. X/A plus a fresh trigger invokes its secondary/self-heal action |
| Empty hand: grip the visible chest grenade, swing, release grip | Hold-to-carry even with latched primary grip. Grip release throws/drops; trigger does not. Invalid/very short sampling can cancel without spending a grenade |
| Optional support-hand carry: squeeze/release primary grip while braced | Support carries the gun; it cannot fire. Original hand can operate the action or squeeze at the primary contact to regrip. Final support release leaves a local cosmetic drop with automatic return; toggle support uses its toggle-off squeeze |
| X / A, tap and release | Reload left / right item immediately on release |
| X / A, hold | Change one persistent firing mode, or prepare that hand's temporary secondary modifier; see Weapons |
| X / A + that hand's fresh trigger pull | Secondary fire for a secondary-action weapon. Single-shot secondaries (e.g. the double-barrel shotguns) need a fresh pull per shot; continuous ones fire while held |
| Free hand: grip the welder hologram at a closed/broken door | Take the welder into that hand; trigger welds, X/A + trigger unwelds, releasing grip puts it back |
| Non-movement stick click | Close an open movement-hand wheel. Otherwise, with neither wheel open, draw/return the right-hand welder near a closed/broken door, or open the movement-hand wheel elsewhere. There is no stick bash; bash physically |
| Trigger | Operate that hand's item; an open empty hand interacts. Syringe self-heal uses the upper-chest zone described above |
| Empty hand: clenched grip + hold trigger | Charge that fist (red glow, rising haptics); punch while still holding to spend it. Replaces interact while clenched, including a partial analog squeeze |
| Menu button, both stick clicks held 0.6 s, or Index right trackpad press held 0.6 s | Toggle and recentre the VR menu (stock UI floats inside). The chord needs both sticks centred, both triggers released and both hands tracked; Index trackpad needs its right trigger released. Release before another toggle |

During play, stock game-menu panels also show **RESUME GAME** in the lower-right corner. Select it with the pointer trigger to return to the match; popups must be finished or cancelled first.

**TRANSFER / BRACE GRIP: TOGGLE** keeps weapons held after the fingers relax. In
**HOLD** mode, the wheel acts as a pocket: point to a weapon, then press that hand's grip
to draw it immediately; release that confirming grip to drop/toss. A grip held
on wheel entry must first open before confirming. Other draw paths with an
already open grip stay held until a deliberate squeeze then release.
The radial is anchored when opened,
80 UU ahead, 20 UU below eye level and 12 UU toward its own side (38 UU when
both wheels are open, side by side). It follows player translation without
following hand tremor or head turns. The wheel has at most ten equal sectors:
OPEN HAND (top), up to eight carried items, then the DROP sector (DROP weapon / DROP DOSH / BACK). Only with nine
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
wheel. A dual pistol purchase has two individual pistol sectors. Each converted
sector selects that exact member and its magazine; an occupied member never
silently selects the other pistol. Selecting an unsplit stock pair prepares the
existing pair and draws only the chosen member. Choices freeze during a
confirmation pull and ownership is rechecked before the draw. Unowned items disappear. Stock silhouettes stay prominent and
shrink only as far as needed to keep ten apart; only the highlighted choice
shows its name and exact ammunition, on a red spray slash. An item held by the
other hand is dimmed and marked HELD. The same label shows OUT for a loose or
returning weapon and GROUND for a settled dropped weapon; it updates while the
wheel remains open. The weapon held by this wheel's hand also shows HELD.

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
pulses lightly. In latched mode, trigger travel above 30% freezes the choice;
trigger release confirms, as before. In continuous-held mode, grip travel above
30% freezes it and a fresh 65% grip press confirms immediately. The confirming
squeeze is consumed by the draw; it cannot also grab support or another item.
A confirm control held on entry must first open. Confirming with nothing
highlighted and Y/B cancel; page/settings navigation keeps the selector open.
The turn-hand stick is captured while its wheel is open and must return to
neutral before turning/jumping resumes. Smooth walking stays available with the
movement-hand wheel open; teleport is blocked while it is open. (Stick-tilt
selection, added in `f782843`, was removed after the 2026-09-26 headset
playtest: two simultaneous methods made the wheel unpredictable.) Wheel labels
are drawn in a single pass; see HUD for the text-alpha path.

Single-tap Y/B waits 240 ms to distinguish a double tap without performing an
intermediate swap. A second held press draws the syringe (quick heal); it does not first empty
the hand. Tracking/menu loss clears pending gestures. Temple flashlight presses
remain a separate consumed gesture. Settings still use their calibration editor;
inventory selection never shows both hands in columns.

## Weapons

For a physical gun stock, select **VR SETTINGS > INTERACTION > SUPPORT HAND
AIMS GUN: OFF**. The primary controller then owns firearm aim and placement;
the support hand can still grip and supply the usual braced spread/recoil
benefits. This works with either hand as primary and saves across Solo and
multiplayer launches (`bDisableSupportHandAim=True`). ON preserves the existing
two-hand alignment and is the default, including for older profiles. Toggling
OFF clears the alignment blend immediately without releasing the support grip.
Primary weapon-fit calibration, recoil and action animations still apply.
Support must still reach and remain near the authored contact; this option
does not calibrate stock mount spacing or bypass grip/tracking checks. Pistols
already aim from the primary hand; two-hand melee alignment is unchanged.

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
| HRG Blast Brawlers | Block/parry (button-driven melee); tap reloads shells in every mode. Either glove's trigger fires that glove's blast; squeezed during a punch it fires on impact. Empty trigger clicks |
| Frost Fang | Temporary modifier: pull the trigger while held for the stock stab; tap reloads. Trigger fires the shotgun; swing the blade physically and brace with both hands across the chest to block |
| VLAD-1000 | One persistent change: SPREAD / SINGLE nail |
| Doomstick | Temporary secondary modifier: pull the trigger while held to fire every loaded barrel |
| S12 Shockgun | Temporary secondary modifier for the shock attachment |
| FAMAS Masterkey | Temporary secondary modifier: pull the trigger while held to fire the underslung shotgun; tap reloads the rifle, or the shotgun when the rifle is full. The front charging handle (the pump) is a support grip: the hand stays on it, and pulling it back and forward cycles the shotgun only after a shotgun shot |
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
| Rail Gun | Starts in MANUAL; the existing mode hold toggles AUTO / MANUAL. AUTO counts as sighted, locking a Zed's weak spot with stock lock-on timing and movement slowdown |
| Mosin Nagant | Block/parry (stock); pull the trigger while held for the stock bayonet bash; the trigger alone fires |
| HRG Head Hunter | Temporary secondary modifier: pull the trigger while held to fire the head-inflating dart |
| Compound Bow | SHARP / CRYO arrows (stock toggle, with its cryo glow). Grip an arrow from the opposite belt pouch and nock it manually; pinch the string with the free-hand trigger, draw and release to fire. Short draws retain the same arrow for re-nocking. Native arrows, ammo and damage remain authoritative |
| HRG Beluga Beat | Temporary secondary modifier: pull the trigger while held for the stock fully charged sonic blast |
| Corrupter Carbine | Temporary secondary modifier: pull the trigger while held to fire the parasite seed |
| Medic pistol, HMTech-101/201/301/401, Hemogoblin, HRG Incision, syringe | Temporary secondary modifier; pull the same hand's trigger while held |
| Tracked Source / Engineer tools | Temporary held secondary intent through the existing tool interface |
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
wait for stock shot/burst recovery to finish only while that same X/A hold and
released trigger remain valid. Trigger use, invalid tracking/actions, menus,
draw/role changes and calibration/reference changes cancel it; release and make
a fresh hold to try again. Only an accepted change confirms with haptics. Each
lower button controls its own hand.

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
Each Blast Brawlers gauntlet fires its own blast (`VRBrawlerBlast`). Squeezing
with a still fist fires at once from that glove's muzzle along the glove.
Squeezing during a punch, or keeping the trigger held as a punch starts, loads
that punch: the blast goes off at its first contact, from the wrist into the
struck point, or at full extension if it touches nothing. Stock economy holds:
one shell pays for a pair of blasts from either gloves, so four shells are
eight blasts. Punches stay physical; the stock trigger attack and its X/A plus
trigger heavy attack are not used (a fast punch is heavy). A quick X/A tap asks the Ion
Thruster for its stock charged ultimate; the stock charge gate remains authoritative.

Blast Brawlers use the holding hand's X/A reload tap in every reload mode,
including with physical reloads enabled. The stock timed reload refills the shared
pool through weapon authority; no wrist flex, second glove or free hand is needed.
Empty triggers click even with EMPTY TRIGGER RELOADS on. Static Strikers and
practice boxing gloves have no ammunition reload.

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
blade contacts use the stock bash damage. The Eviscerator's powered saw uses
its trigger action and spends fuel; a fast physical swing remains a bash.
The Bladed Pistol's bash is its forward blade's dismembering slash.
Holding the Pulverizer trigger during an eligible enemy impact requests one
explosive cartridge per swing, subject to ammunition, reload completion and
the stock firing interval. This works in solo and multiplayer.

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

Tracked bashes, melee strikes, punches and the player's own grab interaction
remain eligible while restrained by any stock Zed grab family, including DAR,
disabling grabs, Hans/Patriarch/tentacles and Bloat King gorge. This does not
force an escape from stronger grabs: stock damage, immunity and release rules
still apply. Death, incapacitation, unrelated interaction locks, invalid hand
ownership and lost tracking cancel interaction. Existing target restrictions
remain: bosses are not grabbable and large living Zeds must already be down.

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

Knocked-down or ragdolled Zeds retain the established downward hammer-fist
bonus, capped at 100 bare-handed. Held-body bonuses are unavailable while the
experimental grab systems are parked.

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

Hit-stop: a Zed struck by a fist briefly plays its animation at 5% (about
60-110 ms for punches by speed, 150 ms charged), so it sticks on the blow. Only the victim's animation slows;
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
facing it, a blue 3D welder hologram, drawn like the reload hints, floats at
chest height in front of it, turning slowly. A free hand entering its 14 UU grab radius gets a pulse
and the hologram brightens; a fresh grip takes the welder into that hand. The
trigger welds (or repairs a broken door), X/A + trigger unwelds, and releasing
grip (once the trigger is released) puts it back. The non-movement stick click
remains a fallback: it loans the welder to the right hand; click again to put
it away, or walk away from every door for 2 s with the trigger released to
return the right hand's previous weapon. While you weld, and whenever you
look straight at a welded door within about 480 UU, a status panel above the
tool shows the door's integrity as a bar and percentage. Unwelded doors offer
the tool without a panel, and a missing hologram never leaves an invisible
grab target. The welder is held like a one-handed pistol
grip from its own authored idle pose, with the controller aim correction and
the pointing beam of a sidearm; the weld is traced along the tool's aim. Its
charge shows on the per-hand readout. Tuning lives in `VRDoorWelding`
defaultproperties (`OfferRange`, `LookRange`, `ReturnDelay`, `HologramRadius`);
the hologram mesh comes from `tools/generate_tool_holograms.py`.

## Dosh

Open either wheel, choose **DROP**, then **DROP DOSH**. Each trigger click
tosses one stock wad (the stock amount, debit and pickup) from that hand's palm
forward along the controller's aim, through the same server-validated toss as
the old wallet; the wheel stays open for repeated tosses. Desktop keeps stock
TossMoney (keyboard B). The physical hip wallet stays inactive.

## Gravity pull

Point an **open, empty** hand at a reload magazine on the floor (with dropped-magazine ammo
recovery on), dosh, an ammo box or a non-weapon map item spawn up to about 10 m away: the
hand opens toward it, a violet ring appears under it (the always-on pickup rings
stay blue), and you hear a soft tick. Full armor or ammo, or a gun you cannot
carry, shows a dim red ring instead; squeezing it gives a red flash and a double
tick. Squeeze grip while it is ringed violet to lock it (the hand closes into a
claw, a brighter ring, a beam to the palm, a soft buzz); the lock holds while the hand stays within 60 degrees of it and
for 0.25 s after letting go. Flick the hand, or draw it back toward you, to pull
the item; keep grip held and it lands in the palm (a pulse just before). A
magazine is held ready for the pouch or a
magwell. A toss already flying toward you within about 6 m is pulled by the
squeeze alone, no flick; one already within catching reach is simply caught. A brief red ring and a double tick mean the
server refused it (ammo full, already carried, too heavy, someone else's pull,
out of reach). A hand that is already a fist never highlights, a Zed in reach
takes the squeeze first, and body zones (pouch, wallet, chest grenade) keep
theirs. **GRAVITY PULL** in the interaction settings turns it off for you; the
host can turn it off for everyone with `VRGravityPull=0` on the server URL.

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
bSupportHandCarry=False
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
is the default; controller-relative movement is optional. bToggleGrip governs transfer/brace contacts, while bHoldSupportGrip
independently selects continuous support grip. An acquired firearm support grip
stays attached across controller distance drift while the grip remains held
and tracking is valid; releasing support does not stow the primary.

In Hold mode, guns equipped automatically at spawn remain in hand until the
first squeeze and release. Explicit quick swaps have the same first-squeeze
exception. Normal draws and catches require continuous grip.

`bSupportHandCarry` is the separate default-on **ALLOW SUPPORT-HAND CARRY**
option under VR SETTINGS > INTERACTION. It applies to supported two-handed
firearms. While braced, observe a released primary grip, then squeeze and
release it deliberately to unlatch. Only the original primary hand can regrip;
the carrier never becomes a firing hand. Final HOLD support release leaves a
local cosmetic drop, followed by automatic return to inventory after the existing
delay. The original item and all ammunition remain owned. A fresh squeeze of a
free hand can catch the local visual; redrawing removes it immediately;
TOGGLE support uses a fresh toggle-off squeeze. Tracking loss disarms release
gestures, so recovered open input cannot stow the gun. Entering carry or regripping interrupts
unfinished physical reload work without paying unseated ammo or refunding paid
ammo; unrelated stock reloads keep their native state. Matching multiplayer
client/server packages and the native carry guard are required.

The optional `SelectorFavorites` config array contains weapon class names in
preferred order. Owned matching actors always lead the wheel in that order,
ahead of the inventory-group order. The array does not grant weapons.

## Interactive reloads

VR SETTINGS > INTERACTION > RELOADS offers **CLASSIC**, **INTERACTIVE**,
**ADVANCED** and **CUSTOM** presets. PHYSICAL RELOADS, REQUIRED PUMP / BOLT CYCLES,
CYCLE READY WEAPONS and the individual ammunition rules can also be selected
independently. Classic is the default. Ready-weapon cycling/live-round ejection
never unlocks an already-ready shotgun pump: SG500 and Trench pumps operate for
an owed shot cycle or an empty/loading action. Changing ammo-loss rules does not
change that admission. Winchester/SPX levers also operate only for an owed
cycle or an empty-reload action: hold the fore-end and swing the trigger hand
through opening and closure. Ordinary two-hand aiming keeps control until
that deliberate motion. Supported bolt/slide ready cycling remains available.
**KEEP CHAMBERED ROUND / +1** controls magazine-gun chamber retention and
extra-round capacity. **CYCLE READY WEAPONS** permits supported bolt/slide/lever
inspection and live-round ejection; shotgun pumps and Winchester/SPX levers are excluded. A live round
racked out of a loaded gun is always lost, whatever the settings say.
**LOSE DROPPED / EJECTED AMMO** decides whether rounds left in a magazine you
drop or pull out, and live rounds ejected from a cylinder, are spent. These choices are independent rather than a single
realistic-ammo switch. All three advanced ammo options start Off. Switching
physical reloads or reload presets preserves them. PERK INSERTION ASSISTANCE
also starts Off.
**SPRINT WHILE RELOADING** (physical reloads, default ON) keeps a sprint running
through every physical reload, two-handed or at the hip, in Solo and online. Off
pauses the sprint for the reload, as the stock game does, and it resumes after.
Either way a pouch grab, hip loader or X/A starts a reload while sprinting.
**EMPTY TRIGGER RELOADS** (physical reloads) decides what an empty trigger does on
every physical gun: on, it starts the reload exactly as X/A would; off, it clicks
and X/A or the pouch reloads. It starts Off; changing physical reloads or presets
preserves an explicit player choice. Button reloads use stock empty-trigger behavior. Each hand's
X/A reloads only that hand's gun. With the other hand busy, X/A still drops the
magazine; the new one is taken once a hand is free. X/A releases only a slide
locked back; a closed slide or a bolt without hold-open needs a hand rack.
With free-hand physical reloads, the .500, Buckshot and Rhino open without
automatically emptying. Tilt backward to eject; no extractor-stem tap or target
circle is required. Stock animation timers stay paused through physical phases.
**LOSE DROPPED / EJECTED AMMO** spends every live round ejected this way; Off
retains the stock count. Seat a speedloader only after extraction, then
close with the existing sideways flick or hand push. Contact pulses the pushing
hand; the final latch pulses only the hand holding the gun. Full cylinders and
guns without reserve can still be inspected and closed without adding ammo.
After extraction, closure waits for seated rounds while reserve is available;
with no reserve it may close empty. Before extraction it may close normally.
On the RELOADS page or under **HUD AND READOUTS**, **RELOAD HINTS** controls the guidance rings and
insertion ghost, defaults ON, and remembers your choice across Solo/Join. It
can be adjusted in any mode; guidance appears for the relevant active physical
interaction. Hints and PERK INSERTION ASSISTANCE keep their saved choices across
preset changes and do not change the preset label. Turning hints off
keeps the physical pouch, ammunition, hand motion, assistance and haptics.
Pouch miniatures remain visible with a held weapon. Blue means acquire/place
ammunition; orange means operate the current mechanism. Required steps pulse
after 0.75 seconds or repeated dry fire. Belt ammunition glows only when it is
needed; optional top-ups remain available without a glow, including on hover.
An accepting receiver shows the carried load's blue alignment ghost immediately,
even when its fitted well already glows, and fades it during insertion.
Gripped mechanisms and automatic reloads stop asking for manual action. Red is
brief refusal feedback on a deliberate failed pouch grab or gravity pull; zero
reserve alone does not paint the receiver red. Dropped ammunition and guns use
quiet blue discovery rings that brighten in actual pickup reach. The plate and
pouch follow the weapon when it is carried by its support grip. See the
per-gun clue changes.
Coverage extends beyond the initial pistol/shotgun/AK-12/SA80 set through the
current reload catalog. Supported mechanisms vary by exact weapon; unsupported
items retain their stock button path. Use physical reloads
for the per-family catalog and current open work for acceptance. The normal-launcher
1858/9mm smoke is prepared only.
The old hidden unlock is no longer required. This build targets the magazine
guns for headset testing; both settings default OFF and await headset acceptance.
physical reloads describes optional per-family mechanisms.
For magazine guns and the MB500, missing assets or unusable stock reload motion keep the
ordinary reload before any magazine is hidden or timer is paused.

- X/A (or an enabled empty-trigger reload) starts the reload and the magazine drops
  out. So does squeezing the off-hand grip at the ammo pouch while the gun
  can reload: the old magazine drops and the new one (or a shell) is already in
  the hand. The gun stays where you hold it for the whole reload; the stock
  animation no longer turns it.
- The stock animation plays up to the moment it would insert the new magazine
  or shell and holds there; no replacement shows in the gun. The gun's own
  magazine, or a shell, waits in the ammo pouch at the front of the off-side
  hip. Hold the off-hand grip there to take it: the hand
  grips it the way the stock reload's hand does. A blue fitted glow or fallback
  ring marks the receiving well/port; a blue ghost shows its entry angle. As you approach, the ammunition and posed
  hand ease into the stock insertion position and angle, then moving closer
  advances the ammunition and original KF2 wrist/finger motion along the stock
  path into the gun. The hand blends into the acquired grip and returns to
  tracking after release without keeping the input grab alive. Pulling back
  reverses that motion until it seats; moving away fades the alignment out.
  Approach from the entry side with the prop roughly aligned. After alignment
  before pushing along the guide. Shells with release-to-seat support can settle
  after sufficient insertion; magazines retain their required seating stroke.
  Early release drops the load. Alignment ghosts are immediate; required-action
  teaching has a fresh 0.75 s delay unless the hand is already nearby.
  Tube-fed shotguns take one shell per step. Break shotguns carry only the
  shells owed, in the groups and poses of their stock reload. Return unused
  ammo to either pouch while still holding its carry control, or release it
  inside the pouch. Leave the pouch once after drawing before a held return
  can register. This covers fresh magazines, clips, loaders, boxes, loose
  rounds and secondary loads. Dropping away from the pouch loses the carried
  rounds when **LOSE DROPPED / EJECTED AMMO** is on; Dosh notes spend currency.
  Tracking/menu cancellation and infinite ammo do not charge a drop. Supported
  detachable magazines, including FAMAS secondary magazines, can be picked up
  again with **RECOVER DROPPED-MAG AMMO** enabled. Carrying one does not finish
  a reload: seat it in the open well, then operate any owed slide, latch or
  finishing handle just as with a magazine from the pouch.
- An empty reload that owes chambering shows an orange part or fallback ring:
  grip the slide or bolt, pull it fully back and let go,
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
- Guidance follows the available step: blue supply/receiver, orange mechanism,
  and a blue carried-load alignment ghost. Fitted parts and fallback rings
  share the 0.75 s teaching delay; contact/alignment is immediate. Pulling the
  trigger twice on a gun that cannot fire shows the current step immediately.
  Acquiring/completing that mechanism clears its attention pulse.
- Letting go of the carry control away from the gun drops what the hand held; take
  another. Firing still interrupts a shotgun reload, as in stock.
- With REQUIRED PUMP / BOLT CYCLES enabled, an SG500 or Trench Gun needs a
  rearward and forward stroke after a shot. The action stays at the position
  where the support hand lets go; release never springs it forward or chambers
  a shell. Regrip resumes there. Ready-weapon cycling and ammo-ejection settings
  leave a ready pump locked forward. HZ12 retains its stock two-shot cadence.
  With PHYSICAL RELOADS enabled, pulling an empty pump to the rear stop starts
  loading without a reload-button press. It stays open while the first port
  shell is carried, inserted and paid. The player then pushes the fore-end
  forward to chamber it; remaining shells use the existing tube-loading route.
  Stock ammo/reserve accounting and reload interruption remain authoritative.
  With SUPPORT HAND CARRY enabled, the same SG500/Trench action works through
  deliberate axial carrier-hand motion at any barrel angle. Braking can stop
  the receiver without reversing it; move the hand the other way to reverse.
  The fore-end stays planted, mechanical stops retain their sound/haptic cues,
  and carrying still cannot fire. Teammates see actual receiver/pump travel.
  Tracking/menu changes cancel motion without completing or paying a stroke;
  any required cycle or unpaid shell remains pending.

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
reload skills also widen the magnet. Design and costs:
physical reloads.

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
Design, numbers and open acceptance are in
teleport locomotion.

## Withdrawn body holsters

Body holsters and HOLSTER FIT are inactive and absent from the VR menus.
Saved `bBodySlotsEnabled`, `BodyHolsterOffsets` and legacy `BodySlotOffsets`
remain compatible profile data; an enabled value does not activate body grab
zones. The weapon wheel continues to equip/stow items. Ammo POUCH FIT and the
chest grenade retain their shared body frame and calibration.

The inactive prototype and the AS2 rig study
remain available for future design work. Primary-hand latched holding remains
the default; the other grip/drop modes have not received user headset acceptance.

## VR Calibration & Practice Mode (In-VR)

Access the in-VR calibration interface from CALIBRATION on the root VR menu,
VR SETTINGS > CALIBRATION, or PRACTICE AND TOOLS > CALIBRATION. HUD AND READOUTS
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
     Seated starts at the fixed 1.54 m pawn eye; crouch with the stick.
   - **SEATED HEIGHT** (beside RECENTER): after CAPTURE SEATED, lower or raise
     the seated view in 1 cm steps, from 40 cm below to 12 cm above the pawn
     eye. Head and hands move together. RESET HEIGHT restores zero; recapture
     preserves the saved adjustment. Standing capture ignores it.
   - **RECENTER**: Requests immediate native view recentering.
   - **HAND FIT**: Opens wrist/controller fit; its subtitle reports current height
     drop and baseline. ALIGN MARKERS shows the debugging geometry.
   - **WRIST INSPECTION PREVIEW**: Closes the selector for eight seconds so the
     real native wrist reveal detector can run, then reopens with which wrists
     it detected. Lower the hand and turn the palm toward your gaze.
   - **CHEST ZONE HERE**: Moves the chest grenade to the current palm.
   - **ALIGN MARKERS**: Draws the OpenXR grip origin (yellow), the wrist the game uses with its aim axes (cyan, red forward, green up), the drawn wrist (magenta), reload targets and the grenade sphere. Touch the controllers together to judge the hand fit.
   - **HAND FIT** (the left tile of the drop row; its subtitle keeps the drop and base heights): nudges where the drawn wrist sits relative to the controller in 0.5 UU steps, back/forward, inward/outward and down/up, mirrored for the left hand, with the markers on while the page is open. RESET HAND FIT returns to the profile's measured offset.
   - **POUCH FIT**: Adjusts the ammunition pickup centre forward/back,
     wider/narrower and up/down in 1 cm steps. Cyan markers show both mirrored
     centres. The ammo prop, reserve readout and pickup point move together;
     grab radius and insertion snap are unchanged. Changes save
     automatically; **RESET POUCH FIT** restores the original placement.

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
  during a normal Survival wave. The ordinary wheel's DROP submenu is Drop weapon/
  Drop dosh/Back, not a practice launcher. Practice
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

The perk grenade's visible centre rides the upper chest where Arizona Sunshine 2 hangs its chest
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

The chest model must be available for the slot to accept a grab or compete
with another body contact. Unsupported or missing chest models leave no
invisible grenade target in either solo or multiplayer.

Calibration page 2 **CHEST ZONE HERE** moves the grenade to the current palm;
the session menu's chest reset puts its visible centre back at the AS2 spot.
New captures and resets keep that centre in the same place when changing perks,
including grenades whose mesh pivot is away from their centre. Older saved chest
zones keep their previous placement; use **RESET CHEST GRENADE ZONE** or capture
the palm position again to adopt the centred placement.

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

In multiplayer, other players see the held grenade at the same authored size
and placement, following the existing 120 Hz hand-tracking stream. Release or
cancellation clears that cosmetic model; tracking expiry, death and leaving
the match clear it too. It has no live fuse, collision or ammo transaction.
Matching multiplayer packages are required for the grenade presentation stream.

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
| Locomotion and Comfort | Smooth/teleport, movement hand/direction, snap/smooth turning, +/- snap angle or smooth sensitivity, teleport blink, clot grab turning |
| Interaction | Dominant hand, primary/support grip, independent Solo/online Zed grabbing, supported reload/manual pump switches and melee hit-stop |
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
Failed or cancelled height capture restores the previous standing/seated mode;
tracking recovery does not perform a capture that has already timed out.

**CLOT GRAB TURNING** under Locomotion and Comfort uses the stock profile's
**No Auto Turn On Clot Grab** option: turning ON means the stock checkbox is OFF.
Changes from either menu are reflected by the other; there is no separate VR
saved override. OFF suppresses the grab-induced turn while preserving physical
head tracking. ON permits the stock non-critical grab turn, including when
enabled during a grab. Strong-grab forced camera turns remain suppressed in VR.

For laser collision diagnosis, open **VR SETTINGS > CALIBRATION > HEIGHT /
CHEST ZONE / WRIST HUD TEST** and switch **ALIGN MARKERS** on. While markers
are enabled, each visible weapon laser records a `KF2VR_LASER_TRACE` sample
in the game log at most once per second. Each sample names the hit actor/component and
their owners, with ray start/end and contact coordinates. `phase=first` is
the original hit; `phase=resolved` appears only after HUD filtering. These diagnostics do not change collision.
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
Blur, DOF and VSync remain off; variable frame rate stays on. Optional AA
and screen effects follow the active launch/profile policy. HBAO+ and reflections
start On; saved choices win, including through texture/filter edits and pre-spawn
menus. Single-pass stereo and threaded rendering are always on. The in-game rows show locked
status rather than changing these launch choices. Quality changes report readback
mismatches.
The VR shell opens only at session entry or through its explicit menu control;
death, boss-kill/end-of-game cinematics and other game camera takeovers do not
open it. Stock game UI floats as a spatial panel within the grounded VR Studio
environment, eliminating disorienting contrary-parallax level motion.
Solo and network launchers share tools/vr-defaults.json. The multiplayer launcher
persists approved preferences in %LOCALAPPDATA%/KF2VR/Profile/KFGame.ini.
See [all launcher switches](../PLAY-MULTIPLAYER.md) for explicit scale overrides.
Report headset readability, control feel and online issues with your build ID.

### Wristwatch chat

Incoming public/team chat from another player adds a ping, double haptic and
pulsing blue watch light. Turn the watch toward your face to read the latest
message for eight seconds in place of supplies/dosh; health, armor and priority
messages remain. New messages replace old ones. Self/system messages do not
notify. The watch hides its light and pending haptic during menus, tracking loss
or watch-off; pawn/session teardown clears the notification. Stock chat remains
available. Headset readability and real multiplayer acceptance remain open.

### Current settings controls

Numeric turn and panel-placement settings show one value with separate `-` and
`+` pointer targets. Press and release the same target to change it. Reload Mode
cycles Button, Physical, Physical + Pump; existing saved combinations are read
without migration. Turning physical reloads off keeps the stored pump preference;
choosing Physical explicitly selects automatic pumping. Unsupported weapons keep
their normal reload path.

Transfer / Brace Grip describes the existing grip preference, not automatic
primary-weapon dropping. Weapons stay equipped until switched or dropped; Support
Grip settings remain separate from weapon selection. Scoreboard is unavailable before
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

An acquired firearm support grip stays attached across controller distance drift in ordinary aiming and physical-stock mode while the grip remains held and tracking is valid. Tracking loss suspends support accuracy. Release/stow, melee and pump/carry handling retain their existing rules.
