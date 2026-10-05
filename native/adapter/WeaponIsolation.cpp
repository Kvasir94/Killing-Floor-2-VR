#include "WeaponIsolation.h"
#include "ScriptField.h"

namespace kf2vr::adapter {
namespace {

void ReturnInt(void* result, std::int32_t value) {
    // UnrealScript bool function results use a 32-bit UBOOL, not C++ bool.
    if (GameScript::Accessible(result,sizeof(value))) std::memcpy(result,&value,sizeof(value));
}

void Count(GameScript& script, void* object, const wchar_t* field) {
    const auto value=script.Read<std::uint32_t>(object,field);
    if (value<0x7fffffff) script.Write(object,field,value+1);
}

// The registry owns script references, so native never holds an actor pointer
// across ticks/GC/possession. Preserve the ingress even on nested VM calls.
} // namespace

bool ResolveInventoryItem(GameScript& script, void* inventory, void* weapon, void*& state) {
    auto* savedItem=script.Read<void*>(inventory,L"NativeQueryWeapon");
    auto* savedState=script.Read<void*>(inventory,L"NativeQueryRuntime");
    state=nullptr;
    if (!script.Write(inventory,L"NativeQueryWeapon",weapon) ||
        !script.Write(inventory,L"NativeQueryRuntime",state)) {
        script.Write(inventory,L"NativeQueryWeapon",savedItem);
        script.Write(inventory,L"NativeQueryRuntime",savedState);
        return false;
    }
    const bool invoked=script.Invoke(inventory,script.FindFunction(inventory,L"ResolveNativeItem"),nullptr);
    if (invoked) state=script.Read<void*>(inventory,L"NativeQueryRuntime");
    const bool restoredItem=script.Write(inventory,L"NativeQueryWeapon",savedItem);
    const bool restoredState=script.Write(inventory,L"NativeQueryRuntime",savedState);
    return invoked && restoredItem && restoredState;
}

bool RouteItemPendingFire(GameScript& script, void* bridge, void* pawn,
                          void* object, void* function, const void* locals, void* result) {
    if (!bridge || !pawn) return false;
    auto* inventory=script.Read<void*>(bridge,L"HeldInventory");
    if (!inventory || script.Read<void*>(inventory,L"PC")!=script.Read<void*>(bridge,L"PC")) return false;
    return RouteInventoryPendingFire(script,inventory,pawn,object,function,locals,result);
}

bool RouteInventoryPendingFire(GameScript& script, void* inventory, void* pawn,
                               void* object, void* function, const void* locals, void* result) {
    if (!inventory || !pawn || script.Read<int>(inventory,L"NativeRoutingEnabled")!=1 ||
        script.Read<void*>(inventory,L"Human")!=pawn) return false;
    const auto name=GameScript::ObjectName(function);
    const bool length=name==script.Intern(L"GetPendingFireLength");
    const bool get=name==script.Intern(L"PendingFire") || name==script.Intern(L"IsPendingFire");
    const bool set=name==script.Intern(L"SetPendingFire");
    const bool clear=name==script.Intern(L"ClearPendingFire");
    const bool clearAll=name==script.Intern(L"ClearAllPendingFire");
    if (!length && !get && !set && !clear && !clearAll) return false;
    // Void setters/clearers have no reflected return storage. Only synthesize
    // a value for the integer/bool getters when failing a managed call closed.
    const auto failResult=[&] { if (length || get) ReturnInt(result,0); };

    auto* manager=script.Read<void*>(pawn,L"InvManager");
    const bool managerCall=object && object==manager;
    void* weapon=nullptr;
    if (managerCall) {
        if (!ReadScriptLocal(function,locals,script.Intern(L"InWeapon"),weapon)) {
            script.Write(inventory,L"NativeFault",1);
            failResult();
            return true;
        }
    } else if (script.IsClass(object,L"KFWeapon")) weapon=object;
    else return false;
    if (!weapon || script.Read<void*>(weapon,L"Instigator")!=pawn ||
        script.Read<void*>(weapon,L"InvManager")!=manager) return false;

    void* state=nullptr;
    if (!ResolveInventoryItem(script,inventory,weapon,state)) {
        script.Write(inventory,L"NativeFault",2);
        failResult();
        return true;
    }
    if (!state) return false; // An unregistered weapon keeps its stock behavior.
    if (script.Read<void*>(state,L"Inventory")!=inventory || script.Read<void*>(state,L"Item")!=weapon ||
        script.Read<int>(state,L"NativeReady")!=1) {
        script.Write(inventory,L"NativeFault",3);
        failResult();
        return true;
    }
    const auto count=script.Read<std::int32_t>(state,L"PendingFireCount");
    if (count<=0 || count>32) {
        script.Write(inventory,L"NativeFault",4);
        failResult();
        return true;
    }
    Count(script,inventory,managerCall?L"NativeManagerCalls":L"NativeWeaponCalls");
    if (length) { ReturnInt(result,count); return true; }
    if (clearAll) {
        if (!script.Write(state,L"PendingFireMask",std::uint32_t{})) script.Write(inventory,L"NativeFault",5);
        return true;
    }
    std::int32_t mode=-1;
    if (!ReadScriptLocal(function,locals,script.Intern(managerCall?L"InFiringMode":L"FireMode"),mode)) {
        script.Write(inventory,L"NativeFault",6);
        failResult();
        return true;
    }
    // Reject malformed modes without touching another bit or the stock array.
    if (mode<0 || mode>=count) { failResult(); return true; }
    const auto bit=std::uint32_t{1}<<mode;
    const auto mask=script.Read<std::uint32_t>(state,L"PendingFireMask");
    if (get) ReturnInt(result,(mask&bit)?1:0);
    else if (!script.Write(state,L"PendingFireMask",set?(mask|bit):(mask&~bit)))
        script.Write(inventory,L"NativeFault",7);
    return true;
}

} // namespace kf2vr::adapter
