#pragma once
#include "GameScript.h"
#include "ScriptField.h"

namespace kf2vr::adapter {
// Select exactly one stock damage callback, then restore the outer selection.
// No custom damage multiplier or second shield callback is introduced.
class ShieldDefenseScope {
    GameScript& script_;
    void* pawn_{};
    void* saved_{};
public:
    ShieldDefenseScope(GameScript& script,void* ledger,void* pawn,void* function):script_(script) {
        if (!ledger || !pawn) return;
        const auto name=GameScript::ObjectName(function);
        if (name!=script.Intern(L"AdjustDamage") && name!=script.Intern(L"PlayTakeHitEffects")) return;
        bool base=false;
        auto* type=GameScript::ObjectClass(pawn);
        for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
            if (GameScript::ObjectName(type)!=script.Intern(L"KFPawn")) continue;
            auto* child=GameScript::Children(type);
            for (unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child))
                if (child==function) { base=true;break; }
            break;
        }
        if (!base) return;
        auto* resolve=script.FindFunction(ledger,L"ResolveShieldDefender");
        ScriptField result{};
        if (!resolve || !FindScriptFieldUncached(resolve,script.Intern(L"ReturnValue"),result)
            || result.offset!=0 || result.size!=sizeof(void*)) return;
        struct Params { void* weapon{}; } p;
        if (!script.Invoke(ledger,resolve,&p)) return;
        saved_=script.Read<void*>(pawn,L"MyKFWeapon");
        if (!p.weapon && !script.IsClass(saved_,L"KFWeap_SMG_G18")) return;
        if (p.weapon && (!script.IsClass(p.weapon,L"KFWeap_SMG_G18")
            || script.Read<void*>(p.weapon,L"Instigator")!=pawn)) return;
        if (script.Write(pawn,L"MyKFWeapon",p.weapon)) pawn_=pawn;
    }
    ~ShieldDefenseScope() { if (pawn_) script_.Write(pawn_,L"MyKFWeapon",saved_); }
    ShieldDefenseScope(const ShieldDefenseScope&)=delete;
    ShieldDefenseScope& operator=(const ShieldDefenseScope&)=delete;
};
}
