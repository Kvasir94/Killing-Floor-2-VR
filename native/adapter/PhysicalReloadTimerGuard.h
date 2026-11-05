#pragma once
#include "GameScript.h"
#include "ScriptField.h"

namespace kf2vr::adapter {
inline bool InvokePhysicalReloadGate(GameScript& script,void* bridge,void* weapon,int kind) {
    struct Parameters { void* weapon; int kind; int result; } parameters{weapon,kind,0};
    auto* gate=script.FindFunction(bridge,L"PhysicalReloadTimerGate");
    ScriptField result;
    if (!FindScriptField(gate,script.Intern(L"ReturnValue"),result) ||
        result.offset!=12 || result.size!=4) return false;
    return script.Invoke(bridge,gate,&parameters) && parameters.result==1;
}

// Payment must be observed before a same-frame role change/stow can retire
// the owner. This scope observes the original stock writer after it returns;
// it never calls PerformReload, predicts ammo, or declares completion.
class AutomaticReloadPaymentScope {
public:
    AutomaticReloadPaymentScope(GameScript& script,void* object,void* function,
                                void* bridge,void* human,void* controller):script_(script) {
        if (GameScript::ObjectName(function)!=script.Intern(L"PerformReload") ||
            !bridge || !human || !controller || !script.IsClass(object,L"KFWeapon") ||
            script.Read<void*>(bridge,L"PC")!=controller || script.Read<void*>(bridge,L"Human")!=human ||
            script.Read<void*>(controller,L"Pawn")!=human ||
            script.Read<void*>(object,L"Instigator")!=human || script.Read<void*>(object,L"Owner")!=human) return;
        bridge_=bridge; weapon_=object;
    }
    ~AutomaticReloadPaymentScope() {
        if (weapon_ && forwarded_) InvokePhysicalReloadGate(script_,bridge_,weapon_,5);
    }
    void Forwarded() { forwarded_=true; }
private:
    GameScript& script_;
    void* bridge_{};
    void* weapon_{};
    bool forwarded_{};
};

// Local physical presentation owns only its exact active weapon's stock
// reload timers. Server-owned magazines use their separate authority fence.
inline bool RoutePhysicalReloadTimer(GameScript& script, void* object, void* function,
                                     void* bridge, void* human, void* controller) {
    const auto name=GameScript::ObjectName(function);
    static thread_local const auto ammoName=script.Intern(L"ReloadAmmoTimer");
    static thread_local const auto statusName=script.Intern(L"ReloadStatusTimer");
    static thread_local const auto secondaryName=script.Intern(L"SendToAltReload");
    static thread_local const auto completeName=script.Intern(L"ReloadComplete");
    static thread_local const auto abortName=script.Intern(L"AbortReload");
    if (name!=ammoName && name!=statusName && name!=secondaryName && name!=completeName && name!=abortName) return false;
    if (!bridge || !human || !controller || !script.IsClass(object,L"KFWeapon") ||
        script.Read<void*>(bridge,L"PC")!=controller ||
        script.Read<void*>(bridge,L"Human")!=human ||
        script.Read<void*>(controller,L"Pawn")!=human ||
        script.Read<void*>(object,L"Instigator")!=human ||
        script.Read<void*>(object,L"Owner")!=human) return false;
    return InvokePhysicalReloadGate(script,bridge,object,
        name==completeName ? 3 : (name==abortName ? 4 : (name==secondaryName ? 2 : (name==statusName ? 1 : 0))));
}
}
