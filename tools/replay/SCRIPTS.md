# Scripted replays (.kfs)

A `.kfs` script drives the real offline game with authored input: either hand
or both, buttons, sticks, walking, turning and head look. It can also run
console commands, take screenshots, and check game state while it runs.
`tools/replay/kfs.py` compiles the script. The generic observer
`KF2VRReplay.ScriptRunner` executes it, and `tools/replay/scripted.py` launches
and watches the game unattended and writes the verdict.

Inputs travel as world goals through the native reload-geometry ingress
(control version 3). Native code converts them through the ordinary tracking
path, so production reload, grab, drop and locomotion code does all the
gameplay work. The runner writes no ammo, reload or inventory state; the only
exceptions are the explicit `draw` setup op and console commands the script
issues. Runs are Solo, offline and hand-replay only. A pass is evidence for a
fix, not headset or online acceptance.

## Running

```powershell
./tools/build-kf2vr.ps1 -NoSelect -Parallel 2
python tools/replay/scripted.py --script tools/replay/scripts/reload-hints.kfs --plan --weapons 9mm
python tools/replay/scripted.py --script tools/replay/scripts/reload-hints.kfs --candidate <absolute release dir> --weapons 9mm,ar15,mb500 --loops 3
```

- `--weapons` runs the script once per weapon, which the script reads as `$weapon`. Weapons can be aliases from `ammo_prepare.FAMILIES` or class paths. Each weapon gets a fresh game process and its own folder.
- `--loops N` repeats the whole list.
- `--var name=value` sets other `$name` values.
- By default one game session runs many cases back to back (`--per-launch`, default 12). A `case` op between cases releases both hands, removes the guns the previous case granted, returns the hands to the ready pose, clears watches, and checks the slate is clean. Settings come from the launch config, so the runner starts one session per settings combination and runs every weapon in it (a console `set` does not reach the live bridge's settings). A timed-out `wait until` or a refused draw fails only that case and skips to the next. If the game crashes or hangs, the runner records the case that was running and relaunches with the rest. `--isolated` restores one launch per case.
- `--plan` compiles the script and prints its ops without launching anything, once per weapon and `--matrix` combination, with the settings each would launch with.
- `--parallel N` (session mode, 1 to 4) splits each session's cases across N game instances that run at once; the runner holds the fixture lease and one native proxy install for the whole batch and staggers the cold starts.
- `--fixture <lane>` (or `KF2VR_FIXTURE=<lane>`) runs in that lane's own game copy and lock, so lanes don't queue on each other or on the shared install. Make the copy once with `python tools/replay/fixture.py create <lane>` (about 55 s and 340 MB: read-only game content is hard-linked from the Steam install, Binaries/Development/config folders are copied). Run `refresh <lane>` after a Steam update and `remove <lane>` to delete it; `list` shows them. Inside a lane, the lock is one blocking wait (`--wait` seconds), and only that lane's own games block it.
- Long runs hold the game slot one chunk at a time (`--per-launch` cases per process, times `--parallel`) and leave it free for `--yield-gap` seconds (default 90) between chunks, so a build or another lane waiting on the fixture lease gets its turn.
- `--wait SECONDS` queues for the game slot (another run, build-observer compile or game holding the fixture lease) instead of failing, so several threads can hand the runner work.
- `--weapons all` asks the game first: one short launch runs the `catalog` op, which dumps every registered weapon with its reload family (from `ReplayCatalog`, the same facts as the legacy batch catalog) into `weapon-catalog.json`, then the script runs once per weapon. Narrow it with `--families detachable,pump,...` or `--dual-only`.
- `--matrix Key=a,b` (repeatable) runs every combination of VR settings for each weapon, overriding the script's `set`/`preset` lines. Keys are `KF2VR.VRHandsBridge` settings; `preset=advanced,classic` expands the named bundles. For example, `--matrix preset=advanced,classic --matrix bLoseReloadAmmo=True,False` gives four runs per gun.

Each run folder holds `ops.txt` (each compiled op with its source line), `game.log`, `native.log`, `captures/index.html` and `summary.md` / `summary.json`. The batch root holds `batch.json`.

The watchdog ends a run early, as a failure, on any of these:

- a fatal log line (`Critical:`, assertion, GPF);
- a `forbid log` match;
- a window that stops responding for `--hang` seconds;
- commit growth beyond `--memory-growth` MB after ready;
- no log output for `--stall` seconds;
- not reaching ready within 240 s;
- the script timeout.

The runner owns the fixture lease. It refuses to start while a game, editor or server is running, and it restores the native deployment and checks that the user config did not change.

## Language

One statement per line, or several separated by `;`. A `#` starts a comment. Durations take `ms`, `s` or `m`. Distances are centimetres. Body offsets are `(forward, right, up)` from the eye and turn with the body. `in gun` offsets use the anchor's bone frame, and `in world` uses world axes. A trailing `&` starts a motion without waiting for it. `sync` waits for both hands. Hands are `left`, `right` or `both`.

| Statement | Meaning |
| --- | --- |
| `setup map=KF-Outpost timeout=240 autoshot=on [stall=25] [res=1920x1080]` | Map, run deadline in seconds (per case in a session), and automatic screenshots on reload steps. `res` sets the window and screenshot size (default 640x360); use it for glow colours and small parts. `start` places the pawn at the run's start and at every case: `keep` (default, the game's own spawn, which differs run to run), `first` (the map's first PlayerStart by name and its facing, the same spot every run; on KF-Outpost `KFPlayerStart_0`) or `X,Y,Z[,Yaw]` (pawn location, yaw in degrees, default 0). Solo only: online the server's spawn stands. Needs a candidate built from 2026-11-11 on, whose adapter logs `ReplayInput body-at-ready`: the replay's body frame then takes the start spot's yaw, so the hands and the view face the same way. `stall` fails a session case early once nothing about the guns, the reload stage or the player's position has changed for that many seconds (default 25, 0 turns it off); `timeout` stays the hard cap |
| `set Key=Value ...` / `preset advanced\|manual\|classic` | Bridge settings for this run (`KF2VR.VRHandsBridge` keys) |
| `include lib/common.kfs` / `define name { ... }` / `do name` | Reuse. Includes resolve beside the script |
| `repeat N { ... }` / `repeat until <cond> [max N] { ... }` / `if <cond> { ... } [else { ... }]` | Loops and branches. `until` and `if` are evaluated in the game. `define name(a, b) { ... $a ... }` / `do name(x, y)` pass parameters; `default name=value` gives a variable a fallback |
| `draw <hand> <weapon> [timeout T]` | Test setup: grants a fresh copy of the weapon (full ammo and reserve, replacing one already carried) and draws it through the inventory API. Any stock dual class (`KFWeap_DualBase`, the Chiappa Rhino dual too) fills both hands; with hold-to-grip it holds both grips, as a player taking two guns does. To change weapons the way a player does, use `select` |
| `select <hand> <weapon\|hand> [refused] [timeout T]` / `wheel <hand> open\|close` | The hand's weapon wheel (`VRHandSelector`) through the player's own input: hold Y/B until it opens, move the hand toward the entry's sector (turning pages through NEXT PAGE), then release and squeeze the grip. Nothing is granted: the wheel lists what is carried. `hand` picks OPEN HAND. A weapon matches by class, then as a member or single of a named dual (a stock dual's sector draws one member into that hand), then by label. A refusal fails the check with the game's own message (`check=select ... value=refused:OTHER_HAND_HOLDS_IT`) and the wheel is closed; `refused` expects one. `wheel open` leaves the wheel open for the `wheel` probes; `wheel close` shuts it with a Y/B press |
| `pose <hand> <anchor> [offset (x,y,z)] [in body\|gun\|world] [rot (p,y,r)] [over T] [&]` | Timed wrist move that tracks a moving target |
| `move <hand> [<point>] to <anchor> [speed V] [tol D] [timeout T] [&]` | Servo until the point (default the wrist) reaches the anchor; fails on timeout |
| `stroke <hand> [<gun L\|R>] to <0..1> [speed V] [tol D] [timeout T]` | Drive the worked action (bolt, lever, hinge, cylinder, belt cover, finish control, M32) along its own sampled path to that progress, closed-loop on the game's reported progress (`VRInteractiveReload.ActionStroke`, or the owed reload lever's `LeverPath`, worked by the trigger hand). Near the goal end it keeps pushing along the path's end tangent, so a stop the sampled path falls short of is still reached; a lever stroke ends when its stage does. `tol` is how close counts as there (default 0.05) |
| `nudge <hand> (x,y,z) [in gun\|body\|world\|rack\|bore] over T [&]` | Relative stroke, for racks, pumps, throws and slaps. `in rack` puts X along the active reload's racking pull (`RackPullDirection`), in units of the production hand stroke (`RackHandStroke`), so 1 means a full rack; `in bore` is the root-bone frame of the gun the hand holds or supports |
| `press <hand> <button> [T]` / `hold` / `release <hand> <button\|all>` | Buttons are trigger, grip, primary (A/X), secondary (B/Y), stick and menu |
| `stick <hand> x y [for T]` / `walk forward\|back\|left\|right T [speed s]` / `turn left\|right [T]` | Sticks and locomotion |
| `look yaw=Y pitch=P [over T] [&]` or `look at <anchor> [over T] [&]` | Body-relative head goal (`at` turns onto an anchor, e.g. `pouch.left`). The offline flat view (and so every screenshot) follows it too: pitch sets the view pitch, and yaw changes turn the view on top of any stick turning |
| `goto <anchor> [dist D] [face] [speed s] [timeout T]` | Walk the pawn with the movement stick until it is within D cm of the anchor (e.g. `nearest(KFDoorActor)`); `face` then turns with the other stick until the view points at it. `ahead D` stands D UU along the anchor's own facing instead (e.g. `goto nearest(KFPawn_Human) ahead 300 face`: in front of that pawn, turned to face it) |
| `snap <probe> as <name>` | Save a probe value; compare later with `@name` |
| `empty-reload <hand>` | That hand's next reload may end with no rounds added (a deliberate empty close, #81): its runner ledger skips the "a reload must add rounds" check once |
| `spawn <zed> [hostile] [dist D] [yaw Y]` | Spawn a zed D UU ahead along the view turned by Y degrees (to clear the practice dummies), fanning out when the spot is blocked. Friendly names (clot, cyst, slasher, gorefast, crawler, stalker, bloat, siren, husk, scrake, fleshpound) and `KFPawn_...` names spawn exactly that `KFGameContent` class with the stock `SpawnZed` steps; any other name goes to the stock lookup (`ClotA`, `GF`, `GF2`, `Sc`...), which may roll a random elite. Without `hostile` the zed has no controller and stands still; `hostile` gives it its own AI on the Zed team, hunting the player (as stock `SpawnAI` and the practice range's attacker do). Count them with `count(KFPawn_Monster)` |
| `damage on\|off` | Whether the player takes hits. Replays start in practice mode, invulnerable; `damage on` uses the practice range's own switch (as `mutate VRPractice damage`), online the server's god mode. Read it back with the `god` probe |
| `hitch <T>` | Fault injection: stall the game thread once for T (1 ms to 5 s; e.g. `hitch 150ms`, a frame at about 7 FPS), as a load spike or a screenshot frame does, so the next frame carries the whole gap. Logs `hitch ms=... stalled=...` with the wall-clock stall it achieved. Use `turn left` (with `console set VRSessionUI bSnapTurn True`) for a snap turn |
| `camera eye\|front\|side\|left\|behind\|over [dist D] [body]` | Where the flat view, and so every capture, looks from: `eye` (default) is the player's view; the others watch the chest from D UU (default 150) outside, follow the body and stay in front of walls and snow banks. Tracking is untouched (the view target is a camera actor). The hands and guns the player sees are shown; the stock third-person body, which does not follow tracking, is hidden unless `body`. Pose lines and capture entries name the camera |
| `aim <hand> at <anchor> [bore]` | Point the hand's controller axis, the gravity grab's aim, at an anchor, e.g. `aim left at nearest(VRWorldDropMagazine)`. With `bore`, steer the held gun's own shot axis instead (its runtime's fire origin and base aim, what the native shot hooks use), e.g. `aim right at nearest(Alive_KFPawn_ZedClot_Alpha) bore`; a pistol's bore sits about 20 degrees below the controller axis, so only `bore` tests where a gun shoots. One-handed guns: a two-handed hold also turns with the support hand and converges only roughly |
| `setammo <hand> [mag N] [reserve N] [mag2 N] [reserve2 N]` | Test setup: set that hand's gun magazine and reserve counts, primary and secondary (e.g. `reserve2 0` for an underbarrel with no grenades left) |
| `trace <probe>... [every T] [for T]` | Log the probes in the background every T (default 0.1 s) for T seconds (default 30) while later ops run, e.g. `trace R.anim R.ammo reload.step every 0.1s for 40s` |
| `netdrop magazine [N]` | Fault injection: the owner's network magazine channel ignores the authority's next N replies (`VRHandsBridge.TestDropMagazineReplies`, logged `phase=test-dropped`), so a run can show a lost reply expiring (#43) |
| `opticset <hand> [view lit\|noshadows\|unlit] [fps N] [size N] [fog on\|off] [prepass on\|off] [far N] [every N]` | Test setup for cost A/B runs (#212): change that hand's physical optic capture (VRM14Scope) and re-attach it; `every N` captures one frame in N. Read the cost from `OpticCaptureTiming` lines in native.log |
| `target [dist D] [size S]` / `target off` | Test setup: a static board D UU straight ahead of the eye, square to the view, S UU wide, textured with a detailed stock material (the M14 atlas), so paired shots compare a fixed texture (scope zoom checks, #212). `tools/replay/measure_scope_zoom.py` reads `scripts/issues/212-scope-zoom.kfs` runs |
| `dosh <amount>` | Add dosh with the stock `DoshMe` cheat; read it back with `dosh` |
| `perk <KFPerk_...>` | Request that perk (`RequestPerkChange`, applied at once where the game allows); read it back with `perk` |
| `headshot <Class> [damage N] [dt <path>]` | Test setup: a stock head hit on the nearest pawn of that class (default 5 damage, Deagle damage type), also reported to the perk's head-shot counter as a weapon impact is, so Rack 'em Up (Rhythm Method, Gunslinger `skill 2 on`) counts it (#224) |
| `skill <index> on\|off` | Test setup: switch the current perk's `PerkSkills` entry, as its saved build would (e.g. Support's Tactical Reload is index 1, which plays the elite clips); the perk's own level gate still applies |
| `buy <weapon>` | A trader purchase through the stock server path: purchases enabled, `ServerBuyWeapon` by trader index (pays dosh), then `ServerCloseTraderMenu`, which creates the bought weapon |
| `wait T` / `wait until <cond> [timeout T] [soft]` | A timeout on `wait until` fails the case and moves to the next; `soft` just continues |
| `expect <cond> [within T]` | Records a pass or fail and continues |
| `watch <cond>` | Checked every frame; a violation is reported once |
| `expect log /re/ [since MARK]` / `forbid log /re/` / `mark NAME` | Checks on the game log. A forbid without `since` also stops the run live |
| `log <probe> ...` / `shot [name] [pose]` / `console <text>` / `autoshot on\|off` / `end` | Output and control |
| `live` | Hand the game to live control (see Live control); plain `scripted.py` skips it |

**Anchors**

- `head`, `body`, `world`
- `wrist.left`
- `pouch` (the moving hand's pouch) or `pouch.left`
- `hip.left`: the paired-gun hip loader, otherwise the pouch
- `R.mag`, `R.well`, `R.action`: the production reload-hint bones of the gun in that hand
- `R.support`, `R.trigger`: the gun's support and trigger grip zones; `R.stroke`: the worked action's contact where it stands now; `R.blade`: the centre of the held weapon's melee head (its profile's MeleeHeadStart/End), carried by the `slash` macro; `R.scope`: a scoped gun's lens (VRM14Scope when it renders, else its RW_Scope or RW_Sight bone), used by the `ads` macro; `pickup.<hand>`: where that wrist goes so its palm lands on the nearest dropped gun's own catch grip (when the game would not take a palm there, as when a gun lies on that side and the grip sits under the floor's surface, the gun's ground circle instead, noted once as `pickup-grip-refused`) `recovered.<hand>`: the centre of the recovered magazine that hand carries (the point the insert guide admits near the well; its floor actor stays where it lay while carried), e.g. `move left recovered.left to R.well`.
- `R.bone(RW_Bolt)`
- `grenade`: the chest grenade slot's grab point, placed for the moving hand's palm (`move left to grenade`, then `hold left grip`)
- `nearest(KFDroppedPickup)`: the nearest live actor of that class; prefix the class with `Alive_` (`nearest(Alive_KFPawn_ZedClot_Alpha)`, also in `zed(...)` anchors) to skip dead pawns
- `reload.target` and `reload.held`: the active physical reload's next target and the point that must reach it, taken from `VRInteractiveReload.RingStep`, the same code that places the hint rings. While the reload needs ammunition the target is the belt pouch grab point. `reload.seat` is the seated position. Pair them as `move left reload.held to reload.target align`; `align` turns the wrist to present the ammunition at the entry orientation the insert guide accepts (`InsertWristQuat`). `reload.straight` is a rock-in magazine well's straight entry with its upright orientation (R60; missing where the well has none), for inserting nearly straight along the well instead of at the stock angle.

**Ammo ledger**: each hand's reload is checked against the ammunition rules (PHYSICAL_RELOAD_SPEC R4-R6) when it ends (`check=ledger`). A weapon change mid-reload voids that hand's ledger (`ledger-void ... reason=weapon-change`). A recovered magazine (a floor or gravity grab) seated during the reload is expected with its own rounds, the reserve paying nothing. Outside a reload no gun may gain rounds (`check=minted`), except the Syringe and the Welder, which recharge by themselves. When both members of a shared-reserve pair reload at once their reserve draws cannot be told apart, so the pair is judged together: `ledger pair.total` (both guns plus the reserve) against what they held before, less the rounds the drops lost.

**Probes**

- Belt-fed reloads: `reload.step` is `belt` between box seating and belt seating. `reload.target` places the working palm on the leading round. Release the previous grip, move there and squeeze; `stroke left R to 0.7` then carries that round along its production path. Per-gun `belt_progress` reads its 0..1 travel (`none` without a belt action), `belt_engaged` reads whether the hand owns it, and `belt_seated` reads the production latch. These probes never write reload state. The shared `follow-reload` macro releases past halfway and waits for the production settle before closing the cover.
- Per hand (`L.` / `R.`):
  - Weapon wheel: `wheel` (open or closed), `wheel_items` (every entry the wheel lists, `page:class`, `#1` for a stock dual's second member, `(occupied)` when the other hand holds it; `none` before the wheel first opened), `wheel_hover` (the hovered entry's label) and `wheel_msg` (the game's message under the wheel, e.g. `DRAW_REFUSED`)
  - Holding: `held`, `grip`, `trigger`, `supports` (the gun this hand holds as a support grip, or `none`)
  - Ammo: `ammo`, `capacity`, `reserve` (the production reserve, `VRPouchAmmo.Reserve`, so dosh-funded guns read right)
  - Insert guide: `guide` (the active reload's VRReloadInsertGuide, for an insert that never captures: `captured`, `progress`, and for its last sample `remaining` depth to the seat and `lateral` miss along the entry-to-seat axis, `to_entry`, `entry_len`, the last uncaptured sample's axis `match` with the entry orientation against `capture_dot`, and the `axial`/`swept`/`straight` modes; gun-local UU; `none` without a reload)
  - Reload state: `state`, `mag_out`, `needs_rack`, `slide_lock`, `eject` (the stock shell-eject emitter's gap from the gun's ShellEject socket and from the palm, in UU), `can_reload`, `reloading`, `await_ammo`, `await_rack`, `cyl_seated`, `cyl_closed`, `hint` (`well`, `action` or `none`)
  - Actions: `pump` (a real pump action, not cycle-only), `needs_pump`, `pump_pull` (0 forward to 1 rear), `pump_engaged`, `cock` (the crossbows' string, R63: 0 forward, rising to 1 as the guided bolt is pushed home and it is cocked), `needs_cycle` (a hand-cycled bolt or lever is owed), `needs_pump2` (the FAMAS underbarrel owes its pump after a secondary shot; an A double-tap opens the secondary session on that stage and `follow-secondary` works it), `lever` (an owed reload lever stage: 1 open it, 2 close it, 0 none), `primary_lever` (the trigger hand works this gun's lever: Winchester, MB464), `finish_profile` and `finish_kind` (the finish control's catalog profile, where 0..2 also complete on a palm press at the button, and its kind: 0 completes on the grab, 1 at 70% of a one-way stroke, else 90% out and back; -1 with none), `action` (worked-action progress, 0 closed to 1 open, or -1)
- Progression: `xp` and `perk_level` (the current perk's experience and level, from KFPlayerController.GetPerkXP), and `xp.<KFPerk_...>` for any perk. `kills.<WeaponDef>` counts this match's kills credited to that weapon definition (the after-action report's `EphemeralMatchStats.WeaponDamageList`, e.g. `kills.VRWeapDef_BareHands`), and `kills.xp_match` the current perk's experience gained this match.
- World and setup: `props.mags` and `props.mag_rounds` (dropped magazines lying loose, the green-ringed `VRWorldDropMagazine` pickups plus any purely local drop, and the rounds they still carry; a magazine in a hand is not counted), `props.rounds` (loose live rounds, world and local) and `props.cases` (spent cases), `setting.<Key>` (the live bridge's own value of a VRHandsBridge setting, via `getall`, else the class default, e.g. `setting.bLoseReloadAmmo`), `god` (the player takes no damage), `nearest(<Class>).pull` (whether the gravity grab may take it: 0 yes, 1 not pullable or not yours, 2 returning, claimed or hidden, 3 too heavy) and `.returning` (a world gun on its way back by itself), and for a dropped gun `.grounded`, `.zone_l`/`.zone_r` (its pickup zone at that palm now: 0 trigger grip or ground circle, 1 support grip, -1 none), `.grip_l`/`.grip_r` (that palm's distance to the hand's own catch grip) and `.grip_z_l`/`.grip_z_r` (that grip's height above the floor under the gun), `nearest(<Class>).health` (a pawn's health, e.g. a spawned zed's), `nearest(<Class>).gore` and `.gore_mesh` (its dismembered hit zones, from stock HitZones[].bPlayedInjury, and whether it has switched to its gore mesh), `nearest(<Class>).lighting` (the light channels of that actor's and its owned actors' visible meshes, e.g. `KFSkeletalMeshComponent:IOD`; a part with neither I nor O renders black), per hand `gravity` (the gravity grab's locked target, else its candidate), `gravity_why` (the first VRGravityPull gate that keeps the nearest dropped magazine from being a target for that hand, e.g. `squeeze-reserved` with a live Zed within 60 UU of the palm, `cone`, `view`, `occluded`, or `ok`), `recover_why` (the first VRMagazineRecovery grab gate for the nearest dropped magazine, or `carrying:` with the carry's flags) and `carry` (magazine, including a recovered floor or gravity grab, gravity, zed, grenade or none: what the hand holds that is not a gun), `fingers` (the rendered free hand's thumb 1 and index 2 rotations relative to the wrist, then the thumb curl control's target: tells an authored grenade grip from the plain fist), `anim` (the stock weapon clip playing: name:position:rate:playing); the secondary (underbarrel) reload's `reloading2` and `stage2` per hand, with `reload.step2` (pouch, action or none) and the `reload.target2` anchor, which the `follow-secondary` macro works through (VRSecondaryReload: an X/A double tap starts it, and its ammo comes out of the pouch on the trigger), and the compound bow's `bow` (this gun is one) and `bow_phase` (1 carried, 2 nocked, 3 drawing, 4 pending). The `bow.nock` anchor is the arrow's nock, where `bow-shot` takes the string.
  - Optic: `optic` (the physical optic on this hand's gun: 1 while its capture renders, 0 suspended, -1 none) and `optic_eye` (the eye's distance behind the lens and offset from its axis, UU)
  - Summary: `family` (catalog family), `ready_to_load` (a reload is under way, or there is nothing to load), `done` (nothing out or owed, full or reserve spent, action closed)
- World: `count(Class)` (`count(Alive_Class)` skips dead pawns, as `nearest` does), `nearest(Class).dist|x|y|z|pitch|yaw|roll|speed|class|hidden`, `dist(anchorA, anchorB)`, `pawn.x|y|z|yaw|view_yaw|travel` (travel is the distance from where the script started)
- Run: `speed`, `health`, `frame_ms`, `time`, `input`, `graphics_preset` (the headset GRAPHICS PRESET label, then which settings groups keep each tier from matching)
- Reload: `reload.step` (`pouch`, `insert`, `rack`, `action`, `eject`, `hip` or `none`; `hip` is a one-handed hip reload whose action stands open: `move left reload.held to reload.target` brings the gun's magazine bone, or its open cylinder's seat, to the hip loader); `reload.actions` names the live action owners (for triage). The `follow-reload(worker, gun, gunhand)` macro in `scripts/lib/common.kfs` loops on it until `done`.

Conditions are `<probe> <op> <value>`, with op one of `== != < <= > >=`. Comparisons are numeric when both sides are numbers, and case-insensitive text otherwise. To add a probe or an anchor, add a case to `ScriptRunner.Probe` or `ScriptRunner.Resolve` and a pattern to `kfs.probe` or `kfs.anchor`.

**Screenshots**: `shot name pose` logs both wrist goals, the solved wrists, the held items, the head and the camera next to the image. Each entry in `captures/index.json` names its session `case`, `weapon` and `settings` label (and, for a capture with a pose, `held_left`, `held_right` and `camera`); `case_index` is only the page (16 captures a page). `captures/index.html` groups the shots by case, and `python tools/replay/contact_sheet.py <run> <out.png> [--columns 6] [--names a,b]` tiles them per case, wrapping rows. With `autoshot on`, every change of a hand's reload signature (weapon state, ammo, magazine out, reload active, awaiting ammo or rack, hint, cylinder seated or closed, slide lock) is logged as a `step` line and captured with its pose, so each step of each reload style gets a picture. A run holds at most 128 captures, paged 16 per index for `captures.py`. A failed check is captured once per case, however often it fails again (a `watch`, a loop, a ledger check every tick).

## Multiplayer (dedicated server)

`tools/replay/scripted_mp.py` runs the same scripts on VR network clients that play on an owned loopback LAN dedicated server: `KFServer.exe` from `--server-root` (default `build/multiplayer/server`, the Host launcher's install) with the candidate's packages, server adapter and the production `KF2VRNet` game (diagnostic auto-ready, Zeds quiet unless `--zeds`). Each client runs `KF2VRReplay.NetScriptRunner`, the client-side ScriptRunner, so the owner's production reload, drop and throw code talks to the real authority.

```powershell
python tools/replay/scripted_mp.py --script tools/replay/scripts/mp/reload-agree.kfs --candidate <absolute release dir> --weapons 9mm,mb500 --clients 2 --wait 1800
```

- `--clients N` (1-3) starts N clients on the one server and splits the cases between them, so they play at once. The runner takes the same fixture lease as `scripted.py` and queues for it with `--wait`.
- `draw` asks the server to grant the gun (`NetScriptServer` / `NetScriptAgent`); the client draws it once it has replicated. Case resets remove the granted guns on the server.
- Extra hand probes read the authority for the gun that hand holds: `L.srv_ammo`, `L.srv_reserve`, `L.srv_weapon`, and `L.ammo_agree` (owner magazine and reserve equal the server's). `scripts/lib/mp.kfs` has `agree`, `fire-agree` and `net-reload`.
- Live `forbid log` patterns are also checked against the server log; the summary lists the server's `KF2VRNet ... phase=refused` lines and grant counts. With one client a match fails only the case whose span of the server log (from its agent's `clear` line) holds it.
- Walking: on a hand-replay network client the native adapter replaces the movement stick's forward axis with the legacy network diagnostic walk (zero), so `walk forward|back` and a stick's forward axis do not move the pawn; strafing does, and so does a `look` (it sets the view yaw). `goto` therefore turns the view so its next point lies to the right and strafes there, then restores the view yaw, or with `face` turns the view onto the anchor. The pawn starts on the server's spawn spot.
- Each session folder holds `server-game.log`, and per client `clientN/driver/game.log`, `clientN/native.log` and `clientN/summary.md`; the root holds `batch.md`.

Scripts live in `scripts/mp/`. A pass is evidence, not online acceptance.

## Campaigns

`tools/replay/campaign.py` runs a manifest of replay invocations unattended and writes one report. `campaigns/full.json` covers every runnable script plus the generic sweeps; a script's own header stays the reference for one-off runs.

```powershell
python tools/replay/campaign.py --plan                       # every command line, and every case compiled
python tools/replay/campaign.py --candidate <absolute release dir> --lanes a,b --mp-lane c
python tools/replay/campaign.py --candidate <release> --areas reload,melee --tier core --kind logic
python tools/replay/campaign.py --candidate <release> --lanes a,b --mp-lane c --resume build/scripted-replay/campaign-<stamp>
```

- Each `--lanes` lane is a worker that runs its Solo entries one after another (`scripted.py --fixture <lane>`); mp entries run one at a time on `--mp-lane` (the shared install without one). With no lanes everything runs in turn on the shared install. `--only`, `--areas`, `--tier` and `--kind` filter the manifest.
- The campaign folder (default `build/scripted-replay/campaign-<UTC stamp>`) holds one runner folder per entry, `logs/`, and `campaign.json` and `campaign.md`, rewritten after every entry: totals, a table per area with each failing case's first failed check, frames to review for visual entries, evidence logs, unfinished and skipped entries. `--resume` keeps finished entries whose definition did not change.
- After each entry the BMP originals of captures that have a PNG are deleted (`--keep-bmp` keeps them).
- A replay is never killed. Ctrl-C stops starting entries and waits for the running ones (a second Ctrl-C leaves them running and exits). An entry past its timeout (from its case count, or the entry's own `timeout`) is left running and collected at the end if it has finished.
- The exit code is non-zero when any non-skipped case failed or an entry did not finish.

Manifest entries: `id`, `runner` (`solo` or `mp`), `script`, and optionally `weapons` (`all` is Solo only), `vars` (name to value), `matrix` (Key or `var.name` to a list of values), `clients` and `zeds` (mp), `extra` (other runner arguments), `after` (an earlier entry of the same runner that must run first on the same lane, e.g. the two phases of `xp-persist`), `timeout` (seconds), `areas` (feature tags), `kind` (`logic` passes on probes, `visual` needs frames reviewed, `evidence` is logs to read), `tier` (`core`, `issue` or `long`), `issues`, `notes` and `skip` (a reason; skipped entries are reported, never counted as passes).

## Live control

`tools/replay/live.py` keeps a game running and takes kfs statements one at a time from a terminal, for a person or an agent reacting to what it sees. Each command prints plain text and exits.

```powershell
python tools/replay/live.py start --candidate <absolute release dir> --fixture <lane> --weapons 9mm [--script x.kfs] [--res 1280x720] [--preset advanced] [--set bToggleGrip=True]
python tools/replay/live.py send "draw right 9mm" "do ready"          # several args are joined with ;
python tools/replay/live.py probe R.ammo R.reserve reload.step
python tools/replay/live.py shot [name]                                # prints the PNG's absolute path
python tools/replay/live.py status | pause | resume | abort
python tools/replay/live.py quit                                       # clean end; prints the summary path
python tools/replay/live.py repl                                       # a prompt for a person
python tools/replay/live.py start --mp --clients 2 --port 18977 --query-port 38215 ...   # then send/probe --client 1|2
```

- `start` launches through `scripted.py` (`scripted_mp.py` with `--mp`) in a background session process that owns the fixture lease, the native install and the watchdogs, and returns once the game is live (`--no-wait`, then `live.py wait`, for a long queue). With `--script` the script runs first, then the session goes live; a script can also end with `live`, which plain `scripted.py` skips. Without one it is just setup plus live.
- `send` compiles with `kfs.py` (the `lib/common`, `lib/melee` and `lib/mp` macros, `$weapon` and `--var` values; `define` persists for the session), waits until the ops have run (`--no-wait` returns once queued; `--timeout`, default 120 s), and prints their notes and verdicts. `setup`, `set`, `preset` and log checks apply at launch only: settings come from the launch config, so give them to `start` (`--preset advanced|manual|classic`, then `--set Key=Value`, repeatable; applied as a script's `preset`/`set` lines are, over the script's own, Solo and `--mp`). `end` quits.
- `probe` answers at once, even while an op waits. `pause` freezes the op cursor and the hand goals (sticks rest) and `resume` continues every timer where it stopped; `abort` drops the running and queued statements, stops the motions and releases every button except grip, so held guns stay in hand (the reply says `grips_held=<mask>`; `release both grip` empties the hands). A failed `wait until` or draw drops the rest of its statement and the session stays up.
- Exit codes: 0 ok, 1 a check failed or the statement was aborted, 2 usage or compile error, 3 session or game gone, 4 timed out (the ops keep running). `quit` exits 0 only when every check passed and the runner restored the game folder.
- In live mode the case deadline, stall and log-silence watchdogs are off; crash, hang and memory watchdogs stay. A session quits itself after `--minutes` (default 40, at most 480). The runners launch with `KF2VR_INPUT_REPLAY_HOLD=1`, so the adapter holds the head-tracking tape's last sample for as long as the session runs; with a candidate built before that, the tape ends after 50 minutes and the session is cut to 45. If the session process dies, the game ends itself 45 s later; then run `live.py recover` to restore the game folder from the run's journal. Never kill the session process or the game.
- Transport: the game's `KF2VRReplay.LiveLink` (an IpDrv `TcpLink`) dials the session's broker on 127.0.0.1 (outbound, so no firewall prompt). Files in the session folder: `session.json`, `daemon.log`, `live-clientN.log` (every line the game sent), `origins.json` (op line ids to statements), `batches.json`, `shots/`, and the runner's usual `run/` folder.
- On a dedicated server each client is its own endpoint (`--client N`); `ammo_agree` and the other `srv_` probes work there. Use ports that differ from the mp lane's (`--port`, `--query-port`).

## Example scripts (`tools/replay/scripts`)

| Script | Covers |
| --- | --- |
| `reload-hints.kfs` | One gun in the right hand, reloaded by the left hand following the production reload steps (pouch, entry ring, rack, action), across reload styles |
| `reload-dual-hip.kfs` | A paired gun in both hands (`--weapons` takes stock dual classes), both reloading at their hip loaders at once |
| `drop-throw-catch.kfs` | World drop, floor pickup, throw and gravity catch, with drop height and orientation probes |
| `movement.kfs` | Walking, strafing, turning and head look with a gun held |
| `big-inventory.kfs` | Granting and cycling many guns under the crash, hang and memory watchdog |

These scripts are starting points. A style whose action is not a straight pull, such as a bolt lift-and-pull or a break-open tilt, needs its own rack macro, written from that gun's path bones in the reload catalogs.
