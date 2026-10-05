#pragma once
#include "ScriptField.h"
#include "DamagePopupArguments.h"
#include <algorithm>

namespace kf2vr::adapter {

// ScoreDamage is the stock post-damage health accounting callback. Read its
// reflected locals rather than assuming a shipping-engine parameter layout.
inline void ForwardSoloDamagePopup(GameScript& script, void* bridge, void* controller,
                                  void* pawn, void* game, void* function, const void* locals) {
    if (!bridge || !controller || !pawn || !script.IsClass(game,L"KFGameInfo") ||
        script.IsClass(game,L"KF2VRNetGame") ||
        script.Read<void*>(bridge,L"PC")!=controller || script.Read<void*>(bridge,L"Human")!=pawn ||
        script.FindFunction(game,L"ScoreDamage")!=function) return;
    auto* world=script.Read<void*>(pawn,L"WorldInfo");
    if (!world || script.Read<unsigned char>(world,L"NetMode")!=0 ||
        script.Read<void*>(world,L"Game")!=game) return;
    std::int32_t amount=0,healthBefore=0;
    void* instigator=nullptr; void* victim=nullptr; void* kind=nullptr;
    if (!ReadScriptLocal(function,locals,script.Intern(L"DamageAmount"),amount) ||
        !ReadScriptLocal(function,locals,script.Intern(L"HealthBeforeDamage"),healthBefore) ||
        !ReadScriptLocal(function,locals,script.Intern(L"InstigatedBy"),instigator) ||
        !ReadScriptLocal(function,locals,script.Intern(L"DamagedPawn"),victim) ||
        !ReadScriptLocal(function,locals,script.Intern(L"DamageType"),kind) ||
        instigator!=controller || amount<=0 || healthBefore<=0 ||
        !script.IsClass(victim,L"KFPawn_Monster")) return;
    auto* hud=script.Read<void*>(bridge,L"SpatialHUD");
    if (!script.IsClass(hud,L"VRSpatialHUD") || script.Read<void*>(hud,L"Bridge")!=bridge ||
        script.Read<void*>(hud,L"PC")!=controller) return;
    auto* receiver=script.FindFunction(hud,L"ReceiveScoredDamage");
    ScriptField v{},a{},k{};
    std::array<std::byte,64> parameters{};
    if (!FindScriptField(receiver,script.Intern(L"Victim"),v) || v.size!=sizeof(victim) ||
        !FindScriptField(receiver,script.Intern(L"Amount"),a) || a.size!=sizeof(amount) ||
        !FindScriptField(receiver,script.Intern(L"Kind"),k) || k.size!=sizeof(kind)) return;
    if (!WriteDamagePopupArguments(parameters,{v.offset,v.size},{a.offset,a.size},{k.offset,k.size},
        victim,std::min(amount,healthBefore),kind)) return;
    script.Invoke(hud,receiver,parameters.data());
}

} // namespace kf2vr::adapter
