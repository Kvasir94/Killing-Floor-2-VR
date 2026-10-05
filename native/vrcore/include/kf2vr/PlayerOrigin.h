// Owns the PlayerOrigin -> World transform: recentre, seated/standing floor
// offset, and artificial (snap) turn.
//
// This is the only object permitted to move the player's play area in the
// world. Head, eyes and both hands all reach World by composing through the
// single transform it produces, so any change made here moves all of them
// together by construction.
#pragma once

#include "kf2vr/Transform.h"

namespace kf2vr {

enum class TrackingSpace {
    // Runtime reports floor-relative poses. Height comes from the headset.
    Standing,
    // Runtime origin is at the seated eye position; a floor offset is applied.
    Seated,
};

struct ComfortSettings {
    // Snap-turn increment. Yaw only -- the research pack carries KF1's
    // yaw-only locomotion rule forward, and pitch/roll of the play area are a
    // reliable way to make people ill.
    float snapTurnDegrees = 30.f;

    // Minimum real-time seconds between distinct stick engagements.
    float snapTurnRepeatSeconds = 0.25f;

    // Stick magnitude that arms a turn, and the lower magnitude it must fall
    // back below before another turn can arm. Two thresholds, so a stick
    // resting near the edge does not chatter.
    float turnEngageThreshold  = 0.75f;
    float turnReleaseThreshold = 0.35f;

    // Seated-mode floor offset, metres. Ignored when Standing.
    float seatedEyeHeightMetres = 1.2f;
};

class PlayerOriginState {
public:
    explicit PlayerOriginState(TrackingSpace space = TrackingSpace::Standing,
                               ComfortSettings comfort = {})
        : space_(space), comfort_(comfort) {}

    // The transform every body pose composes through to reach world space.
    OriginInWorld Current() const {
        return OriginInWorld{Quat::FromAxisAngle({0, 0, 1}, yawRadians_),
                             worldPosition_ + turnOffset_};
    }

    // Where the pawn is, in Unreal units. Set from the game each frame.
    // Turning compensation is separate so this update cannot undo it.
    void SetPawnPosition(const Vec3& worldPos) { worldPosition_ = worldPos; }

    // Recentre: rotate the play area so the head's current facing becomes
    // world forward, keeping the head's world position fixed. Pass the head
    // position from the same converted pose sample used for the yaw.
    //
    // Takes the head yaw measured in the PlayerOrigin frame -- which does not
    // itself contain the origin yaw -- so this is a set, not a subtract:
    //
    //     headWorldYaw = originYaw + headYawInOrigin
    //     want headWorldYaw == 0  =>  originYaw = -headYawInOrigin
    //
    // Written as a set so it is idempotent. Recentring twice with the head
    // held still must land in the same place; a subtract would rotate twice,
    // which is the same shape of mistake as applying a tracking transform
    // twice, and reads as a drifting world to the player.
    void RecentreToHeadYaw(float headYawRadiansInOrigin, const Vec3& headPositionInOrigin) {
        if (!SetYawAboutHead(-headYawRadiansInOrigin, headPositionInOrigin)) return;
        ++recentreCount_;
    }

    // Feed the turn stick once per frame with a REAL-time timestamp.
    //
    // Real time, not game time: the research pack requires head tracking and
    // gesture sampling to stay responsive independently of ZedTime dilation,
    // while fire cadence and ammo stay on game time. Passing game time here
    // would make snap turn crawl during ZedTime.
    //
    // Returns true on the frames a turn actually fires.
    // The converted head position is required: rotating about the runtime's
    // origin would sweep a room-scale player through the world during a turn.
    bool UpdateTurn(float stickX, double realTimeSeconds, const Vec3& headPositionInOrigin) {
        if (!std::isfinite(stickX) || !std::isfinite(realTimeSeconds)) return false;
        const float mag = stickX < 0.f ? -stickX : stickX;

        if (!turnArmed_) {
            if (mag < comfort_.turnReleaseThreshold) turnArmed_ = true;
            return false;
        }
        if (mag < comfort_.turnEngageThreshold) return false;
        if (realTimeSeconds - lastTurnTime_ < comfort_.snapTurnRepeatSeconds) return false;

        const float dir = stickX > 0.f ? 1.f : -1.f;
        if (!SetYawAboutHead(yawRadians_ + dir * comfort_.snapTurnDegrees * kDegToRad,
                            headPositionInOrigin)) return false;
        lastTurnTime_ = realTimeSeconds;
        turnArmed_    = false;
        ++turnCount_;
        return true;
    }

    // Clear latched turn state. Called on focus loss, tracking loss, menu
    // open, death, travel and reconnect -- the research pack's list of moments
    // where a held input must not survive.
    void CancelTransientInput() { turnArmed_ = false; }

    float YawRadians() const { return yawRadians_; }
    TrackingSpace Space() const { return space_; }

    // Floor offset applied to seated mode, in metres, before unit conversion.
    float SeatedFloorOffsetMetres() const {
        return space_ == TrackingSpace::Seated ? comfort_.seatedEyeHeightMetres : 0.f;
    }

    unsigned RecentreCount() const { return recentreCount_; }
    unsigned TurnCount() const { return turnCount_; }

private:
    static constexpr float kPi      = 3.14159265358979323846f;
    static constexpr float kDegToRad = kPi / 180.f;

    static float Wrap(float r) {
        return std::remainder(r, 2.f * kPi);
    }

    bool SetYawAboutHead(float yaw, const Vec3& headPositionInOrigin) {
        if (!std::isfinite(yaw) || !std::isfinite(headPositionInOrigin.x) ||
            !std::isfinite(headPositionInOrigin.y) || !std::isfinite(headPositionInOrigin.z))
            return false;

        const Quat before = Quat::FromAxisAngle({0, 0, 1}, yawRadians_);
        const float wrappedYaw = Wrap(yaw);
        const Quat after = Quat::FromAxisAngle({0, 0, 1}, wrappedYaw);
        // T' = T + R*h - R'*h, so R'*h + T' = R*h + T. Every other body
        // still shares the same origin and rotates around the stationary head.
        turnOffset_ = turnOffset_ + before.Rotate(headPositionInOrigin)
                                  - after.Rotate(headPositionInOrigin);
        yawRadians_ = wrappedYaw;
        return true;
    }

    TrackingSpace   space_;
    ComfortSettings comfort_;
    float    yawRadians_    = 0.f;
    Vec3     worldPosition_{};
    Vec3     turnOffset_{};
    bool     turnArmed_     = true;
    double   lastTurnTime_  = -1e9;
    unsigned recentreCount_ = 0;
    unsigned turnCount_     = 0;
};

}  // namespace kf2vr
