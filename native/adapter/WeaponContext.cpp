#include "WeaponContext.h"
#include "WeaponIsolation.h"
#include "ScriptField.h"
#include <cmath>

namespace kf2vr::adapter {
namespace {

void Count(GameScript& script, void* inventory, const wchar_t* field) {
    const auto value=script.Read<std::uint32_t>(inventory,field);
    if (value<0x7fffffff) script.Write(inventory,field,value+1);
}

void* Registry(GameScript& script, void* bridge, void* pawn) {
    auto* inventory=script.Read<void*>(bridge,L"HeldInventory");
    auto* controller=script.Read<void*>(bridge,L"PC");
    if (!inventory || !pawn || !controller ||
        script.Read<int>(inventory,L"NativeAimRoutingEnabled")!=1 ||
        script.Read<void*>(inventory,L"Human")!=pawn ||
        script.Read<void*>(inventory,L"PC")!=controller ||
        script.Read<void*>(controller,L"Pawn")!=pawn) return nullptr;
    return inventory;
}

WeaponAimPose ReadPose(GameScript& script, void* inventory, void* weapon) {
    WeaponAimPose pose{};
    pose.weapon=weapon;
    void* runtime=nullptr;
    if (!ResolveInventoryItem(script,inventory,weapon,runtime)) {
        script.Write(inventory,L"NativeAimFault",1);
        pose.managed=true; // A failed registry query cannot authorize a shot.
        return pose;
    }
    if (!runtime) return pose;
    pose.managed=true;
    const int hand=script.Read<int>(runtime,L"PrimaryHand");
    const int revision=script.Read<int>(runtime,L"OwnershipRevision");
    const int sequence=script.Read<int>(inventory,L"PoseSequence");
    if (script.Read<void*>(runtime,L"Inventory")!=inventory ||
        script.Read<void*>(runtime,L"Item")!=weapon ||
        script.Read<int>(runtime,L"NativeReady")!=1 ||
        script.Read<int>(runtime,L"NativePoseReady")!=1 ||
        hand<0 || hand>1 || revision<=0 || sequence<=0 ||
        script.Read<void*>(inventory,hand==0?L"LeftItem":L"RightItem")!=runtime ||
        script.Read<int>(runtime,L"PoseOwnershipRevision")!=revision ||
        script.Read<int>(runtime,L"PoseSequence")!=sequence) return pose;
    pose.origin=script.Read<pinned::NativeVector3>(runtime,L"FireLocation");
    pose.base=script.Read<pinned::NativeRotator>(runtime,L"AimBaseRotation");
    pose.recoil=script.Read<pinned::NativeRotator>(runtime,L"RecoilBuffer");
    pose.ready=std::isfinite(pose.origin.x) && std::isfinite(pose.origin.y) && std::isfinite(pose.origin.z) &&
        std::abs(pose.origin.x)<1.0e8f && std::abs(pose.origin.y)<1.0e8f && std::abs(pose.origin.z)<1.0e8f;
    return pose;
}

WeaponAimPose QueryPose(GameScript& script, const WeaponAimStack& stack, void* inventory, void* weapon) {
    // Retain the accepted shot's pose throughout its synchronous stock calls.
    if (const auto* current=stack.Current(); current && current->weapon==weapon) return *current;
    return ReadPose(script,inventory,weapon);
}

template<class T> void ReturnValue(void* result, const T& value) {
    if (GameScript::Accessible(result,sizeof(T))) std::memcpy(result,&value,sizeof(T));
}

} // namespace

void BeginItemAim(GameScript& script, WeaponAimStack& stack, WeaponAimStack::Scope& scope,
                  void* bridge, void* pawn, void* object, void* function,
                  const void* locals, bool& reject) {
    reject=false;
    const auto name=GameScript::ObjectName(function);
    const bool firing=name==script.Intern(L"FireAmmunition");
    const bool aim=name==script.Intern(L"GetAdjustedAim");
    const bool aimFor=name==script.Intern(L"GetAdjustedAimFor");
    const bool healTarget=name==script.Intern(L"UpdateHealTarget") && script.IsClass(object,L"KFWeap_HealerBase");
    const bool flameWarning=name==script.Intern(L"Timer_CheckForAIWarning") && script.IsClass(object,L"KFWeap_FlameBase");
    const bool itemQuery=healTarget || flameWarning;
    if (!firing && !aim && !aimFor && !itemQuery) return;
    auto* inventory=Registry(script,bridge,pawn);
    if (!inventory) return;
    void* weapon=nullptr;
    bool malformed=false;
    if ((firing || aim || itemQuery) && script.IsClass(object,L"KFWeapon")) weapon=object;
    else if (aimFor && (object==pawn || object==script.Read<void*>(inventory,L"PC"))) {
        if (!ReadScriptLocal(function,locals,script.Intern(L"W"),weapon)) {
            script.Write(inventory,L"NativeAimFault",2);
            malformed=true;
        }
    } else return;
    auto pose=malformed ? WeaponAimPose{nullptr,true,false} :
        ((firing || itemQuery) ? ReadPose(script,inventory,weapon) : QueryPose(script,stack,inventory,weapon));
    auto* controller=script.Read<void*>(inventory,L"PC");
    ScriptField field{};
    pinned::NativeRotator* buffer=nullptr;
    if (FindScriptField(GameScript::ObjectClass(controller),script.Intern(L"WeaponBufferRotation"),field) &&
        field.size==sizeof(pinned::NativeRotator)) {
        auto* address=static_cast<std::byte*>(controller)+field.offset;
        if (GameScript::Accessible(address,field.size)) buffer=reinterpret_cast<pinned::NativeRotator*>(address);
    }
    if (!buffer) {
        script.Write(inventory,L"NativeAimFault",3);
        pose.ready=false;
    }
    scope.Enter(pose,buffer);
    reject=(firing || itemQuery) && pose.managed && !pose.ready;
    // Syringe acquisition and flame AI warnings ask for an implicit pawn
    // trace start before adjusted aim. Scope the whole query and suppress it
    // on pose loss without counting it as a rejected shot. A syringe must
    // also discard its earlier target when tracking/ownership is lost.
    if (reject && healTarget) script.Write(object,L"HealTarget",static_cast<void*>(nullptr));
    if (reject && firing) Count(script,inventory,L"NativeRejectedShots");
    if (pose.managed && pose.ready) Count(script,inventory,L"NativeAimCalls");
}

bool RouteItemTraceOrigin(GameScript& script, const WeaponAimStack& stack,
                         void* bridge, void* pawn, void* weapon, void* result) {
    auto* inventory=Registry(script,bridge,pawn);
    if (!inventory) return false;
    const auto pose=QueryPose(script,stack,inventory,weapon);
    if (pose.managed && pose.ready) ReturnValue(result,pose.origin);
    return pose.managed || stack.BlocksLegacy();
}

bool FinishItemAim(GameScript& script, const WeaponAimStack& stack, void* bridge,
                   void* pawn, void* object, void* function, const void* locals, void* result) {
    const auto name=GameScript::ObjectName(function);
    // Temporary, bounded Stoner observation: inspect the final stock aim,
    // including spread, without replacing it or evaluating the mesh again.
    if (name==script.Intern(L"GetAdjustedAim") &&
        GameScript::ObjectName(GameScript::ObjectClass(object))==script.Intern(L"KFWeap_LMG_Stoner63A")) {
        const auto* pose=stack.Current();
        auto* inventory=Registry(script,bridge,pawn);
        void* runtime=nullptr;
        if (inventory && pose && pose->weapon==object && pose->managed && pose->ready &&
            GameScript::Accessible(result,sizeof(pinned::NativeRotator)) &&
            ResolveInventoryItem(script,inventory,object,runtime) && runtime) {
            auto* presenter=script.Read<void*>(runtime,L"Presenter");
            struct Parameters {
                pinned::NativeRotator adjusted, base, recoil;
                pinned::NativeVector3 origin;
            } parameters{};
            if (presenter && script.Read<int>(presenter,L"StonerAimSamples")<120 &&
                ReadScriptLocal(function,locals,script.Intern(L"StartFireLoc"),parameters.origin)) {
                std::memcpy(&parameters.adjusted,result,sizeof(parameters.adjusted));
                parameters.base=pose->base;
                parameters.recoil=pose->recoil;
                script.Invoke(presenter,script.FindFunction(presenter,L"ObserveStonerAim"),&parameters);
            }
        }
        return false;
    }
    if (object==pawn && name==script.Intern(L"GetBaseAimRotation")) {
        const auto* pose=stack.Current();
        if (pose && pose->managed && pose->ready) ReturnValue(result,pose->base);
        return stack.BlocksLegacy();
    }
    if (object==pawn && name==script.Intern(L"GetWeaponStartTraceLocation")) {
        if (!Registry(script,bridge,pawn)) return false;
        void* explicitWeapon=nullptr;
        ReadScriptLocal(function,locals,script.Intern(L"CurrentWeapon"),explicitWeapon);
        if (explicitWeapon) return RouteItemTraceOrigin(script,stack,bridge,pawn,explicitWeapon,result) ||
            explicitWeapon!=script.Read<void*>(bridge,L"ActiveWeapon");
        const auto* pose=stack.Current();
        if (pose && pose->managed && pose->ready) ReturnValue(result,pose->origin);
        // Preserve the existing tracked-tool fallback only for its explicit
        // selected-item context. An unrelated no-item caller keeps stock origin.
        return !pose || stack.BlocksLegacy() || pose->weapon!=script.Read<void*>(bridge,L"ActiveWeapon");
    }
    if (name==script.Intern(L"GetMuzzleLoc") && script.IsClass(object,L"KFWeapon"))
        return RouteItemTraceOrigin(script,stack,bridge,pawn,object,result);
    return false;
}

} // namespace kf2vr::adapter
