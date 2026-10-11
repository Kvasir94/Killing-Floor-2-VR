#pragma once
#include "ConsumedPieceMask.h"
#include "GameScript.h"
#include "include/kf2vr/adapter/LocalWorldGate.h"

namespace kf2vr::adapter {
struct ConsumedScriptArray { void* data; std::int32_t count,max; };

struct ConsumedPublication {
    using Update=void(*)(void*,std::int32_t,void*,void*);
    void* object{};
    void* morphs{};
    std::int32_t lod{};
    Update update{};
};

// Steam SHA256 77ab9c2c...885c994, offline disassembly: skeletal constructor
// 73d060 -> vtable1871290; UpdateTransform slot278 ->755e30. Its756a7f
// call publishes (MeshObject, PredictedLODLevel, component, ActiveMorphs).
// Attach73ff20 constructs only78ccc0/78cb30; those install the two tables
// below. Update7b3a10/7b3890 copy dynamic skin data before enqueueing it.
// Calling UpdateTransform instead would reapply hierarchical bone visibility
// at756990 and overwrite the exact connected-piece mask. No bool-bit writes.
inline ConsumedPublication PrepareConsumedPublication(GameScript& script,void* mesh,std::uintptr_t base) {
    ConsumedPublication out{};
    if (build::selected!=build::Store::Steam || !base || !mesh ||
        !(GameScript::At<std::uint32_t>(mesh,0x80)&1) ||
        GameScript::At<void*>(mesh,0x360)) return out;
    const auto meshTable=GameScript::At<void*>(mesh,0);
    if (GameScript::At<std::uintptr_t>(meshTable,0x278)!=base+0x755e30) return out;
    const auto type=GameScript::ObjectClass(mesh);
    if (script.FieldOffset(type,script.Intern(L"MeshObject"))!=0x2f0 ||
        script.FieldOffset(type,script.Intern(L"ActiveMorphs"))!=0x3a8 ||
        script.FieldOffset(type,script.Intern(L"PredictedLODLevel"))!=0x448 ||
        script.FieldOffset(type,script.Intern(L"SpaceBases"))!=0x2fc) return out;
    auto* object=GameScript::At<void*>(mesh,0x2f0);
    const auto table=GameScript::At<std::uintptr_t>(object,0);
    const auto target=table==base+0x187daa0 ? base+0x7b3a10 :
        table==base+0x187d7f0 ? base+0x7b3890 : 0;
    if (!target || GameScript::At<std::uintptr_t>(reinterpret_cast<void*>(table),0x20)!=target) return out;
    auto* skeleton=GameScript::At<void*>(mesh,0x248);
    if (!skeleton || GameScript::At<void*>(object,0x4c)!=skeleton) return out;
    const int lod=GameScript::At<std::int32_t>(mesh,0x448);
    const int models=GameScript::At<std::int32_t>(skeleton,0x128);
    const int info=GameScript::At<std::int32_t>(skeleton,0x194);
    if (models<=0 || models>32 || info<=0 || info>32 || lod<0 || lod>=models || lod>=info) return out;
    const auto morphs=GameScript::At<ConsumedScriptArray>(mesh,0x3a8);
    // ActiveMorph is (MorphTarget pointer, float weight), packed to 12 bytes
    // in this UE3 build. Empty morph lists need no allocation.
    if (morphs.count<0 || morphs.count>256 || morphs.max<morphs.count || morphs.max>1024 ||
        (morphs.count && !GameScript::Accessible(morphs.data,12*morphs.count))) return out;
    out.object=object;
    out.morphs=static_cast<std::byte*>(mesh)+0x3a8;
    out.lod=lod;
    out.update=reinterpret_cast<ConsumedPublication::Update>(target);
    return out;
}

// Game-thread world submission only, after the caller's executable/world gate.
// Re-enumerate current actors; never cache UObject pointers across GC or travel.
inline int ApplyConsumedPieces(GameScript& script,void* level,void* worldInfo,std::uintptr_t base) {
    if (build::selected!=build::Store::Steam || !level || !worldInfo) return 0;
    auto* actors=GameScript::At<void*>(level,pinned::kLevelActorData);
    const auto count=GameScript::At<std::int32_t>(level,pinned::kLevelActorCount);
    const auto capacity=GameScript::At<std::int32_t>(level,pinned::kLevelActorCapacity);
    if (!actors || count<=0 || count>16384 || capacity<count || capacity>1048576 ||
        !GameScript::Accessible(actors,sizeof(void*)*count)) return 0;
    const auto registryName=script.Intern(L"BreacherConsumedPiece");
    int applied=0,registries=0;
    for (int i=0;i<count && registries<64;++i) {
        auto* actor=GameScript::At<void*>(actors,sizeof(void*)*i);
        // Exact class identity first: ordinary actors cost only two guarded
        // scalar loads, with no superclass traversal or reflected field walk.
        if (!actor || GameScript::ObjectName(GameScript::ObjectClass(actor))!=registryName ||
            script.Read<void*>(actor,L"WorldInfo")!=worldInfo ||
            script.Read<std::int32_t>(actor,L"NativeConsumedReady")!=1) continue;
        ++registries;
        auto* payload=script.Read<void*>(actor,L"Payload");
        auto* mesh=script.Read<void*>(actor,L"NativeConsumedMesh");
        if (!payload || !mesh || script.Read<void*>(actor,L"Owner")!=payload ||
            script.Read<void*>(payload,L"Mesh")!=mesh ||
            !script.IsClass(mesh,L"SkeletalMeshComponent")) continue;
        const auto length=script.Read<std::int32_t>(actor,L"NativeConsumedCount");
        if (length<=0 || length>kConsumedMaxBones) continue;
        const auto offset=script.FieldOffset(GameScript::ObjectClass(actor),script.Intern(L"NativeConsumedIndices"));
        if (!offset) continue;
        std::array<std::int32_t,kConsumedMaxBones> selected{};
        if (!GuardedCopy(selected.data(),static_cast<const std::byte*>(actor)+offset,sizeof(std::int32_t)*length)) continue;
        const auto space=script.Read<ConsumedScriptArray>(mesh,L"SpaceBases");
        if (space.count<=0 || space.count>kConsumedMaxBones || space.max<space.count || space.max>kConsumedMaxBones ||
            !GameScript::Accessible(space.data,sizeof(ConsumedBoneAtom)*space.count)) continue;
        if (GameScript::At<std::int32_t>(GameScript::At<void*>(mesh,0x248),0xcc)!=space.count) continue;
        const auto publication=PrepareConsumedPublication(script,mesh,base);
        if (!publication.update) continue;
        const int changed=CollapseConsumedBones(static_cast<ConsumedBoneAtom*>(space.data),space.count,selected.data(),length);
        if (changed) {
            publication.update(publication.object,publication.lod,mesh,publication.morphs);
            // Matches756aa0 after MeshObject::Update; not a packed UObject bool.
            const std::int32_t updated=1;
            std::memcpy(static_cast<std::byte*>(publication.object)+0x28,&updated,sizeof(updated));
            applied+=changed;
        }
    }
    return applied;
}
}
