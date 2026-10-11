#pragma once

namespace kf2vr::adapter {
enum class VampireReloadCall { Other, BeginStock, SyncFiring, Pay };

// A fence survives terminal sessions: stock RPCs carry no session identifier.
// Explicit stock fallback and physical payment are the only refill owners.
struct VampireReloadPolicy {
    bool exactWeapon=false, authority=false, owned=false, fenced=false;
    bool currentGun=false, payment=false;
    int state=0;

    constexpr bool Suppress(VampireReloadCall call) const {
        if (!exactWeapon || !authority || !owned || !fenced) return false;
        if (call==VampireReloadCall::BeginStock) return true;
        // Even a timed fallback is paid by its server timer. An old sync RPC
        // cannot distinguish that reload from the one it originally observed.
        if (call==VampireReloadCall::SyncFiring) return true;
        if (call==VampireReloadCall::Pay)
            return !(currentGun && (payment || state==4));
        return false;
    }
};
}
