#pragma once

#include "GameScript.h"
#include <cmath>
#include <cstdint>

namespace kf2vr::adapter {

// AnimNode.BoneAtom, as Core/Classes/Object.uc declares it:
//   quat Rotation (16) | vector Translation (12) | float Scale (4)
struct ReloadBoneAtom {
    float rotation[4];
    float translation[3];
    float scale;
};
static_assert(sizeof(ReloadBoneAtom)==32,"BoneAtom is a 32 byte script struct");

// UE3 TArray<T> header: { T* Data; INT Count; INT Max; }
struct ReloadScriptArray {
    void* data;
    std::int32_t count;
    std::int32_t max;
};

// Up to eight spare-load bones, matching VRHandsBridge.NativeReloadMagBones.
struct ReloadBoneIndices { std::int32_t index[8]; };
constexpr int kReloadMaxBones=8;

// Script publishes 0 when no pop is in flight and exactly 1 once the curve has
// settled; neither is worth touching composed bones for. The upper bound keeps
// a corrupt read from inflating a magazine across the map.
inline bool ReloadPopActive(float scale) {
    return std::isfinite(scale) && scale>0.f && scale<=4.f && std::abs(scale-1.f)>.0005f;
}

// SpaceBases are composed component-space transforms, so a child round does not
// inherit its magazine's scale the way a local transform would. Scale every
// published bone and draw each one toward the magazine origin by the same
// factor, which keeps the rounds seated in the feed lips as the body grows.
inline int ScaleReloadBones(void* atoms, std::int32_t count,
                            const ReloadBoneIndices& bones, int boneCount, float scale) {
    if (!atoms || boneCount<=0 || boneCount>kReloadMaxBones || !ReloadPopActive(scale)) return 0;
    const auto primary=bones.index[0];
    if (primary<0 || primary>=count) return 0;
    auto* all=static_cast<ReloadBoneAtom*>(atoms);
    if (!GameScript::Accessible(all+primary,sizeof(ReloadBoneAtom))) return 0;
    float origin[3];
    for (int axis=0;axis<3;++axis) {
        origin[axis]=all[primary].translation[axis];
        if (!std::isfinite(origin[axis])) return 0;
    }
    int applied=0;
    for (int slot=0;slot<boneCount;++slot) {
        const auto index=bones.index[slot];
        if (index<0 || index>=count) continue;
        auto* atom=all+index;
        if (!GameScript::Accessible(atom,sizeof(ReloadBoneAtom))) continue;
        if (!std::isfinite(atom->scale)) continue;
        // A composed atom carries the rig's authored scale, which is 1 for
        // every shipped weapon bone but is multiplied rather than replaced so
        // an authored value survives the pop. Zero means the bone is collapsed
        // (script's own hide), and scaling zero would keep it collapsed.
        const float base=atom->scale!=0.f ? atom->scale : 1.f;
        bool finite=true;
        for (int axis=0;axis<3;++axis) finite=finite && std::isfinite(atom->translation[axis]);
        if (!finite) continue;
        for (int axis=0;axis<3;++axis)
            atom->translation[axis]=origin[axis]+(atom->translation[axis]-origin[axis])*scale;
        atom->scale=base*scale;
        ++applied;
    }
    return applied;
}

// Runs immediately after the final PlaceWeapon of the frame, which is after
// skeletal evaluation and before scene submission. Earlier than that and the
// animation pass would recompose these atoms and discard the pop.
inline int ApplyReloadMeshPop(GameScript& script, void* bridge, void* weapon) {
    if (!bridge || !weapon) return 0;
    const auto scale=script.Read<float>(bridge,L"NativeReloadMagScale");
    if (!ReloadPopActive(scale)) return 0;
    const auto boneCount=script.Read<std::int32_t>(bridge,L"NativeReloadMagBoneCount");
    if (boneCount<=0 || boneCount>kReloadMaxBones) return 0;
    const auto bones=script.Read<ReloadBoneIndices>(bridge,L"NativeReloadMagBones");
    auto* mesh=script.Read<void*>(weapon,L"MySkelMesh");
    if (!mesh) return 0;
    const auto spaceBases=script.Read<ReloadScriptArray>(mesh,L"SpaceBases");
    if (spaceBases.count<=0 || spaceBases.count>1024) return 0;
    return ScaleReloadBones(spaceBases.data,spaceBases.count,bones,boneCount,scale);
}

} // namespace kf2vr::adapter
