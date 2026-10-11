#include "ConsumedPieceMask.h"
#include <cstdio>
#include <cstring>
#include <limits>

using namespace kf2vr::adapter;
namespace {
int failures=0, checks=0;
void Check(bool ok,const char* message) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n",message); }
}
using Rig=std::array<ConsumedBoneAtom,8>;
Rig MakeRig() {
    Rig r{};
    for (int i=0;i<8;++i) {
        r[i].rotation[3]=1.f;
        r[i].translation[0]=float(i*7);
        r[i].translation[1]=float(i-3);
        r[i].scale=1.f;
    }
    return r;
}
void Invalid(const std::int32_t* selected,int count,const char* message) {
    auto r=MakeRig(); const auto before=r;
    Check(CollapseConsumedBones(r.data(),8,selected,count)==0,message);
    Check(std::memcmp(r.data(),before.data(),sizeof(r))==0,"invalid selection is transactional");
}
}
int main() {
    // Selected torso has a detached descendant interleaved in reference-bone
    // order. Membership is the saved connected set, not index or parent range.
    const std::int32_t torso[]{0,1,4,7};
    auto r=MakeRig(); const auto original=r;
    Check(CollapseConsumedBones(r.data(),8,torso,4)==4,"noncontiguous connected set consumes exactly four atoms");
    for (int i:torso) {
        Check(r[i].scale==0.f,"selected bone collapses");
        Check(std::memcmp(r[i].translation,original[0].translation,sizeof(r[i].translation))==0,"selected skin shares one collapse origin");
        Check(std::memcmp(r[i].rotation,original[i].rotation,sizeof(r[i].rotation))==0,"rotation remains unchanged");
    }
    for (int i:{2,3,5,6}) Check(std::memcmp(&r[i],&original[i],sizeof(r[i]))==0,"detached piece remains byte identical");
    const auto collapsed=r;
    Check(CollapseConsumedBones(r.data(),8,torso,4)==4 && std::memcmp(r.data(),collapsed.data(),sizeof(r))==0,"repeat publication is idempotent");
    const std::int32_t limb[]{3,5};
    Check(CollapseConsumedBones(r.data(),8,limb,2)==2,"a later separate piece can be consumed independently");
    Check(std::memcmp(&r[2],&original[2],sizeof(r[2]))==0 && std::memcmp(&r[6],&original[6],sizeof(r[6]))==0,"second selection preserves remaining pieces");
    const std::int32_t badHigh[]{0,8},badLow[]{0,-1},duplicate[]{1,1};
    Invalid(badHigh,2,"out of range fails before writes");
    Invalid(badLow,2,"negative index fails before writes");
    Invalid(duplicate,2,"duplicate snapshot fails before writes");
    Invalid(nullptr,2,"missing snapshot rejected");
    Invalid(torso,0,"empty snapshot rejected");
    Invalid(torso,9,"oversized snapshot rejected");
    r=MakeRig(); r[7].scale=std::numeric_limits<float>::quiet_NaN(); const auto corrupt=r;
    Check(!CollapseConsumedBones(r.data(),8,torso,4) && std::memcmp(r.data(),corrupt.data(),sizeof(r))==0,"late nonfinite selected atom rejects whole transaction");
    r=MakeRig(); r[6].scale=std::numeric_limits<float>::infinity();
    Check(CollapseConsumedBones(r.data(),8,torso,4)==4 && std::isinf(r[6].scale),"unselected data is neither inspected nor changed");
    Check(!CollapseConsumedBones(nullptr,8,torso,4),"missing pose rejected");
    Check(!CollapseConsumedBones(r.data(),kConsumedMaxBones+1,torso,4),"unbounded pose rejected");
    std::printf("Consumed piece mask checks=%d failures=%d\n",checks,failures);
    return failures ? 1 : 0;
}
