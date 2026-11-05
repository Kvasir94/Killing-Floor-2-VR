#include "SecondaryAmmoCorrection.h"
#include <cstdio>

int main() {
    using kf2vr::adapter::DecodeSecondaryAmmoCorrection;
    int loaded=99,failures=0;
    auto check=[&](bool ok,const char* label) {
        if (!ok) { ++failures; std::printf("FAIL: %s\n",label); }
    };
    check(DecodeSecondaryAmmoCorrection(-256,0,loaded) && loaded==0,"empty pools");
    check(DecodeSecondaryAmmoCorrection(-263,20,loaded) && loaded==7,"six plus retained chamber");
    check(DecodeSecondaryAmmoCorrection(-257,INT_MAX-1,loaded) && loaded==1,"largest valid total");
    loaded=99;
    check(!DecodeSecondaryAmmoCorrection(-255,15,loaded) && loaded==99,"receipt is not ammo");
    check(!DecodeSecondaryAmmoCorrection(7,20,loaded),"stock primary correction is not secondary");
    check(!DecodeSecondaryAmmoCorrection(-263,-1,loaded),"negative reserve");
    check(!DecodeSecondaryAmmoCorrection(-263,INT_MAX,loaded),"overflowing total");
    check(!DecodeSecondaryAmmoCorrection(INT_MIN,0,loaded),"reserved extreme encoding");
    check(DecodeSecondaryAmmoCorrection(-INT_MAX,0,loaded) && loaded==INT_MAX-256,"largest encodable load");
    return failures ? 1 : 0;
}
