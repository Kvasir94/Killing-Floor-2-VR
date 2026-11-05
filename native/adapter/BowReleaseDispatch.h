#pragma once
#include "BowReleasePolicy.h"
#include "GameScript.h"
#include "ScriptField.h"
#include <array>
#include <limits>

namespace kf2vr::adapter {
namespace bowRelease {
inline bool ExactClass(GameScript& script,void* object,const wchar_t* name) {
    return object && GameScript::ObjectName(GameScript::ObjectClass(object))==script.Intern(name);
}
inline void* DirectChild(GameScript& script,void* owner,const wchar_t* name,const wchar_t* kind) {
    const auto wanted=script.Intern(name);
    auto* child=GameScript::Children(owner);
    for (unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child)) {
        if (GameScript::ObjectName(child)==wanted) return script.IsClass(child,kind) ? child : nullptr;
    }
    return nullptr;
}
inline bool Field(GameScript& script,void* function,const wchar_t* name,
                  const wchar_t* kind,std::size_t size,ScriptField& field) {
    return DirectChild(script,function,name,kind) &&
        FindScriptField(function,script.Intern(name),field) && field.size==size &&
        field.offset<512 && field.size<=512-field.offset;
}
inline bool Disjoint(const ScriptField& a,const ScriptField& b) {
    return a.offset+a.size<=b.offset || b.offset+b.size<=a.offset;
}
inline bool SpreadSchema(GameScript& script,void* function,ScriptField& input,ScriptField& output) {
    return Field(script,function,L"BaseAim",L"StructProperty",sizeof(pinned::NativeRotator),input) &&
        Field(script,function,L"ReturnValue",L"StructProperty",sizeof(pinned::NativeRotator),output) &&
        Disjoint(input,output);
}
inline bool SpawnSchema(GameScript& script,void* function,ScriptField& origin,ScriptField& direction) {
    ScriptField projectile{},output{};
    const bool valid=Field(script,function,L"KFProjClass",L"ClassProperty",sizeof(void*),projectile) &&
        Field(script,function,L"RealStartLoc",L"StructProperty",sizeof(pinned::NativeVector3),origin) &&
        Field(script,function,L"AimDir",L"StructProperty",sizeof(pinned::NativeVector3),direction) &&
        Field(script,function,L"ReturnValue",L"ObjectProperty",sizeof(void*),output);
    const std::array fields{projectile,origin,direction,output};
    if (!valid) return false;
    for (std::size_t i=0;i<fields.size();++i)
        for (std::size_t j=i+1;j<fields.size();++j) if (!Disjoint(fields[i],fields[j])) return false;
    return true;
}
inline bool Schemas(GameScript& script,void* gun) {
    if (!ExactClass(script,gun,L"KFWeap_Bow_CompoundBow")) return false;
    unsigned spawns=0,spreads=0;
    // Preflight before ammunition is consumed, including both spawn bodies:
    // the bow initializes velocity again after KFWeapon returns.
    auto* type=GameScript::ObjectClass(gun);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        ScriptField a{},b{};
        if (auto* spawn=DirectChild(script,type,L"SpawnProjectile",L"Function")) {
            if (!SpawnSchema(script,spawn,a,b)) return false;
            ++spawns;
        }
        if (auto* spread=DirectChild(script,type,L"AddSpread",L"Function")) {
            if (!SpreadSchema(script,spread,a,b)) return false;
            ++spreads;
        }
    }
    return spawns==2 && spreads>=1;
}
inline bool ValidAuthority(GameScript& script,void* authority,void* controller) {
    if (!ExactClass(script,authority,L"VRCompoundBowAuthority") || !controller ||
        script.Read<void*>(authority,L"Controller")!=controller) return false;
    auto* human=script.Read<void*>(authority,L"Human");
    auto* gun=script.Read<void*>(authority,L"Gun");
    auto* world=script.Read<void*>(controller,L"WorldInfo");
    return script.IsClass(human,L"KFPawn_Human") && script.Read<int>(human,L"Health")>0 &&
        script.Read<unsigned char>(human,L"Role")==3 &&
        script.Read<void*>(human,L"Controller")==controller && script.Read<void*>(controller,L"Pawn")==human &&
        world && script.Read<void*>(human,L"WorldInfo")==world &&
        ExactClass(script,gun,L"KFWeap_Bow_CompoundBow") && script.Read<unsigned char>(gun,L"Role")==3 &&
        script.Read<void*>(gun,L"WorldInfo")==world && script.Read<void*>(gun,L"Instigator")==human &&
        script.Read<void*>(gun,L"Owner")==human;
}
inline void* ResolveAuthority(GameScript& script,void* controller,void* bridge) {
    if (script.IsClass(controller,L"KF2VRNetPlayerController")) {
        auto* channel=script.Read<void*>(controller,L"NetChannel");
        if (script.IsClass(channel,L"KF2VRNetChannel") &&
            script.Read<void*>(channel,L"Owner")==controller &&
            script.Read<void*>(channel,L"BoundPawn")==script.Read<void*>(controller,L"Pawn")) {
            auto* authority=script.Read<void*>(channel,L"BowAuthority");
            if (ValidAuthority(script,authority,controller)) return authority;
        }
    }
    if (bridge && script.Read<void*>(bridge,L"PC")==controller) {
        auto* authority=script.Read<void*>(bridge,L"BowAuthority");
        if (ValidAuthority(script,authority,controller)) return authority;
    }
    return nullptr;
}
struct Frame {
    void* authority{};
    void* gun{};
    pinned::NativeVector3 origin{},direction{};
    pinned::NativeRotator rotation{};
    BowReleaseShotState shot;
    bool fault=false;
};
inline thread_local Frame* top=nullptr;
}

// Borrowed UObject references never outlive the synchronous accepted callback.
// Every inherited stock body continues through the ordinary handling/perk path.
class BowReleaseDispatchScope {
    enum class Call { Other,Shot,Spread,Spawn } call_=Call::Other;
    GameScript& script_;
    bowRelease::Frame frame_,*active_=nullptr,*previous_=nullptr;
    bool changesTop_=false,suppressed_=false,forwarded_=false;
    void* result_=nullptr;
public:
    BowReleaseDispatchScope(GameScript& script,void* object,void* function,void* locals,
                            void* result,void* bridge=nullptr) : script_(script) {
        using namespace bowRelease;
        struct Names {
            GameScript::Name gate,release,shot,spread,spawn,begin,serverBegin,sync,clientGate;
        };
        static thread_local const Names names{script.Intern(L"NativeBowReleaseGate"),
            script.Intern(L"NativeBowReleaseShot"),script.Intern(L"FireAmmunition"),
            script.Intern(L"AddSpread"),script.Intern(L"SpawnProjectile"),
            script.Intern(L"StartFire"),script.Intern(L"ServerStartFire"),script.Intern(L"ServerSyncWeaponFiring"),
            script.Intern(L"NativeBowClientGate")};
        const auto name=GameScript::ObjectName(function);
        if (name==names.clientGate) {
            if (object!=bridge || !script.IsClass(object,L"VRHandsBridge") ||
                script.FindFunction(object,L"NativeBowClientGate")!=function) return;
            suppressed_=true;
            script.Write(object,L"NativeBowVersion",0);
            auto* controller=script.Read<void*>(object,L"PC");
            auto* human=script.Read<void*>(object,L"Human");
            if (controller && script.IsClass(human,L"KFPawn_Human") &&
                script.Read<void*>(controller,L"Pawn")==human && script.Read<void*>(human,L"Controller")==controller)
                script.Write(object,L"NativeBowVersion",1);
            return;
        }
        const bool gate=name==names.gate,release=name==names.release,shot=name==names.shot;
        const bool spread=name==names.spread,spawn=name==names.spawn;
        const bool begin=name==names.serverBegin || name==names.begin,sync=name==names.sync;
        if (!gate && !release && !shot && !spread && !spawn && !begin && !sync) return;
        if (gate || release) {
            if (!ExactClass(script,object,L"VRCompoundBowAuthority") ||
                script.FindFunction(object,gate ? L"NativeBowReleaseGate" : L"NativeBowReleaseShot")!=function) return;
            // An unowned/invalid callback never executes its firing body.
            suppressed_=true;
            if (gate) script.Write(object,L"NativeVersion",0);
            auto* controller=script.Read<void*>(object,L"Controller");
            if (ResolveAuthority(script,controller,bridge)!=object || !Schemas(script,script.Read<void*>(object,L"Gun"))) return;
            if (gate) { script.Write(object,L"NativeVersion",1);return; }
            const auto request=script.Read<int>(object,L"RequestId");
            frame_.authority=object;frame_.gun=script.Read<void*>(object,L"Gun");
            frame_.origin=script.Read<pinned::NativeVector3>(object,L"ReleaseOrigin");
            frame_.rotation=script.Read<pinned::NativeRotator>(object,L"ReleaseRotation");
            if (top || request<=0 || request==std::numeric_limits<int>::max() ||
                script.Read<int>(object,L"NativePermit")!=1 || script.Read<int>(object,L"NativeFence")!=1 ||
                script.Read<int>(object,L"Status")!=1 || !BoundedBowOrigin(frame_.origin) ||
                !CanonicalBowRotation(frame_.rotation) || script.Read<unsigned char>(frame_.gun,L"CurrentFireMode")>1 ||
                !script.Write(object,L"NativeEntered",1)) return;
            previous_=top;top=&frame_;changesTop_=true;suppressed_=false;return;
        }
        if (shot && top && object!=top->gun) {
            // Another item cannot borrow the accepted bow's shot or aim.
            previous_=top;top=nullptr;changesTop_=true;return;
        }
        if (!ExactClass(script,object,L"KFWeap_Bow_CompoundBow") ||
            script.Read<unsigned char>(object,L"Role")!=3) return;
        auto* controller=script.Read<void*>(script.Read<void*>(object,L"Instigator"),L"Controller");
        auto* authority=ResolveAuthority(script,controller,bridge);
        if (!authority || script.Read<void*>(authority,L"Gun")!=object ||
            script.Read<int>(authority,L"NativeFence")!=1) return;
        if (begin || sync) {
            unsigned char mode=255;
            suppressed_=!ReadScriptLocal(function,locals,script.Intern(L"FireModeNum"),mode) || mode<=1;
            return;
        }
        if (script.Read<unsigned char>(object,L"CurrentFireMode")>1) return;
        if (shot) {
            suppressed_=true;
            if (!top || top->authority!=authority || top->gun!=object || !top->shot.BeginShot()) return;
            active_=top;call_=Call::Shot;suppressed_=false;
            return;
        }
        if (!top || top->authority!=authority || top->gun!=object) return;
        active_=top;
        if (spread) {
            ScriptField input{},output{};
            const bool outer=!active_->shot.Spreading();
            suppressed_=true;
            if (!locals || !result || !SpreadSchema(script,function,input,output) ||
                !GameScript::Accessible(static_cast<std::byte*>(locals)+input.offset,input.size) ||
                !GameScript::Accessible(result,sizeof(pinned::NativeRotator)) || !active_->shot.BeginSpread()) {
                active_->fault=true;return;
            }
            if (outer) std::memcpy(static_cast<std::byte*>(locals)+input.offset,&active_->rotation,input.size);
            result_=result;call_=Call::Spread;suppressed_=false;
        } else if (spawn) {
            ScriptField origin{},direction{};
            suppressed_=true;
            if (result && GameScript::Accessible(result,sizeof(void*))) {
                void* empty=nullptr;std::memcpy(result,&empty,sizeof(empty));
            }
            if (!locals || !SpawnSchema(script,function,origin,direction) ||
                !GameScript::Accessible(static_cast<std::byte*>(locals)+origin.offset,origin.size) ||
                !GameScript::Accessible(static_cast<std::byte*>(locals)+direction.offset,direction.size) ||
                !active_->shot.BeginSpawn()) { active_->fault=true;return; }
            std::memcpy(static_cast<std::byte*>(locals)+origin.offset,&active_->origin,origin.size);
            std::memcpy(static_cast<std::byte*>(locals)+direction.offset,&active_->direction,direction.size);
            result_=result;call_=Call::Spawn;suppressed_=false;
        }
    }
    ~BowReleaseDispatchScope() {
        if (active_) {
            if (call_==Call::Shot) {
                if (!forwarded_) active_->fault=true;
                if (active_->shot.EndShot(forwarded_) && active_->shot.Completed())
                    script_.Write(active_->authority,L"NativeShotCount",1);
            } else if (call_==Call::Spawn) {
                if (!forwarded_) active_->fault=true;
                active_->shot.EndSpawn();
            }
            else if (call_==Call::Spread) {
                pinned::NativeRotator rotation{};
                const bool valid=forwarded_ && GuardedCopy(&rotation,result_,sizeof(rotation));
                if (!valid) active_->fault=true;
                if (active_->shot.EndSpread(valid)) active_->direction=BowArrowDirection(rotation);
            }
        }
        if (changesTop_ && bowRelease::top==&frame_)
            script_.Write(frame_.authority,L"NativeFault",frame_.fault ? 1 : 0);
        if (changesTop_) bowRelease::top=previous_;
    }
    BowReleaseDispatchScope(const BowReleaseDispatchScope&)=delete;
    BowReleaseDispatchScope& operator=(const BowReleaseDispatchScope&)=delete;
    void Forwarded() { forwarded_=true; }
    bool Suppressed() const { return suppressed_; }
};
}
