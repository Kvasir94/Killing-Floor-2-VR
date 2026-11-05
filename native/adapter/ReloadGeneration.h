#pragma once
#include <climits>

namespace kf2vr::adapter {
// The weapon-channel marker identifies the reload that preceded it, even if
// the owner-channel completion arrives after a new reload of the same actor.
struct ReloadGeneration {
    int current=0, barrier=0, serial=0;
    void Begin() {
        // INT_MAX is terminal, never reused as a valid reload generation.
        current=current>=0 && current<INT_MAX ? current+1 : INT_MAX;
    }
    bool Mark(int incoming) {
        if (incoming<=0 || incoming==INT_MAX || incoming<=serial) return false;
        serial=incoming;
        barrier=current;
        return true;
    }
};
}
