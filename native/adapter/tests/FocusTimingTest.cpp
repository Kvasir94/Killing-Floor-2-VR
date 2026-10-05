// Executes the production MinHook and MASM bridge against a bounded synthetic
// world-tick instruction fixture. This is ABI evidence, not game acceptance.
#include "FocusTiming.h"
#include <windows.h>
#include <MinHook.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
using namespace kf2vr::adapter::focus;
namespace {
int failures=0, decisions=0, finishes=0;
float requested=0.2f;
void* expectedWorld=nullptr;
void* controller=reinterpret_cast<void*>(0x1234);
void Check(bool ok,const char* name) { if (!ok) { ++failures; std::printf("FAIL %s\n",name); } }
Decision Choose(void* world,void* info,float delta) noexcept {
    ++decisions;
    Check(world==expectedWorld && info==expectedWorld,"pinned R15/R12 argument transfer");
    Check(delta==0.02f,"XMM0 to callback XMM2 transfer");
    return {requested,controller};
}
void Finished() noexcept {
    ++finishes;
    const bool accepted=std::isfinite(requested) && requested>=0.05f && requested<=1.0f;
    const float scale=accepted?requested:1.0f;
    Check(std::abs(ControllerDelta(controller,0.02f*scale)-0.02f*scale)<0.000001f,"player movement receives the same slowed delta as the world");
    Check(ControllerDelta(reinterpret_cast<void*>(0x5678),0.01f)==0.01f,"other controller unchanged");
}
}
int main() {
    auto* code=static_cast<unsigned char*>(VirtualAlloc(nullptr,0x600000,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE));
    if (!code) return 2;
    auto base=reinterpret_cast<std::uintptr_t>(code);
    Check(MH_Initialize()==MH_OK,"MinHook initialises");
    Check(!CreateHooks(base,Choose,Finished),"unrecognised instructions refused");
    // Real entry prefix and frame-local placement, reduced to the registers
    // used by the real seam. Three pushes + 32-byte shadow space align RSP.
    const unsigned char prologue[]={
        0x48,0x8b,0xc4,0xf3,0x0f,0x11,0x50,0x18,0x48,0x89,0x48,0x08,
        0x55,0x41,0x54,0x41,0x57,0x48,0x8d,0x68,0xa1,
        0x48,0x83,0xec,0x20,0x49,0x89,0xcf,0x49,0x89,0xcc,
        0x0f,0x10,0x81,0x10,0x06,0x00,0x00}; // MOVUPS XMM0,[RCX+610h]
    std::memcpy(code+WorldTickRva,prologue,sizeof(prologue));
    const auto jump=WorldTickRva+sizeof(prologue);
    code[jump]=0xe9;
    const auto displacement=static_cast<std::int32_t>(SimulationDeltaRva-(jump+5));
    std::memcpy(code+jump+1,&displacement,4);
    const unsigned char seam[]={0xf3,0x41,0x0f,0x11,0x84,0x24,0xf0,0x05,0x00,0x00,
        0x41,0x0f,0x11,0x84,0x24,0x00,0x06,0x00,0x00, // preserve result lanes for inspection
        0x48,0x83,0xc4,0x20,0x41,0x5f,0x41,0x5c,0x5d,0xc3};
    std::memcpy(code+SimulationDeltaRva,seam,sizeof(seam));
    FlushInstructionCache(GetCurrentProcess(),code,0x600000);
    Check(CreateHooks(base,Choose,Finished),"both production hooks created");
    Check(MH_EnableHook(MH_ALL_HOOKS)==MH_OK,"hooks enabled");
    alignas(16) std::array<unsigned char,0x700> world{};
    expectedWorld=world.data();
    const std::array<float,4> lanes{0.02f,7.0f,11.0f,13.0f};
    std::memcpy(world.data()+0x610,lanes.data(),16);
    using Tick=void(*)(void*,int,float);
    for (float value : {0.2f,1.0f,0.05f,0.0f,-1.0f,2.0f,std::numeric_limits<float>::quiet_NaN()}) {
        requested=value;
        reinterpret_cast<Tick>(code+WorldTickRva)(world.data(),2,0.02f);
        float actual;
        std::memcpy(&actual,world.data()+0x5f0,4);
        const float scale=std::isfinite(value) && value>=0.05f && value<=1.0f?value:1.0f;
        Check(std::abs(actual-0.02f*scale)<0.000001f,"trampoline writes adjusted delta");
        Check(std::memcmp(world.data()+0x604,world.data()+0x614,12)==0,"XMM0 upper lanes preserved");
        Check(ControllerDelta(controller,0.004f)==0.004f,"frame compensation cleared on return");
    }
    Check(decisions==7 && finishes==7,"one decision and completion per tick");
    MH_DisableHook(MH_ALL_HOOKS); MH_Uninitialize();
    VirtualFree(code,0,MEM_RELEASE);
    std::printf("FocusTiming ABI fixture: %d failure(s)\n",failures);
    return failures?1:0;
}
