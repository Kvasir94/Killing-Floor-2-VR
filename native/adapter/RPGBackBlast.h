#pragma once

#include "GameScript.h"
#include "kf2vr/adapter/VerifiedLayout.h"
#include "kf2vr/Basis.h"

namespace kf2vr::adapter {

// KFGame.exe's execLocalOutVariable (RVA 0x5f4e0) resolves references through
// FFrame+0x3c: each record is { UProperty*, address, next }. Writing VM locals
// alone does not update a script caller's out vector/rotator.
inline void* RPGOutParameter(void* function, void* stack, GameScript::Name name, std::size_t size) {
    void* property=nullptr;
    auto* child=GameScript::Children(function);
    for (unsigned count=0;child && count<128;++count,child=GameScript::NextField(child)) {
        if (GameScript::ObjectName(child)==name &&
            GameScript::At<std::int32_t>(child,0x6c)==static_cast<std::int32_t>(size)) {
            property=child; break;
        }
    }
    if (!property) return nullptr;
    auto* record=GameScript::At<void*>(stack,0x3c);
    for (unsigned count=0;record && count<16;++count) {
        if (!GameScript::Accessible(record,24)) return nullptr;
        if (GameScript::At<void*>(record,0)==property) {
            auto* address=GameScript::At<void*>(record,8);
            return GameScript::Accessible(address,size) ? address : nullptr;
        }
        record=GameScript::At<void*>(record,16);
    }
    return nullptr;
}

inline bool RouteRPGBackBlast(GameScript& script, void* bridge, void* weapon, void* function, void* stack) {
    auto* locationOut=RPGOutParameter(function,stack,script.Intern(L"BlastLocation"),sizeof(Vec3));
    auto* rotationOut=RPGOutParameter(function,stack,script.Intern(L"BlastRotation"),sizeof(pinned::NativeRotator));
    // Resolve both references before writing either one. If reflection or the
    // tracked item is unavailable, let KF2 execute its original function.
    if (!locationOut || !rotationOut) return false;
    struct Parameters { void* weapon; } parameters{weapon};
    if (!script.Write(bridge,L"NativeBackBlastReady",0) ||
        !script.Invoke(bridge,script.FindFunction(bridge,L"ResolveRPGBackBlast"),&parameters) ||
        script.Read<int>(bridge,L"NativeBackBlastReady")!=1) return false;
    const auto location=script.Read<Vec3>(bridge,L"NativeBackBlastLocation");
    const auto rotation=script.Read<pinned::NativeRotator>(bridge,L"NativeBackBlastRotation");
    std::memcpy(locationOut,&location,sizeof(location));
    std::memcpy(rotationOut,&rotation,sizeof(rotation));
    return true;
}

} // namespace kf2vr::adapter
