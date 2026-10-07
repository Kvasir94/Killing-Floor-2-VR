#include "WeaponRuntimeDispatch.h"
#include "WeaponIsolation.h"
#include "ScriptField.h"
#include "MagazineFeedState.h"
#include "EmptyMagazineState.h"

namespace kf2vr::adapter {
namespace {

// Keep this exact-class admission aligned with VRWeaponRuntime. Physical
// magazine geometry alone does not establish a single-round chamber contract.
bool AuditedMagazineWeapon(GameScript& script, void* weapon) {
    const auto name=GameScript::ObjectName(GameScript::ObjectClass(weapon));
    static constexpr const wchar_t* classes[]={
        L"KFWeap_Pistol_9mm",
        L"KFWeap_Pistol_Deagle",
        L"KFWeap_Pistol_Colt1911",
        L"KFWeap_Pistol_Medic",
        L"KFWeap_AssaultRifle_AK12",
        L"KFWeap_AssaultRifle_Bullpup",
        L"KFWeap_Rifle_M14EBR",
        L"KFWeap_SMG_Medic",
        L"KFWeap_AssaultRifle_AR15",
        L"KFWeap_AssaultRifle_SCAR",
        L"KFWeap_SMG_MP7",
        L"KFWeap_SMG_Kriss",
        L"KFWeap_SMG_P90",
        L"KFWeap_AssaultRifle_G36C",
        L"KFWeap_SMG_HK_UMP",
        L"KFWeap_SMG_MP5RAS",
        L"KFWeap_Shotgun_Medic",
        L"KFWeap_AssaultRifle_Medic",
        L"KFWeap_Pistol_G18C",
        L"KFWeap_AssaultRifle_FNFal",
    };
    for (const auto* type:classes) if (name==script.Intern(type)) return true;
    return false;
}

void Count(GameScript& script, void* object, const wchar_t* field) {
    const auto count=script.Read<std::uint32_t>(object,field);
    if (count<0x7fffffff) script.Write(object,field,count+1);
}

void* Registry(GameScript& script, void* bridge, void* pawn) {
    auto* registry=script.Read<void*>(bridge,L"HeldInventory");
    auto* controller=script.Read<void*>(bridge,L"PC");
    if (!pawn || !controller || !registry ||
        script.Read<int>(registry,L"NativeRoutingEnabled")!=1 ||
        script.Read<void*>(registry,L"PC")!=controller ||
        script.Read<void*>(registry,L"Human")!=pawn ||
        script.Read<void*>(controller,L"Pawn")!=pawn) return nullptr;
    return registry;
}

void* Runtime(GameScript& script, void* registry, void* weapon) {
    void* runtime=nullptr;
    if (!ResolveInventoryItem(script,registry,weapon,runtime)) {
        script.Write(registry,L"NativeRuntimeFault",1);
        return nullptr;
    }
    if (!runtime) return nullptr;
    if (script.Read<void*>(runtime,L"Inventory")!=registry ||
        script.Read<void*>(runtime,L"Item")!=weapon ||
        script.Read<int>(runtime,L"NativeReady")!=1) {
        script.Write(registry,L"NativeRuntimeFault",2);
        return nullptr;
    }
    return runtime;
}

bool CurrentPose(GameScript& script, void* registry, void* runtime) {
    const auto hand=script.Read<int>(runtime,L"PrimaryHand");
    const auto sequence=script.Read<int>(registry,L"PoseSequence");
    const auto revision=script.Read<int>(runtime,L"OwnershipRevision");
    return hand>=0 && hand<=1 && sequence>0 && revision>0 &&
        script.Read<void*>(registry,hand==0?L"LeftItem":L"RightItem")==runtime &&
        script.Read<int>(runtime,L"NativePoseReady")==1 &&
        script.Read<int>(runtime,L"PoseSequence")==sequence &&
        script.Read<int>(runtime,L"PoseOwnershipRevision")==revision;
}

bool FieldMatches(GameScript& script, void* function, const wchar_t* name,
                    std::size_t offset, std::size_t size) {
    ScriptField field{};
    return FindScriptField(function,script.Intern(name),field) && field.offset==offset && field.size==size;
}

bool IsDeclaredFunction(GameScript& script, void* weapon, void* function, const wchar_t* className) {
    // These declarations belong to the pinned native game classes. Cache
    // metadata only, never a pawn/item, rather than scanning hundreds of
    // reflected fields during every automatic shot and nested callback.
    static thread_local std::unordered_map<GameScript::Name,std::unordered_map<void*,bool>> declarations;
    const auto declaringName=script.Intern(className);
    auto& functions=declarations[declaringName];
    if (const auto found=functions.find(function);found!=functions.end()) return found->second;
    auto* type=GameScript::ObjectClass(weapon);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        if (GameScript::ObjectName(type)!=declaringName) continue;
        auto* child=GameScript::Children(type);
        for (unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child))
            if (child==function) { functions[function]=true; return true; }
        functions[function]=false;
        return false;
    }
    return false;
}

bool HasObjectField(GameScript& script, void* object, const wchar_t* name, std::size_t size) {
    static thread_local std::unordered_map<void*,std::unordered_map<GameScript::Name,ScriptField>> fields;
    auto* type=GameScript::ObjectClass(object);
    if (!type) return false;
    auto& reflected=fields[type];
    const auto fieldName=script.Intern(name);
    auto found=reflected.find(fieldName);
    if (found==reflected.end()) {
        ScriptField field{};
        if (!FindScriptField(type,fieldName,field)) return false;
        found=reflected.emplace(fieldName,field).first;
    }
    const auto field=found->second;
    return field.size==size && GameScript::Accessible(static_cast<std::byte*>(object)+field.offset,size);
}

bool IsOwned(GameScript& script, void* registry, void* weapon) {
    struct Parameters { void* weapon; std::int32_t result; } parameters{weapon,0};
    auto* function=script.FindFunction(registry,L"IsOwned");
    if (!FieldMatches(script,function,L"W",offsetof(Parameters,weapon),sizeof(parameters.weapon)) ||
        !FieldMatches(script,function,L"ReturnValue",offsetof(Parameters,result),sizeof(parameters.result)) ||
        !script.Invoke(registry,function,&parameters)) {
        script.Write(registry,L"NativeRuntimeFault",8);
        return false;
    }
    return parameters.result!=0;
}

} // namespace

bool SuppressManagedRecoil(GameScript& script, void* bridge, void* pawn,
                            void* weapon, void* controller) {
    // Pinned SHA 77ab9c...94: exec wrapper d310b0 parses controller/float/out
    // rotator normally, then d31196 loads RDX, d3119b loads XMM2, d311a1 R9,
    // d311a4 RCX=this, d311a7 calls vtable+770. KFWeapon vtable 1b1b8a0's
    // slot is e000c0; its prologue preserves those same four arguments.
    // Hooking here consumes no VM operands and cannot break an out reference.
    auto* registry=Registry(script,bridge,pawn);
    if (!registry || controller!=script.Read<void*>(registry,L"PC") ||
        script.Read<int>(registry,L"NativeRecoilScheduling")!=1) return false;
    auto* runtime=Runtime(script,registry,weapon);
    if (!runtime) return false;
    if (script.Read<void*>(registry,L"NativeRecoilItem")==weapon) {
        Count(script,registry,L"NativeRecoilIntegrations");
        return false;
    }
    Count(script,registry,L"NativeRecoilSuppressions");
    return true;
}

bool ResolveItemPresenter(GameScript& script, void* bridge, void* pawn,
                           void* weapon, void*& presenter) {
    presenter=nullptr;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return false;
    auto* runtime=Runtime(script,registry,weapon);
    if (!runtime) return false;
    if (CurrentPose(script,registry,runtime)) {
        auto* candidate=script.Read<void*>(runtime,L"Presenter");
        if (candidate && script.Read<void*>(candidate,L"ActiveWeapon")==weapon &&
            script.Read<void*>(candidate,L"PC")==script.Read<void*>(registry,L"PC") &&
            script.Read<void*>(candidate,L"Human")==pawn) presenter=candidate;
    }
    return true;
}

bool MagazineFeedBlocksShot(GameScript& script, void* bridge, void* pawn,
                             void* weapon, void* function) {
    if (!weapon || !IsDeclaredFunction(script,weapon,function,L"KFWeapon")) return false;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return false;
    auto* runtime=Runtime(script,registry,weapon);
    if (!runtime) return false;
    const auto mode=script.Read<std::uint8_t>(weapon,L"CurrentFireMode");
    if (mode>1 || !(script.Read<int>(runtime,L"MagazineFeedModeMask") & (1<<mode))) return false;
    const EmptyMagazineState empty{script.Read<int>(runtime,L"EmptyMagazineFlags")};
    if (empty.BlocksFire()) return true;
    MagazineFeedState state{script.Read<int>(runtime,L"MagazineFeedFlags"),
                            script.Read<int>(runtime,L"MagazineFeedLastAmmo")};
    if (!(state.flags&MagazineFeedState::Ready)) return false;
    const auto ammo=script.Read<int>(weapon,L"AmmoCount");
    if (!state.Apply(MagazineFeedState::Event::Observe,ammo)) return false;
    script.Write(runtime,L"MagazineFeedFlags",state.flags);
    script.Write(runtime,L"MagazineFeedLastAmmo",state.lastAmmo);
    return state.BlocksFire(ammo);
}

void CompleteMagazineShot(GameScript& script, void* bridge, void* pawn,
                          void* weapon, void* function) {
    if (!weapon || !IsDeclaredFunction(script,weapon,function,L"KFWeapon")) return;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return;
    auto* runtime=Runtime(script,registry,weapon);
    if (!runtime) return;
    const auto mode=script.Read<std::uint8_t>(weapon,L"CurrentFireMode");
    if (mode>1 || !(script.Read<int>(runtime,L"MagazineFeedModeMask") & (1<<mode))) return;
    MagazineFeedState state{script.Read<int>(runtime,L"MagazineFeedFlags"),
                            script.Read<int>(runtime,L"MagazineFeedLastAmmo")};
    if (!state.Out()) return;
    if (!state.Apply(MagazineFeedState::Event::Shot,script.Read<int>(weapon,L"AmmoCount"))) return;
    script.Write(runtime,L"MagazineFeedShotMode",static_cast<int>(mode));
    script.Write(runtime,L"MagazineFeedFlags",state.flags);
    script.Write(runtime,L"MagazineFeedLastAmmo",state.lastAmmo);
    // Stock already consumed the shot. Stop its ordinary auto refire now, not
    // on the next hand/HUD tick; the script retains the stock reliable RPCs.
    script.Invoke(runtime,script.FindFunction(runtime,L"FlushMagazineShot"),nullptr);
}

bool RouteMagazineFeedEvent(GameScript& script, void* bridge, void* pawn,
                            void* object, void* function, const void* locals, void* result) {
    if (!script.IsClass(object,L"VRWeaponRuntime") ||
        script.FindFunction(object,L"NativeMagazineFeedEvent")!=function) return false;
    const std::int32_t refused=0;
    if (result) std::memcpy(result,&refused,sizeof(refused));
    auto* registry=Registry(script,bridge,pawn);
    auto* weapon=script.Read<void*>(object,L"Item");
    if (!registry || !weapon || Runtime(script,registry,weapon)!=object || !result) return true;
    std::int32_t event=0,ammo=0;
    if (!ReadScriptLocal(function,locals,script.Intern(L"EventCode"),event) ||
        !ReadScriptLocal(function,locals,script.Intern(L"StockAmmo"),ammo) ||
        ammo!=script.Read<int>(weapon,L"AmmoCount")) return true;
    if (event>=8 && event<=11) {
        // Separate no-chamber policy. Script admits exact audited removable
        // catalog loads; native validates the owned actor and stock snapshot.
        std::int32_t action=0;
        if (!ReadScriptLocal(function,locals,script.Intern(L"ActionKind"),action)) return true;
        EmptyMagazineState state{script.Read<int>(object,L"EmptyMagazineFlags")};
        if (!state.Apply(static_cast<EmptyMagazineState::Event>(event-8),ammo,action) ||
            !script.Write(object,L"EmptyMagazineFlags",state.flags)) return true;
        const std::int32_t accepted=1;
        std::memcpy(result,&accepted,sizeof(accepted));
        return true;
    }
    if (!AuditedMagazineWeapon(script,weapon)) return true;
    MagazineFeedState state{script.Read<int>(object,L"MagazineFeedFlags"),
                            script.Read<int>(object,L"MagazineFeedLastAmmo")};
    if (!state.Apply(static_cast<MagazineFeedState::Event>(event),ammo)) return true;
    if (!script.Write(object,L"MagazineFeedFlags",state.flags) ||
        !script.Write(object,L"MagazineFeedLastAmmo",state.lastAmmo)) return true;
    const std::int32_t accepted=1;
    std::memcpy(result,&accepted,sizeof(accepted));
    return true;
}

bool RouteManagedWeaponLifecycle(GameScript& script, void* bridge, void* pawn,
                                  void* object, void* function, const void* locals) {
    const auto name=GameScript::ObjectName(function);
    int event=0;
    if (name==script.Intern(L"AttachWeaponTo")) event=1;
    else if (name==script.Intern(L"DetachWeapon")) event=2;
    else if (name==script.Intern(L"NotifyBeginState")) event=3;
    else if (name==script.Intern(L"NotifyEndState")) event=4;
    else if (name==script.Intern(L"SetCurrentWeapon") && pawn &&
        object==script.Read<void*>(pawn,L"InvManager") &&
        script.Read<int>(bridge,L"NativeIndependentHands")==1) event=5;
    else if (name==script.Intern(L"ClientWeaponSet") && pawn &&
        object==script.Read<void*>(pawn,L"InvManager") &&
        script.Read<int>(bridge,L"NativeIndependentHands")==1 &&
        IsDeclaredFunction(script,object,function,L"KFInventoryManager")) event=6;
    if (!event || (event<5 && !script.IsClass(object,L"KFWeapon"))) return false;
    // Derived stock bodies initialize the syringe/medic displays and stop a
    // flame pilot. Consume only their KFWeapon Super call, whose work touches
    // common pawn arms/attachment/state; let the weapon-specific body finish.
    if (event<5 && !IsDeclaredFunction(script,object,function,L"KFWeapon")) return false;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return false;
    void* weapon=object;
    if (event>=5) {
        if (!ReadScriptLocal(function,locals,script.Intern(event==5 ? L"DesiredWeapon" : L"NewWeapon"),weapon)) {
            script.Write(registry,L"NativeRuntimeFault",7);
            return true;
        }
        if (event==5 && !IsOwned(script,registry,weapon)) return false;
    } else if (event==1 && script.Read<int>(bridge,L"NativeIndependentHands")==1) {
        // A new purchase has no runtime yet. Still route attachment so its
        // async stock callback cannot take over the shared first-person arms.
        // Script checks exact pawn/pair ownership, including retired aggregates
        // whose Instigator was already cleared. Other players pass through.
    } else {
        auto* runtime=Runtime(script,registry,weapon);
        if (!runtime || !script.Read<void*>(runtime,L"Presenter")) return false;
    }
    if (event==2) {
        auto* overlay=script.Read<void*>(weapon,L"OverlayMesh");
        if (overlay) {
            struct DetachParameters { void* component; } detach{overlay};
            auto* detachFunction=script.FindFunction(weapon,L"DetachComponent");
            if (!FieldMatches(script,detachFunction,L"ExComponent",0,sizeof(detach.component)) ||
                !script.Invoke(weapon,detachFunction,&detach)) script.Write(registry,L"NativeRuntimeFault",11);
        }
    }
    struct Parameters { void* weapon; std::int32_t event, result; } parameters{weapon,event,0};
    auto* dispatch=script.FindFunction(bridge,L"DispatchManagedWeapon");
    if (!FieldMatches(script,dispatch,L"W",offsetof(Parameters,weapon),sizeof(parameters.weapon)) ||
        !FieldMatches(script,dispatch,L"EventCode",offsetof(Parameters,event),sizeof(parameters.event)) ||
        !FieldMatches(script,dispatch,L"ReturnValue",offsetof(Parameters,result),sizeof(parameters.result)) ||
        !script.Invoke(bridge,dispatch,&parameters)) {
        script.Write(registry,L"NativeRuntimeFault",3);
        // An activated managed item cannot safely reattach the shared arms or
        // clear the other item's pawn state when its dispatcher is missing.
        return true;
    }
    if (event==6 && parameters.result) {
        // KFInventoryManager's client body calls native AddWeaponToGroup,
        // rewriting replicated Inventory links into its own sorted order.
        // Pair splices use the server's order; mixing both creates cycles.
        // Retain Engine's equip/state handling, with one server-owned chain.
        auto* parent=GameScript::SuperStruct(function);
        bool compatible=parent && IsDeclaredFunction(script,object,parent,L"InventoryManager");
        for (const auto* fieldName : {L"NewWeapon",L"bOptionalSet",L"bDoNotActivate"}) {
            ScriptField childField{},parentField{};
            compatible=compatible && FindScriptField(function,script.Intern(fieldName),childField) &&
                FindScriptField(parent,script.Intern(fieldName),parentField) &&
                childField.offset==parentField.offset && childField.size==parentField.size &&
                locals && GameScript::Accessible(static_cast<const std::byte*>(locals)+childField.offset,childField.size);
        }
        if (!compatible || !script.Invoke(object,parent,const_cast<void*>(locals)))
            script.Write(registry,L"NativeRuntimeFault",12);
        return true;
    }
    // Unsupported owned items are not selector candidates, but their stock
    // automatic pickup/trader selection cannot replace a managed hand either.
    return parameters.result!=0;
}

bool RouteManagedSprint(GameScript& script, void* bridge, void* pawn,
                          void* object, void* function, const void* locals) {
    if (object!=pawn || GameScript::ObjectName(function)!=script.Intern(L"SetSprinting") ||
        script.Read<int>(bridge,L"NativeIndependentHands")!=1 ||
        !IsDeclaredFunction(script,pawn,function,L"KFPawn")) return false;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return false;
    struct Parameters { std::int32_t desired, result; } parameters{};
    auto* dispatch=script.FindFunction(bridge,L"DispatchManagedSprint");
    if (!ReadScriptLocal(function,locals,script.Intern(L"bNewSprintStatus"),parameters.desired) ||
        !FieldMatches(script,dispatch,L"bNewSprintStatus",offsetof(Parameters,desired),sizeof(parameters.desired)) ||
        !FieldMatches(script,dispatch,L"ReturnValue",offsetof(Parameters,result),sizeof(parameters.result)) ||
        !script.Invoke(bridge,dispatch,&parameters)) {
        script.Write(registry,L"NativeRuntimeFault",9);
        return true;
    }
    return parameters.result!=0;
}

int ManagedRecoilHand(GameScript& script, void* bridge, void* pawn, void* weapon, void* function,
                      int* supportHand) {
    if (supportHand) *supportHand=-1;
    if (GameScript::ObjectName(function)!=script.Intern(L"HandleRecoil") ||
        !IsDeclaredFunction(script,weapon,function,L"KFWeapon")) return -1;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return -1;
    auto* runtime=Runtime(script,registry,weapon);
    if (!runtime || !CurrentPose(script,registry,runtime)) return -1;
    const auto primary=script.Read<int>(runtime,L"PrimaryHand");
    if (supportHand) {
        const auto support=script.Read<int>(runtime,L"SupportHand");
        if (support>=0 && support<=1 && support!=primary &&
            script.Read<int>(runtime,L"NativeSupportReady")==1 &&
            script.Read<int>(runtime,L"SupportPoseOwnershipRevision")==script.Read<int>(runtime,L"OwnershipRevision"))
            *supportHand=support;
    }
    return primary;
}

bool RouteManagedMelee(GameScript& script, void* bridge, void* pawn,
                         void* object, void* function, const void* locals, void* result) {
    const auto name=GameScript::ObjectName(function);
    const bool grapple=name==script.Intern(L"IsGrappleBlocked");
    const bool parried=name==script.Intern(L"ClientPlayParryEffects");
    const bool blocked=name==script.Intern(L"ClientPlayBlockEffects");
    if (grapple || parried || blocked) {
        if (!bridge || !pawn || !script.IsClass(object,L"KFWeap_MeleeBase") ||
            script.Read<void*>(object,L"Instigator")!=pawn) return false;
        if (!grapple) {
            // The blocking-state override calls this global body once; count
            // only that body, then let the stock sound and particle play.
            if (!IsDeclaredFunction(script,object,function,L"KFWeap_MeleeBase")) return false;
            struct Parameters { void* weapon; std::int32_t parried; } parameters{object,parried?1:0};
            auto* notify=script.FindFunction(bridge,L"NotifyMeleeDefense");
            if (FieldMatches(script,notify,L"W",offsetof(Parameters,weapon),sizeof(parameters.weapon)) &&
                FieldMatches(script,notify,L"Parried",offsetof(Parameters,parried),sizeof(parameters.parried)))
                script.Invoke(bridge,notify,&parameters);
            return false;
        }
        if (script.Read<int>(bridge,L"NativeIndependentHands")!=1) return false;
        auto* registry=Registry(script,bridge,pawn);
        if (!registry) return false;
        struct Parameters { void* instigator; void* weapon; std::int32_t result; } parameters{nullptr,object,-1};
        auto* resolve=script.FindFunction(registry,L"ResolveGrappleBlock");
        if (!ReadScriptLocal(function,locals,script.Intern(L"InstigatedBy"),parameters.instigator) ||
            !FieldMatches(script,resolve,L"InstigatedBy",offsetof(Parameters,instigator),sizeof(parameters.instigator)) ||
            !FieldMatches(script,resolve,L"Asked",offsetof(Parameters,weapon),sizeof(parameters.weapon)) ||
            !FieldMatches(script,resolve,L"ReturnValue",offsetof(Parameters,result),sizeof(parameters.result)) ||
            !script.Invoke(registry,resolve,&parameters)) {
            script.Write(registry,L"NativeRuntimeFault",15);
            return false;
        }
        // -1: the asked item is itself the blocker (or unmanaged); run stock.
        if (parameters.result<0) return false;
        const std::int32_t blockedGrab=parameters.result>0 ? 1 : 0;
        if (GameScript::Accessible(result,sizeof(blockedGrab))) std::memcpy(result,&blockedGrab,sizeof(blockedGrab));
        return true;
    }
    const bool aim=name==script.Intern(L"GetMeleeAimRotation");
    const bool origin=name==script.Intern(L"GetMeleeStartTraceLocation");
    const bool impact=name==script.Intern(L"MeleeAttackImpact") || name==script.Intern(L"MeleeAttackDestructibles");
    if ((!aim && !origin && !impact) || !script.IsClass(object,L"KFMeleeHelperWeapon")) return false;
    auto* registry=Registry(script,bridge,pawn);
    if (!registry) return false;
    // Canonical references avoid a guessed UObject outer offset or retaining
    // helper pointers across a frame, ownership transfer or garbage collection.
    for (const auto* field : {L"LeftItem",L"RightItem",L"LeftSupport",L"RightSupport"}) {
        auto* runtime=script.Read<void*>(registry,field);
        auto* weapon=script.Read<void*>(runtime,L"Item");
        if (!weapon || script.Read<void*>(weapon,L"MeleeAttackHelper")!=object) continue;
        void* presenter=nullptr;
        if (!ResolveItemPresenter(script,bridge,pawn,weapon,presenter)) return false;
        if (impact) {
            if (presenter) return false;
            const std::int32_t noHit=0;
            if (GameScript::Accessible(result,sizeof(noHit))) std::memcpy(result,&noHit,sizeof(noHit));
            return true;
        }
        if (aim) {
            const auto rotation=script.Read<pinned::NativeRotator>(presenter,L"FireRotation");
            if (GameScript::Accessible(result,sizeof(rotation))) std::memcpy(result,&rotation,sizeof(rotation));
        } else {
            const auto hand=script.Read<int>(runtime,L"PrimaryHand");
            const auto location=script.Read<pinned::NativeVector3>(presenter,hand==0?L"LeftPosition":L"RightPosition");
            if (GameScript::Accessible(result,sizeof(location))) std::memcpy(result,&location,sizeof(location));
        }
        return true;
    }
    return false;
}

thread_local WeaponEffectsScope* WeaponEffectsScope::top_=nullptr;

WeaponEffectsScope::PawnState WeaponEffectsScope::ReadPawnState() {
    return {script_.Read<void*>(pawn_,L"Weapon"),script_.Read<void*>(pawn_,L"WeaponAttachment"),
        script_.Read<std::uint8_t>(pawn_,L"FiringMode"),script_.Read<std::uint8_t>(pawn_,L"FlashCount"),
        script_.Read<pinned::NativeVector3>(pawn_,L"FlashLocation"),
        script_.Read<pinned::NativeVector3>(pawn_,L"LastFiringFlashLocation")};
}

void WeaponEffectsScope::WritePawnState(const PawnState& state) {
    bool written=script_.Write(pawn_,L"Weapon",state.weapon);
    written=script_.Write(pawn_,L"WeaponAttachment",state.attachment) && written;
    written=script_.Write(pawn_,L"FiringMode",state.firingMode) && written;
    written=script_.Write(pawn_,L"FlashCount",state.flashCount) && written;
    written=script_.Write(pawn_,L"FlashLocation",state.flashLocation) && written;
    written=script_.Write(pawn_,L"LastFiringFlashLocation",state.lastFlashLocation) && written;
    if (!written) script_.Write(inventory_,L"NativeRuntimeFault",6);
}

void WeaponEffectsScope::Enter(void* bridge, void* pawn, void* object, void* function, const void* locals) {
    const auto name=GameScript::ObjectName(function);
    if (pawn_ || defensivePawn_ || object!=pawn) return;
    if (name==script_.Intern(L"AdjustDamage") || name==script_.Intern(L"PlayTakeHitEffects")) {
        // Only the base pawn body reads MyKFWeapon. Keep all derived bodies,
        // out parameters, perk adjustments and the single stock weapon call.
        if (script_.Read<int>(bridge,L"NativeIndependentHands")!=1 ||
            !IsDeclaredFunction(script_,pawn,function,L"KFPawn")) return;
        auto* registry=Registry(script_,bridge,pawn);
        if (!registry) return;
        struct Parameters { void* weapon; } parameters{};
        auto* resolve=script_.FindFunction(registry,L"ResolveDefensiveItem");
        if (!FieldMatches(script_,resolve,L"ReturnValue",0,sizeof(parameters.weapon)) ||
            !script_.Invoke(registry,resolve,&parameters) ||
            !HasObjectField(script_,pawn,L"MyKFWeapon",sizeof(void*))) {
            script_.Write(registry,L"NativeRuntimeFault",12);
            return;
        }
        savedDefensiveWeapon_=script_.Read<void*>(pawn,L"MyKFWeapon");
        if (parameters.weapon) {
            auto* runtime=Runtime(script_,registry,parameters.weapon);
            if (!runtime || !CurrentPose(script_,registry,runtime) ||
                !script_.IsClass(parameters.weapon,L"KFWeap_MeleeBase") ||
                !IsOwned(script_,registry,parameters.weapon)) {
                script_.Write(registry,L"NativeRuntimeFault",13);
                return;
            }
        } else {
            // A selected managed melee item may still be in its stock block
            // state during pose/menu cancellation. Do not let that stale item
            // defend; unrelated stock weapons retain their original callback.
            if (!script_.IsClass(savedDefensiveWeapon_,L"KFWeap_MeleeBase") ||
                !Runtime(script_,registry,savedDefensiveWeapon_)) return;
        }
        if (!script_.Write(pawn,L"MyKFWeapon",parameters.weapon)) {
            script_.Write(registry,L"NativeRuntimeFault",14);
            return;
        }
        defensivePawn_=pawn;
        inventory_=registry;
        // No item is retained beyond this callback. Nested damage/FX scopes
        // save the current synchronous selection and restore it in LIFO order.
        return;
    }
    const bool effects=name==script_.Intern(L"WeaponFired") || name==script_.Intern(L"WeaponStoppedFiring");
    bool receipts=false;
    for (const auto* entry : {L"GetWeaponFiringMode",L"SetFiringMode",L"FiringModeUpdated",
        L"IncrementFlashCount",L"ClearFlashCount",L"FlashCountUpdated",
        L"SetFlashLocation",L"ClearFlashLocation",L"FlashLocationUpdated"})
        receipts=receipts || name==script_.Intern(entry);
    if (!effects && !receipts) return;
    auto* registry=Registry(script_,bridge,pawn);
    if (!registry) return;
    void* weapon=nullptr;
    if (!ReadScriptLocal(function,locals,script_.Intern(L"InWeapon"),weapon)) {
        script_.Write(registry,L"NativeRuntimeFault",4);
        return;
    }
    auto* runtime=Runtime(script_,registry,weapon);
    if (runtime && !script_.Read<void*>(runtime,L"Presenter")) runtime=nullptr;
    if (!runtime && (!top_ || top_->pawn_!=pawn)) return;
    const auto fieldValid=[&](void* owner,const wchar_t* field,std::size_t size) {
        return HasObjectField(script_,owner,field,size);
    };
    if (!fieldValid(pawn,L"Weapon",sizeof(void*)) || !fieldValid(pawn,L"WeaponAttachment",sizeof(void*)) ||
        !fieldValid(pawn,L"FiringMode",1) || !fieldValid(pawn,L"FlashCount",1) ||
        !fieldValid(pawn,L"FlashLocation",sizeof(pinned::NativeVector3)) ||
        !fieldValid(pawn,L"LastFiringFlashLocation",sizeof(pinned::NativeVector3)) ||
        (runtime && (!fieldValid(runtime,L"NativeFiringMode",1) || !fieldValid(runtime,L"NativeFlashCount",1) ||
            !fieldValid(runtime,L"NativeFlashLocation",sizeof(pinned::NativeVector3)) ||
            !fieldValid(runtime,L"NativeLastFiringFlashLocation",sizeof(pinned::NativeVector3)) ||
            !fieldValid(weapon,L"CurrentFireMode",1)))) {
        script_.Write(registry,L"NativeRuntimeFault",10);
        return;
    }
    pawn_=pawn; inventory_=registry; runtime_=runtime;
    parent_=top_;
    top_=this;
    stockOwner_=parent_ && parent_->pawn_==pawn ? parent_->stockOwner_ : this;
    if (parent_ && parent_->pawn_==pawn && parent_->runtime_==runtime) return;
    ownsState_=true;
    saved_=ReadPawnState();
    PawnState desired{};
    if (!runtime) desired=stockOwner_->saved_;
    else {
        // A -> B -> A reentry resumes A's suspended synchronous state. A
        // nested same-item callback never reloads an older persistent receipt.
        auto* child=parent_;
        for (auto* ancestor=child?child->parent_:nullptr;ancestor;child=ancestor,ancestor=ancestor->parent_) {
            if (ancestor->pawn_==pawn && ancestor->runtime_==runtime) {
                suspendedBy_=child;
                desired=child->saved_;
                break;
            }
        }
        if (!suspendedBy_) desired={weapon,script_.Read<void*>(runtime,L"EffectsAttachment"),
            script_.Read<std::uint8_t>(runtime,L"NativeFiringMode"),script_.Read<std::uint8_t>(runtime,L"NativeFlashCount"),
            script_.Read<pinned::NativeVector3>(runtime,L"NativeFlashLocation"),
            script_.Read<pinned::NativeVector3>(runtime,L"NativeLastFiringFlashLocation")};
        if (effects) desired.firingMode=script_.Read<std::uint8_t>(weapon,L"CurrentFireMode");
    }
    WritePawnState(desired);
}

WeaponEffectsScope::~WeaponEffectsScope() {
    if (defensivePawn_ && !script_.Write(defensivePawn_,L"MyKFWeapon",savedDefensiveWeapon_))
        script_.Write(inventory_,L"NativeRuntimeFault",14);
    if (!pawn_) return;
    if (ownsState_) {
        const auto finalState=ReadPawnState();
        if (runtime_ && suspendedBy_) suspendedBy_->saved_=finalState;
        else if (runtime_) {
            bool saved=script_.Write(runtime_,L"NativeFiringMode",finalState.firingMode);
            saved=script_.Write(runtime_,L"NativeFlashCount",finalState.flashCount) && saved;
            saved=script_.Write(runtime_,L"NativeFlashLocation",finalState.flashLocation) && saved;
            saved=script_.Write(runtime_,L"NativeLastFiringFlashLocation",finalState.lastFlashLocation) && saved;
            if (!saved) script_.Write(inventory_,L"NativeRuntimeFault",5);
        } else {
            // An unmanaged nested callback keeps stock receipt mutations for
            // the eventual outer restore, without inheriting a managed item.
            stockOwner_->saved_.firingMode=finalState.firingMode;
            stockOwner_->saved_.flashCount=finalState.flashCount;
            stockOwner_->saved_.flashLocation=finalState.flashLocation;
            stockOwner_->saved_.lastFlashLocation=finalState.lastFlashLocation;
        }
        WritePawnState(saved_);
    }
    top_=parent_;
}

} // namespace kf2vr::adapter
