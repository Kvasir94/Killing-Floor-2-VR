#pragma once
#include <algorithm>
#include <cmath>

namespace kf2vr::adapter {
struct IndependentAxes { float x=0, y=0, turn=0; };

// Script commands must not revive a stale XR sample after XInput neutralizes.
inline IndependentAxes MapIndependentLocomotion(bool fresh, int validMask, int movementHand,
    float x, float y, float turn) {
    IndependentAxes out;
    if (!fresh) return out;
    const int move=movementHand==1?1:0;
    const auto axis=[](float value) { return std::isfinite(value)?std::clamp(value,-1.f,1.f):0.f; };
    if (validMask & (1<<move)) { out.x=axis(x); out.y=axis(y); }
    if (validMask & (1<<(1-move))) out.turn=axis(turn);
    return out;
}
}
