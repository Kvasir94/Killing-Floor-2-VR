#pragma once
#include <algorithm>
#include <cmath>

namespace kf2vr::adapter {
// The input owner applies the horizontal deadzone. Beyond it, smooth yaw
// uses the configured steady rate, independent of stick deflection.
inline float ScaleSmoothTurnAxis(float axis,float scale) {
    if (!std::isfinite(axis)) return 0.f;
    if (!std::isfinite(scale)) scale=.5f;
    if (axis == 0.f) return 0.f;
    return std::copysign(std::min(std::clamp(scale,.1f,2.f),1.f),axis);
}
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
