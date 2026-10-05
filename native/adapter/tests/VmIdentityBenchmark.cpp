// Isolated CPU microbenchmark, never a gameplay/VR FPS estimate.
#include "GameScript.h"
#include "VmEntryIdentity.h"
#include "VmSampleTiming.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>

using kf2vr::adapter::GameScript;
namespace {
__declspec(noinline) bool Duplicate(const void* stack) {
    auto* session=GameScript::At<void*>(stack,0x14);
    const auto sessionName=GameScript::ObjectName(session);
    auto* weapon=GameScript::At<void*>(stack,0x14);
    const auto weaponName=GameScript::ObjectName(weapon);
    return session==weapon && sessionName==weaponName && weaponName==73;
}
__declspec(noinline) bool Reuse(const void* stack) {
    auto* function=GameScript::At<void*>(stack,0x14);
    const auto name=GameScript::ObjectName(function);
    // Both dispatch decisions consume the same invocation-local identity.
    return function && name==73;
}
double Run(bool(*read)(const void*),const void* stack,unsigned& checksum) {
    constexpr unsigned iterations=20000;
    const auto start=std::chrono::steady_clock::now();
    for(unsigned i=0;i<iterations;++i) checksum+=read(stack);
    return std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-start).count()/iterations;
}
__declspec(noinline) bool Fast(const void* stack) {
    void* function=nullptr;std::uint64_t name=0;
    return kf2vr::adapter::ReadVmEntryIdentity(stack,function,name) && name==73;
}
__declspec(noinline) bool Sampled(const void* stack) {
    kf2vr::adapter::timing::VmSampleScope entry;
    const bool result=Fast(stack);
    { kf2vr::adapter::timing::VmBodySample body; }
    return result;
}
}
int main() {
    std::array<std::byte,256> stack{},function{};
    void* node=function.data();GameScript::Name name=73;
    std::memcpy(stack.data()+0x14,&node,sizeof(node));
    std::memcpy(function.data()+0x48,&name,sizeof(name));
    unsigned checksum=0;
    Run(Duplicate,stack.data(),checksum);Run(Reuse,stack.data(),checksum);
    std::array<double,10> before{},after{};
    for(unsigned i=0;i<before.size();++i) {
        // Reverse order on alternate trials to reduce order/thermal bias.
        if(i%2) { after[i]=Run(Reuse,stack.data(),checksum);before[i]=Run(Duplicate,stack.data(),checksum); }
        else { before[i]=Run(Duplicate,stack.data(),checksum);after[i]=Run(Reuse,stack.data(),checksum); }
    }
    std::sort(before.begin(),before.end());std::sort(after.begin(),after.end());
    const double oldMedian=(before[4]+before[5])/2,newMedian=(after[4]+after[5])/2;
    std::printf("{\"scope\":\"synthetic-VM-identity-only\",\"trials\":10,\"callsPerTrial\":20000,"
        "\"duplicateMedianNs\":%.3f,\"reuseMedianNs\":%.3f,\"reductionPercent\":%.3f,\"checksum\":%u}\n",
        oldMedian,newMedian,100*(1-newMedian/oldMedian),checksum);
    if(checksum!=440000)return 1;
    std::array<double,10> fast{},sampled{};
    kf2vr::adapter::timing::vmSamplingEnabled=true;
    for(unsigned i=0;i<fast.size();++i) {
        if(i%2) { sampled[i]=Run(Sampled,stack.data(),checksum);fast[i]=Run(Fast,stack.data(),checksum); }
        else { fast[i]=Run(Fast,stack.data(),checksum);sampled[i]=Run(Sampled,stack.data(),checksum); }
    }
    std::sort(fast.begin(),fast.end());std::sort(sampled.begin(),sampled.end());
    std::printf("{\"scope\":\"synthetic-VM-entry-only\",\"checkedMedianNs\":%.3f,\"fastMedianNs\":%.3f,\"sampledFastMedianNs\":%.3f}\n",
        newMedian,(fast[4]+fast[5])/2,(sampled[4]+sampled[5])/2);
    return checksum==840000?0:1;
}
