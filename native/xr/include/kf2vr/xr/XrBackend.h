// Runtime-neutral coherent XR poses. Units are metres, +Y up, -Z forward.
#pragma once
#include <cstdint>
#include "kf2vr/Transform.h"
namespace kf2vr::xr {
enum class SessionState : std::uint8_t { Idle, Ready, Synchronized, Visible, Focused, Stopping, Exiting, LossPending };
// Actual angular bounds in radians. Apply tan() when constructing projection.
struct FovRadians { float angleLeft=0, angleRight=0, angleUp=0, angleDown=0; };
template<typename EyeFrame> struct EyeView {
    FovRadians fov;
    Transform<EyeFrame, frames::Tracking> pose;
    bool poseValid=false, poseTracked=false;
};
template<typename GripFrame, typename AimFrame> struct HandState {
    Transform<GripFrame, frames::Tracking> grip;
    Transform<AimFrame, frames::Tracking> aim;
    bool poseValid=false, poseTracked=false, aimPoseValid=false, aimPoseTracked=false;
    // Zero unless focused and the individual action is active.
    float triggerAxis=0, gripAxis=0, stickX=0, stickY=0;
    bool primaryPressed=false, secondaryPressed=false, stickPressed=false, menuPressed=false;
    // Inactive input is not a physical release; consumers must keep hold suppression.
    bool triggerActive=false, gripActive=false, stickActive=false;
    bool primaryActive=false, secondaryActive=false, stickClickActive=false, menuActive=false;
    // Held to open the mod's VR menu: Index right trackpad press (force).
    bool menuHoldPressed=false, menuHoldActive=false;
};
struct FrameState {
    SessionState state=SessionState::Idle;
    bool shouldRender=false, viewsValid=false;
    bool actionsSynced=false; // xrSyncActions succeeded while focused this frame
    // OpenXR monotonic time domain in seconds; never use for game simulation.
    double predictedDisplayTime=0, predictedDisplayPeriod=0;
    // All eyes, head, grips and aims are located at this frame's predicted time.
    std::uint64_t poseSampleId=0;
    // Changes only when the runtime's announced origin change takes effect.
    // A consumer must never combine poses from different epochs.
    std::uint64_t referenceSpaceEpoch=0;
    Transform<frames::Head, frames::Tracking> head;
    bool headPoseValid=false, headPoseTracked=false;
    EyeView<frames::EyeL> eyeLeft;
    EyeView<frames::EyeR> eyeRight;
    HandState<frames::GripLeft, frames::AimLeft> handLeft;
    HandState<frames::GripRight, frames::AimRight> handRight;
};
class IXrBackend {
public:
    virtual ~IXrBackend()=default;
    virtual const char* Name() const=0;
    virtual bool Initialise()=0;
    virtual void Shutdown()=0;
    // Each true result requires EndFrame, even when shouldRender is false.
    virtual bool BeginFrame(FrameState& out)=0;
    virtual bool EndFrame()=0;
    virtual std::uint32_t RecommendedWidth() const=0;
    virtual std::uint32_t RecommendedHeight() const=0;
};
class NullBackend final : public IXrBackend {
public:
    const char* Name() const override { return "null"; }
    bool Initialise() override { return false; }
    void Shutdown() override {}
    bool BeginFrame(FrameState& out) override { out={}; return false; }
    bool EndFrame() override { return false; }
    std::uint32_t RecommendedWidth() const override { return 0; }
    std::uint32_t RecommendedHeight() const override { return 0; }
};
}
