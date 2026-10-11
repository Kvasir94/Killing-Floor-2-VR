#pragma once
#include "GameScript.h"
#include "VampireReloadPolicy.h"

namespace kf2vr::adapter {
inline bool ExactVampireClass(GameScript& script, void* object, const wchar_t* name) {
    return object && GameScript::ObjectName(GameScript::ObjectClass(object))==script.Intern(name);
}

inline bool ValidVampireAuthority(GameScript& script, void* authority, void* controller) {
    if (!ExactVampireClass(script,authority,L"VRVampireReloadAuthority") || !controller ||
        script.Read<void*>(authority,L"Controller")!=controller) return false;
    auto* human=script.Read<void*>(authority,L"Human");
    return script.IsClass(human,L"KFPawn_Human") &&
        script.Read<unsigned char>(human,L"Role")==3 &&
        script.Read<void*>(human,L"Controller")==controller &&
        script.Read<void*>(controller,L"Pawn")==human &&
        script.Read<void*>(controller,L"WorldInfo")==script.Read<void*>(human,L"WorldInfo");
}

// Resolve from reflected owners every call; no native UObject pointer survives.
inline void* NetworkVampireAuthority(GameScript& script, void* controller) {
    if (!script.IsClass(controller,L"KF2VRNetPlayerController")) return nullptr;
    auto* channel=script.Read<void*>(controller,L"NetChannel");
    if (!script.IsClass(channel,L"KF2VRNetChannel") ||
        script.Read<void*>(channel,L"Owner")!=controller ||
        script.Read<void*>(channel,L"BoundPawn")!=script.Read<void*>(controller,L"Pawn")) return nullptr;
    auto* facade=script.Read<void*>(channel,L"VampireReload");
    auto* authority=script.Read<void*>(facade,L"Authority");
    return ValidVampireAuthority(script,authority,controller) ? authority : nullptr;
}

inline bool RouteVampireReloadGuard(GameScript& script, void* object, void* function,
                                    void* localBridge=nullptr) {
    const auto name=GameScript::ObjectName(function);
    static thread_local const auto capabilityName=script.Intern(L"NativeVampireReloadGate");
    static thread_local const auto beginName=script.Intern(L"ServerSendToReload");
    static thread_local const auto syncName=script.Intern(L"ServerSyncWeaponFiring");
    static thread_local const auto payName=script.Intern(L"PerformReload");
    const bool capability=name==capabilityName;
    VampireReloadCall call=VampireReloadCall::Other;
    if (name==beginName) call=VampireReloadCall::BeginStock;
    else if (name==syncName) call=VampireReloadCall::SyncFiring;
    else if (name==payName) call=VampireReloadCall::Pay;
    if (!capability && call==VampireReloadCall::Other) return false;

    void* controller=nullptr;
    if (capability) controller=script.Read<void*>(object,L"Controller");
    else {
        if (!ExactVampireClass(script,object,L"KFWeap_HRG_Vampire") ||
            script.Read<unsigned char>(object,L"Role")!=3) return false;
        controller=script.Read<void*>(script.Read<void*>(object,L"Instigator"),L"Controller");
    }
    auto* authority=NetworkVampireAuthority(script,controller);
    if (!authority && localBridge && script.Read<void*>(localBridge,L"PC")==controller) {
        auto* candidate=script.Read<void*>(localBridge,L"VampireAuthority");
        if (ValidVampireAuthority(script,candidate,controller)) authority=candidate;
    }
    if (!authority) return false;
    if (capability) {
        if (authority!=object || script.FindFunction(object,L"NativeVampireReloadGate")!=function) return false;
        return script.Write(authority,L"NativeVersion",1);
    }
    // Include inherited/super bodies: Vampire's PerformReload calls its stock
    // parent, which differs from FindFunction's resolved leaf implementation.
    VampireReloadPolicy policy;
    policy.exactWeapon=true; policy.authority=true;
    const auto* human=script.Read<void*>(authority,L"Human");
    policy.owned=script.Read<void*>(object,L"Instigator")==human &&
        script.Read<void*>(object,L"Owner")==human;
    policy.fenced=script.Read<int>(authority,L"NativeFence")==1;
    policy.currentGun=script.Read<void*>(authority,L"Gun")==object;
    policy.payment=script.Read<int>(authority,L"NativePayment")==1;
    policy.state=script.Read<int>(authority,L"Status");
    return policy.Suppress(call);
}
}
