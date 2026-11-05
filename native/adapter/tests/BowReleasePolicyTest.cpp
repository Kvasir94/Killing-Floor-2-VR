#include "BowReleasePolicy.h"
#include <cstdio>
#include <limits>

using namespace kf2vr::adapter;
int failures=0;
void Check(bool condition,const char* message) {
    if (!condition) { ++failures;std::printf("FAIL %s\n",message); }
}
bool Near(float a,float b) { return std::abs(a-b)<0.00001f; }
int main() {
    BowReleaseShotState release;
    Check(!release.BeginSpread() && !release.BeginSpawn(),"aim/spawn require a stock shot");
    Check(release.BeginShot() && release.BeginShot(),"stock inherited shot bodies share one release");
    Check(release.BeginSpread() && release.BeginSpread(),"nested spread bodies are admitted");
    Check(!release.EndSpread(true),"inner spread result cannot replace final stock direction");
    Check(!release.BeginSpawn(),"spawn waits for outer spread result");
    Check(release.EndSpread(true),"outer spread returns final direction");
    Check(!release.BeginSpread(),"a release cannot reroll its spread");
    Check(release.BeginSpawn() && release.BeginSpawn(),"bow and parent use the same projectile arguments");
    release.EndSpawn();release.EndSpawn();
    Check(!release.BeginSpawn(),"a repeated spawn cannot create a second arrow");
    Check(!release.EndShot(true) && !release.Completed(),"inner body does not acknowledge completion");
    Check(release.EndShot(true) && release.Completed(),"forwarded outer stock body completes the release");
    Check(!release.BeginShot() && release.ShotUsed(),"a completed release cannot pay twice");
    BowReleaseShotState rejected;
    Check(rejected.BeginShot() && rejected.EndShot(false) && !rejected.Completed(),
        "an admitted but rejected dispatch is not a completed stock shot");
    BowReleaseShotState invalid,other;
    Check(invalid.BeginShot() && invalid.BeginSpread(),"separate release starts independently");
    Check(!invalid.EndSpread(false) && !invalid.BeginSpawn(),"invalid spread cannot spawn");
    Check(other.BeginShot() && other.BeginSpread() && other.EndSpread(true) && other.BeginSpawn(),
        "another scoped release cannot inherit a failure or consumed token");
    const auto x=BowArrowDirection({0,0,0}),y=BowArrowDirection({0,16384,30000});
    const auto z=BowArrowDirection({16384,0,-32768}),wrapped=BowArrowDirection({0,65535,0});
    Check(Near(x.x,1) && Near(x.y,0) && Near(x.z,0),"UE arrow forward X");
    Check(Near(y.x,0) && Near(y.y,1) && Near(y.z,0),"yaw and roll convention");
    Check(Near(z.x,0) && Near(z.y,0) && Near(z.z,1),"positive pitch points up");
    Check(wrapped.x>0.9999f && wrapped.y<0,"compressed yaw wraps continuously");
    Check(CanonicalBowRotation({-32768,65535,0}) && !CanonicalBowRotation({65536,0,0}),"bounded input rotation");
    Check(BoundedBowOrigin({1,-2,3}) && !BoundedBowOrigin({std::numeric_limits<float>::infinity(),0,0}) &&
        !BoundedBowOrigin({0,std::numeric_limits<float>::quiet_NaN(),0}),"non-finite origin rejected");
    return failures ? 1 : 0;
}
