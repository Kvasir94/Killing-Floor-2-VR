#include "VmEntryIdentity.h"
#include "VmSampleTiming.h"
#include <array>
#include <cstdio>
using namespace kf2vr::adapter;
int checks=0,failures=0;
void Check(bool ok,const char* text) { ++checks;if(!ok){++failures;std::printf("FAIL %s\n",text);} }
bool GuardPropagates(const void* stack) {
    void* function=nullptr;std::uint64_t name=0;
    __try { ReadVmEntryIdentity(stack,function,name); }
    __except(GetExceptionCode()==EXCEPTION_GUARD_PAGE ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) { return true; }
    return false;
}
int main() {
    std::array<char,256> stack{},function{};
    void* node=function.data();std::uint64_t identity=73;
    std::memcpy(stack.data()+0x14,&node,sizeof(node));std::memcpy(function.data()+0x48,&identity,sizeof(identity));
    void* found=nullptr;std::uint64_t name=0;
    Check(ReadVmEntryIdentity(stack.data(),found,name) && found==node && name==73,"live unaligned entry identity");
    identity=94;std::memcpy(function.data()+0x48,&identity,sizeof(identity));
    Check(ReadVmEntryIdentity(stack.data(),found,name) && name==94,"no stale name cache");
    Check(!ReadVmEntryIdentity(nullptr,found,name) && !found && !name,"null input clears outputs");
    auto* pages=static_cast<char*>(VirtualAlloc(nullptr,8192,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    if(!pages)return 2;
    DWORD old=0;VirtualProtect(pages+4096,4096,PAGE_NOACCESS,&old);
    Check(!ReadVmEntryIdentity(pages+4096,found,name) && !found && !name,"inaccessible stack");
    node=pages+4096;std::memcpy(stack.data()+0x14,&node,sizeof(node));
    Check(!ReadVmEntryIdentity(stack.data(),found,name) && !found && !name,"inaccessible function");
    node=pages+4096-0x48-4;std::memcpy(stack.data()+0x14,&node,sizeof(node));
    Check(!ReadVmEntryIdentity(stack.data(),found,name) && !found && !name,"name crossing inaccessible page");
    VirtualProtect(pages,4096,PAGE_READWRITE|PAGE_GUARD,&old);
    Check(GuardPropagates(pages),"guard exceptions are not swallowed");
    VirtualFree(pages,0,MEM_RELEASE);
    using namespace timing;
    auto& state=VmSamples();state={};vmSamplingEnabled=false;
    {VmSampleScope s;VmBodySample b;Check(!state.current,"disabled sampler has no active entry");}
    Check(state.calls==0 && state.samples==0,"disabled sampler has no accounting");
    vmSamplingEnabled=true;state.random=0; // Deterministically select every entry for this test.
    {VmSampleScope outer;auto* parent=state.current;
        {VmBodySample body;Sleep(2);{VmSampleScope child;VmBodySample nested;}}
        Check(state.current==parent,"recursive callback restores parent");
    }
    Check(!state.current && state.calls==2 && state.samples==2,"recursive callback counted once per entry");
    Check(state.bodyMs>=1 && state.dispatchMs>=0 && state.dispatchMs<state.bodyMs,"original body excluded from dispatch");
    state.ResetTotals();state.random=0x6d2b79f5;unsigned selected=0;
    for(unsigned i=0;i<65536;++i)selected+=state.Select();
    Check(selected>180 && selected<330,"sampling rate approximately one in 256");
    std::printf("VM entry checks=%d failures=%d\n",checks,failures);return failures?1:0;
}
