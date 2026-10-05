#include "HeadAim.h"

#include <cmath>
#include <algorithm>
#include "kf2vr/Basis.h"

namespace kf2vr::adapter {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kRadiansPerUnit = 2.0 * kPi / 65536.0;
std::int32_t Wrapped(std::int64_t value) {
    const auto word = static_cast<std::uint32_t>(value) & 65535u;
    return word < 32768u ? static_cast<std::int32_t>(word) : static_cast<std::int32_t>(word) - 65536;
}
bool ValidFrame(const xr::FrameState& frame) {
    const auto& q = frame.head.rot;
    const auto& p = frame.head.pos;
    return frame.state == xr::SessionState::Focused && frame.shouldRender &&
        frame.headPoseValid && frame.headPoseTracked && frame.poseSampleId != 0 &&
        std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z) &&
        std::isfinite(q.x) && std::isfinite(q.y) && std::isfinite(q.z) && std::isfinite(q.w) &&
        std::abs(q.LengthSq() - 1.0f) < 0.02f && std::isfinite(frame.head.scale) &&
        std::abs(frame.head.scale - 1.0f) < 1.0e-5f;
}
template<typename From,typename To>
bool SamePose(const Transform<From,To>& left, const Transform<From,To>& right) {
    return left.pos.x==right.pos.x && left.pos.y==right.pos.y && left.pos.z==right.pos.z &&
        left.rot.x==right.rot.x && left.rot.y==right.rot.y && left.rot.z==right.rot.z &&
        left.rot.w==right.rot.w && left.scale==right.scale;
}
template<typename Eye>
bool SameEye(const xr::EyeView<Eye>& left, const xr::EyeView<Eye>& right) {
    return SamePose(left.pose,right.pose) && left.poseValid==right.poseValid && left.poseTracked==right.poseTracked &&
        left.fov.angleLeft==right.fov.angleLeft && left.fov.angleRight==right.fov.angleRight &&
        left.fov.angleUp==right.fov.angleUp && left.fov.angleDown==right.fov.angleDown;
}
template<typename Grip,typename Aim>
bool SameHandPose(const xr::HandState<Grip,Aim>& left, const xr::HandState<Grip,Aim>& right) {
    return SamePose(left.grip,right.grip) && SamePose(left.aim,right.aim) &&
        left.poseValid==right.poseValid && left.poseTracked==right.poseTracked &&
        left.aimPoseValid==right.aimPoseValid && left.aimPoseTracked==right.aimPoseTracked;
}
void TrackingAngles(const HeadInTracking& reference, const HeadInTracking& head,
                    std::int32_t& yaw, std::int32_t& pitch) {
    const Quat relative = (reference.rot.Normalized().Inverse() * head.rot.Normalized()).Normalized();
    const Vec3 forward = relative.Rotate({0,0,-1});
    const double horizontal = std::hypot(static_cast<double>(forward.x), static_cast<double>(forward.z));
    // Yaw is undefined at the poles. Hold the prior yaw inside a narrow pole
    // cone; pitch still updates and the stereo residual retains full tracking.
    if (horizontal > 0.01)
        yaw = Wrapped(std::llround(std::atan2(forward.x, -forward.z) / kRadiansPerUnit));
    pitch = Wrapped(std::llround(std::atan2(forward.y, horizontal) / kRadiansPerUnit));
}
} // namespace

Quat NativeActorRotation(const pinned::NativeRotator& value) {
    const auto yaw = static_cast<float>(Wrapped(value.yaw) * kRadiansPerUnit);
    const auto pitch = static_cast<float>(Wrapped(value.pitch) * kRadiansPerUnit);
    const auto roll = static_cast<float>(Wrapped(value.roll) * kRadiansPerUnit);
    // UE3 FRotationMatrix: forward=(cos(P)*cos(Y),cos(P)*sin(Y),sin(P)).
    return (Quat::FromAxisAngle({0,0,1}, yaw) * Quat::FromAxisAngle({0,1,0}, -pitch) *
            Quat::FromAxisAngle({1,0,0}, -roll)).Normalized();
}

Quat NativeCameraRotation(const pinned::NativeRotator& value) {
    const Quat actor = NativeActorRotation(value);
    // Actor local (forward,right,up) -> camera local (right,up,forward).
    return {actor.y, actor.z, actor.x, actor.w};
}

HeadAimStatus HeadAim::Prepare(std::uintptr_t controller, const pinned::NativeRotator& current,
                              const xr::FrameState& frame, HeadAimRequest& out) {
    out = {};
    pendingToken_ = 0;
    if (!controller || (ready_ && controller != controller_)) Reset();
    if (!controller || !ValidFrame(frame)) {
        Suspend();
        return HeadAimStatus::Unavailable;
    }
    if (!ready_ || controller != controller_ || frame.poseSampleId < lastSampleId_ || SpaceChanged(frame)) {
        Reset();
        controller_ = controller;
        reference_ = frame.head;
        // Recenter heading while preserving real-world gravity. Calibrating
        // pitch/roll into the reference tilts the entire game when the headset
        // is picked up or the player looks down during initialization.
        const Vec3 forward=frame.head.rot.Normalized().Rotate({0,0,-1});
        const float heading=std::atan2(-forward.x,-forward.z);
        reference_.rot=Quat::FromAxisAngle({0,1,0},heading);
        standingHeight_=frame.head.pos.y; floorShift_=0;
        lastSampleId_ = frame.poseSampleId;
        referenceSpaceEpoch_ = frame.referenceSpaceEpoch;
        ready_ = true;
        return HeadAimStatus::ReferenceEstablished;
    }
    suspended_ = false;
    if (frame.poseSampleId == lastSampleId_) return HeadAimStatus::NoChange;
    auto yaw = trackingYaw_, pitch = trackingPitch_;
    TrackingAngles(reference_, frame.head, yaw, pitch);
    const auto deltaYaw = Wrapped(static_cast<std::int64_t>(yaw) - trackingYaw_);
    const auto deltaPitch = Wrapped(static_cast<std::int64_t>(pitch) - trackingPitch_);
    if (!deltaYaw && !deltaPitch) {
        lastSampleId_ = frame.poseSampleId;
        return HeadAimStatus::NoChange;
    }
    out.controller = controller;
    out.before = current;
    out.rotation = {Wrapped(static_cast<std::int64_t>(current.pitch) + deltaPitch),
                    Wrapped(static_cast<std::int64_t>(current.yaw) + deltaYaw), current.roll};
    out.poseSampleId = frame.poseSampleId;
    out.trackingYaw = yaw; out.trackingPitch = pitch;
    out.token = ++token_;
    pendingToken_ = out.token;
    return HeadAimStatus::RotationRequested;
}

bool HeadAim::Commit(const HeadAimRequest& request, const pinned::NativeRotator& actual) {
    if (!ready_ || suspended_ || !pendingToken_ || request.token != pendingToken_ ||
        request.controller != controller_ || request.poseSampleId <= lastSampleId_) return false;
    appliedYaw_ = Wrapped(static_cast<std::int64_t>(appliedYaw_) +
                          Wrapped(static_cast<std::int64_t>(actual.yaw) - request.before.yaw));
    appliedPitch_ = Wrapped(static_cast<std::int64_t>(appliedPitch_) +
                            Wrapped(static_cast<std::int64_t>(actual.pitch) - request.before.pitch));
    trackingYaw_ = request.trackingYaw;
    trackingPitch_ = request.trackingPitch;
    lastSampleId_ = request.poseSampleId;
    pendingToken_ = 0;
    return true;
}

bool HeadAim::RenderState(std::uintptr_t controller, const pinned::NativeRotator& current,
                         AppliedHeadAim& out) const {
    if (!ready_ || suspended_ || controller != controller_) return false;
    BuildRenderState(current,out);
    return true;
}

bool HeadAim::RenderFrameState(std::uintptr_t controller, const pinned::NativeRotator& current,
                              const xr::FrameState& frame, std::uint64_t sampleAgeMilliseconds,
                              AppliedHeadAim& out) const {
    if (!ready_ || controller != controller_ || !ValidFrame(frame) || SpaceChanged(frame) ||
        !frame.viewsValid || !frame.eyeLeft.poseValid || !frame.eyeRight.poseValid ||
        sampleAgeMilliseconds>250 || frame.poseSampleId<lastSampleId_ ||
        (suspended_ && frame.poseSampleId==lastSampleId_)) return false;
    // Strip only the rotation already committed to the engine camera. The
    // stereo builder applies this frame's full head pose as the residual,
    // even though gameplay remains suspended until a valid controller tick.
    BuildRenderState(current,out);
    return true;
}

bool HeadAim::BeginRenderPair(std::uintptr_t controller, const pinned::NativeRotator& current,
                             const xr::FrameState& frame, std::uint64_t sampleAgeMilliseconds,
                             RenderPairLease& lease, AppliedHeadAim& out) const {
    lease={};
    if (!RenderFrameState(controller,current,frame,sampleAgeMilliseconds,out)) return false;
    lease.owner_=this;
    lease.controller_=controller;
    lease.camera_=current;
    lease.sample_=frame.poseSampleId;
    lease.epoch_=frame.referenceSpaceEpoch;
    lease.token_=token_;
    lease.inputSample_=lastSampleId_;
    lease.displayTime_=frame.predictedDisplayTime;
    lease.head_=frame.head;
    lease.left_=frame.eyeLeft;
    lease.right_=frame.eyeRight;
    lease.handLeft_=frame.handLeft;
    lease.handRight_=frame.handRight;
    lease.state_=out;
    return true;
}

bool HeadAim::FinishRenderPair(std::uintptr_t controller, const pinned::NativeRotator& current,
                              const xr::FrameState& frame, RenderPairLease& lease,
                              AppliedHeadAim& out) const {
    // Age admitted this pair once, before either eye rendered. Rechecking it
    // after the left eye would turn a slow frame into a permanently failed
    // right eye. Everything identifying the accepted frame must still match.
    const bool accepted=lease.owner_==this && ready_ && controller==controller_ &&
        controller==lease.controller_ && frame.poseSampleId==lease.sample_ &&
        frame.referenceSpaceEpoch==lease.epoch_ && !SpaceChanged(frame) &&
        ValidFrame(frame) && frame.viewsValid && frame.eyeLeft.poseValid && frame.eyeRight.poseValid &&
        current.pitch==lease.camera_.pitch && current.yaw==lease.camera_.yaw && current.roll==lease.camera_.roll &&
        token_==lease.token_ && lastSampleId_==lease.inputSample_ && SamePose(reference_,lease.state_.reference) &&
        frame.predictedDisplayTime==lease.displayTime_ && SamePose(frame.head,lease.head_) &&
        SameEye(frame.eyeLeft,lease.left_) && SameEye(frame.eyeRight,lease.right_) &&
        SameHandPose(frame.handLeft,lease.handLeft_) && SameHandPose(frame.handRight,lease.handRight_);
    if (accepted) out=lease.state_;
    lease={};
    return accepted;
}

void HeadAim::BuildRenderState(const pinned::NativeRotator& current, AppliedHeadAim& out) const {
    const pinned::NativeRotator body{Wrapped(static_cast<std::int64_t>(current.pitch) - appliedPitch_),
        Wrapped(static_cast<std::int64_t>(current.yaw) - appliedYaw_), current.roll};
    const Quat localApplied = (NativeActorRotation(body).Inverse() * NativeActorRotation(current)).Normalized();
    out.reference = reference_;
    out.cameraRotation = {localApplied.y, localApplied.z, localApplied.x, localApplied.w};
    out.bodyRotation = NativeActorRotation(body);
}

bool HeadAim::Suspend() noexcept {
    const bool changed = ready_ && !suspended_;
    suspended_ = true;
    pendingToken_ = 0;
    ++token_;
    return changed;
}

bool HeadAim::WorldUpTransition(std::uintptr_t controller, const pinned::NativeRotator& destination,
                               pinned::NativeRotator& rotation) {
    if (!ready_ || controller != controller_) return false;
    // BuildRenderState subtracts appliedPitch_ from the engine rotation.
    // Replacing it with a pawn/destination pitch would bake that old tracked
    // component into body gravity. HMD roll stays in the stereo residual.
    rotation = {appliedPitch_, destination.yaw, 0};
    pendingToken_ = 0;
    ++token_;
    return true;
}

bool HeadAim::RebasePortal(std::uintptr_t controller, const pinned::NativeRotator& before,
                           const xr::FrameState& frame) {
    AppliedHeadAim previous;
    if (!ValidFrame(frame) || SpaceChanged(frame) || !RenderState(controller,before,previous)) return false;
    // Native camera axes reflect XR Z, so quaternion conjugation is
    // (-x,-y,z,w). Shifting the reference removes the same local rotation
    // from both eye orientation and position, preserving binocular geometry.
    const auto applied=previous.cameraRotation;
    const Quat inTracking{-applied.x,-applied.y,applied.z,applied.w};
    reference_.rot=(reference_.rot*inTracking).Normalized();
    appliedYaw_=appliedPitch_=0;
    trackingYaw_=trackingPitch_=0;
    TrackingAngles(reference_,frame.head,trackingYaw_,trackingPitch_);
    lastSampleId_=frame.poseSampleId;
    pendingToken_=0;
    ++token_;
    return true;
}

bool HeadAim::SpaceChanged(const xr::FrameState& frame) const noexcept {
    return ready_ && referenceSpaceEpoch_ != frame.referenceSpaceEpoch;
}

namespace {
constexpr float kLeanMetres = kDefaultLeanMetres;
Vec3 LocalHeadOffset(const AppliedHeadAim& aim, const xr::FrameState& frame) {
    return BasisXrToUnreal(aim.reference.rot.Inverse().Rotate(frame.head.pos-aim.reference.pos));
}
Quat RoomBodyYaw(const AppliedHeadAim& aim) {
    const auto forward=aim.bodyRotation.Rotate({1,0,0});
    return Quat::FromAxisAngle({0,0,1},std::atan2(forward.y,forward.x));
}
}

Vec3 RoomMovementRequest(const AppliedHeadAim& aim, const xr::FrameState& frame, float delta) {
    if (!ValidFrame(frame) || !std::isfinite(delta) || delta <= 0) return {};
    auto offset = LocalHeadOffset(aim, frame);
    offset.z = 0;
    const float distance = offset.Length();
    if (distance <= kLeanMetres) return {};
    // At most 3 m/s and 50 ms per simulation tick, including after a hitch.
    const float move = (std::min)(distance-kLeanMetres, 3.f*(std::min)(delta,.05f));
    auto world = RoomBodyYaw(aim).Rotate(offset * (move/distance));
    world.z = 0;
    return world*kProvisionalUnrealUnitsPerMetre;
}

void HeadAim::ConsumeRoomMovement(Vec3 acceptedWorld, const AppliedHeadAim& before) {
    if (!ready_ || suspended_ || !std::isfinite(acceptedWorld.x) || !std::isfinite(acceptedWorld.y)) return;
    acceptedWorld.z = 0; // A swept step's height is already in the pawn's view.
    const auto local = RoomBodyYaw(before).Inverse().Rotate(acceptedWorld*(1.f/kProvisionalUnrealUnitsPerMetre));
    reference_.pos = reference_.pos + reference_.rot.Rotate(BasisUnrealToXr(local));
}

void HeadAim::PivotTurn(const xr::FrameState& frame, const AppliedHeadAim& before,
                        const AppliedHeadAim& after) {
    if (!ready_ || suspended_ || !ValidFrame(frame) || SpaceChanged(frame)) return;
    const auto offset = LocalHeadOffset(before, frame);
    const auto world = RoomBodyYaw(before).Rotate(offset);
    const auto turnedLocal = RoomBodyYaw(after).Inverse().Rotate(world);
    reference_.pos = frame.head.pos-reference_.rot.Rotate(BasisUnrealToXr(turnedLocal));
}

float SanitiseLeanMetres(float requested) noexcept {
    if (!std::isfinite(requested)) return kDefaultLeanMetres;
    return (std::min)((std::max)(requested, kDefaultLeanMetres), kMaximumLeanMetres);
}

void BoundRoomView(AppliedHeadAim& aim, const xr::FrameState& frame, float leanMetres) {
    leanMetres = SanitiseLeanMetres(leanMetres);
    auto offset = LocalHeadOffset(aim, frame);
    const float horizontal = std::hypot(offset.x, offset.y);
    if (horizontal <= leanMetres) return;
    offset.x *= leanMetres/horizontal;
    offset.y *= leanMetres/horizontal;
    // Shared by both eyes and hands. Blocked room movement cannot separate
    // the rendered head from its collision capsule indefinitely.
    aim.reference.pos = frame.head.pos-aim.reference.rot.Rotate(BasisUnrealToXr(offset));
}

void HeadAim::SetFloorEye(float pawnEyeMetres) noexcept {
    if (!ready_) return;
    float shift=0;
    if (std::isfinite(pawnEyeMetres) && pawnEyeMetres>0)
        shift=(std::min)((std::max)(pawnEyeMetres-standingHeight_,-kMaxFloorLift),kMaxFloorDrop);
    if (std::abs(shift-floorShift_)<1e-4f) return;
    // Only the height moves: the yaw-only reference keeps horizontal room
    // offsets, and room movement, pivot turns and lean bounds preserve it.
    reference_.pos.y+=shift-floorShift_;
    floorShift_=shift;
}

void HeadAim::Reset() noexcept {
    controller_ = 0; reference_ = {}; ready_ = false;
    standingHeight_ = floorShift_ = 0;
    suspended_ = false;
    lastSampleId_ = pendingToken_ = 0;
    trackingYaw_ = trackingPitch_ = appliedYaw_ = appliedPitch_ = 0;
    // Keep the token monotonic across resets so old requests cannot commit.
    ++token_;
}

} // namespace kf2vr::adapter
