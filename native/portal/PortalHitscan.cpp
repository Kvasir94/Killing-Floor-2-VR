#include "PortalHitscan.h"


#include <array>
#include <cstring>
#include "../adapter/RPGBackBlast.h"
#include "kf2vr/adapter/LocalWorldGate.h"

namespace kf2vr::portal {
namespace {
using adapter::GameScript;
struct ScriptArray { void* data{}; std::int32_t count{},capacity{}; };
static_assert(sizeof(ScriptArray)==16);

struct Field { void* property{}; std::size_t offset{},size{}; };
bool FindField(GameScript& script,void* function,const wchar_t* name,std::size_t wanted,Field& out) {
    const auto fieldName=script.Intern(name);
    auto* p=GameScript::Children(function);
    for (unsigned count=0;p && count<128;++count,p=GameScript::NextField(p)) {
        if (GameScript::ObjectName(p)!=fieldName) continue;
        const auto offset=GameScript::At<std::int32_t>(p,0x8c),size=GameScript::At<std::int32_t>(p,0x6c);
        if (offset<0 || offset>512 || size<=0 || size>256 || std::size_t(offset+size)>768 ||
            (wanted && std::size_t(size)!=wanted)) return false;
        out={p,std::size_t(offset),std::size_t(size)}; return true;
    }
    return false;
}
bool ValidArray(const ScriptArray& a,std::size_t elementSize) {
    return a.count>=0 && a.capacity>=a.count && a.capacity<=4096 &&
        (!a.capacity || GameScript::Accessible(a.data,std::size_t(a.capacity)*elementSize));
}
}

void PortalHitscan::Initialise(std::uintptr_t gameBase,LogFn log) {
    log_=log;
    base_=gameBase; script_.Initialise(gameBase); Reset();
}
void PortalHitscan::Reset() {
    localPlayer_=nullptr; pawn_=nullptr; gun_=nullptr; bridge_=nullptr; stockFunction_=nullptr; thread_=0;
}
bool PortalHitscan::Alive(void* object,const wchar_t* type) {
    return GameScript::Accessible(object,0x120) && script_.IsClass(object,type);
}
bool PortalHitscan::LocalPawn(void*& pawn) {
    if (!base_ || thread_!=GetCurrentThreadId()) return false;
    adapter::pinned::LocalWorldSnapshot world;
    auto read=[](std::uintptr_t address,void* target,std::size_t count) {
        if (!GameScript::Accessible(reinterpret_cast<void*>(address),count)) return false;
        std::memcpy(target,reinterpret_cast<void*>(address),count); return true;
    };
    if (!adapter::pinned::CheckStandaloneWorld(base_,reinterpret_cast<std::uintptr_t>(localPlayer_),read,world)) return false;
    auto* controller=reinterpret_cast<void*>(world.controller);
    pawn=script_.Read<void*>(controller,L"Pawn");
    return Alive(pawn,L"KFPawn_Human") && script_.Read<void*>(pawn,L"Controller")==controller && script_.Read<int>(pawn,L"Health")>0;
}
void PortalHitscan::Refresh(void* localPlayer,void* gun) {
    if (!base_ || (thread_ && thread_!=GetCurrentThreadId())) return;
    thread_=GetCurrentThreadId(); localPlayer_=localPlayer;
    void* pawn=nullptr;
    if (!LocalPawn(pawn)) { if(log_ && report_!=1) log_("PortalShots register refused local player=%p",localPlayer); report_=1; Reset(); return; }
    if (pawn_!=pawn) { gun_=nullptr; bridge_=nullptr; stockFunction_=nullptr; }
    pawn_=pawn;
    gun_=gun;
    if (!Alive(gun_,L"VRWeap_PortalGun") || script_.Read<void*>(gun_,L"Instigator")!=pawn_) {
        if(log_ && report_!=2) log_("PortalShots register refused gun=%p pawn=%p",gun_,pawn_); report_=2;
        gun_=nullptr; bridge_=nullptr; stockFunction_=nullptr; return;
    }
    // VRWeap_PortalGun and VRSourceWeapon do not override CalcWeaponFire. This
    // resolves the exact KFWeapon implementation, leaving subclass overrides
    // and their other scripted behavior in the original VM.
    stockFunction_=script_.FindFunction(gun_,L"CalcWeaponFire");
    bridge_=script_.Read<void*>(gun_,L"HitscanBridge");
    if (!Alive(bridge_,L"VRPortalHitscan")) {
        auto* ensure=script_.FindFunction(gun_,L"EnsureHitscanBridge");
        std::array<std::byte,64> parameters{};
        if (ensure) script_.Invoke(gun_,ensure,parameters.data());
        bridge_=script_.Read<void*>(gun_,L"HitscanBridge");
    }
    auto* pair=script_.FindFunction(bridge_,L"HasPair");
    Field pairResult;
    std::array<std::byte,768> pairParameters{};
    if (!pair || !FindField(script_,pair,L"ReturnValue",4,pairResult) ||
        !script_.Invoke(bridge_,pair,pairParameters.data()) ||
        !GameScript::At<std::int32_t>(pairParameters.data(),pairResult.offset)) {
        stockFunction_=nullptr; return;
    }
    if(log_ && report_!=3) log_("PortalShots registered gun=%p bridge=%p trace=%p",gun_,bridge_,stockFunction_); report_=3;
}

bool PortalHitscan::Route(void* object,void* frame,void* result) {
    if (thread_!=GetCurrentThreadId() || depth_ || !stockFunction_ || !GameScript::Accessible(frame,0x44) ||
        GameScript::At<void*>(frame,0x14)!=stockFunction_) return false;
    void* pawn=nullptr;
    if (!LocalPawn(pawn) || pawn!=pawn_ || !Alive(object,L"KFWeapon") || script_.FindFunction(object,L"CalcWeaponFire")!=stockFunction_ || script_.Read<void*>(object,L"Instigator")!=pawn ||
        !Alive(gun_,L"VRWeap_PortalGun") || !Alive(bridge_,L"VRPortalHitscan") ||
        script_.Read<void*>(bridge_,L"Launcher")!=gun_ || script_.Read<void*>(bridge_,L"Instigator")!=pawn) return false;
    const auto mode=script_.Read<std::uint8_t>(object,L"CurrentFireMode");
    const auto modes=script_.Read<ScriptArray>(object,L"WeaponFireTypes");
    if (!ValidArray(modes,1) || mode>=modes.count || GameScript::At<std::uint8_t>(modes.data,mode)!=0) return false;
    auto* ready=script_.FindFunction(bridge_,L"Ready");
    Field readyWeapon,readyReturn;
    if (!ready || !FindField(script_,ready,L"W",sizeof(void*),readyWeapon) || !FindField(script_,ready,L"ReturnValue",4,readyReturn)) return false;
    std::array<std::byte,768> readyParameters{};
    std::memcpy(readyParameters.data()+readyWeapon.offset,&object,sizeof(object));
    if (!script_.Invoke(bridge_,ready,readyParameters.data()) || GameScript::At<std::int32_t>(readyParameters.data(),readyReturn.offset)==0) return false;
    auto* route=script_.FindFunction(bridge_,L"RouteCalcWeaponFire");
    if (!route) return false;
    static constexpr const wchar_t* names[]{L"StartTrace",L"EndTrace",L"ImpactList",L"Extent",L"ReturnValue"};
    static constexpr std::size_t widths[]{12,12,16,12,0};
    std::array<Field,5> source,target;
    for (std::size_t i=0;i<5;++i) if (!FindField(script_,stockFunction_,names[i],widths[i],source[i]) ||
        !FindField(script_,route,names[i],source[i].size,target[i])) return false;
    // Native ImpactInfo is a POD struct. Require its actual reflected size to
    // match both functions, and bound the out-array before borrowing it.
    if (source[4].size<80 || source[4].size>128 || !GameScript::Accessible(result,source[4].size)) return false;
    auto* locals=GameScript::At<void*>(frame,0x2c);
    if (!locals) return false;
    auto* outArray=adapter::RPGOutParameter(stockFunction_,frame,script_.Intern(L"ImpactList"),sizeof(ScriptArray));
    if (!outArray) return false;
    const auto array=GameScript::At<ScriptArray>(outArray,0);
    if (!ValidArray(array,source[4].size)) return false;
    std::array<std::byte,768> parameters{};
    for (std::size_t i=0;i<4;++i) {
        auto* input=i==2 ? outArray : static_cast<std::byte*>(locals)+source[i].offset;
        if (!GameScript::Accessible(input,source[i].size)) return false;
        std::memcpy(parameters.data()+target[i].offset,input,source[i].size);
    }
    auto* shouldRoute=script_.FindFunction(bridge_,L"ShouldRoute");
    Field gateStart,gateEnd,gateExtent,gateReturn;
    if (!shouldRoute || !FindField(script_,shouldRoute,L"StartTrace",12,gateStart) ||
        !FindField(script_,shouldRoute,L"EndTrace",12,gateEnd) || !FindField(script_,shouldRoute,L"Extent",12,gateExtent) ||
        !FindField(script_,shouldRoute,L"ReturnValue",4,gateReturn)) return false;
    std::array<std::byte,768> gateParameters{};
    std::memcpy(gateParameters.data()+gateStart.offset,parameters.data()+target[0].offset,12);
    std::memcpy(gateParameters.data()+gateEnd.offset,parameters.data()+target[1].offset,12);
    std::memcpy(gateParameters.data()+gateExtent.offset,parameters.data()+target[3].offset,12);
    if (!script_.Invoke(bridge_,shouldRoute,gateParameters.data()) ||
        GameScript::At<std::int32_t>(gateParameters.data(),gateReturn.offset)==0) return false;
    auto* previous=script_.Read<void*>(bridge_,L"NativeFiringWeapon");
    if (!script_.Write<void*>(bridge_,L"NativeFiringWeapon",object)) return false;
    struct Scope {
        unsigned& depth; GameScript& script; void* bridge; void* previous;
        Scope(unsigned& d,GameScript& s,void* b,void* p):depth(d),script(s),bridge(b),previous(p) { ++depth; }
        ~Scope() { --depth; script.Write<void*>(bridge,L"NativeFiringWeapon",previous); }
    } scope(depth_,script_,bridge_,previous);
    const bool invoked=script_.Invoke(bridge_,route,parameters.data());
    if (!invoked) return false;
    // ProcessEvent's out-parameter record points at this parameter buffer. A
    // script array append may reallocate it; propagate its complete header to
    // the original caller's out record, never to a guessed VM local address.
    std::memcpy(outArray,parameters.data()+target[2].offset,sizeof(ScriptArray));
    std::memcpy(result,parameters.data()+target[4].offset,source[4].size);
    ++routedCalls_; return true;
}

// Preserve subclass WeaponFired behavior. Only replace the stock declaration,
// and copy reflected parameter widths rather than assuming packed bool layout.
bool PortalHitscan::Effects(void* object,void* frame) {
    void* pawn=nullptr;
    if (depth_ || !stockFunction_ || !LocalPawn(pawn) || pawn!=pawn_ || object!=pawn ||
        !Alive(bridge_,L"VRPortalHitscan") || !GameScript::Accessible(frame,0x44)) return false;
    auto* function=GameScript::At<void*>(frame,0x14);
    bool stock=false;
    for (auto* type=GameScript::ObjectClass(object);type;type=GameScript::SuperStruct(type)) {
        if (GameScript::ObjectName(type)!=script_.Intern(L"KFPawn")) continue;
        for (auto* child=GameScript::Children(type);child;child=GameScript::NextField(child))
            if (child==function) { stock=true; break; }
        break;
    }
    if (!stock) return false;
    auto* targetFunction=script_.FindFunction(bridge_,L"PlayRoutedEffects");
    auto* locals=GameScript::At<void*>(frame,0x2c);
    std::array<std::byte,768> parameters{};
    const wchar_t* names[]{L"InWeapon",L"bViaReplication",L"HitLocation"};
    const std::size_t sizes[]{8,4,12};
    for (unsigned i=0;i<3;++i) {
        Field source,target;
        if (!FindField(script_,function,names[i],sizes[i],source) ||
            !FindField(script_,targetFunction,names[i],sizes[i],target) ||
            !GameScript::Accessible(static_cast<std::byte*>(locals)+source.offset,source.size)) return false;
        std::memcpy(parameters.data()+target.offset,static_cast<std::byte*>(locals)+source.offset,source.size);
    }
    Field returned;
    if (!FindField(script_,targetFunction,L"ReturnValue",4,returned)) return false;
    ++depth_;
    const bool invoked=script_.Invoke(bridge_,targetFunction,parameters.data());
    --depth_;
    return invoked && GameScript::At<std::int32_t>(parameters.data(),returned.offset)!=0;
}

bool PortalHitscan::ProjectileWall(void* object,void* frame) {
    void* pawn=nullptr;
    if (depth_ || !stockFunction_ || !LocalPawn(pawn) || pawn!=pawn_ ||
        !Alive(object,L"Projectile") || script_.Read<void*>(object,L"Instigator")!=pawn ||
        !Alive(bridge_,L"VRPortalHitscan") || !GameScript::Accessible(frame,0x44)) return false;
    auto* function=GameScript::At<void*>(frame,0x14);
    auto* targetFunction=script_.FindFunction(bridge_,L"RouteProjectileWall");
    auto* locals=GameScript::At<void*>(frame,0x2c);
    std::array<std::byte,768> parameters{};
    Field projectile,returned;
    if (!FindField(script_,targetFunction,L"P",8,projectile) ||
        !FindField(script_,targetFunction,L"ReturnValue",4,returned)) return false;
    std::memcpy(parameters.data()+projectile.offset,&object,8);
    const wchar_t* names[]{L"HitNormal",L"Wall",L"WallComp"};
    const std::size_t sizes[]{12,8,8};
    for (unsigned i=0;i<3;++i) {
        Field source,target;
        if (!FindField(script_,function,names[i],sizes[i],source) ||
            !FindField(script_,targetFunction,names[i],sizes[i],target) ||
            !GameScript::Accessible(static_cast<std::byte*>(locals)+source.offset,source.size)) return false;
        std::memcpy(parameters.data()+target.offset,static_cast<std::byte*>(locals)+source.offset,source.size);
    }
    ++depth_;
    const bool invoked=script_.Invoke(bridge_,targetFunction,parameters.data());
    --depth_;
    return invoked && GameScript::At<std::int32_t>(parameters.data(),returned.offset)!=0;
}

} // namespace kf2vr::portal
