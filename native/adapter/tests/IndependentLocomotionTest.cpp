#include "IndependentLocomotion.h"
#include <cstdio>
#include <limits>
using kf2vr::adapter::MapIndependentLocomotion;
int main() {
    int failures=0;
    const auto check=[&](bool pass,const char* label) { if (!pass) { ++failures; std::printf("FAIL %s\n",label); } };
    auto out=MapIndependentLocomotion(true,3,0,.4f,1.f,.8f);
    check(out.x==.4f && out.y==1 && out.turn==.8f,"independent movement and turn");
    out=MapIndependentLocomotion(false,3,0,1,1,1);
    check(out.x==0 && out.y==0 && out.turn==0,"stale or modal input cannot revive script motion");
    out=MapIndependentLocomotion(true,2,0,1,1,1);
    check(out.x==0 && out.y==0 && out.turn==1,"lost movement hand stops only movement");
    out=MapIndependentLocomotion(true,2,1,1,1,1);
    check(out.x==1 && out.y==1 && out.turn==0,"movement hand swaps independently");
    out=MapIndependentLocomotion(true,3,0,std::numeric_limits<float>::quiet_NaN(),2,-2);
    check(out.x==0 && out.y==1 && out.turn==-1,"nonfinite rejection and bounds");
    return failures?1:0;
}
