#include "CorpseDamageObserver.h"
#include "ScriptField.h"
#include "include/kf2vr/adapter/VerifiedLayout.h"
#include <array>
#include <cmath>

namespace kf2vr::adapter {
namespace {

constexpr std::size_t ParameterCapacity=512;
thread_local bool notifying=false;
struct HuskContactFrame {
    void* projectile;
    HuskContactFrame* previous;
};
thread_local HuskContactFrame* handlingHusk=nullptr;
thread_local bool inBoneRadiusDamage=false;
thread_local SwipeCallFrame* swipeCalls=nullptr;
thread_local bool routingSwipe=false;
struct MeleeBodyHit {
    void* helper{};
    void* body{};
    void* attacker{};
    void* causer{};
    void* kind{};
    pinned::NativeVector3 location{};
    const std::byte* hitInfo{};
    std::size_t size{};
    bool used{};
};
thread_local MeleeBodyHit* meleeBodyHit=nullptr;

// Walk only reflected metadata. Never retain a pawn, mutator or world pointer.
void* DirectChild(GameScript& script, void* owner, const wchar_t* name, const wchar_t* kind) {
    const auto wanted=script.Intern(name);
    auto* child=GameScript::Children(owner);
    for (unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child)) {
        if (GameScript::ObjectName(child)==wanted)
            return script.IsClass(child,kind) ? child : nullptr;
    }
    return nullptr;
}

bool ExactDamage(GameScript& script, void* victim, void* function,bool dying) {
    auto* type=GameScript::ObjectClass(victim);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        if (GameScript::ObjectName(type)!=script.Intern(L"KFPawn")) continue;
        auto* owner=dying ? DirectChild(script,type,L"Dying",L"State") : type;
        return owner && DirectChild(script,owner,L"TakeDamage",L"Function")==function;
    }
    return false;
}

bool ExactHelper(GameScript& script,void* helper,void* function,const wchar_t* name) {
    auto* type=GameScript::ObjectClass(helper);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        if (GameScript::ObjectName(type)==script.Intern(L"KFMeleeHelperAI"))
            return DirectChild(script,type,name,L"Function")==function;
    }
    return false;
}

template<class T>
bool Local(GameScript& script,void* function,const void* locals,const wchar_t* name,const wchar_t* kind,T& value);

bool Parameter(GameScript& script, void* function, const wchar_t* name,
               const wchar_t* kind, std::size_t size, ScriptField& field) {
    if (!DirectChild(script,function,name,kind) ||
        !FindScriptField(function,script.Intern(name),field) ||
        field.offset>=ParameterCapacity || field.size>ParameterCapacity-field.offset) return false;
    return size ? field.size==size : field.size>0 && field.size<=256;
}

bool Disjoint(const ScriptField& a,const ScriptField& b) {
    return a.offset+a.size<=b.offset || b.offset+b.size<=a.offset;
}

template<class T>
bool Local(GameScript& script,void* function,const void* locals,const wchar_t* name,const wchar_t* kind,T& value) {
    ScriptField field{};
    return locals && Parameter(script,function,name,kind,sizeof(T),field) &&
        GuardedCopy(&value,static_cast<const std::byte*>(locals)+field.offset,sizeof(T));
}

bool Finite(const pinned::NativeVector3& value) {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

template<class T>
bool ObjectValue(GameScript& script,void* object,const wchar_t* name,T& value) {
    ScriptField field{};
    if (!object || !FindScriptField(GameScript::ObjectClass(object),script.Intern(name),field) ||
        field.size!=sizeof(T)) return false;
    return GuardedCopy(&value,static_cast<const std::byte*>(object)+field.offset,sizeof(T));
}

void* BreacherReceiver(GameScript& script,void* world) {
    void* game=nullptr;
    void* mutator=nullptr;
    if (!ObjectValue(script,world,L"Game",game) || !script.IsClass(game,L"GameInfo") ||
        !ObjectValue(script,game,L"BaseMutator",mutator)) return nullptr;
    for (unsigned count=0;mutator && count<64;++count) {
        if (!script.IsClass(mutator,L"Mutator")) return nullptr;
        if (script.IsClass(mutator,L"BreacherMutator")) break;
        void* next=nullptr;
        if (!ObjectValue(script,mutator,L"NextMutator",next) || next==mutator) return nullptr;
        mutator=next;
    }
    void* mutatorWorld=nullptr;
    if (!mutator || !script.IsClass(mutator,L"BreacherMutator") ||
        !ObjectValue(script,mutator,L"WorldInfo",mutatorWorld) || mutatorWorld!=world) return nullptr;
    return mutator;
}

// Returns only an invocation-local receiver. Callers never cache it across ticks.
void* NotifyDamage(GameScript& script,void* victim,void* function,const void* locals,bool dying) {
    if (notifying || (dying && inBoneRadiusDamage) || !locals || !function ||
        GameScript::ObjectName(function)!=script.Intern(L"TakeDamage") ||
        !script.IsClass(victim,L"KFPawn_Monster") || !ExactDamage(script,victim,function,dying)) return nullptr;

    unsigned char role=0,mode=255;
    int health=1;
    void* world=nullptr;
    if (!ObjectValue(script,victim,L"Role",role) || role!=3 ||
        !ObjectValue(script,victim,L"Health",health) || (dying ? health>0 : health<=0) ||
        !ObjectValue(script,victim,L"WorldInfo",world) || !script.IsClass(world,L"WorldInfo") ||
        !ObjectValue(script,world,L"NetMode",mode) || mode>2) return nullptr;

    struct Argument { const wchar_t* name; const wchar_t* kind; std::size_t size; };
    const std::array<Argument,7> arguments{{
        {L"Damage",L"IntProperty",sizeof(std::int32_t)},
        {dying ? L"EventInstigator" : L"InstigatedBy",L"ObjectProperty",sizeof(void*)},
        {L"HitLocation",L"StructProperty",sizeof(pinned::NativeVector3)},
        {L"Momentum",L"StructProperty",sizeof(pinned::NativeVector3)},
        {L"DamageType",L"ClassProperty",sizeof(void*)},
        {L"HitInfo",L"StructProperty",0},
        {L"DamageCauser",L"ObjectProperty",sizeof(void*)}
    }};
    std::array<ScriptField,7> source{};
    for (std::size_t i=0;i<arguments.size();++i) {
        const auto& a=arguments[i];
        if (!Parameter(script,function,a.name,a.kind,a.size,source[i])) return nullptr;
        for (std::size_t j=0;j<i;++j) if (!Disjoint(source[i],source[j])) return nullptr;
    }

    std::int32_t damage=0;
    void* instigator=nullptr;
    void* damageType=nullptr;
    void* causer=nullptr;
    pinned::NativeVector3 location{},momentum{};
    if (!ReadScriptLocal(function,locals,script.Intern(L"Damage"),damage) ||
        !ReadScriptLocal(function,locals,script.Intern(arguments[1].name),instigator) ||
        !ReadScriptLocal(function,locals,script.Intern(L"DamageType"),damageType) ||
        !ReadScriptLocal(function,locals,script.Intern(L"DamageCauser"),causer) ||
        !ReadScriptLocal(function,locals,script.Intern(L"HitLocation"),location) ||
        !ReadScriptLocal(function,locals,script.Intern(L"Momentum"),momentum)) return nullptr;
    // Even unattributed/zero/invalid-contact live hits must shadow an outer hit.
    // The script begin callback only stores context; NetDamage validates it.
    if (dying && (damage<=0 || !Finite(location) || !Finite(momentum) ||
        !script.IsClass(instigator,L"Controller") || !script.IsClass(damageType,L"Class") ||
        (causer && !script.IsClass(causer,L"Actor")))) return nullptr;

    auto* mutator=BreacherReceiver(script,world);
    if (!mutator) return nullptr;
    auto* notify=script.FindFunction(mutator,dying ? L"NativeCorpseDamage" : L"NativeLiveDamageBegin");
    if (!notify) return nullptr;
    // Do not open a context that this package cannot close.
    if (!dying) {
        auto* end=script.FindFunction(mutator,L"NativeLiveDamageEnd");
        ScriptField endVictim{};
        if (!end || !GameScript::Accessible(end,0xf8) || GameScript::At<std::uint16_t>(end,0xd4)!=0 ||
            !Parameter(script,end,L"Victim",L"ObjectProperty",sizeof(void*),endVictim)) return nullptr;
    }

    ScriptField victimField{};
    if (!Parameter(script,notify,L"Victim",L"ObjectProperty",sizeof(void*),victimField)) return nullptr;
    std::array<ScriptField,7> destination{};
    for (std::size_t i=0;i<arguments.size();++i) {
        const auto& a=arguments[i];
        const auto* targetName=i==1 ? L"EventInstigator" : a.name;
        if (!Parameter(script,notify,targetName,a.kind,source[i].size,destination[i]) ||
            !Disjoint(victimField,destination[i])) return nullptr;
        for (std::size_t j=0;j<i;++j) if (!Disjoint(destination[i],destination[j])) return nullptr;
    }
    alignas(16) std::array<std::byte,ParameterCapacity> parameters{};
    std::memcpy(parameters.data()+victimField.offset,&victim,sizeof(victim));
    for (std::size_t i=0;i<arguments.size();++i)
        if (!GuardedCopy(parameters.data()+destination[i].offset,
                         static_cast<const std::byte*>(locals)+source[i].offset,source[i].size)) return nullptr;
    if (!dying) {
        ScriptField radial{};
        if (!Parameter(script,notify,L"bRadial",L"BoolProperty",sizeof(std::uint32_t),radial) ||
            !Disjoint(victimField,radial)) return nullptr;
        for (const auto& field:destination) if (!Disjoint(field,radial)) return nullptr;
        // No adjacent bool shares this word (checked above). All bits support
        // any reflected UE3 bool mask without assuming that its mask is one.
        const std::uint32_t value=inBoneRadiusDamage ? ~std::uint32_t{} : 0;
        std::memcpy(parameters.data()+radial.offset,&value,sizeof(value));
    }

    // Optional script policy only. It must not damage actors from this callback.
    // The caller always resumes the unmodified stock damage body.
    struct NotifyGuard { NotifyGuard() { notifying=true; } ~NotifyGuard() { notifying=false; } } guard;
    return script.Invoke(mutator,notify,parameters.data()) ? mutator : nullptr;
}

} // namespace

SwipeDispatchScope::SwipeDispatchScope(GameScript& script,void* object,void* function,void* locals) {
    // Ordinary VM calls need no frame or large buffer initialization. Once a
    // stock swipe starts, every nested call still shadows its exact parent.
    if (!swipeCalls && (!function || !locals ||
        GameScript::ObjectName(function)!=script.Intern(L"DoSwipeImpact") ||
        !ExactHelper(script,object,function,L"DoSwipeImpact"))) return;
    // Link each actual invocation, without searching an arbitrary caller
    // stack. Consumers accept only the exact immediate stock call chain.
    frame_.emplace(object,function,locals,swipeCalls);
    swipeCalls=&*frame_;
    auto* hit=meleeBodyHit;
    if (!hit || hit->used || !function || !locals || object!=hit->body ||
        GameScript::ObjectName(function)!=script.Intern(L"TakeDamage") || !frame_->previous ||
        frame_->previous->helper!=hit->helper ||
        !ExactHelper(script,hit->helper,frame_->previous->function,L"ApplyMeleeDamage")) return;
    const bool dying=ExactDamage(script,object,function,true);
    if (!dying && !ExactDamage(script,object,function,false)) return;
    void* attacker=nullptr;
    void* kind=nullptr;
    void* causer=nullptr;
    pinned::NativeVector3 point{};
    if (!Local(script,function,locals,dying ? L"EventInstigator" : L"InstigatedBy",L"ObjectProperty",attacker) || attacker!=hit->attacker ||
        !Local(script,function,locals,L"DamageType",L"ClassProperty",kind) || kind!=hit->kind ||
        !Local(script,function,locals,L"DamageCauser",L"ObjectProperty",causer) || causer!=hit->causer ||
        !Local(script,function,locals,L"HitLocation",L"StructProperty",point) ||
        point.x!=hit->location.x || point.y!=hit->location.y || point.z!=hit->location.z) return;
    ScriptField info{};
    if (!Parameter(script,function,L"HitInfo",L"StructProperty",hit->size,info)) return;
    // Check against every stock argument before changing only the missing hit
    // metadata. Damage, momentum, controller and causer remain stock outputs.
    struct Other { const wchar_t* name; const wchar_t* kind; std::size_t size; };
    const std::array<Other,6> others{{
        {L"Damage",L"IntProperty",sizeof(std::int32_t)},
        {dying ? L"EventInstigator" : L"InstigatedBy",L"ObjectProperty",sizeof(void*)},
        {L"HitLocation",L"StructProperty",sizeof(point)}, {L"Momentum",L"StructProperty",sizeof(point)},
        {L"DamageType",L"ClassProperty",sizeof(void*)}, {L"DamageCauser",L"ObjectProperty",sizeof(void*)}
    }};
    for (const auto& other:others) {
        ScriptField field{};
        if (!Parameter(script,function,other.name,other.kind,other.size,field) || !Disjoint(info,field)) return;
    }
    auto* address=static_cast<std::byte*>(locals)+info.offset;
    if (info.size>original_.size() || !GuardedCopy(original_.data(),address,info.size)) return;
    // ApplyMeleeDamage omits HitInfo. An unexpected nonempty value is not ours
    // to overwrite, even inside the correctly matched synchronous scope.
    for (std::size_t i=0;i<info.size;++i) if (original_[i]!=std::byte{}) return;
    if (!GuardedCopy(address,hit->hitInfo,info.size)) return;
    patched_=address;
    patchSize_=info.size;
    hit->used=true;
}

SwipeDispatchScope::~SwipeDispatchScope() {
    if (patched_) GuardedCopy(patched_,original_.data(),patchSize_);
    if (frame_) swipeCalls=frame_->previous;
}

bool RouteHeldSwipeContact(GameScript& script,void* helper,void* function,const void* locals) {
    if (routingSwipe || !locals || !function ||
        GameScript::ObjectName(function)!=script.Intern(L"ResolvePawnMeleeDamage") ||
        !ExactHelper(script,helper,function,L"ResolvePawnMeleeDamage")) return false;
    auto* candidate=swipeCalls ? swipeCalls->previous : nullptr;
    auto* swipe=candidate ? candidate->previous : nullptr;
    if (!candidate || !swipe || candidate->helper!=helper || swipe->helper!=helper ||
        !ExactHelper(script,helper,candidate->function,L"ProcessSwipeHit") ||
        !ExactHelper(script,helper,swipe->function,L"DoSwipeImpact")) return false;
    void* victim=nullptr;
    void* accepted=nullptr;
    void* enumerated=nullptr;
    void* kind=nullptr;
    void* candidateKind=nullptr;
    std::int32_t damage=0,candidateDamage=0;
    float momentum=0,candidateMomentum=0,range=0;
    pinned::NativeVector3 coneStart{},coneDirection{},start{},end{};
    if (!Local(script,function,locals,L"Victim",L"ObjectProperty",victim) || !script.IsClass(victim,L"KFPawn_Human") ||
        !Local(script,function,locals,L"Damage",L"IntProperty",damage) ||
        !Local(script,function,locals,L"Momentum",L"FloatProperty",momentum) || !std::isfinite(momentum) ||
        !Local(script,function,locals,L"InDamageType",L"ClassProperty",kind) || !script.IsClass(kind,L"Class") ||
        !Local(script,candidate->function,candidate->locals,L"A",L"ObjectProperty",accepted) || accepted!=victim ||
        !Local(script,candidate->function,candidate->locals,L"Damage",L"IntProperty",candidateDamage) || candidateDamage!=damage ||
        !Local(script,candidate->function,candidate->locals,L"MomentumScalar",L"FloatProperty",candidateMomentum) || candidateMomentum!=momentum ||
        !Local(script,candidate->function,candidate->locals,L"InDamageType",L"ClassProperty",candidateKind) || candidateKind!=kind ||
        !Local(script,swipe->function,swipe->locals,L"P",L"ObjectProperty",enumerated) || enumerated!=victim ||
        !Local(script,swipe->function,swipe->locals,L"ConeStart",L"StructProperty",coneStart) || !Finite(coneStart) ||
        !Local(script,swipe->function,swipe->locals,L"ConeDir",L"StructProperty",coneDirection) || !Finite(coneDirection) ||
        !Local(script,swipe->function,swipe->locals,L"ConeRange",L"FloatProperty",range) || !std::isfinite(range) || range<=0 || range>2048) return false;
    void* outer=nullptr;
    void* instigator=nullptr;
    void* attacker=nullptr;
    void* world=nullptr;
    float eye=0;
    unsigned char role=0;
    if (!ObjectValue(script,helper,L"Outer",outer) || !script.IsClass(outer,L"KFPawn_Monster") ||
        !ObjectValue(script,outer,L"Instigator",instigator) || instigator!=outer ||
        !ObjectValue(script,outer,L"Controller",attacker) || !script.IsClass(attacker,L"Controller") ||
        !ObjectValue(script,outer,L"Role",role) || role!=3 ||
        !ObjectValue(script,outer,L"WorldInfo",world) || !script.IsClass(world,L"WorldInfo") ||
        !ObjectValue(script,outer,L"Location",start) || !Finite(start) ||
        !ObjectValue(script,victim,L"Location",end) || !Finite(end) ||
        !ObjectValue(script,victim,L"BaseEyeHeight",eye) || !std::isfinite(eye)) return false;
    end.z+=eye;
    auto* mutator=BreacherReceiver(script,world);
    auto* notify=mutator ? script.FindFunction(mutator,L"NativeHeldSwipeContact") : nullptr;
    auto* apply=script.FindFunction(helper,L"ApplyMeleeDamage");
    if (!notify || !apply || !ExactHelper(script,helper,apply,L"ApplyMeleeDamage")) return false;

    struct Arg { const wchar_t* name; const wchar_t* kind; std::size_t size; const void* value; };
    const std::array<Arg,12> args{{
        {L"Helper",L"ObjectProperty",sizeof(helper),&helper}, {L"Victim",L"ObjectProperty",sizeof(victim),&victim},
        {L"ConeStart",L"StructProperty",sizeof(coneStart),&coneStart}, {L"ConeDirection",L"StructProperty",sizeof(coneDirection),&coneDirection},
        {L"ConeRange",L"FloatProperty",sizeof(range),&range}, {L"SegmentStart",L"StructProperty",sizeof(start),&start},
        {L"SegmentEnd",L"StructProperty",sizeof(end),&end}, {L"Body",L"ObjectProperty",sizeof(void*),nullptr},
        {L"ContactPoint",L"StructProperty",sizeof(start),nullptr}, {L"HitInfo",L"StructProperty",0,nullptr},
        {L"ReturnValue",L"BoolProperty",sizeof(std::uint32_t),nullptr}, {L"AttackKind",L"ClassProperty",sizeof(kind),&kind}
    }};
    std::array<ScriptField,args.size()> fields{};
    alignas(16) std::array<std::byte,ParameterCapacity> parameters{};
    for (std::size_t i=0;i<args.size();++i) {
        if (!Parameter(script,notify,args[i].name,args[i].kind,args[i].size,fields[i])) return false;
        for (std::size_t j=0;j<i;++j) if (!Disjoint(fields[i],fields[j])) return false;
        if (args[i].value) std::memcpy(parameters.data()+fields[i].offset,args[i].value,args[i].size);
    }
    struct RouteScope { RouteScope() { routingSwipe=true; } ~RouteScope() { routingSwipe=false; } } route;
    if (!script.Invoke(mutator,notify,parameters.data())) return false;
    std::uint32_t blocked=0;
    MeleeBodyHit contact{};
    std::memcpy(&blocked,parameters.data()+fields[10].offset,sizeof(blocked));
    std::memcpy(&contact.body,parameters.data()+fields[7].offset,sizeof(contact.body));
    std::memcpy(&contact.location,parameters.data()+fields[8].offset,sizeof(contact.location));
    if (!blocked || !script.IsClass(contact.body,L"KFPawn_Monster") || !Finite(contact.location) ||
        (contact.location.x==0 && contact.location.y==0 && contact.location.z==0)) return false;
    for (std::size_t i=0;i<swipe->damagedCount;++i)
        if (swipe->damagedBodies[i]==contact.body) return true;
    // This attack can block several candidates behind one body, but may
    // damage/charge that body only once. Storage belongs to this VM frame.
    if (swipe->damagedCount==swipe->damagedBodies.size()) return false;
    contact.helper=helper; contact.attacker=attacker; contact.causer=outer; contact.kind=kind;
    contact.hitInfo=parameters.data()+fields[9].offset; contact.size=fields[9].size;
    const std::array<Arg,5> applyArgs{{
        {L"Victim",L"ObjectProperty",sizeof(contact.body),&contact.body}, {L"Damage",L"IntProperty",sizeof(damage),&damage},
        {L"InMomentum",L"FloatProperty",sizeof(momentum),&momentum}, {L"InDamageType",L"ClassProperty",sizeof(kind),&kind},
        {L"HitLocation",L"StructProperty",sizeof(contact.location),&contact.location}
    }};
    std::array<ScriptField,applyArgs.size()> applyFields{};
    alignas(16) std::array<std::byte,ParameterCapacity> applyParameters{};
    for (std::size_t i=0;i<applyArgs.size();++i) {
        if (!Parameter(script,apply,applyArgs[i].name,applyArgs[i].kind,applyArgs[i].size,applyFields[i])) return false;
        for (std::size_t j=0;j<i;++j) if (!Disjoint(applyFields[i],applyFields[j])) return false;
        std::memcpy(applyParameters.data()+applyFields[i].offset,applyArgs[i].value,applyArgs[i].size);
    }
    struct HitScope {
        MeleeBodyHit* previous;
        explicit HitScope(MeleeBodyHit& hit) : previous(meleeBodyHit) { meleeBodyHit=&hit; }
        ~HitScope() { meleeBodyHit=previous; }
    } hitScope(contact);
    swipe->damagedBodies[swipe->damagedCount++]=contact.body;
    const bool applied=script.Invoke(helper,apply,applyParameters.data());
    if (!applied) swipe->damagedBodies[--swipe->damagedCount]=nullptr;
    return applied;
}

RadiusDamageScope::RadiusDamageScope(GameScript& script,void* pawn,void* function)
    : previous_(inBoneRadiusDamage) {
    if (!function || GameScript::ObjectName(function)!=script.Intern(L"TakeRadiusDamageOnBones") ||
        !script.IsClass(pawn,L"Pawn")) return;
    unsigned char role=0;
    if (!ObjectValue(script,pawn,L"Role",role) || role!=3) return;
    auto* type=GameScript::ObjectClass(pawn);
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        if (GameScript::ObjectName(type)!=script.Intern(L"Pawn")) continue;
        if (DirectChild(script,type,L"TakeRadiusDamageOnBones",L"Function")==function)
            inBoneRadiusDamage=true;
        break;
    }
}

RadiusDamageScope::~RadiusDamageScope() {
    // Saved state uses constant storage and restores arbitrary synchronous
    // nesting without a counter that could overflow or lose an outer scope.
    inBoneRadiusDamage=previous_;
}

bool RouteHeldHuskContact(GameScript& script,void* projectile,void* function,const void* locals) {
    if (!function || !locals || GameScript::ObjectName(function)!=script.Intern(L"ProcessTouch") ||
        GameScript::ObjectName(GameScript::ObjectClass(projectile))!=script.Intern(L"KFProj_Husk_Fireball") ||
        DirectChild(script,GameScript::ObjectClass(projectile),L"ProcessTouch",L"Function")!=function) return false;
    // A synchronous explosion callback may re-enter this same projectile. It
    // is already owned by the outer contact and must not execute a second hit.
    unsigned contactDepth=0;
    for (auto* frame=handlingHusk;frame;frame=frame->previous) {
        if (++contactDepth>16) return false;
        if (frame->projectile==projectile) return true;
    }
    if (contactDepth==16) return false;
    unsigned char role=0,mode=255;
    void* world=nullptr;
    if (!ObjectValue(script,projectile,L"Role",role) || role!=3 ||
        !ObjectValue(script,projectile,L"WorldInfo",world) || !script.IsClass(world,L"WorldInfo") ||
        !ObjectValue(script,world,L"NetMode",mode) || mode>2) return false;
    void* victim=nullptr;
    void* contact=nullptr;
    void* mesh=nullptr;
    void* victimWorld=nullptr;
    pinned::NativeVector3 location{},normal{};
    std::array<ScriptField,3> source{};
    if (!Parameter(script,function,L"Other",L"ObjectProperty",sizeof(void*),source[0]) ||
        !Parameter(script,function,L"HitLocation",L"StructProperty",sizeof(location),source[1]) ||
        !Parameter(script,function,L"HitNormal",L"StructProperty",sizeof(normal),source[2]) ||
        !Disjoint(source[0],source[1]) || !Disjoint(source[0],source[2]) || !Disjoint(source[1],source[2])) return false;
    if (!ReadScriptLocal(function,locals,script.Intern(L"Other"),victim) || !script.IsClass(victim,L"KFPawn_Monster") ||
        !ReadScriptLocal(function,locals,script.Intern(L"HitLocation"),location) || !Finite(location) ||
        !ReadScriptLocal(function,locals,script.Intern(L"HitNormal"),normal) || !Finite(normal) ||
        !ObjectValue(script,projectile,L"LastTouchComponent",contact) || !contact ||
        !ObjectValue(script,victim,L"Mesh",mesh) || contact!=mesh ||
        !ObjectValue(script,victim,L"WorldInfo",victimWorld) || victimWorld!=world) return false;
    auto* mutator=BreacherReceiver(script,world);
    if (!mutator) return false;
    auto* notify=script.FindFunction(mutator,L"NativeHeldHuskContact");
    if (!notify) return false;
    struct Argument { const wchar_t* name; const wchar_t* kind; const void* value; std::size_t size; };
    const std::array<Argument,5> args{{
        {L"Shot",L"ObjectProperty",&projectile,sizeof(projectile)},
        {L"Victim",L"ObjectProperty",&victim,sizeof(victim)},
        {L"HitLocation",L"StructProperty",&location,sizeof(location)},
        {L"HitNormal",L"StructProperty",&normal,sizeof(normal)},
        {L"ContactComponent",L"ObjectProperty",&contact,sizeof(contact)}
    }};
    std::array<ScriptField,5> fields{};
    ScriptField returned{};
    if (!Parameter(script,notify,L"ReturnValue",L"BoolProperty",sizeof(std::int32_t),returned)) return false;
    alignas(16) std::array<std::byte,ParameterCapacity> parameters{};
    for (std::size_t i=0;i<args.size();++i) {
        const auto& a=args[i];
        if (!Parameter(script,notify,a.name,a.kind,a.size,fields[i]) || !Disjoint(returned,fields[i])) return false;
        for (std::size_t j=0;j<i;++j) if (!Disjoint(fields[i],fields[j])) return false;
        std::memcpy(parameters.data()+fields[i].offset,a.value,a.size);
    }
    struct ContactScope {
        HuskContactFrame frame;
        explicit ContactScope(void* shot) : frame{shot,handlingHusk} { handlingHusk=&frame; }
        ~ContactScope() { handlingHusk=frame.previous; }
    } scope(projectile);
    if (!script.Invoke(mutator,notify,parameters.data())) return false;
    std::int32_t consumed=0;
    std::memcpy(&consumed,parameters.data()+returned.offset,sizeof(consumed));
    // Do not dereference the projectile after the callback: Shutdown can destroy it.
    return consumed!=0;
}

void ObserveCorpseDamage(GameScript& script,void* victim,void* function,const void* locals) {
    NotifyDamage(script,victim,function,locals,true);
}

LiveDamageScope::LiveDamageScope(GameScript& script,void* victim,void* function,const void* locals)
    : script_(script) {
    if (!victim) return;
    mutator_=NotifyDamage(script,victim,function,locals,false);
    if (mutator_) {
        victim_=victim;
        ObjectValue(script_,mutator_,L"WorldInfo",world_);
    }
}

LiveDamageScope::~LiveDamageScope() {
    if (!mutator_ || notifying || !script_.IsClass(mutator_,L"BreacherMutator")) return;
    void* world=nullptr;
    if (!ObjectValue(script_,mutator_,L"WorldInfo",world) || world!=world_) return;
    auto* end=script_.FindFunction(mutator_,L"NativeLiveDamageEnd");
    ScriptField field{};
    if (!end || !Parameter(script_,end,L"Victim",L"ObjectProperty",sizeof(void*),field)) return;
    alignas(16) std::array<std::byte,ParameterCapacity> parameters{};
    std::memcpy(parameters.data()+field.offset,&victim_,sizeof(victim_));
    struct NotifyGuard { NotifyGuard() { notifying=true; } ~NotifyGuard() { notifying=false; } } guard;
    script_.Invoke(mutator_,end,parameters.data());
}

} // namespace kf2vr::adapter
