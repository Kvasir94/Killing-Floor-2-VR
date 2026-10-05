#pragma once

#include "StereoViews.h"

namespace kf2vr::adapter {

namespace pinned {
inline constexpr std::uintptr_t kPlayerControllerTickRva = 0x582000;
inline constexpr std::uintptr_t kActorSetRotationRva = 0x6f43c0;
// Windows x64: Tick's float is XMM1, TickType is R8D. UBOOL is 32-bit.
using PlayerControllerTickFn = std::int32_t (*)(void*, float, std::int32_t);
using ActorSetRotationFn = std::int32_t (*)(void*, const NativeRotator*);
}

enum class HeadAimStatus { Unavailable, ReferenceEstablished, NoChange, RotationRequested };
struct HeadAimRequest {
    std::uintptr_t controller{};
    pinned::NativeRotator before{}, rotation{};
    std::uint64_t token{}, poseSampleId{};
    std::int32_t trackingYaw{}, trackingPitch{};
};

// Pure state/math. The root adapter owns pointer reads, standalone/focus gates,
// native SetRotation, Tick, and readback. No engine or OS calls happen here.
// Injects tracked yaw/pitch deltas before stock PlayerTick, leaving controller
// roll and stock stick/recoil updates intact. CameraCache keeps stock timing;
// this is not an exact same-sample firing guarantee.
class HeadAim {
public:
    // One accepted XR frame, held only between its sequential eye renders.
    // The right eye consumes it; callers also clear it at each new left eye.
    class RenderPairLease {
        friend class HeadAim;
        const HeadAim* owner_{};
        std::uintptr_t controller_{};
        pinned::NativeRotator camera_{};
        std::uint64_t sample_{}, epoch_{}, token_{}, inputSample_{};
        double displayTime_{};
        HeadInTracking head_{};
        xr::EyeView<frames::EyeL> left_{};
        xr::EyeView<frames::EyeR> right_{};
        xr::HandState<frames::GripLeft, frames::AimLeft> handLeft_{};
        xr::HandState<frames::GripRight, frames::AimRight> handRight_{};
        AppliedHeadAim state_{};
    };
    HeadAimStatus Prepare(std::uintptr_t controller,
                          const pinned::NativeRotator& current,
                          const xr::FrameState& frame, HeadAimRequest& out);
    // Call only after native SetRotation succeeds and its actual result was
    // read back. A stale request is rejected without changing state.
    bool Commit(const HeadAimRequest& request, const pinned::NativeRotator& actual);
    // Read current controller rotation after normal simulation, near the
    // camera submission. False means no coherent gameplay-aim reference.
    bool RenderState(std::uintptr_t controller, const pinned::NativeRotator& current,
                     AppliedHeadAim& out) const;
    // Presentation only: a newly acquired, focused XR frame can still use the
    // preserved calibration after a slow prior frame suspended gameplay aim.
    // The caller supplies the age of this frame, not the prior input sample.
    // This never resumes input, commits head motion or moves the room anchor.
    bool RenderFrameState(std::uintptr_t controller, const pinned::NativeRotator& current,
                          const xr::FrameState& frame, std::uint64_t sampleAgeMilliseconds,
                          AppliedHeadAim& out) const;
    // Admit a fresh left eye. Its right eye may finish after a rendering stall
    // using exactly this accepted frame/calibration, without admitting another
    // stale frame or enabling gameplay input. Finish consumes even a bad lease.
    bool BeginRenderPair(std::uintptr_t controller, const pinned::NativeRotator& current,
                         const xr::FrameState& frame, std::uint64_t sampleAgeMilliseconds,
                         RenderPairLease& lease, AppliedHeadAim& out) const;
    bool FinishRenderPair(std::uintptr_t controller, const pinned::NativeRotator& current,
                          const xr::FrameState& frame, RenderPairLease& lease,
                          AppliedHeadAim& out) const;
    bool SpaceChanged(const xr::FrameState& frame) const noexcept;
    // These affect the local tracking origin only. Collision movement belongs
    // to the engine; consume its accepted XY displacement, never a request.
    void ConsumeRoomMovement(Vec3 acceptedWorld, const AppliedHeadAim& before);
    void PivotTurn(const xr::FrameState& frame, const AppliedHeadAim& before,
                   const AppliedHeadAim& after);
    // The engine already mapped controller orientation through a portal.
    // Fold the old applied HMD rotation into the tracking reference so eye
    // and hand residuals remain continuous without adding that rotation twice.
    bool RebasePortal(std::uintptr_t controller, const pinned::NativeRotator& before,
                      const xr::FrameState& frame);
    // A stock map/server relocation replaced controller rotation absolutely.
    // Keep its camera heading, but restore the level body underneath the HMD
    // pitch already accounted for by Commit. No tracking origin is recaptured.
    // An established reference remains usable during a loading suspension.
    bool WorldUpTransition(std::uintptr_t controller, const pinned::NativeRotator& destination,
                           pinned::NativeRotator& rotation);
    // Stop using stale/unfocused tracking without turning it into a new
    // recenter. Resume consumes only the movement since the last committed
    // pose. Returns true only for the first suspension of a live reference.
    bool Suspend() noexcept;
    void Reset() noexcept;
    // STAGE space only: put the real floor on the pawn's floor by pinning the
    // reference height to the pawn's standing eye (metres above its floor),
    // so the view stands at the player's real eye height. Zero restores the
    // fixed eye (LOCAL space, seated play). The shift is clamped so a tall
    // player's eye stays inside the capsule and a short one is not sunk.
    void SetFloorEye(float pawnEyeMetres) noexcept;
    // Head height captured at the last recenter, before any floor shift.
    float StandingHeight() const noexcept { return standingHeight_; }
    float FloorShift() const noexcept { return floorShift_; }
    static constexpr float kMaxFloorLift = 0.12f;
    static constexpr float kMaxFloorDrop = 0.40f;

private:
    float standingHeight_=0, floorShift_=0;
    void BuildRenderState(const pinned::NativeRotator& current, AppliedHeadAim& out) const;
    std::uintptr_t controller_{};
    HeadInTracking reference_{};
    std::uint64_t token_{}, pendingToken_{}, lastSampleId_{};
    std::uint64_t referenceSpaceEpoch_{};
    std::int32_t trackingYaw_{}, trackingPitch_{}, appliedYaw_{}, appliedPitch_{};
    bool ready_ = false, suspended_ = false;
};

// Native actor rotators use 65536 units/turn. These helpers use quaternion
// composition, preserving UE3 pitch/yaw/roll signs and camera-axis conversion.
Quat NativeActorRotation(const pinned::NativeRotator& value);
Quat NativeCameraRotation(const pinned::NativeRotator& value);
// Metres in tracking; Unreal units for collision requests. Preserve vertical
// tracking and leave stairs, crouch, jumping and gravity to the stock pawn.
Vec3 RoomMovementRequest(const AppliedHeadAim& aim, const xr::FrameState& frame, float delta);
// How far the rendered head and hands may lean horizontally past the pawn's
// capsule. The script widens it while a living Zed is pressed against the
// player -- so a lunge can actually reach into it -- and narrows it back
// afterwards; a missing, invalid or smaller value is the 5 cm default.
inline constexpr float kDefaultLeanMetres = .05f;
inline constexpr float kMaximumLeanMetres = .6f;
float SanitiseLeanMetres(float requested) noexcept;
void BoundRoomView(AppliedHeadAim& aim, const xr::FrameState& frame, float leanMetres = kDefaultLeanMetres);

} // namespace kf2vr::adapter
