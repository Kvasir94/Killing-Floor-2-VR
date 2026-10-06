# KF2 native adapter

The Windows x64 adapter targets exact Steam and Epic executable hashes in
`include/kf2vr/adapter/GameBuild.h`, with matching launcher recognition in
`tools/multiplayer/game_install.py`. Steam SDK inputs are pinned in
[install_manifest.json](../../docs/intake/install_manifest.json). Its `dinput8.dll`
proxy forwards system DirectInput exports and starts adapter work outside loader
lock. The full game SHA-256 must match before MinHook trampolines are prepared
and the hook set is enabled.

| Component | Responsibility |
| --- | --- |
| `Proxy.cpp`, `Adapter.cpp` | Loading, compatibility gate, engine/render hooks and shutdown |
| `include/kf2vr/adapter/VerifiedLayout.h` | Pinned function addresses and engine view/family layouts |
| `StereoViews.cpp` | Per-eye projection, relative HMD poses and scoped restoration of engine views |
| `AtlasBlit.cpp` | Eye-atlas copy with D3D11 context-state restoration |
| `XrGamepad.cpp` | XR input routing, cancellation, held-input suppression and stale-input handling |
| `GameScript.h`, `VRHandsBridge.uc` | Script reflection, hand/weapon transforms and gameplay bridge |
| `include/kf2vr/adapter/LocalWorldGate.h` | Admission checks for supported world/runtime state |

The stereo path starts OpenXR on the game's D3D11 device. It uses one predicted
pose sample for both eyes, renders a separate single-view pass for each eye,
copies the eye atlas and ends the XR frame at Present. `-kf2vr-stereo -onethread`
is the ordinary one-thread stereo path; the launcher exposes threaded rendering
as an experimental option. The adapter restores the original engine view state
and does not intentionally tick gameplay twice.

Build with the [source instructions](../../docs/BUILDING.md). Native CTests cover
eligible math/state/render logic; they do not establish headset comfort, actual
weapon alignment or network behavior. Launch playable packages through their
launcher for deployment and recovery. See [controls](../../docs/VR_CONTROLS.md)
and [launch options](../../PLAY-MULTIPLAYER.md).

## Integration invariants

- Validate inferred ABIs against the pinned executable; script declarations alone
  do not establish native layouts.
- Prepare every trampoline before enabling hooks and refuse unsupported builds.
- Restore temporary engine and D3D11 state before returning to the game.
- Keep game actions on the game-thread input/gameplay path. Render callbacks must
  not execute arbitrary console or gameplay commands.
- Invalidate engine references across travel, garbage collection and disconnect.
- Check shots, muzzle effects and visible weapon alignment in actual play when
  changing controller aim, placement or weapon behavior.
