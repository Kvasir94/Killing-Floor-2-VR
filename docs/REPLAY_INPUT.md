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

## Parser and gameplay boundary

`native_replay_input` checks stream parsing, per-hand press/hold/release/double-tap
values, timestamps, availability, stale samples, epochs, owner replacement and
EOF. It does not implement a second trigger-arming or weapon state machine.
Production arming, fire and reload require game-event observations from the
normal script/weapon path. A synthetic input run does not establish headset or
live-controller acceptance. Input timestamps are deterministic; Unreal game
DeltaTime and weapon timers remain engine-owned.

## Developer tools

The normal player launcher does not enable this input source. The optional
`tools/replay/` helpers prepare an isolated session and parse its output; use
them only when deliberately investigating a supported input/gameplay issue.
Do not combine replay flags with a normal headset or network session. Complete
cleanup before changing releases, and use a fresh prepared directory for each run.
Headset feel and real online behavior still require human testing.
