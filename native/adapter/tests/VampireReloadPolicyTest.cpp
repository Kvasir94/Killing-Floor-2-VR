#include "VampireReloadPolicy.h"
#include <cstdio>
#include <initializer_list>
#include <stdexcept>

using namespace kf2vr::adapter;
static void Check(bool condition,const char* message) {
    if (!condition) throw std::runtime_error(message);
}
int main() {
    try {
        VampireReloadPolicy p{true,true,true,true,true,false,1};
        Check(p.Suppress(VampireReloadCall::BeginStock),"held late begin rejected");
        Check(p.Suppress(VampireReloadCall::SyncFiring),"held firing sync rejected");
        Check(p.Suppress(VampireReloadCall::Pay),"held unpaid refill rejected");
        for (int terminal : {0,2,3}) {
            p.state=terminal;
            Check(p.Suppress(VampireReloadCall::BeginStock),"terminal begin tombstone");
            Check(p.Suppress(VampireReloadCall::SyncFiring),"terminal sync tombstone");
            Check(p.Suppress(VampireReloadCall::Pay),"terminal refill tombstone");
        }
        p.state=1; p.payment=true;
        Check(!p.Suppress(VampireReloadCall::Pay),"explicit physical payment");
        Check(p.Suppress(VampireReloadCall::SyncFiring),"payment does not authorize RPC");
        p.currentGun=false;
        Check(p.Suppress(VampireReloadCall::Pay),"payment cannot refill old gun");
        p.currentGun=true; p.payment=false; p.state=4;
        Check(!p.Suppress(VampireReloadCall::Pay),"authorized stock timer");
        Check(p.Suppress(VampireReloadCall::SyncFiring),"late sync cannot accelerate fallback");
        Check(p.Suppress(VampireReloadCall::BeginStock),"fallback still rejects late begin");
        p.currentGun=false;
        Check(p.Suppress(VampireReloadCall::Pay),"stock cannot pay other gun");
        for (int field=0;field<4;++field) {
            auto unrelated=p;
            if (field==0) unrelated.exactWeapon=false;
            if (field==1) unrelated.authority=false;
            if (field==2) unrelated.owned=false;
            if (field==3) unrelated.fenced=false;
            for (auto call : {VampireReloadCall::BeginStock,VampireReloadCall::SyncFiring,VampireReloadCall::Pay})
                Check(!unrelated.Suppress(call),"unmanaged stock behavior preserved");
        }
        Check(!p.Suppress(VampireReloadCall::Other),"unrelated callback preserved");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr,"%s\n",error.what()); return 1;
    }
}
