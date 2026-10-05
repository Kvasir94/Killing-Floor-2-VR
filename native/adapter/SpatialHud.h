#pragma once
#include "SpatialMenu.h"
#include <array>

namespace kf2vr::adapter {
struct SpatialHudSettings {
    // 0: comfort anchor with dead zones; 1: screen-stable accessibility mode.
    int followMode=0;
    float distance=1.65f;
    float height=.40f;
    float scale=1.f;
    float yawDeadZoneDegrees=12.f;
    float pitchDeadZoneDegrees=8.f;
    float translationDeadZone=.12f;
    float detailLookDegrees=12.f;
};

// Tracking-space layout. Wrist surfaces remain physical world panels; session
// and alert surfaces use foreground DPG in script so geometry cannot hide them.
class SpatialHud {
public:
    void Reset() { panels_={}; wrists_={}; anchored_=false; detailVisible_=false; detailSince_=-1;
        lastTime_=0; epoch_=0; yaw_=0; pitch_=0; anchorHead_={}; }
    void Update(const xr::FrameState& frame, int preferredWeaponHand, unsigned heldWeaponMask, bool enabled,
                unsigned suppressedHands=0, bool selectorActive=false,
                const SpatialHudSettings& settings={});
    const std::array<SpatialMenuPanel,5>& Panels() const { return panels_; }
    bool DetailVisible() const { return detailVisible_; }
private:
    std::array<SpatialMenuPanel,5> panels_{}; // status, LEFT ammo, RIGHT ammo, session, alert
    struct WristReveal {
        bool visible=false;
        double raisedAt=-1;
    };
    std::array<WristReveal,2> wrists_{};
    bool anchored_=false;
    bool detailVisible_=false;
    double detailSince_=-1;
    float yaw_=0;
    float pitch_=0;
    Vec3 anchorHead_{};
    double lastTime_=0;
    std::uint64_t epoch_=0;
};
}
