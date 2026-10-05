#pragma once
#include "ScriptField.h"

namespace kf2vr::adapter {
// KFPawn_Human draws the Commando perk outside the HUD wrapper. Suppress only
// the local current perk's stock Canvas pass after its stereo bars are ready.
inline bool SuppressCommandoHud(GameScript& script, void* perk, void* function,
                                void* bridge, void* controller) {
    if (!bridge || !controller || script.Read<void*>(bridge,L"PC")!=controller ||
        perk!=script.Read<void*>(controller,L"CurrentPerk") ||
        !script.IsClass(perk,L"KFPerk_Commando") ||
        script.FindFunction(perk,L"DrawSpecialPerkHUD")!=function) return false;
    auto* hud=script.Read<void*>(bridge,L"SpatialHUD");
    if (!script.IsClass(hud,L"VRSpatialHUD") ||
        script.Read<void*>(hud,L"Bridge")!=bridge || script.Read<void*>(hud,L"PC")!=controller) return false;
    struct Parameters { std::uint32_t ready=0; } parameters;
    auto* check=script.FindFunction(hud,L"CommandoHealthbarsActive");
    ScriptField returned{};
    if (!FindScriptField(check,script.Intern(L"ReturnValue"),returned) ||
        returned.offset!=0 || returned.size!=sizeof(parameters.ready)) return false;
    return script.Invoke(hud,check,&parameters) && parameters.ready!=0;
}

// Resolve the current stock list at each icon callback: targets can be removed
// or reordered after the world markers were placed. Missing metadata fails open.
inline bool SuppressLockOnIcon(GameScript& script, void* weapon, void* function,
                              void* locals, void* bridge, void* controller) {
    if (!bridge || !controller || !weapon ||
        script.Read<void*>(bridge,L"PC")!=controller ||
        (!script.IsClass(weapon,L"KFWeap_RocketLauncher_Seeker6") &&
         !script.IsClass(weapon,L"KFWeap_HRG_Locust")) ||
        script.FindFunction(weapon,L"DrawTargetingIcon")!=function) return false;
    auto* pawn=script.Read<void*>(controller,L"Pawn");
    if (!pawn || script.Read<void*>(bridge,L"Human")!=pawn ||
        script.Read<void*>(weapon,L"Instigator")!=pawn ||
        script.Read<void*>(pawn,L"Weapon")!=weapon) return false;
    std::int32_t index=-1;
    if (!ReadScriptLocal(function,locals,script.Intern(L"Index"),index) || index<0) return false;
    struct ScriptArray { void** data; std::int32_t count,max; };
    ScriptField targets{};
    if (!FindScriptField(GameScript::ObjectClass(weapon),script.Intern(L"LockedTargets"),targets) ||
        targets.size!=sizeof(ScriptArray)) return false;
    const auto list=GameScript::At<ScriptArray>(weapon,targets.offset);
    if (!list.data || list.count<=0 || list.count>64 || list.max<list.count || index>=list.count ||
        !GameScript::Accessible(list.data,sizeof(void*)*list.count)) return false;
    auto* target=GameScript::At<void*>(list.data,sizeof(void*)*index);
    if (!script.IsClass(target,L"Pawn")) return false;
    auto* hud=script.Read<void*>(bridge,L"SpatialHUD");
    if (!script.IsClass(hud,L"VRSpatialHUD") || script.Read<void*>(hud,L"Bridge")!=bridge ||
        script.Read<void*>(hud,L"PC")!=controller) return false;
    struct Parameters { void* weapon; void* target; std::uint32_t ready=0; } parameters{weapon,target};
    auto* check=script.FindFunction(hud,L"LockOnMarkerActive");
    ScriptField source{},pawnField{},returned{};
    if (!FindScriptField(check,script.Intern(L"W"),source) || source.offset!=offsetof(Parameters,weapon) ||
        source.size!=sizeof(parameters.weapon) ||
        !FindScriptField(check,script.Intern(L"P"),pawnField) || pawnField.offset!=offsetof(Parameters,target) ||
        pawnField.size!=sizeof(parameters.target) ||
        !FindScriptField(check,script.Intern(L"ReturnValue"),returned) ||
        returned.offset!=offsetof(Parameters,ready) || returned.size!=sizeof(parameters.ready)) return false;
    return script.Invoke(hud,check,&parameters) && parameters.ready!=0;
}
}
