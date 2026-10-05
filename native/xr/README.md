# OpenXR D3D11 backend

`OpenXrD3D11Backend` is a standalone-capable runtime foundation. It does not hook KF2, render the game's scene, or establish headset comfort/performance acceptance.

Use one render thread. `Initialise(options)` either retains the supplied game D3D11 device or creates a standalone device on the runtime's required adapter. A supplied device must match the adapter LUID and minimum feature level. Runtime initialization can launch SteamVR or the configured OpenXR runtime.

For each successful `BeginFrame(frame)`, call `EndFrame()` exactly once, including frames with `shouldRender == false` or invalid tracking. Call `RenderEyes(callback)` at most once between them. Each callback receives a borrowed colour texture, sRGB render target, and D32 depth target for one eye. Finish all eye work before returning `true`. The backend acquires, waits, unbinds, and releases each image. A failed callback drops the entire stereo layer. The caller owns D3D11 state; any game adapter must save and restore the game's pipeline around the callbacks.

Both eyes and the head/hand poses are located at the same predicted display time. `poseSampleId` identifies this frame, not a gameplay step. `FovRadians` stores actual angles; projections must apply `tan` to the bounds. Left/right eyes and grip/aim frames have distinct C++ types. Pose validity requires both orientation and position flags; tracking flags remain separate. Gameplay input is zero outside session focus or when the individual action is inactive. Input policy, hold suppression on focus regain, weapon cadence, and player simulation belong to the VR core/game adapter.

Core bindings are suggested for Khronos simple controllers, Oculus Touch, Valve Index, Vive wands, and Microsoft motion controllers. Unbound controls stay zero and the runtime can remap suggestions. Per-hand haptic requests and game action routing are implemented through the adapter. Controller models, optional vendor profiles, skeletal hands and compositor depth submission remain separate feature work.

A stage origin is requested by default, with local origin fallback. `Info().stageSpace` identifies the result. Reference-space change events are counted in diagnostics; the KF2 adapter implements origin compensation/recentering and multiplayer room movement; see room movement for its validation boundary. Frame counters report begun, ended, submitted, invalid-view frames, focus losses, and reference-space changes.

`ShouldQuit()` covers runtime exit/loss and fatal errors. `LastError()` supplies an actionable diagnostic. Callback failures are recoverable; the next `BeginFrame` clears the prior diagnostic. Swapchain waits time out after one second and fail the session; they never pass an unready image to the caller. `Shutdown()` releases partially constructed resources as well as complete sessions and never calls game-wide `ClearState` or falls back to another graphics adapter.

Implementation follows the [Khronos OpenXR specification](https://registry.khronos.org/OpenXR/specs/1.0-khr/html/xrspec.html) and the vendored `third_party/openxr-sdk-source/src/tests/hello_xr` API examples. SDK/build validation is distinct from running the `xrsmoke` scene and from validating actual KF2 rendering in a headset.
