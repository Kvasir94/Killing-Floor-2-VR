#pragma once
#include <array>
#include <cmath>
#include <cstdint>

namespace kf2vr::adapter {
struct ConsumedBoneAtom {
    float rotation[4];
    float translation[3];
    float scale;
};
static_assert(sizeof(ConsumedBoneAtom)==32);
constexpr int kConsumedMaxBones=1024;

// Transactional validation precedes writes. Selection comes from the original
// connected-piece snapshot, not a skeleton subtree (which can contain another
// hand's detached limb). Unselected composed transforms remain byte-identical.
inline int CollapseConsumedBones(ConsumedBoneAtom* atoms,int count,
                                 const std::int32_t* selected,int selectedCount) {
    if (!atoms || !selected || count<=0 || count>kConsumedMaxBones ||
        selectedCount<=0 || selectedCount>count) return 0;
    std::array<bool,kConsumedMaxBones> seen{};
    for (int n=0;n<selectedCount;++n) {
        const int index=selected[n];
        if (index<0 || index>=count || seen[index]) return 0;
        seen[index]=true;
        const auto& atom=atoms[index];
        for (float value:atom.rotation) if (!std::isfinite(value)) return 0;
        for (float value:atom.translation) if (!std::isfinite(value)) return 0;
        if (!std::isfinite(atom.scale)) return 0;
    }
    const std::array<float,3> point{atoms[selected[0]].translation[0],
        atoms[selected[0]].translation[1],atoms[selected[0]].translation[2]};
    for (int n=0;n<selectedCount;++n) {
        auto& atom=atoms[selected[n]];
        // Zero scale alone leaves weighted vertices between different bone
        // origins. A common origin collapses the whole selected skin region.
        for (int axis=0;axis<3;++axis) atom.translation[axis]=point[axis];
        atom.scale=0.f;
    }
    return selectedCount;
}
}
