#pragma once
#include <cstdint>

namespace kf2vr::localtest {
// No game pointers: the validated world callback supplies a short-lived mask.
// Missing/expired authorization cannot renew a held diagnostic action.
class DiagnosticInput {
public:
    void Update(bool authorized, int triggerMask, int buttonMask, std::uint64_t now) {
        active_=authorized && !(triggerMask&~3) && !(buttonMask&~9);
        triggers_=active_?triggerMask:0; buttons_=active_?buttonMask:0; tick_=now;
    }
    void Clear() { active_=false; triggers_=buttons_=0; }
    bool Fresh(std::uint64_t now) const { return active_ && now>=tick_ && now-tick_<=250; }
    int Triggers(std::uint64_t now) const { return Fresh(now)?triggers_:0; }
    int Buttons(std::uint64_t now) const { return Fresh(now)?buttons_:0; }
private:
    bool active_=false;
    int triggers_=0,buttons_=0;
    std::uint64_t tick_=0;
};
}
