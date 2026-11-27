#include "ArmLossDispatch.h"
#include "ScriptField.h"
#include <array>
#include <cstdint>
#include <cstring>

namespace kf2vr::adapter {
namespace {
thread_local bool routing=false;

void* Mutator(GameScript& s,void* actor) {
    if(!actor) return nullptr;
    auto* world=s.Read<void*>(actor,L"WorldInfo");
    auto* game=world?s.Read<void*>(world,L"Game"):nullptr;
    auto* m=game?s.Read<void*>(game,L"BaseMutator"):nullptr;
    for(unsigned n=0;m && n<32;++n,m=s.Read<void*>(m,L"NextMutator"))
        if(s.IsClass(m,L"VRArmLossMutator")) return m;
    return nullptr;
}

// One script call on the mutator or bridge with up to three parameters and an
// int return. Parameters are written by name into a zeroed frame.
struct Call {
    GameScript& s;void* receiver;void* function;
    alignas(16) std::array<std::byte,256> bytes{};
    bool valid;
    Call(GameScript& script,void* target,const wchar_t* name):s(script),receiver(target),
        function(target?script.FindFunction(target,name):nullptr),valid(function!=nullptr) {}
    template<class T> Call& Put(const wchar_t* name,const T& value) {
        ScriptField f{};
        if(!valid || !FindScriptField(function,s.Intern(name),f) || f.size!=sizeof(T) || f.offset>bytes.size()-sizeof(T))
            valid=false;
        else std::memcpy(bytes.data()+f.offset,&value,sizeof(T));
        return *this;
    }
    // Returns the script's int result, or `fallback` when the call could not run.
    int Int(int fallback) {
        ScriptField r{};
        if(!valid || !FindScriptField(function,s.Intern(L"ReturnValue"),r) || r.size!=sizeof(int) || r.offset>bytes.size()-sizeof(int))
            return fallback;
        routing=true;
        const bool ran=s.Invoke(receiver,function,bytes.data());
        routing=false;
        if(!ran) return fallback;
        int value=fallback;std::memcpy(&value,bytes.data()+r.offset,sizeof(value));
        return value;
    }
    void Run() {
        if(!valid) return;
        routing=true;s.Invoke(receiver,function,bytes.data());routing=false;
    }
};

void Answer(void* result,bool value) {
    // Script bools return as a 32-bit UBOOL.
    if(result && GameScript::Accessible(result,sizeof(std::uint32_t)))
        *static_cast<std::uint32_t*>(result)=value?1u:0u;
}

bool ArmLost(GameScript& s,void* zed) { return zed && s.Read<int>(zed,L"InjuredHitZones")!=0; }
}

bool RouteArmLoss(GameScript& s,void* object,void* function,const void* locals,void* result,void* handsBridge) {
    if(routing || !object || !function) return false;
    const auto name=GameScript::ObjectName(function);
    if(name==s.Intern(L"CanInjureHitZone")) {
        if(!s.IsClass(object,L"KFPawn_Monster") || s.Read<unsigned char>(object,L"Role")!=3) return false;
        void* kind=nullptr;int zone=-1;
        if(!ReadScriptLocal(function,locals,s.Intern(L"DamageType"),kind)
            || !ReadScriptLocal(function,locals,s.Intern(L"HitZoneIdx"),zone)) return false;
        auto* m=Mutator(s,object);
        if(!m || Call(s,m,L"NativeCanInjureArm").Put(L"Zed",object).Put(L"DamageType",kind).Put(L"HitZoneIdx",zone).Int(0)!=1)
            return false;
        Answer(result,true);
        return true;
    }
    if(name==s.Intern(L"CanDoAttackAnim")) {
        if(!s.IsClass(object,L"KFPawnAnimInfo")) return false;
        void* zed=nullptr;int index=-1;
        if(!ReadScriptLocal(function,locals,s.Intern(L"P"),zed)
            || !ReadScriptLocal(function,locals,s.Intern(L"Idx"),index)
            || !s.IsClass(zed,L"KFPawn_Monster") || !ArmLost(s,zed)) return false;
        auto* m=Mutator(s,zed);
        if(!m || Call(s,m,L"NativeAttackAllowed").Put(L"Zed",zed).Put(L"Idx",index).Int(1)!=0) return false;
        Answer(result,false);
        return true;
    }
    if(name==s.Intern(L"MeleeImpactNotify")) {
        if(!s.IsClass(object,L"KFPawn_Monster") || !ArmLost(s,object)) return false;
        void* notify=nullptr;
        if(!ReadScriptLocal(function,locals,s.Intern(L"Notify"),notify)) return false;
        auto* m=Mutator(s,object);
        return m && Call(s,m,L"NativeImpactAllowed").Put(L"Zed",object).Put(L"Notify",notify).Int(1)==0;
    }
    if(name==s.Intern(L"CanDoFireball") || name==s.Intern(L"CanDoFlamethrower")) {
        if(!s.IsClass(object,L"KFAIController_ZedHusk")) return false;
        auto* zed=s.Read<void*>(object,L"Pawn");
        if(!s.IsClass(zed,L"KFPawn_Monster") || !ArmLost(s,zed)) return false;
        auto* m=Mutator(s,zed);
        if(!m || Call(s,m,L"NativeHuskGunAllowed").Put(L"Zed",zed).Int(1)!=0) return false;
        Answer(result,false);
        return true;
    }
    if(name==s.Intern(L"HitZoneInjured") && handsBridge) {
        if(s.IsClass(object,L"KFPawn_Monster"))
            Call(s,handsBridge,L"NativeArmLossInjured").Put(L"Zed",object).Run();
        return false;
    }
    return false;
}
}
