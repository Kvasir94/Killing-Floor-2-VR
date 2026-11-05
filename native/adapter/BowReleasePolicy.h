#pragma once
#include "include/kf2vr/adapter/VerifiedLayout.h"
#include <cmath>

namespace kf2vr::adapter {

inline bool BoundedBowOrigin(const pinned::NativeVector3& value) {
    constexpr float bound=10000000.f;
    return value.x>=-bound && value.x<=bound && value.y>=-bound && value.y<=bound &&
        value.z>=-bound && value.z<=bound;
}

inline bool CanonicalBowRotation(const pinned::NativeRotator& value) {
    const auto axis=[](std::int32_t v) { return v>=-32768 && v<=65535; };
    return axis(value.pitch) && axis(value.yaw) && axis(value.roll);
}

inline pinned::NativeVector3 BowArrowDirection(const pinned::NativeRotator& value) {
    constexpr double radiansPerUnit=6.2831853071795864769/65536.;
    const double pitch=value.pitch*radiansPerUnit,yaw=value.yaw*radiansPerUnit;
    return {static_cast<float>(std::cos(pitch)*std::cos(yaw)),
        static_cast<float>(std::cos(pitch)*std::sin(yaw)),static_cast<float>(std::sin(pitch))};
}

// A release may enter inherited stock bodies, but cannot pay/fire twice or
// reroll spread for another projectile. Each state lives on one call stack.
class BowReleaseShotState {
    unsigned shotDepth_=0,spreadDepth_=0,spawnDepth_=0;
    bool shotUsed_=false,shotCompleted_=false,spreadUsed_=false,spreadReady_=false,spawnUsed_=false;
public:
    bool BeginShot() {
        if (!shotDepth_ && shotUsed_) return false;
        shotUsed_=true;++shotDepth_;return true;
    }
    bool EndShot(bool forwarded) {
        if (!shotDepth_ || --shotDepth_) return false;
        shotCompleted_=forwarded;return true;
    }
    bool BeginSpread() {
        if (!shotDepth_ || (!spreadDepth_ && spreadUsed_)) return false;
        spreadUsed_=true;++spreadDepth_;return true;
    }
    // Only the outer return includes every stock/super adjustment.
    bool EndSpread(bool valid) {
        if (!spreadDepth_) return false;
        if (--spreadDepth_) return false;
        spreadReady_=valid;return valid;
    }
    bool BeginSpawn() {
        if (!shotDepth_ || !spreadReady_ || (!spawnDepth_ && spawnUsed_)) return false;
        spawnUsed_=true;++spawnDepth_;return true;
    }
    void EndSpawn() { if (spawnDepth_) --spawnDepth_; }
    bool ShotUsed() const { return shotUsed_; }
    bool Completed() const { return shotCompleted_; }
    bool Spreading() const { return spreadDepth_!=0; }
};
}
