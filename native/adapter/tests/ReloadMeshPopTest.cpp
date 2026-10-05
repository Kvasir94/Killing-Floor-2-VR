#include "ReloadMeshPop.h"
#include <array>
#include <cmath>
#include <cstdio>

using namespace kf2vr::adapter;
namespace {
int failures=0;
void Check(bool ok,const char* message) {
    if (!ok) { ++failures; std::printf("FAIL: %s\n",message); }
}
bool Near(float a,float b,float tolerance=.0005f) { return std::abs(a-b)<tolerance; }

// Magazine body at x=10 with two rounds seated 2 and 4 units along it.
std::array<ReloadBoneAtom,4> Rig() {
    std::array<ReloadBoneAtom,4> atoms{};
    for (auto& atom : atoms) { atom.rotation[3]=1.f; atom.scale=1.f; }
    atoms[1].translation[0]=10.f;                 // magazine
    atoms[2].translation[0]=12.f;                 // round
    atoms[3].translation[0]=14.f;                 // round
    atoms[0].translation[0]=-50.f;                // unrelated receiver bone
    return atoms;
}
}
int main() {
    Check(!ReloadPopActive(0.f),"a published zero means no pop is in flight");
    Check(!ReloadPopActive(1.f),"a settled curve is not worth touching bones for");
    Check(!ReloadPopActive(std::nanf("")),"a corrupt read is rejected");
    Check(!ReloadPopActive(9.f),"an implausible scale cannot inflate a magazine");
    Check(ReloadPopActive(.01f) && ReloadPopActive(1.18f),"burst and overshoot both apply");

    auto atoms=Rig();
    ReloadBoneIndices bones{}; bones.index[0]=1; bones.index[1]=2; bones.index[2]=3;
    Check(ScaleReloadBones(atoms.data(),4,bones,3,.5f)==3,"every published bone is scaled");
    Check(Near(atoms[1].scale,.5f) && Near(atoms[1].translation[0],10.f),
          "the magazine scales about its own origin and does not move");
    Check(Near(atoms[2].translation[0],11.f) && Near(atoms[3].translation[0],12.f),
          "rounds are drawn toward the magazine origin so they stay in the feed lips");
    Check(Near(atoms[0].translation[0],-50.f) && Near(atoms[0].scale,1.f),
          "an unpublished bone is never touched");

    atoms=Rig();
    bones.index[1]=99;
    Check(ScaleReloadBones(atoms.data(),4,bones,3,1.18f)==2,"an out-of-range index is skipped, not clamped");
    Check(Near(atoms[3].scale,1.18f),"a later valid bone still applies after a skipped one");

    atoms=Rig();
    ReloadBoneIndices missing{}; missing.index[0]=7;
    Check(ScaleReloadBones(atoms.data(),4,missing,1,1.18f)==0,
          "an out-of-range magazine yields no origin, so nothing is scaled");

    atoms=Rig();
    atoms[1].translation[1]=std::nanf("");
    Check(ScaleReloadBones(atoms.data(),4,bones,3,1.18f)==0,"a non-finite origin aborts the whole pop");

    atoms=Rig();
    atoms[2].scale=0.f;
    bones.index[1]=2;
    ScaleReloadBones(atoms.data(),4,bones,3,1.18f);
    Check(Near(atoms[2].scale,1.18f),"a collapsed bone pops from its hidden state instead of staying at zero");

    Check(ScaleReloadBones(nullptr,4,bones,3,1.18f)==0,"a missing SpaceBases array is refused");
    Check(ScaleReloadBones(atoms.data(),4,bones,kReloadMaxBones+1,1.18f)==0,"an over-long bone list is refused");

    std::printf("Reload mesh pop checks=%d failures=%d\n",21,failures);
    return failures==0 ? 0 : 1;
}
