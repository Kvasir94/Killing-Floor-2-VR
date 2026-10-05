#include "HandWrist.h"
#include <cmath>
#include <cstdio>
#include <limits>

using namespace kf2vr;
using namespace kf2vr::adapter;
namespace {
int failures=0;
void Check(bool ok,const char* message) {
    if (!ok) { ++failures; std::printf("FAIL: %s\n",message); }
}
bool Near(const Vec3& a,const Vec3& b) { return (a-b).Length()<1e-3f; }
}
int main() {
    const Vec3 offset{-6.f,4.1f,.7f};
    const Vec3 grip{10.f,-20.f,30.f};
    Check(Near(WristFromGrip(grip,{},offset,1),grip+offset),"a level right aim puts the wrist behind, outboard and above");
    Check(Near(WristFromGrip(grip,{},offset,0),grip+Vec3{-6.f,-4.1f,.7f}),"the left wrist is outboard to its own side");
    // Turned 90 degrees left (Unreal yaw is about +Z): forward becomes -Y.
    const auto yaw=Quat::FromAxisAngle({0,0,1},-1.5707963f);
    Check(Near(WristFromGrip({},yaw,{-6.f,0,0},1),yaw.Rotate({-6.f,0,0})),"the offset turns with the hand");
    // Rolled 90 degrees: the hand's "up" is now sideways in the world.
    const auto roll=Quat::FromAxisAngle({1,0,0},1.5707963f);
    Check(std::abs(WristFromGrip({},roll,{0,0,1.f},1).z)<1e-3f,"a rolled hand carries its up offset sideways");
    const float nan=std::numeric_limits<float>::quiet_NaN();
    Check(Near(WristFromGrip(grip,{},{nan,0,0},1),grip),"a corrupt offset leaves the grip origin");
    Check(Near(WristFromGrip(grip,{},{50.f,0,0},0),grip),"an implausible offset leaves the grip origin");
    Check(Near(WristFromGrip(grip,{},{},0),grip),"a zero offset is the raw grip origin");
    if (failures==0) std::printf("hand wrist: all checks passed\n");
    return failures==0?0:1;
}
