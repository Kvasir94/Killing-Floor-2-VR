#pragma once
#include "kf2vr/Math.h"
#include <cmath>

namespace kf2vr::adapter {

// OpenXR puts /input/grip/pose at the palm centroid inside the controller
// handle. Everything downstream of LeftPosition/RightPosition treats that
// point as the wrist joint: the drawn wrist bone, a held gun's authored wrist,
// the reload ammunition, grab and holster points. The script supplies where
// the wrist sits relative to the grip origin, in the hand's aim frame (Unreal
// axes: +X forward, +Y outboard for the RIGHT hand, +Z up). The left hand is
// its mirror image across the aim frame's lateral plane.
inline constexpr float kMaxWristOffsetUnits = 20.f;

inline Vec3 SanitiseWristOffset(const Vec3& offset) {
    if (!std::isfinite(offset.x) || !std::isfinite(offset.y) || !std::isfinite(offset.z)) return {};
    if (offset.LengthSq() > kMaxWristOffsetUnits*kMaxWristOffsetUnits) return {};
    return offset;
}

inline Vec3 WristOffsetForHand(const Vec3& rightHandOffset, unsigned hand) {
    const auto offset=SanitiseWristOffset(rightHandOffset);
    return hand==0 ? Vec3{offset.x,-offset.y,offset.z} : offset;
}

// Grip origin and aim rotation in the same (player-origin) frame.
inline Vec3 WristFromGrip(const Vec3& gripOrigin, const Quat& aimRotation,
                          const Vec3& rightHandOffset, unsigned hand) {
    return gripOrigin+aimRotation.Rotate(WristOffsetForHand(rightHandOffset,hand));
}

}  // namespace kf2vr::adapter
