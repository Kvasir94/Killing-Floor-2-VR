#include "ReloadGeneration.h"
#include <cstdio>
#include <cstdint>

using kf2vr::adapter::ReloadGeneration;
int checks=0,failures=0;
void Check(bool pass,const char* label) {
    ++checks;
    if (!pass) { ++failures; std::printf("FAIL %s\n",label); }
}
int main() {
    ReloadGeneration gun;
    Check(gun.Mark(1) && gun.barrier==0,"a marker before any reload has no valid generation");
    gun.Begin();
    Check(gun.current==1 && gun.barrier==0,"starting a reload cannot reuse an earlier marker");
    Check(gun.Mark(2) && gun.barrier==gun.current,"weapon-channel marker captures the preceding reload");
    gun.Begin();
    Check(gun.current==2 && gun.barrier==1,"new same-actor reload invalidates delayed old completion");
    Check(!gun.Mark(2) && gun.barrier==1,"duplicate marker cannot attach itself to the new reload");
    Check(!gun.Mark(1) && gun.barrier==1,"older marker cannot overwrite the accepted generation");
    Check(gun.Mark(3) && gun.barrier==2,"new completion marker belongs to the new reload");
    const auto saved=gun;
    Check(!gun.Mark(0) && !gun.Mark(-1) && !gun.Mark(INT_MAX) &&
          gun.current==saved.current && gun.barrier==saved.barrier && gun.serial==saved.serial,
          "malformed serials leave the full fence unchanged");
    ReloadGeneration exhausted{INT_MAX-1,INT_MAX-2,5};
    exhausted.Begin();
    Check(exhausted.current==INT_MAX,"generation exhaustion reaches an invalid terminal value");
    exhausted.Begin();
    Check(exhausted.current==INT_MAX,"generation exhaustion never wraps to a reusable value");
    Check(exhausted.Mark(6) && exhausted.barrier==INT_MAX,"a later marker cannot revive exhausted generations");
    ReloadGeneration corrupted{-1};
    corrupted.Begin();
    Check(corrupted.current==INT_MAX,"negative generation fails closed instead of aliasing a new reload");

    // Cross the two channel arrival orders, same-actor reload replacement,
    // repeated markers and interleaved independent weapons on production state.
    for (int requestFirst=0;requestFirst<2;++requestFirst) {
        ReloadGeneration left,right;
        for (int reload=1;reload<=1000;++reload) {
            left.Begin(); right.Begin();
            const int serial=reload*2;
            const int waiting=requestFirst ? serial : 0;
            left.Mark(serial);
            Check(left.current==reload*2-1 && left.barrier==left.current &&
                  (waiting==0 || left.serial==waiting),"either owner-channel arrival order resolves the same marker");
            Check(right.current==reload && right.barrier==0 && right.serial==0,
                  "the other weapon cannot inherit a marker");
            left.Begin();
            left.Mark(serial);
            Check(left.barrier!=left.current,"repeated old completion stays invalid after an intervening reload");
            left.Mark(serial+1);
            Check(left.barrier==left.current,"a distinct marker resolves the intervening reload");
        }
    }
    {
        ReloadGeneration actor;
        std::uint32_t seed=0x72656c64;
        int serial=1;
        for (int event=0;event<10000;++event) {
            seed=seed*1664525u+1013904223u;
            const auto before=actor;
            switch(seed%4) {
            case 0:
                actor.Begin();
                Check(actor.current==before.current+1 && actor.barrier==before.barrier && actor.serial==before.serial,
                      "random reload starts retain the old marker's identity");
                break;
            case 1:
                Check(actor.Mark(serial++) && actor.barrier==actor.current,
                      "random fresh marker captures the current exact reload");
                break;
            default:
                Check(!actor.Mark(before.serial-int(seed%3)) && actor.current==before.current &&
                      actor.serial==before.serial && actor.barrier==before.barrier,
                      "random duplicate and reordered markers are idempotent");
                break;
            }
        }
    }
    std::printf("Reload generation checks=%d failures=%d\n",checks,failures);
    return failures ? 1 : 0;
}
