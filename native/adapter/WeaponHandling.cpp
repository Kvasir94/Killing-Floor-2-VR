#include "WeaponHandling.h"
#include "ScriptField.h"

namespace kf2vr::adapter {
namespace {

bool FieldMatches(GameScript& script, void* function, const wchar_t* name,
                  std::size_t offset, std::size_t size) {
    ScriptField field{};
    return FindScriptField(function,script.Intern(name),field) && field.offset==offset && field.size==size;
}

int QueryPolicy(GameScript& script, void* bridge, void* weapon) {
    struct Parameters { void* weapon; std::int32_t result; } params{weapon,-1};
    auto* function=script.FindFunction(bridge,L"GetWeaponHandlingPolicy");
    if (!FieldMatches(script,function,L"W",offsetof(Parameters,weapon),sizeof(params.weapon)) ||
        !FieldMatches(script,function,L"ReturnValue",offsetof(Parameters,result),sizeof(params.result)) ||
        !script.Invoke(bridge,function,&params)) {
        script.Write(bridge,L"NativeHandlingFault",2);
        return -1;
    }
    return params.result>=0 && params.result<=1 ? params.result : -1;
}

int ApplySights(GameScript& script, void* bridge, void* weapon, int policy) {
    struct Parameters { void* weapon; std::int32_t policy, result; } params{weapon,policy,0};
    auto* function=script.FindFunction(bridge,L"ApplyBallisticSights");
    if (!FieldMatches(script,function,L"W",offsetof(Parameters,weapon),sizeof(params.weapon)) ||
        !FieldMatches(script,function,L"Policy",offsetof(Parameters,policy),sizeof(params.policy)) ||
        !FieldMatches(script,function,L"ReturnValue",offsetof(Parameters,result),sizeof(params.result)) ||
        !script.Invoke(bridge,function,&params)) {
        script.Write(bridge,L"NativeHandlingFault",3);
        return 0;
    }
    return params.result>=1 && params.result<=2 ? params.result : 0;
}

void RestoreSights(GameScript& script, void* bridge, void* weapon, int saved) {
    struct Parameters { void* weapon; std::int32_t saved; } params{weapon,saved};
    auto* function=script.FindFunction(bridge,L"RestoreBallisticSights");
    if (!FieldMatches(script,function,L"W",offsetof(Parameters,weapon),sizeof(params.weapon)) ||
        !FieldMatches(script,function,L"Saved",offsetof(Parameters,saved),sizeof(params.saved)) ||
        !script.Invoke(bridge,function,&params)) script.Write(bridge,L"NativeHandlingFault",4);
}

} // namespace

WeaponHandlingStack::Scope::~Scope() {
    if (!active_) return;
    if (savedSights_) RestoreSights(script_,bridge_,weapon_,savedSights_);
    stack_.top_=parent_;
}

void WeaponHandlingStack::Scope::Enter(void* bridge, void* weapon, int policy, bool applySights) {
    if (active_) return;
    parent_=stack_.top_;
    bridge_=bridge;
    weapon_=weapon;
    policy_=policy;
    stack_.top_=this;
    active_=true;
    if (applySights && policy>=0) savedSights_=ApplySights(script_,bridge,weapon,policy);
}

void BeginWeaponHandling(GameScript& script, WeaponHandlingStack& stack,
                         WeaponHandlingStack::Scope& scope, void* bridge,
                         void* pawn, void* controller, void* object, void* function) {
    const auto name=GameScript::ObjectName(function);
    const bool shot=name==script.Intern(L"FireAmmunition");
    const bool spread=name==script.Intern(L"AddSpread");
    const bool recoil=name==script.Intern(L"HandleRecoil");
    const bool view=name==script.Intern(L"ProcessViewRotation") && object==controller;
    if ((!shot && !spread && !recoil && !view) || !bridge || !pawn || !controller ||
        script.Read<int>(bridge,L"NativeHandlingEnabled")!=1 ||
        script.Read<void*>(bridge,L"PC")!=controller || script.Read<void*>(bridge,L"Human")!=pawn ||
        script.Read<void*>(controller,L"Pawn")!=pawn) return;
    auto* weapon=view ? script.Read<void*>(pawn,L"Weapon") : object;
    if (!script.IsClass(weapon,L"KFWeapon")) return;
    int policy=-1;
    // The same item's super/nested calls reuse its accepted shot policy. A
    // different item (including an unsupported tool) shadows that policy.
    if (!stack.CurrentPolicy(weapon,policy)) policy=QueryPolicy(script,bridge,weapon);
    scope.Enter(bridge,weapon,policy,spread || recoil || view);
}

} // namespace kf2vr::adapter
