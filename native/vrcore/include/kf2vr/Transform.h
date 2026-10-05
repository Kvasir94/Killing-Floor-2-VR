// Frame-typed similarity transform (rotation, uniform scale, translation).
#pragma once

#include "kf2vr/Frames.h"
#include "kf2vr/Math.h"

namespace kf2vr {

// Maps a point expressed in frame `From` into frame `To`:
//
//     p_to = rot * (scale * p_from) + pos
//
// Uniform scale is dimensionless: From and To use the same units and axis
// convention. Runtime poses normally have scale 1. ToUnreal re-expresses both
// local and parent coordinates in Unreal units; it does not leave a unit
// conversion in scale to stretch subsequently composed game-asset offsets.
template <typename From, typename To>
struct Transform {
    Quat  rot{};
    Vec3  pos{};
    float scale = 1.f;

    constexpr Transform() = default;
    constexpr Transform(const Quat& r, const Vec3& p, float s = 1.f)
        : rot(r), pos(p), scale(s) {}

    static Transform Identity() { return {}; }

    Vec3 Apply(const Vec3& p) const { return rot.Rotate(p * scale) + pos; }

    // Direction vectors ignore translation. Scale is also dropped: a direction
    // is only meaningful normalised, and carrying scale here invites callers to
    // treat a direction as a displacement.
    Vec3 ApplyDirection(const Vec3& d) const { return rot.Rotate(d); }

    // Compose left-to-right, in the order the frames chain:
    //
    //     Transform<A,B>.Then(Transform<B,C>) -> Transform<A,C>
    //
    // Deliberately the only composition operator. `operator*` is omitted
    // because its argument order is a coin flip that reviewers get wrong, and
    // getting it wrong here is exactly the double-application class of bug.
    template <typename Next>
    Transform<From, Next> Then(const Transform<To, Next>& next) const {
        return Transform<From, Next>{
            (next.rot * rot).Normalized(),
            next.rot.Rotate(pos * next.scale) + next.pos,
            scale * next.scale};
    }

    Transform<To, From> Inverse() const {
        const Quat  ri = rot.Inverse();
        const float si = 1.f / scale;
        return Transform<To, From>{ri, ri.Rotate(pos * -si), si};
    }
};

// Convenience aliases for the chains this project actually builds.
using HeadInTracking  = Transform<frames::Head, frames::Tracking>;
using HeadInOrigin    = Transform<frames::Head, frames::PlayerOrigin>;
using HeadInWorld     = Transform<frames::Head, frames::World>;
using OriginInWorld   = Transform<frames::PlayerOrigin, frames::World>;
using WeaponInWorld   = Transform<frames::Weapon, frames::World>;
using MuzzleInWorld   = Transform<frames::Muzzle, frames::World>;

}  // namespace kf2vr
