#include "OpticProbeBindings.h"
#include <array>
#include <cstdio>

int main() {
    using kf2vr::adapter::OpticProbeBindings;
    using kf2vr::adapter::OpticProbeIdentity;
    std::array<unsigned char,12> objects{};
    const OpticProbeIdentity capture{&objects[0],&objects[1],&objects[2]};
    const OpticProbeIdentity other{&objects[3],&objects[4],&objects[5]};
    void* firstProbe=&objects[6];
    void* secondProbe=&objects[7];
    void* thirdProbe=&objects[8];
    void* fourthProbe=&objects[9];
    int failures=0;
    auto check=[&](bool ok,const char* label) {
        if (!ok) { ++failures;std::printf("FAIL: %s\n",label); }
    };

    OpticProbeBindings<> bindings;
    // Game submission records the capture before the render resource exists.
    // That immutable queued identity must resolve when creation arrives later.
    const auto queuedCapture=capture;
    check(!bindings.Matches(firstProbe,queuedCapture),"unregistered deferred probe fails open");
    bindings.Register(firstProbe,capture);
    check(bindings.Matches(firstProbe,queuedCapture),"deferred registration resolves earlier capture snapshot");
    bindings.Register(secondProbe,capture);
    check(bindings.Matches(firstProbe,queuedCapture),"replacement probe preserves earlier queued native resource");
    check(bindings.Matches(secondProbe,queuedCapture),"replacement probe also resolves current capture");

    check(!bindings.Matches(firstProbe,{other.component,capture.owner,capture.target}),"component identity is exact");
    check(!bindings.Matches(firstProbe,{capture.component,other.owner,capture.target}),"owner identity is exact");
    check(!bindings.Matches(firstProbe,{capture.component,capture.owner,other.target}),"target identity is exact");
    check(!bindings.Matches(firstProbe,{}),"empty captured identity never matches");
    check(!bindings.Matches(nullptr,queuedCapture),"missing native resource fails open");

    bindings.Register(firstProbe,{});
    check(!bindings.Find(firstProbe).Valid(),"foreign reuse forgets old native address binding");
    check(!bindings.Matches(firstProbe,queuedCapture),"foreign address reuse cannot satisfy old queued capture");
    check(bindings.Matches(secondProbe,queuedCapture),"foreign reuse leaves other queued resource intact");
    bindings.Register(firstProbe,other);
    check(bindings.Matches(firstProbe,other),"reused address can bind its new exact capture");
    check(!bindings.Matches(firstProbe,queuedCapture),"new capture cannot inherit old queued identity");
    bindings.Register(firstProbe,{capture.component,nullptr,capture.target});
    check(!bindings.Find(firstProbe).Valid(),"partial foreign identity also invalidates reused address");

    OpticProbeBindings<2> bounded;
    bounded.Register(firstProbe,capture);
    bounded.Register(secondProbe,other);
    bounded.Register(nullptr,capture);
    bounded.Register(thirdProbe,{});
    check(bounded.Matches(firstProbe,capture) && bounded.Matches(secondProbe,other),
        "foreign or null creations do not evict queued captures");
    bounded.Register(thirdProbe,capture);
    check(!bounded.Find(firstProbe).Valid(),"bounded eviction makes oldest queued probe fail open");
    check(!bounded.Matches(firstProbe,capture),"evicted probe cannot borrow same capture's newer resource");
    check(bounded.Matches(secondProbe,other) && bounded.Matches(thirdProbe,capture),
        "bounded eviction preserves remaining exact captures");
    bounded.Register(fourthProbe,other);
    check(!bounded.Find(secondProbe).Valid(),"bounded eviction advances to next oldest resource");
    bounded.Clear();
    check(!bounded.Find(thirdProbe).Valid() && !bounded.Find(fourthProbe).Valid(),"reset clears all native resource bindings");
    check(!bounded.Matches(thirdProbe,capture) && !bounded.Matches(fourthProbe,other),"reset invalidates queued capture matches");
    std::printf("Optic probe binding failures=%d\n",failures);
    return failures ? 1 : 0;
}
