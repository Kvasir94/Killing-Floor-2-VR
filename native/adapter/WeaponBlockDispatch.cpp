#include "WeaponBlockDispatch.h"
#include "ScriptField.h"
#include "WeaponBlockSurface.h"
#include "WeaponImpactBody.h"
#include <array>
#include <cmath>

namespace kf2vr::adapter {
namespace {
thread_local bool notifying=false;
thread_local unsigned damageDepth=0;
struct ThrownDamageContext {
    void* prop{};void* weapon{};void* victim{};void* kind{};void* instigator{};
    GameScript::Name zone{};
    weaponblock::Vec source{};
    unsigned damageDepth{},blockedDepth{};
};
thread_local std::array<ThrownDamageContext,8> thrownContexts{};
thread_local unsigned thrownCount=0;
void* Direct(GameScript& s,void* owner,const wchar_t* name,const wchar_t* kind) {
    auto* f=GameScript::Children(owner);
    for(unsigned n=0;f && n<4096;++n,f=GameScript::NextField(f))
        if(GameScript::ObjectName(f)==s.Intern(name)) return s.IsClass(f,kind)?f:nullptr;
    return nullptr;
}
bool Exact(GameScript& s,void* object,void* function,const wchar_t* type,const wchar_t* name) {
    auto* c=GameScript::ObjectClass(object);
    for(unsigned n=0;c && n<64;++n,c=GameScript::SuperStruct(c))
        if(GameScript::ObjectName(c)==s.Intern(type)) return Direct(s,c,name,L"Function")==function;
    return false;
}
template<class T> bool Local(GameScript& s,void* function,const void* locals,const wchar_t* name,const wchar_t* type,T& value){
    ScriptField field{};
    return locals&&Direct(s,function,name,type)&&FindScriptField(function,s.Intern(name),field)
        &&field.size==sizeof(T)&&field.offset<=256-sizeof(T)
        &&GuardedCopy(&value,static_cast<const std::byte*>(locals)+field.offset,sizeof(T));
}
struct Arguments {
    GameScript& s;void* function;
    alignas(16) std::array<std::byte,256> bytes{};
    std::array<ScriptField,8> fields{};unsigned count=0;
    bool valid=true;
    bool Field(const wchar_t* name,const wchar_t* type,std::size_t size,ScriptField& out) {
        if(!valid || count==fields.size() || !Direct(s,function,name,type)
            || !FindScriptField(function,s.Intern(name),out) || out.size!=size || out.offset>bytes.size()-size)
            return valid=false;
        for(unsigned n=0;n<count;++n)
            if(out.offset<fields[n].offset+fields[n].size && fields[n].offset<out.offset+out.size)
                return valid=false;
        fields[count++]=out;return true;
    }
    template<class T> bool Put(const wchar_t* name,const wchar_t* type,const T& value) {
        ScriptField f{};
        if(!Field(name,type,sizeof(T),f)) return false;
        std::memcpy(bytes.data()+f.offset,&value,sizeof(T));return true;
    }
    int ReadInt(ScriptField f) const { int value=0;std::memcpy(&value,bytes.data()+f.offset,sizeof(value));return value; }
    bool Call(void* receiver) {
        if(!valid) return false;
        struct Guard {Guard(){notifying=true;}~Guard(){notifying=false;}} guard;
        return s.Invoke(receiver,function,bytes.data());
    }
};
bool SurfaceSweep(GameScript& s,void* object,void* function,const void* locals) {
    if(!Exact(s,object,function,L"KF2VRNetWeaponBlockRig",L"NativeSurfaceSweep"))return false;
    // This is a private server-side math service, not a client block claim.
    if(s.Read<unsigned char>(object,L"Role")!=3 || !locals)return true;
    auto read=[&]<class T>(const wchar_t* name,const wchar_t* type,T& value){
        ScriptField field{};
        return Direct(s,function,name,type)&&FindScriptField(function,s.Intern(name),field)
            &&field.size==sizeof(T)&&field.offset<=256-sizeof(T)
            &&GuardedCopy(&value,static_cast<const std::byte*>(locals)+field.offset,sizeof(T));
    };
    weaponblock::Motion weapon,blade;weaponblock::Hit hit;float scale=0;int id=0,result=0;
    const bool valid=read(L"Geometry",L"IntProperty",id)&&read(L"OldRoot",L"StructProperty",weapon.before)
        &&read(L"Root",L"StructProperty",weapon.after)&&read(L"OldQ",L"StructProperty",weapon.beforeQ)
        &&read(L"Q",L"StructProperty",weapon.afterQ)&&read(L"OldBlade",L"StructProperty",blade.before)
        &&read(L"BladeRoot",L"StructProperty",blade.after)&&read(L"OldBladeQ",L"StructProperty",blade.beforeQ)
        &&read(L"BladeQ",L"StructProperty",blade.afterQ)&&read(L"BladeScale",L"FloatProperty",scale);
    if(valid)if(const auto* surface=weaponblock::Catalog(id))result=surface->Sweep(weaponblock::GorefastBlade(),weapon,blade,scale,hit)?1:0;
    // Object mailbox avoids FFrame out-parameter/return ABI assumptions. The
    // script clears it immediately before this synchronous private math call.
    if(result&&s.Write(object,L"SurfacePoint",hit.point)&&s.Write(object,L"SurfaceNormal",hit.normal))
        s.Write(object,L"SurfaceHit",result);
    return true;
}
bool ThrownSurfaceSweep(GameScript& s,void* object,void* function,const void* locals) {
    if(!Exact(s,object,function,L"VRWorldDropGun",L"NativeThrownSurfaceSweep"))return false;
    s.Write(object,L"SurfaceHit",0);s.Write(object,L"SurfaceCurrentOverlap",0);
    if(s.Read<unsigned char>(object,L"Role")!=3||!locals)return true;
    // Script owns the exact drop lifecycle and packed bool properties. Calling
    // its narrow integer predicate avoids assuming the native bool-mask ABI.
    auto* permission=s.FindFunction(object,L"NativeThrownSurfaceAllowed");
    if(!permission||!Exact(s,object,permission,L"VRWorldDropGun",L"NativeThrownSurfaceAllowed"))return true;
    Arguments allowed{s,permission};ScriptField permitted{};
    if(!allowed.Field(L"ReturnValue",L"IntProperty",sizeof(int),permitted)
        ||!allowed.Call(object)||allowed.ReadInt(permitted)!=1)return true;
    auto read=[&]<class T>(const wchar_t* name,const wchar_t* type,T& value){
        ScriptField field{};
        return Direct(s,function,name,type)&&FindScriptField(function,s.Intern(name),field)
            &&field.size==sizeof(T)&&field.offset<=256-sizeof(T)
            &&GuardedCopy(&value,static_cast<const std::byte*>(locals)+field.offset,sizeof(T));
    };
    weaponblock::Motion weapon,victim;weaponblock::Hurtbox shape;weaponblock::Hit hit;
    int id=0,kind=-1;float seconds=0,scale=0;
    const bool valid=read(L"Geometry",L"IntProperty",id)
        &&read(L"OldRoot",L"StructProperty",weapon.before)&&read(L"OldQ",L"StructProperty",weapon.beforeQ)
        &&read(L"Root",L"StructProperty",weapon.after)&&read(L"Q",L"StructProperty",weapon.afterQ)
        &&read(L"OldVictim",L"StructProperty",victim.before)&&read(L"OldVictimQ",L"StructProperty",victim.beforeQ)
        &&read(L"VictimRoot",L"StructProperty",victim.after)&&read(L"VictimQ",L"StructProperty",victim.afterQ)
        &&read(L"ShapeKind",L"IntProperty",kind)&&read(L"HalfExtent",L"StructProperty",shape.halfExtent)
        &&read(L"Radius",L"FloatProperty",shape.radius)&&read(L"HalfLength",L"FloatProperty",shape.halfLength)
        &&read(L"DeltaSeconds",L"FloatProperty",seconds)&&read(L"WeaponScale",L"FloatProperty",scale);
    if(!valid||kind<0||kind>2||!weaponblock::CatalogIsWorld(id))return true;
    shape.kind=static_cast<weaponblock::HurtboxKind>(kind);
    const auto* surface=weaponblock::Catalog(id);if(!surface)return true;
    // Endpoint overlap is independent of a usable sweep interval. It is used
    // only to rearm one-impact-per-contact bookkeeping, never to apply damage.
    const weaponblock::Motion endWeapon{weapon.after,weapon.after,weapon.afterQ,weapon.afterQ};
    const weaponblock::Motion endVictim{victim.after,victim.after,victim.afterQ,victim.afterQ};
    weaponblock::Hit endpoint;
    const int overlap=surface->SweepHurtbox(endWeapon,endVictim,shape,endpoint,scale)?1:0;
    s.Write(object,L"SurfaceCurrentOverlap",overlap);
    if(!std::isfinite(seconds)||seconds<=0||seconds>.1f
        ||!surface->SweepHurtbox(weapon,victim,shape,hit,scale))return true;
    const auto info=weaponblock::CatalogFaceInfo(id,hit.triangleIndex);
    const int triangle=static_cast<int>(hit.triangleIndex);
    const int region=weaponblock::ClassifyCatalogContact(id,hit.triangleIndex,hit.localPoint);
    weaponblock::Vec tipAxis,edgeAxis,edgeTangent;
    weaponblock::CatalogContactAxes(id,hit.localPoint,tipAxis,edgeAxis,edgeTangent);
    const weaponblock::Vec scaledLocal{hit.localPoint.x*scale,hit.localPoint.y*scale,hit.localPoint.z*scale};
    const auto weaponVelocity=weaponblock::RigidPointVelocity(weapon,scaledLocal,hit.fraction,seconds);
    const auto victimVelocity=weaponblock::RigidPointVelocity(victim,hit.victimLocalPoint,hit.fraction,seconds);
    if(s.Write(object,L"SurfacePoint",hit.point)&&s.Write(object,L"SurfaceNormal",hit.normal)
        &&s.Write(object,L"SurfaceLocalPoint",hit.localPoint)&&s.Write(object,L"SurfaceFraction",hit.fraction)
        &&s.Write(object,L"SurfaceTriangle",triangle)&&s.Write(object,L"SurfaceMaterial",info.material)
        &&s.Write(object,L"SurfaceSourceFace",info.sourceFace)&&s.Write(object,L"SurfaceRegion",region)
        &&s.Write(object,L"SurfaceTipAxis",tipAxis)&&s.Write(object,L"SurfaceEdgeAxis",edgeAxis)
        &&s.Write(object,L"SurfaceEdgeTangent",edgeTangent)
        &&s.Write(object,L"SurfaceWeaponVelocity",weaponVelocity)&&s.Write(object,L"SurfaceVictimVelocity",victimVelocity))
        s.Write(object,L"SurfaceHit",1);
    return true;
}
bool ThrownBodyResponse(GameScript& s,void* object,void* function,const void* locals){
    if(!Exact(s,object,function,L"VRWorldDropGun",L"NativeThrownBodyResponse"))return false;
    s.Write(object,L"BodyResponseValid",0);
    if(s.Read<unsigned char>(object,L"Role")!=3)return true;
    auto* permission=s.FindFunction(object,L"NativeThrownSurfaceAllowed");
    if(!permission||!Exact(s,object,permission,L"VRWorldDropGun",L"NativeThrownSurfaceAllowed"))return true;
    Arguments allowed{s,permission};ScriptField result{};
    if(!allowed.Field(L"ReturnValue",L"IntProperty",sizeof(int),result)||!allowed.Call(object)||allowed.ReadInt(result)!=1)return true;
    weaponblock::Vec at,normal,victim,impulse,velocity;float restitution=0;
    if(!Local(s,function,locals,L"At",L"StructProperty",at)
        ||!Local(s,function,locals,L"HitNormal",L"StructProperty",normal)
        ||!Local(s,function,locals,L"VictimVelocity",L"StructProperty",victim)
        ||!Local(s,function,locals,L"Restitution",L"FloatProperty",restitution))return true;
    weaponblock::RigidBodyState body;
    if(ReadWeaponImpactBody(s,object,body)&&weaponblock::ContactImpulse(body,at,normal,victim,restitution,impulse,velocity)
        &&s.Write(object,L"BodyResponseImpulse",impulse)&&s.Write(object,L"BodyResponseVelocity",velocity))
        s.Write(object,L"BodyResponseValid",1);
    return true;
}

// Read-only zone query for any rig-frame point (held bash, thrown contact).
bool SharpAt(GameScript& s,void* object,void* function,const void* locals){
    if(!Exact(s,object,function,L"VRWorldGunRigs",L"NativeSharpAt"))return false;
    int id=0;weaponblock::Vec point{};float slack=0;
    if(Local(s,function,locals,L"Geometry",L"IntProperty",id)
        &&Local(s,function,locals,L"LocalPoint",L"StructProperty",point)
        &&Local(s,function,locals,L"Slack",L"FloatProperty",slack))
        s.Write(object,L"SharpResult",weaponblock::ClassifyCatalogPoint(id,point,slack));
    return true;
}

}

WeaponBlockScope::WeaponBlockScope(GameScript& s,void* object,void* function,const void* locals) {
    // Every script call passes here: intern the one stable name once.
    static const auto sharpAtName=s.Intern(L"NativeSharpAt");
    static const auto thrownResponseName=s.Intern(L"NativeThrownBodyResponse");
    static const auto thrownDamageName=s.Intern(L"NativeThrownDamage");
    static const auto thrownSweepName=s.Intern(L"NativeThrownSurfaceSweep");
    if(!function || !object)return;
    const auto name=GameScript::ObjectName(function);
    if(name==sharpAtName&&SharpAt(s,object,function,locals)){suppressed_=true;return;}
    // Thrown world weapons hit Zeds in stable play (Kvasir94, 2026-10-29, #116):
    // the surface sweep, its stock damage attribution and the body response.
    // Weapon-arm cancellation (NativeSurfaceSweep, Gorefast melee) stays parked.
    constexpr bool experimentalWeaponContacts = false;
    if(name==thrownResponseName&&ThrownBodyResponse(s,object,function,locals)){suppressed_=true;return;}
    if(name==thrownDamageName&&Exact(s,object,function,L"VRWorldDropGun",L"NativeThrownDamage")){
        // This synchronous wrapper contains only the exact owned-prop stock
        // TakeDamage call. No context survives its ProcessInternal return.
        if(thrownCount==thrownContexts.size()||s.Read<unsigned char>(object,L"Role")!=3){suppressed_=true;return;}
        ThrownDamageContext context{};context.prop=object;context.weapon=s.Read<void*>(object,L"OwnedWeapon");
        auto* owner=s.Read<void*>(object,L"DropOwner");context.instigator=s.Read<void*>(owner,L"Controller");
        if(!context.weapon||!context.instigator
            ||!Local(s,function,locals,L"Victim",L"ObjectProperty",context.victim)
            ||!Local(s,function,locals,L"Kind",L"ClassProperty",context.kind)
            ||!Local(s,function,locals,L"Zone",L"NameProperty",context.zone)
            ||!Local(s,function,locals,L"Source",L"StructProperty",context.source)
            ||!s.IsClass(context.victim,L"KFPawn_Monster")||s.Read<unsigned char>(context.victim,L"Role")!=3
            ||!std::isfinite(context.source.x)||!std::isfinite(context.source.y)||!std::isfinite(context.source.z)){
            suppressed_=true;return;
        }
        thrownContext_=thrownCount++;thrownContexts[thrownContext_]=context;ownsThrownContext_=true;return;
    }
    if(thrownCount){
        auto& context=thrownContexts[thrownCount-1];
        if(name==s.Intern(L"TakeDamage")){
            void* causer=nullptr;void* kind=nullptr;void* instigator=nullptr;
            const bool matching=object==context.victim
                &&Local(s,function,locals,L"DamageCauser",L"ObjectProperty",causer)&&causer==context.weapon
                &&Local(s,function,locals,L"DamageType",L"ClassProperty",kind)&&kind==context.kind
                &&Local(s,function,locals,L"InstigatedBy",L"ObjectProperty",instigator)&&instigator==context.instigator;
            thrownContext_=thrownCount-1;ownsThrownDamage_=true;++context.damageDepth;
            // Super.TakeDamage calls with the same exact identity remain in
            // the stock chain; secondary/reentrant damage has no source override.
            if(!matching){blocksThrownArmor_=true;++context.blockedDepth;}
        }
        else if(name==s.Intern(L"AdjustBoneDamage")&&context.damageDepth&&!context.blockedDepth
            &&Exact(s,object,function,L"KFZedArmorInfo",L"AdjustBoneDamage")
            &&s.Read<void*>(context.victim,L"ArmorInfo")==object){
            GameScript::Name zone{};void* kind=nullptr;ScriptField source{};
            if(Local(s,function,locals,L"BoneName",L"NameProperty",zone)&&zone==context.zone
                &&Local(s,function,locals,L"DamageType",L"ClassProperty",kind)&&kind==context.kind
                &&Direct(s,function,L"DamagerSource",L"StructProperty")
                &&FindScriptField(function,s.Intern(L"DamagerSource"),source)&&source.size==sizeof(context.source)&&source.offset<=244)
                GuardedCopy(static_cast<std::byte*>(const_cast<void*>(locals))+source.offset,&context.source,sizeof(context.source));
        }
    }
    if(name==thrownSweepName&&ThrownSurfaceSweep(s,object,function,locals)){suppressed_=true;return;}
    if(!experimentalWeaponContacts)return;
    if(name==s.Intern(L"NativeSurfaceSweep")&&SurfaceSweep(s,object,function,locals)){suppressed_=true;return;}
    if(notifying)return;
    const bool begin=name==s.Intern(L"PlayAnimation")
        && Exact(s,object,function,L"KFSM_MeleeAttack",L"PlayAnimation");
    const bool resolve=name==s.Intern(L"ResolvePawnMeleeDamage")
        && Exact(s,object,function,L"KFMeleeHelperAI",L"ResolvePawnMeleeDamage");
    const bool delayed=name==s.Intern(L"ApplyDelayedPawnDamage")
        && Exact(s,object,function,L"KFMeleeHelperAI",L"ApplyDelayedPawnDamage");
    const bool direct=name==s.Intern(L"ApplyMeleeDamage") && damageDepth==0
        && Exact(s,object,function,L"KFMeleeHelperAI",L"ApplyMeleeDamage");
    if(!begin && !resolve && !delayed && !direct) return;
    if(resolve || delayed) { ownsDepth_=true;++damageDepth; }
    // KFMeleeHelperAI is `within Actor`: Instigator in its bytecode belongs
    // to Outer, not to the helper UObject itself.
    auto* zed=s.Read<void*>(object,begin?L"KFPOwner":L"Outer");
    if(!s.IsClass(zed,L"KFPawn_ZedGorefast") || s.IsClass(zed,L"KFPawn_ZedGorefastDualBlade")
        || s.Read<unsigned char>(zed,L"Role")!=3) return;
    auto* world=s.Read<void*>(zed,L"WorldInfo");auto* game=s.Read<void*>(world,L"Game");
    if(!s.IsClass(game,L"KF2VRNetGame")) return;
    const auto* callbackName=begin?L"NativeWeaponBlockAttack":delayed?L"NativeWeaponBlockDelayed":L"NativeWeaponBlockDamage";
    auto* callback=s.FindFunction(game,callbackName);
    if(!callback) return;
    Arguments args{s,callback};
    ScriptField result{},pending{};
    if(begin) { args.Put(L"Zed",L"ObjectProperty",zed);args.Call(game);return; }
    args.Put(L"Helper",L"ObjectProperty",object);
    args.Field(L"ReturnValue",L"IntProperty",sizeof(int),result);
    if(delayed) {
        ScriptField index{};int value=-1;
        if(!locals || !Direct(s,function,L"i",L"IntProperty")
            || !FindScriptField(function,s.Intern(L"i"),index) || index.size!=sizeof(value) || index.offset>252
            || !GuardedCopy(&value,static_cast<const std::byte*>(locals)+index.offset,sizeof(value))) return;
        args.Put(L"Index",L"IntProperty",value);
        script_=&s;game_=game;helper_=object;delayedIndex_=value;
        if(args.Call(game)) suppressed_=args.ReadInt(result)==1;
        return;
    }
    args.Put(L"Zed",L"ObjectProperty",zed);
    const int directFlag=direct?1:0;
    args.Put(L"DirectDamage",L"IntProperty",directFlag);
    args.Field(L"PendingBefore",L"IntProperty",sizeof(int),pending);
    if(!args.Call(game)) return;
    const int serial=args.ReadInt(result);
    suppressed_=serial==-1;
    if(resolve && serial>0) {
        script_=&s;game_=game;zed_=zed;helper_=object;serial_=serial;first_=args.ReadInt(pending);
    }
}

WeaponBlockScope::~WeaponBlockScope() {
    if(ownsThrownDamage_&&thrownContext_<thrownCount){
        auto& context=thrownContexts[thrownContext_];
        if(blocksThrownArmor_)--context.blockedDepth;
        --context.damageDepth;
    }
    if(ownsThrownContext_&&thrownCount&&thrownContext_==thrownCount-1){
        thrownContexts[--thrownCount]={};
    }
    if(script_ && delayedIndex_>=0) {
        // Pinned KFGame.exe TickPingCompensation: event at RVA 0xdf4518,
        // then stable memmove/Remove(i,1) at 0xdf451e..0xdf4555. Complete
        // after the event body (including nested appends), before that removal.
        auto& s=*script_;
        if(auto* callback=s.FindFunction(game_,L"NativeWeaponBlockDelayedComplete")) {
            Arguments args{s,callback};
            args.Put(L"Helper",L"ObjectProperty",helper_);
            args.Put(L"Index",L"IntProperty",delayedIndex_);
            args.Call(game_);
        }
    }
    else if(script_ && !suppressed_ && first_>=0) {
        auto& s=*script_;
        auto* callback=s.FindFunction(game_,L"NativeWeaponBlockQueued");
        if(callback) {
            Arguments args{s,callback};
            args.Put(L"Zed",L"ObjectProperty",zed_);args.Put(L"Helper",L"ObjectProperty",helper_);
            args.Put(L"Serial",L"IntProperty",serial_);args.Put(L"FirstPending",L"IntProperty",first_);
            args.Call(game_);
        }
    }
    if(ownsDepth_) --damageDepth;
}
}
