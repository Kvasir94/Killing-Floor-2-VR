#pragma once

#include "HeadAim.h"

namespace kf2vr::adapter {

// A stock angular pellet fan in the accepted weapon's local axes. Native
// rotator addition wraps before conversion, just as stock adjusted aim does.
inline Vec3 WeaponFanDirection(const pinned::NativeRotator& base,
                              const pinned::NativeRotator& recoil,
                              float initialOffset, float spread,
                              std::uint8_t pellet, bool horizontal) {
    const auto sum=[](std::int32_t a, std::int32_t b) {
        return static_cast<std::int32_t>((static_cast<std::uint32_t>(a)+
                                         static_cast<std::uint32_t>(b)) & 65535u);
    };
    const auto orientation=NativeActorRotation({sum(base.pitch,recoil.pitch),
        sum(base.yaw,recoil.yaw),sum(base.roll,recoil.roll)});
    const auto axis=horizontal ? Vec3{0,0,1} : Vec3{0,1,0};
    return orientation.Rotate(Quat::FromAxisAngle(axis,initialOffset+spread*pellet).Rotate({1,0,0}));
}

} // namespace kf2vr::adapter
