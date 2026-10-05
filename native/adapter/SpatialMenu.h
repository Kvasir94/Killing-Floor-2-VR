#pragma once
#include "kf2vr/xr/XrBackend.h"

namespace kf2vr::adapter {
// Metres in XR tracking space; panel +X right, +Y up, +Z toward the viewer.
struct SpatialMenuPanel {
    bool valid=false;
    Vec3 center;
    Quat rotation;
    float width=1.7320508f, height=1.f;
    // Zero is a flat plane. Otherwise the panel is a vertical cylinder section
    // whose axis passes this far behind the centre (toward the viewer), so
    // every column is face-on and equidistant from the opening head position.
    // width stays the arc length, so u maps linearly along the curve.
    float curveRadius=0;
};
struct SpatialMenuPointer {
    bool rayVisible=false, hit=false, down=false, pressed=false, released=false, cancelled=false;
    float u=0, v=0;
    Vec3 rayStart, rayEnd;
    int scrollSteps=0;
};
bool IntersectSpatialMenu(const SpatialMenuPanel&, const Vec3& origin,
                          const Vec3& direction, float& u, float& v, Vec3& point);
class SpatialMenu {
public:
    bool Update(const xr::FrameState&, bool visible, float sourceAspect, int pointerHand=1);
    void Reset();
    void CancelInput() { pointer_={}; armed_=false; scrollArmed_=false; scrollDirection_=0; }
    // A movie can decline input while the controller still points at it. Keep
    // aiming feedback visible, but require a fresh trigger release to rearm.
    void DisarmInput();
    void Configure(float distance, float height, float scale);
    // The studio backdrop curves the panel; the live-world backdrop keeps the
    // exact flat rectangle its regression captures were taken against.
    void SetCurved(bool curved) { curved_=curved; }
    void Recenter() { Reset(); }
    float Distance() const { return distance_; }
    float Height() const { return height_; }
    float Scale() const { return scale_; }
    const SpatialMenuPanel& Panel() const { return panel_; }
    const SpatialMenuPointer& Pointer() const { return pointer_; }
private:
    SpatialMenuPanel panel_;
    SpatialMenuPointer pointer_;
    bool armed_=false;
    std::uint64_t epoch_=0;
    double lastTime_=0;
    bool haveTime_=false;
    bool scrollArmed_=false;
    int scrollDirection_=0;
    int pointerHand_=1;
    double nextScrollTime_=0;
    float distance_=1.5f, height_=0, scale_=1;
    bool curved_=false;
};
}
