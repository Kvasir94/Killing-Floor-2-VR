#pragma once
#include "GameScript.h"
#include "ScriptField.h"
#include <array>

namespace kf2vr::adapter {
namespace secondaryReload {

inline void* DirectChild(GameScript& script,void* owner,const wchar_t* name,const wchar_t* kind) {
    const auto wanted=script.Intern(name);
    auto* child=GameScript::Children(owner);
    for (unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child)) {
        // Reflection lists belong to the pinned, loaded stock classes.
        if (GameScript::ObjectName(child)==wanted)
            return script.IsClass(child,kind) ? child : nullptr;
    }
    return nullptr;
}

inline void* BridgeClass(GameScript& script,void* bridge) {
    const auto wanted=script.Intern(L"VRHandsBridge");
    auto* type=GameScript::ObjectClass(bridge);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type))
        if (GameScript::ObjectName(type)==wanted) return type;
    return nullptr;
}

inline bool Field(GameScript& script,void* owner,const wchar_t* name,const wchar_t* kind,
                  std::size_t size,ScriptField& field,bool direct=false) {
    if (direct && !DirectChild(script,owner,name,kind)) return false;
    if (!FindScriptField(owner,script.Intern(name),field) || field.size!=size) return false;
    if (!direct) {
        bool found=false;
        for (unsigned depth=0;owner && depth<64;++depth,owner=GameScript::SuperStruct(owner)) {
            if (DirectChild(script,owner,name,kind)) { found=true;break; }
        }
        if (!found) return false;
    }
    return true;
}

inline bool WeaponParameter(GameScript& script,void* function,ScriptField& weapon) {
    return Field(script,function,L"W",L"ObjectProperty",sizeof(void*),weapon,true) &&
        weapon.offset<=32-sizeof(void*);
}

inline void* StockPayment(GameScript& script,void* gun) {
    auto* type=GameScript::ObjectClass(gun);
    const auto exact=GameScript::ObjectName(type);
    const wchar_t* owner=nullptr;
    if (exact==script.Intern(L"KFWeap_AssaultRifle_M16M203") ||
        exact==script.Intern(L"KFWeap_AssaultRifle_HRGIncendiaryRifle") ||
        exact==script.Intern(L"KFWeap_AssaultRifle_HRGTeslauncher"))
        owner=L"KFWeap_AssaultRifle_M16M203";
    else if (exact==script.Intern(L"KFWeap_AssaultRifle_MedicRifleGrenadeLauncher"))
        owner=L"KFWeap_AssaultRifle_MedicRifleGrenadeLauncher";
    else if (exact==script.Intern(L"KFWeap_AssaultRifle_FAMAS")) owner=L"KFWeap_AssaultRifle_FAMAS";
    else if (exact==script.Intern(L"KFWeap_Shotgun_S12")) owner=L"KFWeap_Shotgun_S12";
    if (!owner) return nullptr;
    const auto wanted=script.Intern(owner);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        if (GameScript::ObjectName(type)!=wanted) continue;
        auto* state=DirectChild(script,type,L"AltReloading",L"State");
        return state ? DirectChild(script,state,L"PerformReload",L"Function") : nullptr;
    }
    return nullptr;
}

// Only the two shared scratch fields are borrowed. All loaded/reserve ammo and
// the owning weapon's server RPC remain inside stock script payment.
struct RestorePrimary {
    void* amount=nullptr;
    void* shots=nullptr;
    int savedAmount=0,savedShots=0;
    ~RestorePrimary() {
        if (amount) std::memcpy(amount,&savedAmount,sizeof(savedAmount));
        if (shots) std::memcpy(shots,&savedShots,sizeof(savedShots));
    }
};

inline thread_local bool paying=false;
struct PaymentScope {
    PaymentScope() { paying=true; }
    ~PaymentScope() { paying=false; }
};

inline bool Pay(GameScript& script,void* bridge,void* gun,void* human,void* controller) {
    if (paying || !gun || !human || !controller ||
        script.Read<void*>(bridge,L"Human")!=human || script.Read<void*>(bridge,L"PC")!=controller ||
        script.Read<void*>(controller,L"Pawn")!=human || script.Read<void*>(human,L"Controller")!=controller ||
        script.Read<void*>(gun,L"Instigator")!=human || script.Read<void*>(gun,L"Owner")!=human ||
        script.Read<void*>(gun,L"WorldInfo")!=script.Read<void*>(human,L"WorldInfo")) return false;
    auto* payment=StockPayment(script,gun);
    if (!payment) return false;

    // This exact bridge helper checks the live physical transaction, local
    // control, current state and infinite-spare setting in UnrealScript.
    auto* amountFunction=DirectChild(script,BridgeClass(script,bridge),
        L"NativeSecondaryReloadAmount",L"Function");
    ScriptField amountWeapon{},amountResult{},fireMode{};
    if (!amountFunction || script.FindFunction(bridge,L"NativeSecondaryReloadAmount")!=amountFunction ||
        !WeaponParameter(script,amountFunction,amountWeapon) ||
        !Field(script,amountFunction,L"ReturnValue",L"IntProperty",sizeof(int),amountResult,true) ||
        amountResult.offset>32-sizeof(int) || amountResult.offset<amountWeapon.offset+sizeof(void*) ||
        !Field(script,payment,L"FireModeNum",L"ByteProperty",sizeof(unsigned char),fireMode,true) ||
        fireMode.offset>=32) return false;
    std::array<std::byte,32> amountArgs{};
    std::memcpy(amountArgs.data()+amountWeapon.offset,&gun,sizeof(gun));
    if (!script.Invoke(bridge,amountFunction,amountArgs.data())) return false;
    int amount=0;
    std::memcpy(&amount,amountArgs.data()+amountResult.offset,sizeof(amount));
    if (amount<=0) return false;

    ScriptField remaining{},shots{},ammo{},capacity{};
    auto* type=GameScript::ObjectClass(gun);
    if (!Field(script,type,L"ReloadAmountLeft",L"IntProperty",sizeof(int),remaining) ||
        !Field(script,type,L"ShotsHit",L"IntProperty",sizeof(int),shots) ||
        !Field(script,type,L"AmmoCount",L"IntProperty",sizeof(int),ammo) ||
        !Field(script,type,L"MagazineCapacity",L"IntProperty",sizeof(int),capacity)) return false;
    auto* bytes=static_cast<std::byte*>(gun);
    auto* remainingAt=bytes+remaining.offset;
    auto* shotsAt=bytes+shots.offset;
    // ScriptField.size is UProperty.ElementSize, including for these stock
    // fixed int arrays. Validate both elements before reading slot one.
    if (!GameScript::Accessible(bytes+ammo.offset,2*sizeof(int)) ||
        !GameScript::Accessible(bytes+capacity.offset,2*sizeof(int))) return false;
    const auto ammoBefore=GameScript::At<int>(gun,ammo.offset+sizeof(int));
    const auto capacityAlt=GameScript::At<int>(gun,capacity.offset+sizeof(int));
    if (ammoBefore<0 || capacityAlt<=ammoBefore || amount>capacityAlt-ammoBefore ||
        !GameScript::Accessible(remainingAt,sizeof(int)) || !GameScript::Accessible(shotsAt,sizeof(int))) return false;
    RestorePrimary restore{remainingAt,shotsAt,GameScript::At<int>(gun,remaining.offset),
        GameScript::At<int>(gun,shots.offset)};
    PaymentScope scope;
    std::memcpy(remainingAt,&amount,sizeof(amount));
    std::array<std::byte,32> args{};
    args[fireMode.offset]=std::byte{1};
    // Direct UFunction invocation bypasses active-state name resolution without
    // entering AltReloading or touching the primary animation/timers/status.
    return script.Invoke(gun,payment,args.data()) &&
        GameScript::At<int>(gun,ammo.offset+sizeof(int))>ammoBefore;
}
}

inline bool RouteSecondaryReloadPayment(GameScript& script,void* object,void* function,
                                        void* locals,void* result,void* bridge,
                                        void* human,void* controller) {
    if (GameScript::ObjectName(function)!=script.Intern(L"NativePaySecondaryReload") ||
        !bridge || object!=bridge ||
        !script.IsClass(bridge,L"VRHandsBridge") ||
        secondaryReload::DirectChild(script,secondaryReload::BridgeClass(script,bridge),
            L"NativePaySecondaryReload",L"Function")!=function ||
        script.FindFunction(bridge,L"NativePaySecondaryReload")!=function) return false;
    const int rejected=0;
    if (result) std::memcpy(result,&rejected,sizeof(rejected));
    ScriptField weapon{},returned{};
    void* gun=nullptr;
    if (!result || !locals || !secondaryReload::WeaponParameter(script,function,weapon) ||
        !secondaryReload::Field(script,function,L"ReturnValue",L"BoolProperty",sizeof(int),returned,true) ||
        returned.offset>32-sizeof(int) || returned.offset<weapon.offset+sizeof(void*) ||
        !GuardedCopy(&gun,static_cast<const std::byte*>(locals)+weapon.offset,sizeof(gun))) return true;
    const int paid=secondaryReload::Pay(script,bridge,gun,human,controller) ? 1 : 0;
    std::memcpy(result,&paid,sizeof(paid));
    return true;
}
}
