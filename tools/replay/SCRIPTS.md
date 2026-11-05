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
- By default one game session runs many cases back to back (`--per-launch`, default 40). A `case` op between cases releases both hands, removes the guns the previous case granted, returns the hands to the ready pose, clears watches, and checks the slate is clean. Settings come from the launch config, so the runner starts one session per settings combination and runs every weapon in it (a console `set` does not reach the live bridge's settings). A timed-out `wait until` or a refused draw fails only that case and skips to the next. If the game crashes or hangs, the runner records the case that was running and relaunches with the rest. `--isolated` restores one launch per case.
- `--plan` compiles the script and prints its ops without launching anything.
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
| `setup map=KF-Outpost timeout=240 autoshot=on [stall=25] [res=1920x1080]` | Map, run deadline in seconds (per case in a session), and automatic screenshots on reload steps. `res` sets the window and screenshot size (default 640x360); use it for glow colours and small parts. `start` places the pawn at the run's start and at every case: `keep` (default, the game's own spawn), `first` (the map's first PlayerStart by name, the same spot every run) or `X,Y,Z[,Yaw]`. Not usable yet: after the teleport the native side keeps its eye base at the old spawn, so every hand goal reads thousands of UU out of range (`ReloadCase goal-out-of-range`) and input stops. Leave it at `keep`. `stall` fails a session case early once nothing about the guns, the reload stage or the player's position has changed for that many seconds (default 25, 0 turns it off); `timeout` stays the hard cap |
| `set Key=Value ...` / `preset advanced\|classic` | Bridge settings for this run (`KF2VR.VRHandsBridge` keys) |
| `include lib/common.kfs` / `define name { ... }` / `do name` | Reuse. Includes resolve beside the script |
| `repeat N { ... }` / `repeat until <cond> [max N] { ... }` / `if <cond> { ... } [else { ... }]` | Loops and branches. `until` and `if` are evaluated in the game. `define name(a, b) { ... $a ... }` / `do name(x, y)` pass parameters; `default name=value` gives a variable a fallback |
| `draw <hand> <weapon> [timeout T]` | Grants the weapon if it is missing and draws it through the normal inventory API. A dual class fills both hands |
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
| `spawn <zed> [dist D] [yaw Y]` | Spawn a zed D UU ahead along the view turned by Y degrees (to clear the practice dummies), with the stock `SpawnZed` cheat (standalone). Friendly names map to stock prefixes: clot, cyst, slasher, gorefast, crawler, stalker, bloat, siren, husk, scrake, fleshpound; count them with `count(KFPawn_Monster)` |
| `aim <hand> at <anchor>` | Point the hand's controller axis, the gravity grab's aim, at an anchor, e.g. `aim left at nearest(VRWorldDropMagazine)` |
| `setammo <hand> [mag N] [reserve N] [mag2 N] [reserve2 N]` | Test setup: set that hand's gun magazine and reserve counts, primary and secondary (e.g. `reserve2 0` for an underbarrel with no grenades left) |
| `trace <probe>... [every T] [for T]` | Log the probes in the background every T (default 0.1 s) for T seconds (default 30) while later ops run, e.g. `trace R.anim R.ammo reload.step every 0.1s for 40s` |
| `netdrop magazine [N]` | Fault injection: the owner's network magazine channel ignores the authority's next N replies (`VRHandsBridge.TestDropMagazineReplies`, logged `phase=test-dropped`), so a run can show a lost reply expiring (#43) |
| `dosh <amount>` | Add dosh with the stock `DoshMe` cheat; read it back with `dosh` |
| `perk <KFPerk_...>` | Request that perk (`RequestPerkChange`, applied at once where the game allows); read it back with `perk` |
| `buy <weapon>` | A trader purchase through the stock server path: purchases enabled, `ServerBuyWeapon` by trader index (pays dosh), then `ServerCloseTraderMenu`, which creates the bought weapon |
| `wait T` / `wait until <cond> [timeout T] [soft]` | A timeout on `wait until` fails the case and moves to the next; `soft` just continues |
| `expect <cond> [within T]` | Records a pass or fail and continues |
| `watch <cond>` | Checked every frame; a violation is reported once |
| `expect log /re/ [since MARK]` / `forbid log /re/` / `mark NAME` | Checks on the game log. A forbid without `since` also stops the run live |
| `log <probe> ...` / `shot [name] [pose]` / `console <text>` / `autoshot on\|off` / `end` | Output and control |

**Anchors**

- `head`, `body`, `world`
- `wrist.left`
- `pouch` (the moving hand's pouch) or `pouch.left`
- `hip.left`: the paired-gun hip loader, otherwise the pouch
- `R.mag`, `R.well`, `R.action`: the production reload-hint bones of the gun in that hand
- `R.support`, `R.trigger`: the gun's support and trigger grip zones; `R.stroke`: the worked action's contact where it stands now; `R.blade`: the centre of the held weapon's melee head (its profile's MeleeHeadStart/End), carried by the `slash` macro; `R.scope`: a scoped gun's lens (VRM14Scope when it renders, else its RW_Scope or RW_Sight bone), used by the `ads` macro; `pickup.<hand>`: where that wrist goes so its palm lands on the nearest dropped gun's own catch grip
- `R.bone(RW_Bolt)`
- `nearest(KFDroppedPickup)`: the nearest live actor of that class
- `reload.target` and `reload.held`: the active physical reload's next target and the point that must reach it, taken from `VRInteractiveReload.RingStep`, the same code that places the hint rings. While the reload needs ammunition the target is the belt pouch grab point. `reload.seat` is the seated position. Pair them as `move left reload.held to reload.target align`; `align` turns the wrist to present the ammunition at the entry orientation the insert guide accepts (`InsertWristQuat`).

**Probes**

- Per hand (`L.` / `R.`):
  - Holding: `held`, `grip`, `trigger`, `supports` (the gun this hand holds as a support grip, or `none`)
  - Ammo: `ammo`, `capacity`, `reserve` (the production reserve, `VRPouchAmmo.Reserve`, so dosh-funded guns read right)
  - Reload state: `state`, `mag_out`, `needs_rack`, `slide_lock`, `eject` (the stock shell-eject emitter's gap from the gun's ShellEject socket and from the palm, in UU), `can_reload`, `reloading`, `await_ammo`, `await_rack`, `cyl_seated`, `cyl_closed`, `hint` (`well`, `action` or `none`)
  - Actions: `pump` (a real pump action, not cycle-only), `needs_pump`, `pump_pull` (0 forward to 1 rear), `pump_engaged`, `cock` (the crossbow's cocking, R32: -1 pump back with the string loose, 0 forward on the string, 1 cocked), `needs_cycle` (a hand-cycled bolt or lever is owed), `needs_pump2` (the FAMAS underbarrel owes its pump after a secondary shot; an A double-tap opens the secondary session on that stage and `follow-secondary` works it), `lever` (an owed reload lever stage: 1 open it, 2 close it, 0 none), `primary_lever` (the trigger hand works this gun's lever: Winchester, MB464), `finish_profile` and `finish_kind` (the finish control's catalog profile, where 0..2 also complete on a palm press at the button, and its kind: 0 completes on the grab, 1 at 70% of a one-way stroke, else 90% out and back; -1 with none), `action` (worked-action progress, 0 closed to 1 open, or -1)
- Progression: `xp` and `perk_level` (the current perk's experience and level, from KFPlayerController.GetPerkXP), and `xp.<KFPerk_...>` for any perk. `kills.<WeaponDef>` counts this match's kills credited to that weapon definition (the after-action report's `EphemeralMatchStats.WeaponDamageList`, e.g. `kills.VRWeapDef_BareHands`), and `kills.xp_match` the current perk's experience gained this match.
- World and setup: `props.mags`, `props.mag_rounds`, `props.rounds` and `props.cases` (live dropped magazines, the rounds they carry, loose live rounds and spent cases), `setting.<Key>` (a live VRHandsBridge setting read back with `get`, e.g. `setting.bLoseReloadAmmo`), `nearest(<Class>).health` (a pawn's health, e.g. a spawned zed's), `nearest(<Class>).gore` and `.gore_mesh` (its dismembered hit zones, from stock HitZones[].bPlayedInjury, and whether it has switched to its gore mesh), per hand `gravity` (the gravity grab's locked target, else its candidate) and `carry` (magazine, gravity, zed or none: what the hand holds that is not a gun), `anim` (the stock weapon clip playing: name:position:rate:playing); the secondary (underbarrel) reload's `reloading2` and `stage2` per hand, with `reload.step2` (pouch, action or none) and the `reload.target2` anchor, which the `follow-secondary` macro works through (VRSecondaryReload: an X/A double tap starts it, and its ammo comes out of the pouch on the trigger), and the compound bow's `bow` (this gun is one) and `bow_phase` (1 carried, 2 nocked, 3 drawing, 4 pending). The `bow.nock` anchor is the arrow's nock, where `bow-shot` takes the string.
  - Summary: `family` (catalog family), `ready_to_load` (a reload is under way, or there is nothing to load), `done` (nothing out or owed, full or reserve spent, action closed)
- World: `count(Class)`, `nearest(Class).dist|x|y|z|pitch|yaw|roll|speed|class|hidden`, `dist(anchorA, anchorB)`, `pawn.x|y|z|yaw|view_yaw|travel` (travel is the distance from where the script started)
- Run: `speed`, `health`, `frame_ms`, `time`, `input`, `graphics_preset` (the headset GRAPHICS PRESET label, then which settings groups keep each tier from matching)
- Reload: `reload.step` (`pouch`, `insert`, `rack`, `action`, `eject` or `none`); `reload.actions` names the live action owners (for triage). The `follow-reload(worker, gun, gunhand)` macro in `scripts/lib/common.kfs` loops on it until `done`.

Conditions are `<probe> <op> <value>`, with op one of `== != < <= > >=`. Comparisons are numeric when both sides are numbers, and case-insensitive text otherwise. To add a probe or an anchor, add a case to `ScriptRunner.Probe` or `ScriptRunner.Resolve` and a pattern to `kfs.probe` or `kfs.anchor`.

**Screenshots**: `shot name pose` logs both wrist goals, the solved wrists, the held items and the head next to the image. With `autoshot on`, every change of a hand's reload signature (weapon state, ammo, magazine out, reload active, awaiting ammo or rack, hint, cylinder seated or closed, slide lock) is logged as a `step` line and captured with its pose, so each step of each reload style gets a picture. A run holds at most 128 captures, paged 16 per index for `captures.py`.

## Multiplayer (dedicated server)

`tools/replay/scripted_mp.py` runs the same scripts on VR network clients that play on an owned loopback LAN dedicated server: `KFServer.exe` from `--server-root` (default `build/multiplayer/server`, the Host launcher's install) with the candidate's packages, server adapter and the production `KF2VRNet` game (diagnostic auto-ready, Zeds quiet unless `--zeds`). Each client runs `KF2VRReplay.NetScriptRunner`, the client-side ScriptRunner, so the owner's production reload, drop and throw code talks to the real authority.

```powershell
python tools/replay/scripted_mp.py --script tools/replay/scripts/mp/reload-agree.kfs --candidate <absolute release dir> --weapons 9mm,mb500 --clients 2 --wait 1800
```

- `--clients N` (1-3) starts N clients on the one server and splits the cases between them, so they play at once. The runner takes the same fixture lease as `scripted.py` and queues for it with `--wait`.
- `draw` asks the server to grant the gun (`NetScriptServer` / `NetScriptAgent`); the client draws it once it has replicated. Case resets remove the granted guns on the server.
- Extra hand probes read the authority for the gun that hand holds: `L.srv_ammo`, `L.srv_reserve`, `L.srv_weapon`, and `L.ammo_agree` (owner magazine and reserve equal the server's). `scripts/lib/mp.kfs` has `agree`, `fire-agree` and `net-reload`.
- Live `forbid log` patterns are also checked against the server log; the summary lists the server's `KF2VRNet ... phase=refused` lines and grant counts.
- Each session folder holds `server-game.log`, and per client `clientN/driver/game.log`, `clientN/native.log` and `clientN/summary.md`; the root holds `batch.md`.

Scripts live in `scripts/mp/`. A pass is evidence, not online acceptance.

## Example scripts (`tools/replay/scripts`)

| Script | Covers |
| --- | --- |
| `reload-hints.kfs` | One gun in the right hand, reloaded by the left hand following the production reload steps (pouch, entry ring, rack, action), across reload styles |
| `reload-dual-hip.kfs` | A paired gun in both hands, both reloading at their hip loaders at once |
| `drop-throw-catch.kfs` | World drop, floor pickup, throw and gravity catch, with drop height and orientation probes |
| `movement.kfs` | Walking, strafing, turning and head look with a gun held |
| `big-inventory.kfs` | Granting and cycling many guns under the crash, hang and memory watchdog |

These scripts are starting points. A style whose action is not a straight pull, such as a bolt lift-and-pull or a break-open tilt, needs its own rack macro, written from that gun's path bones in the reload catalogs.
