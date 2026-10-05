#pragma once

#include "GameScript.h"

namespace kf2vr::adapter {

class WeaponHandlingStack {
public:
    class Scope {
    public:
        Scope(WeaponHandlingStack& stack, GameScript& script) : stack_(stack),script_(script) {}
        Scope(const Scope&)=delete;
        Scope& operator=(const Scope&)=delete;
        ~Scope();
        void Enter(void* bridge, void* weapon, int policy, bool applySights);
    private:
        friend class WeaponHandlingStack;
        WeaponHandlingStack& stack_;
        GameScript& script_;
        Scope* parent_{};
        void* bridge_{};
        void* weapon_{};
        int policy_=-1, savedSights_=0;
        bool active_=false;
    };
    bool CurrentPolicy(void* weapon, int& policy) const {
        if (!top_ || top_->weapon_!=weapon) return false;
        policy=top_->policy_;
        return true;
    }
private:
    Scope* top_{};
};

// Capture at the actual shot boundary, then select sighted ballistics only
// during stock spread/recoil routines. Native stock recoil integration remains
// inside the existing controller ProcessViewRotation call, exactly once.
void BeginWeaponHandling(GameScript& script, WeaponHandlingStack& stack,
                         WeaponHandlingStack::Scope& scope, void* bridge,
                         void* pawn, void* controller, void* object, void* function);

} // namespace kf2vr::adapter
