#pragma once
#include <windows.h>
#include <Xinput.h>
#include <memory>
#include "kf2vr/xr/XrBackend.h"

namespace kf2vr::adapter {

// Raw, independently armed script actions. Physical X/Y and A remain separate
// even when both lower face buttons reload the single equipped prototype gun.
struct HandWeaponButtons {
    int activeMask = 0;
    int pressedMask = 0;
};
HandWeaponButtons MapHandWeaponButtons(const xr::FrameState& frame, int validHandMask);
// The script owns weapon actions; stock input continues to handle use/jump,
// locomotion and bash. This prevents duplicate reloads and weapon firing.
void RemoveScriptWeaponActions(XINPUT_GAMEPAD& pad);

// Candidate VR -> stock KF2 gamepad adapter, not an installed API hook.
// Publishes only controller index 0. The integration layer decides when to
// intercept XInput and forwards all other calls/indices to the real DLL.
class XrGamepad {
public:
    explicit XrGamepad(unsigned staleTimeoutMilliseconds = 250);
    ~XrGamepad();
    XrGamepad(const XrGamepad&) = delete;
    XrGamepad& operator=(const XrGamepad&) = delete;

    // Called once per XR sample on the render thread. Timestamp is any finite
    // monotonic real-time seconds value. Freshness uses a separate internal
    // Windows monotonic clock, so the caller's clock epoch does not matter.
    void SetFrame(const xr::FrameState& frame, double realTimeSeconds);
    // Thread-safe snapshots for the GAME'S XInput callback only. Index 0 stays
    // connected with neutral state after loss/cancel, balancing held releases.
    DWORD GetState(DWORD deviceIndex, XINPUT_STATE* state);
    DWORD GetCapabilities(DWORD deviceIndex, DWORD flags, XINPUT_CAPABILITIES* capabilities) const;
    // Call on shutdown, travel, weapon/menu transitions, or integration loss.
    // Every control must physically release/center while active before rearming.
    void Cancel();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace kf2vr::adapter
