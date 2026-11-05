#pragma once
#include <algorithm>
#include <cmath>

namespace kf2vr::adapter {
// Smooth turn is a yaw rate applied directly to the controller, like snap
// turn. Routing it through KF2's gamepad look made TURN SPEED meaningless:
// the stock response curve maps 75% to about half and 100% to 1.3x its
// rate, everything above 100% clamped to full deflection, and aim-assist
// friction near Zeds, sprint (0.675x) and view smoothing changed it further
// (playtest 011320). 100% is 120 degrees a second; 75% matches the old
// default's ~90. The input owner applies the horizontal deadzone; beyond it
// the rate is steady, independent of deflection.
constexpr float kSmoothTurnDegreesPerSecond=120.f;
class SmoothTurnInput {
    float remainder_=0.f;
public:
    void Reset() { remainder_=0.f; }
    // Whole Unreal yaw units (65536 per turn) to apply this tick; the
    // fraction carries over so slow frames and fast frames turn alike.
    int Update(float axis,bool available,float scale,double seconds) {
        if (!available || !std::isfinite(axis) || axis==0.f || !std::isfinite(seconds) || seconds<=0.0) {
            Reset(); return 0;
        }
        if (!std::isfinite(scale)) scale=1.f;
        const double step=std::min(seconds,.1)*std::clamp(scale,.1f,2.f)*kSmoothTurnDegreesPerSecond*65536.0/360.0;
        const double total=std::copysign(step,static_cast<double>(axis))+remainder_;
        const double whole=std::trunc(total);
        remainder_=static_cast<float>(total-whole);
        return static_cast<int>(whole);
    }
};
// Frame-rate independent, release-to-arm controls. Loss, travel and a held
// control on entry cannot produce a delayed turn or menu activation.
class SnapTurnInput {
    bool armed_=false;
public:
    void Reset() { armed_=false; }
    int Update(float axis,bool available,float degrees) {
        if (!available || !std::isfinite(axis) || std::abs(axis)>1.f ||
            !std::isfinite(degrees) || degrees<15.f || degrees>90.f) { Reset(); return 0; }
        if (std::abs(axis)<=.2f) armed_=true;
        if (!armed_ || std::abs(axis)<.7f) return 0;
        armed_=false;
        return static_cast<int>(std::lround((axis>0?1.f:-1.f)*degrees*65536.f/360.f));
    }
};
class SessionMenuInput {
    bool menuArmed_=false,chordArmed_=false,chordHeld_=false,holdArmed_=false,holdHeld_=false;
    double chordSince_=0,holdSince_=0,lastTime_=0;
    bool haveTime_=false;
public:
    void Reset() { *this={}; }
    // hold: a single control held for 0.6 s (Index right trackpad press).
    bool Update(bool available,bool menuActive,bool menuDown,bool chordActive,bool chordDown,double now,
                bool holdActive=false,bool holdDown=false) {
        if (!available || !std::isfinite(now) || (haveTime_ && (now<lastTime_ || now-lastTime_>.25))) {
            Reset(); return false;
        }
        haveTime_=true; lastTime_=now;
        if (!menuActive) menuArmed_=false;
        else if (!menuDown) menuArmed_=true;
        const bool menu=menuActive && menuDown && menuArmed_;
        if (menuDown) menuArmed_=false;
        if (!chordActive) { chordArmed_=false; chordHeld_=false; }
        else if (!chordDown) { chordArmed_=true; chordHeld_=false; }
        if (chordDown && chordArmed_ && !chordHeld_) { chordHeld_=true; chordSince_=now; }
        const bool chord=chordHeld_ && chordArmed_ && now-chordSince_>=.6;
        if (chord) chordArmed_=false;
        if (!holdActive) { holdArmed_=false; holdHeld_=false; }
        else if (!holdDown) { holdArmed_=true; holdHeld_=false; }
        if (holdDown && holdArmed_ && !holdHeld_) { holdHeld_=true; holdSince_=now; }
        const bool hold=holdHeld_ && holdArmed_ && now-holdSince_>=.6;
        if (hold) holdArmed_=false;
        return menu || chord || hold;
    }
};
}
