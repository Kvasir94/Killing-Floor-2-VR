#include "PerkContext.h"
#include "ScriptField.h"

namespace kf2vr::adapter {
namespace {

// Single object parameter at offset zero, the only shape the entries take.
bool ObjectParameter(GameScript& script, void* function, const wchar_t* name) {
    ScriptField field{};
    return function && FindScriptField(function,script.Intern(name),field) &&
        field.offset==0 && field.size==sizeof(void*);
}

} // namespace

PerkCall ClassifyPerkCall(GameScript& script, void* object, void* function, const void* locals) {
    PerkCall call{};
    const auto name=GameScript::ObjectName(function);
    if (name==script.Intern(L"FireAmmunition")) {
        if (!script.IsClass(object,L"KFWeapon")) return call;
        call={PerkEntry::Fire,script.Read<void*>(object,L"Instigator"),object};
    } else if (name==script.Intern(L"TakeDamage")) {
        if (!script.IsClass(object,L"KFPawn_Monster")) return call;
        void* instigator=nullptr;
        void* causer=nullptr;
        if (!ReadScriptLocal(function,locals,script.Intern(L"InstigatedBy"),instigator) ||
            !ReadScriptLocal(function,locals,script.Intern(L"DamageCauser"),causer) ||
            !script.IsClass(instigator,L"KFPlayerController")) return call;
        call={PerkEntry::Damage,script.Read<void*>(instigator,L"Pawn"),causer};
    } else if (name==script.Intern(L"UpdateGroundSpeed")) {
        if (!script.IsClass(object,L"KFPawn_Human")) return call;
        call={PerkEntry::Movement,object,nullptr};
    }
    if (!script.IsClass(call.pawn,L"KFPawn_Human")) call={};
    return call;
}

bool PawnHasAuthority(GameScript& script, void* pawn) {
    auto* world=script.Read<void*>(pawn,L"WorldInfo");
    // ENetMode: NM_Standalone 0, NM_DedicatedServer 1, NM_ListenServer 2, NM_Client 3.
    return world && script.Read<unsigned char>(world,L"NetMode")!=3 &&
        script.Read<unsigned char>(pawn,L"Role")==3;
}

void PerkScope::Enter(void* provider, const PerkCall& call) {
    if (provider_ || !provider || call.entry==PerkEntry::None) return;
    if (call.entry==PerkEntry::Movement) {
        auto* function=script_.FindFunction(provider,L"NativePerkMovement");
        if (!function || !script_.Invoke(provider,function,nullptr)) return;
    } else {
        const auto* entry=call.entry==PerkEntry::Fire ? L"NativePerkFire" : L"NativePerkDamage";
        const auto* parameter=call.entry==PerkEntry::Fire ? L"W" : L"Causer";
        auto* function=script_.FindFunction(provider,entry);
        struct Parameters { void* argument; } parameters{call.argument};
        if (!ObjectParameter(script_,function,parameter) || !script_.Invoke(provider,function,&parameters)) return;
    }
    provider_=provider;
}

void EnterLocalPerk(GameScript& script, PerkScope& scope, void* bridge, void* pawn,
                    void* object, void* function, const void* locals) {
    if (!bridge || !pawn) return;
    const auto call=ClassifyPerkCall(script,object,function,locals);
    if (call.entry==PerkEntry::None || call.pawn!=pawn ||
        (call.entry!=PerkEntry::Fire && !PawnHasAuthority(script,pawn))) return;
    scope.Enter(bridge,call);
}

PerkScope::~PerkScope() {
    if (!provider_) return;
    script_.Invoke(provider_,script_.FindFunction(provider_,L"NativePerkEnd"),nullptr);
}

} // namespace kf2vr::adapter
