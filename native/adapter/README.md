# KF2 native adapter

An implemented, experimental x64 integration for the executable pinned in
[install_manifest.json](../../docs/intake/install_manifest.json). The opt-in
`dinput8.dll` proxy forwards system DirectInput exports and starts the adapter
outside loader lock. The adapter checks the full game SHA256 before preparing
MinHook trampolines and enabling the hook set together.

**Integration status (2026-09-18):** all 26 native tests and the two-client
control/combat/recovery/lifecycle gates passed on their recorded builds.
Partial headset testing left grenade and second-hand findings unresolved.
See current validation.

**Historical early prototype evidence:** Local Support gameplay with 9mm
and MB500 renders into OpenXR on the game's D3D11 device. Live headset feedback
confirms clear rendering, head tracking, walking, firing and stick turning in
run `20260912-082153-903-401c4f16`. That prototype added controller aim and arm
IK for the MB500, 9mm and syringe. See the Support prototype
for controls, local replay evidence and remaining headset validation.

## Implemented path

| Component | Responsibility | Current evidence |
|---|---|---|
| `Proxy.cpp`, `Adapter.cpp` | Opt-in loading, hash gate, view/submit/Present/resize hooks and explicit shutdown | Live game rendering on the RTX3080Ti device; successful1923x2016 native resize before Canvas creation. |
| `include/kf2vr/adapter/VerifiedLayout.h` | Pinned function addresses and engine view/family layouts | Offline disassembly, documented in render map and view layout. |
| `StereoViews.cpp` | Deep-copy a left/right view pair, asymmetric projection, relative HMD poses and scoped restoration of the original family | Live sequential single-view passes restore map lighting; both eye captures and user headset feedback accepted. |
| `AtlasBlit.cpp` | Copy the game's eye atlas to XR eye targets while restoring D3D11 context state | 97 WARP pixel/state checks pass. |
| `XrGamepad.cpp` | Map XR inputs with cancellation, hold suppression and stale-input watchdog; Adapter dispatches stock native InputAxis/InputKey | User confirmed locomotion, turning and firing. Virtual XInput stays neutral to avoid duplicate delivery. |
| `GameScript.h`, `VRHandsBridge.uc` | Pinned script reflection, controller-to-weapon placement, scoped aim/origin hooks and arm IK | Actual local game replay with stock shotgun/pistol damage, reload, bash and syringe healing. |
| `include/kf2vr/adapter/LocalWorldGate.h` | Local-world admission checks for the experimental native path | Isolated gate checks pass; these do not establish safety for network play. |

The early build below had seven CTest suites; the current multiplayer builder
builds and runs 26. This older log is historical evidence only;
see LastTest.log.

Stereo is opt-in via `-kf2vr-stereo -onethread`. It creates OpenXR from the
game's swapchain device, starts an XR frame at the selected world-family submit,
renders the whole viewport separately for each eye, snapshots both into an
atlas, and ends the XR frame at Present. Each pass uses one native scene view;
putting both views in one native family produced a dark world in live testing.
`-kf2vr-singleview` retains the one-view-to-both-eyes diagnostic mode.

The view pair uses one predicted pose sample and the normal engine presentation
lifecycle. It does not deliberately tick gameplay twice. Live acceptance must
still establish a coherent same-step eye pair, correct first-person treatment
and successful restoration across pause, resize, travel and exit. World scale
is provisionally 100 Unreal units/metre from KF2's player dimensions; separate persistent eye view state,
room-scale collision, calibrated weapons and VR menus remain unfinished.

## Local fixture

Use [test-bootstrap.ps1](../../tools/test-bootstrap.ps1), after building the
current native adapter and SDK package. It pins the game/package/source hashes,
copies complete configs into a unique workspace run and refuses to stop an
unrelated game/editor process. `-PrepareOnly` records the plan without copying
native files or launching.

`-NativeProbe` temporarily creates the proxy and its required OpenXR loader
beside the game, refusing existing files. Cleanup removes only hashes it staged,
after its owned process exits. A durable `restore_pending` record survives a
lock or interrupted cleanup; [recover-fixture.ps1](../../tools/recover-fixture.ps1)
is the reviewed recovery entry point.

`-SupportDemo` adds the separate `VRDemo` mutator to revision 2 `VRBootstrap`.
It selects Support and the 9mm through stock setters, uses the stock Ready/spawn
path and records inventory evidence rather than granting weapons. Start a
manual headset session with:

```powershell
.\tools\test-bootstrap.ps1 -Stereo -SupportDemo
```

There is no startup or play time limit. Close the game normally whenever you
finish, keeping the terminal open for final logging and temporary-file cleanup.
A normal close records a completed session even if startup is still in
progress. Startup and native evidence are recorded separately, so a completed
session does not assert successful verification or headset acceptance. Crashes,
runtime errors and cleanup errors still record a failure. Records and logs are
saved under `build/bootstrap-runs/`.

Add `-Timed` for bounded Support verification with `-DurationSeconds` and
`-KeepRunningSeconds`. `-HandReplay` and passive diagnostics remain bounded.

Both classes compiled, and the
070121 game log
records revision 2 standalone initialization and Support with 9mm/MB500 at
136.46 seconds. That run's verifier missed the markers because KF2 printed
short class names; its original failed record remains intact. The corrected
matcher recognizes the observed format. This validates the stock script path,
not headset rendering, locomotion or tracked aiming.

`-Stereo` implies the native probe and records `Game XR ready`, a `StereoPair`
with two eyes/two native submissions, and `GameXREnd` with an atlas and positive submission
count. Bounded verification requires those markers; a normal manual close can
leave them unobserved without failing the session. Failure/refusal/fallback logs
still reject the fixture. Those markers establish
game rendering/submission only when observed; headset appearance and comfort
require human acceptance.

The launcher scopes `KF2VR_LOG_PATH` and `KF2VR_STOP_PATH` to the owned child.
When a bounded run closes the game, the launcher creates `stop.request` and waits up to three
seconds for `XR shutdown completed`; the adapter handles shutdown from Present,
outside loader lock. The record distinguishes observed XR shutdown and graceful,
forced or natural process exit. Abrupt termination is not clean XR teardown.

The local fixture described above is standalone; the separate tools/multiplayer
fixtures cover the explicit network client path. Protected servers remain outside
that scope. The copied engine config sets `bUseVAC=false` for its Steam server mode.
This does not prevent a client from joining a secure server. See
the verified scope and limitations.

## Invariants

- Validate inferred ABIs against the pinned executable and a live fixture before
  accepting them; script declarations alone do not validate native layouts.
- Prepare every trampoline before enabling hooks, and fail closed on an unknown
  build or unsupported runtime state.
- Restore temporary engine/D3D state before returning to the game.
- Keep game actions in the stock game-thread input/gameplay path. Rendering
  callbacks must not execute arbitrary console/gameplay commands.
- Invalidate engine references across travel, GC and disconnect before those
  transitions are accepted. The fresh-map fixture alone does not prove them;
  separate integration recovery/lifecycle receipts cover their recorded scenarios.
- Keep actual shots, muzzle effects and visible weapons aligned before claiming
  tracked-controller aiming; an input mapping or debug ray is insufficient.
