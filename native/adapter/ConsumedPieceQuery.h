#pragma once
#include "GameScript.h"
#include <array>
#include <intrin.h>

namespace kf2vr::adapter::consumedQuery {
using MatchBone=int(*)(void*,GameScript::Name);
inline MatchBone original=nullptr;
inline std::uintptr_t imageBase=0;
inline std::uintptr_t matchRva=0;
inline std::array<std::uintptr_t,3> callers{};
inline GameScript::ReflectionProfile reflection{};
inline bool (*onOwnerThread)()=nullptr;
struct ScriptArray { void* data; std::int32_t count,max; };

// Only the three PhysicsAsset query loops may hide a consumed body's bone.
// Steam: LineCheck802770 calls MatchRefBone74bc40, return8029ec skips -1
// before geometry802b2b and nearest-hit selection802b35. AllInteractions
// return803283 and PointCheck return804b6d have the same pre-query skip.
// Dedicated pinned2ea16bb5: MatchRefBone6feb50 is byte-normalized identical;
// its query returns below retain the same component/FName ABI and -1 branch.
// Ordinary animation, physics, script and grab calls always retain stock results.
inline bool Configure(std::uintptr_t base,bool server,bool (*ownerThread)()) {
    imageBase=base;
    matchRva=server ? 0x6feb50 : 0x74bc40;
    callers=server ? std::array<std::uintptr_t,3>{0x7a9d4c,0x7aa5e3,0x7abf7d} :
        std::array<std::uintptr_t,3>{0x8029ec,0x803283,0x804b6d};
    reflection=server ? GameScript::ReflectionProfile{0xc3b70,0xc8f40,0x210,0x7b200} : GameScript::ReflectionProfile{};
    onOwnerThread=ownerThread;
    constexpr unsigned char entry[]{0x48,0x83,0xec,0x28,0x33,0xc0};
    std::array<unsigned char,sizeof(entry)> actual{};
    if (!base || !ownerThread || !GuardedCopy(actual.data(),reinterpret_cast<void*>(base+matchRva),actual.size()) ||
        std::memcmp(actual.data(),entry,sizeof(entry))) return false;
    for (auto site:callers) {
        std::array<unsigned char,5> call{};
        if (!GuardedCopy(call.data(),reinterpret_cast<void*>(base+site-5),call.size()) || call[0]!=0xe8) return false;
        std::int32_t displacement=0;
        std::memcpy(&displacement,call.data()+1,sizeof(displacement));
        if (base+site+displacement!=base+matchRva) return false;
    }
    return true;
}

inline bool Consumed(GameScript& script,void* mesh,int bone) {
    if (!mesh || bone<0 || bone>=1024) return false;
    auto* owner=script.Read<void*>(mesh,L"Owner");
    if (!owner || script.Read<void*>(owner,L"Mesh")!=mesh || !script.IsClass(owner,L"KFPawn_Monster")) return false;
    const auto children=script.Read<ScriptArray>(owner,L"Children");
    if (children.count<=0 || children.count>128 || children.max<children.count || children.max>4096 ||
        !GameScript::Accessible(children.data,sizeof(void*)*children.count)) return false;
    const auto markerName=script.Intern(L"BreacherConsumedPiece");
    const auto world=script.Read<void*>(owner,L"WorldInfo");
    if (!world) return false;
    for (int i=0;i<children.count;++i) {
        auto* marker=GameScript::At<void*>(children.data,sizeof(void*)*i);
        if (GameScript::ObjectName(GameScript::ObjectClass(marker))!=markerName ||
            script.Read<void*>(marker,L"Owner")!=owner || script.Read<void*>(marker,L"Payload")!=owner ||
            script.Read<void*>(marker,L"WorldInfo")!=world ||
            script.Read<void*>(marker,L"NativeConsumedMesh")!=mesh ||
            script.Read<int>(marker,L"NativeConsumedReady")!=1) continue;
        const int count=script.Read<int>(marker,L"NativeConsumedCount");
        if (count<=0 || count>1024) continue;
        const auto offset=script.FieldOffset(GameScript::ObjectClass(marker),script.Intern(L"NativeConsumedIndices"));
        if (!offset) continue;
        std::array<std::int32_t,1024> indices;
        if (!GuardedCopy(indices.data(),static_cast<const std::byte*>(marker)+offset,sizeof(std::int32_t)*count)) continue;
        bool valid=true,found=false;
        for (int j=0;j<count;++j) {
            if (indices[j]<0 || indices[j]>=1024) { valid=false; break; }
            if (indices[j]==bone) found=true;
        }
        if (valid && found) return true;
    }
    return false;
}

__declspec(noinline) inline int Hook(void* mesh,GameScript::Name name) {
    const auto caller=reinterpret_cast<std::uintptr_t>(_ReturnAddress())-imageBase;
    const int bone=original(mesh,name);
    if (bone<0 || !onOwnerThread || !onOwnerThread() ||
        (caller!=callers[0] && caller!=callers[1] && caller!=callers[2])) return bone;
    thread_local GameScript script(imageBase,reflection);
    return Consumed(script,mesh,bone) ? -1 : bone;
}
}
