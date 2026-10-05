# Offline native input replay

This developer input source feeds the normal `VRHandsBridge.NativeHandsUpdate`
callback. The production bridge converts poses and updates `HandInventory` once
per game tick. Replays must not also write bridge inputs, call inventory updates,
or force weapon fire/reload/ammunition state from a scripted driver.

## Activation and isolation

Use an isolated, owned standalone game session with all three exact flags:

```
-kf2vr-hand-replay -onethread -kf2vr-input-replay
```

Set `KF2VR_INPUT_REPLAY` in that child process's environment to an absolute input
file path. The environment variable alone does nothing. Loading happens before
hooks start; missing/malformed input refuses adapter initialization. Stereo,
network play and the old motion fixture cannot be combined with this source.
The normal player launcher does not activate it.

A launch harness must retain the normal package/config isolation and verified
native deployment/restore, take `Local\KF2VR_DevelopmentFixture`, refuse existing
user game/editor/server processes, impose startup and overall deadlines, and
clean up only its own child process and verified deployed files. Native-only
builds may use `tools/build-multiplayer-native.ps1 -AllowRuntimeOverlap` from an
independent worktree; this does not grant runtime ownership.

The source binds to the first local bridge and pawn. Changing either stops the
stream permanently for this process. A new process is required to restart. End
of input publishes unavailable frames indefinitely, cancelling held inputs via
the production path. It never returns to static fixture input or live XR.

## Version 1 text format

ASCII/UTF-8 without BOM, classic decimal locale, whitespace-separated numbers.
The header is:

```
KF2VR_INPUT 1 STEP_MICROSECONDS SEED
```

`STEP_MICROSECONDS` is 1000 through 100000. `SEED` is unsigned 64-bit provenance;
it does not reseed the game's random state. Establish any scenario inventory,
perk and world state before its input sequence and record them externally.

Every subsequent nonempty, non-comment line is one record. A comment starts
with `#` in column one. Records contain, in this order:

1. Tick count (positive), sample age in milliseconds, reference-space epoch,
   focused (0/1), actions synced (0/1), head valid (0/1).
2. Head pose: `x y z qx qy qz qw`.
3. Left hand: availability flags, pressed buttons, trigger axis, grip axis,
   stick X, stick Y, grip pose, aim pose.
4. Right hand: the same fields as the left hand.

Poses are OpenXR tracking space: metres, +Y up, -Z forward. Quaternions must be
finite and normalized within 0.02 squared length. Invalid poses use valid numeric
placeholders and cleared availability bits. Axes must be finite; trigger/grip
range is 0..1, sticks -1..1. Trailing tokens, unknown versions/bits, malformed
records and streams exceeding 360000 ticks are rejected.

Hand availability flags are a sum of:

| Value | Meaning |
| --- | --- |
| 1 | Grip pose valid |
| 2 | Grip pose tracked |
| 4 | Aim pose valid |
| 8 | Aim pose tracked |
| 16 | Trigger action active |
| 32 | Grip action active |
| 64 | Stick action active |
| 128 | Primary button active |
| 256 | Secondary button active |
| 512 | Stick click active |
| 1024 | Menu action active |

Pressed button bits are primary=1, secondary=2, stick=4, menu=8. Availability
is independent of value: inactive zero is **not** a physical release. A release
that rearms firing must have valid poses, active trigger and trigger value zero.

The record repeats for its tick count. Each normal bridge update consumes one
tick and receives a unique sample ID (starting at 1) and timestamp
`sample ID * STEP_MICROSECONDS / 1000000`. Render callbacks consume no ticks.
The first sample after an epoch change, samples older than 250 ms, unfocused or
unsynced samples, and samples with invalid head pose take the shared unavailable
input path. Subsequent samples in the new epoch can resume, with production
release-to-rearm semantics still in force.

## Verification boundary

`native_replay_input` checks stream parsing, per-hand press/hold/release/double-tap
values, timestamps, availability, stale samples, epochs, owner replacement and
EOF. It does not implement a second trigger-arming or weapon state machine.
Production arming, fire and reload require game-event observations from the
normal script/weapon path. A synthetic input run does not establish headset or
live-controller acceptance. Input timestamps are deterministic; Unreal game
DeltaTime and weapon timers remain engine-owned.

## Supported developer launch

Keep the selected production candidate immutable. `SourceRoot` is its checkout;
the integrated runner can use the same checkout and matching native build.
An independently owned replay checkout may also target that candidate. Build
the native adapter with the repository build script, then compile the observer
against the selected candidate's production script output:

```powershell
$SourceRoot = (Get-Location).Path
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-multiplayer-native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/replay/build-observer.ps1 `
  -ProductionScriptRoot "$SourceRoot/build/multiplayer/script"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SourceRoot/tools/test-bootstrap.ps1" `
  -UsabilityCapture -PrepareOnly
```

Use the printed fresh `run.json` path as `$Record`. Preparation verifies the
candidate source/package guard. Steam must be running and authenticated.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/replay/run.ps1 `
  -SourceRoot $SourceRoot -Record $Record `
  -InputFile tools/replay/stock-launchers.input -Observer -TimeoutSeconds 180
```

The runner disables legacy script drivers in the copied game config before
launching, preserves encoding and line endings, verifies candidate files and
native/observer build hashes, and never changes the selected-release pointer.
Each attempt needs a new prepared directory. It writes `input-replay-run.json`
there and retains the native deployment journal for crash recovery. Do not
retry a run with an unresolved deployment journal or a live owned child.

Before native deployment, the runner requires one override for each standard
INI inside that prepared directory. Keep the original BOM-free ANSI bytes or
BOM-marked UTF-16, including byte order and line endings. Do not copy configs
through `utf-8-sig` or a text writer that adds a UTF-8 BOM or translates CRLF.
The runner preserves those bytes when disabling the legacy script input flags.

UE3 misreads a UTF-8 BOM at the first section of an INI. For
`KFSystemSettings.ini`, this can discard `[SystemSettings]`, initialize graphics
values to zero and reduce the world viewport to 1x1 while chat remains visible.
The preflight rejects a UTF-8 BOM in every standard override and requires the
complete `[SystemSettings]` section with finite, positive `ResX`, `ResY`,
`ScreenPercentage` and `MaxDrawDistanceScale`. Prepare again from intact configs
when it fails; do not force renderer flags or camera fading to manufacture a
visible world. A successful PNG write or normal process exit alone does not
establish visible-world capture. Inspect the actual saved pixels separately
from input-event observations.

`tools/replay/run.py` and its config tests are development tooling absent from
the player package. Updating them does not require rebuilding or reselecting
an unchanged playable release; a clean source export carries their new identity.

The optional observer declares its setup: HX25 in the left hand, M79 in the
right, toggle carry, stock fallback reload. It calls the production inventory
API to establish those initial holdings, then only observes input/weapon state.
It requires two fires and reloads per weapon, loaded chambers and matching
reserve debit. It does **not** prove physical break-action insertion/closure,
rendered-world quality or headset behavior. Those require separate authored
controller trajectories and observations through the same ingress.

For a retained game log, the same acceptance parser can be run directly:

```powershell
python tools/replay/analyze.py '<prepared run>/game.log'
```

With `-Observer`, the runner also requires this parser's evidence of unavailable
input, held-trigger reconnect suppression, released-trigger rearming, and a
subsequent shot in each hand. A normal process exit alone is not acceptance.
