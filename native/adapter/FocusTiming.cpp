#include "include/kf2vr/adapter/GameBuild.h"
#include "FocusTiming.h"
#include "FrameTiming.h"
#include <windows.h>
#include <MinHook.h>
#include <cmath>
#include <cstring>

extern "C" {
void FocusSimulationDetour();
void* FocusSimulationTrampoline = nullptr;
}

namespace kf2vr::adapter::focus {
namespace {
using WorldTick = void(*)(void*, int, float);
WorldTick originalTick = nullptr;
Decide decideFrame = nullptr;
Finish finishFrame = nullptr;
struct Frame { void* world{}; Decision decision{}; bool adjusted{}; };
thread_local Frame frame;
void HookWorldTick(void* world, int type, float delta) {
    timing::Scope timing(timing::WorldTick);
    // Reentrancy never inherits an outer world's slowdown. The middle hook
    // accepts only the frame entered through this exact native boundary.
    const auto previous = frame;
    frame = {world, {}, false};
    originalTick(world, type, delta);
    if (frame.adjusted && finishFrame) finishFrame();
    frame = previous;
}
bool Match(std::uintptr_t at, const unsigned char* bytes, std::size_t size) {
    MEMORY_BASIC_INFORMATION region{};
    if (!VirtualQuery(reinterpret_cast<void*>(at), &region, sizeof(region)) ||
        region.State != MEM_COMMIT || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)) ||
        at + size > reinterpret_cast<std::uintptr_t>(region.BaseAddress) + region.RegionSize)
        return false;
    return std::memcmp(reinterpret_cast<void*>(at), bytes, size) == 0;
}
}
bool CreateHooks(std::uintptr_t base, Decide decide, Finish finish) noexcept {
    static constexpr unsigned char entry[] = {0x48,0x8b,0xc4,0xf3,0x0f,0x11,0x50,0x18,0x48,0x89,0x48,0x08};
    static constexpr unsigned char seam[] = {0xf3,0x41,0x0f,0x11,0x84,0x24,0xf0,0x05,0x00,0x00};
    if (!base || !decide || !Match(base+build::Rva(WorldTickRva),entry,sizeof(entry)) ||
        !Match(base+build::Rva(SimulationDeltaRva),seam,sizeof(seam))) return false;
    auto* world = reinterpret_cast<void*>(base+build::Rva(WorldTickRva));
    auto* simulation = reinterpret_cast<void*>(base+build::Rva(SimulationDeltaRva));
    if (MH_CreateHook(world,reinterpret_cast<void*>(&HookWorldTick),
                      reinterpret_cast<void**>(&originalTick)) != MH_OK) return false;
    if (MH_CreateHook(simulation,reinterpret_cast<void*>(&FocusSimulationDetour),
                      &FocusSimulationTrampoline) != MH_OK) {
        MH_RemoveHook(world); originalTick = nullptr; return false;
    }
    decideFrame = decide;
    finishFrame = finish;
    return true;
}
float ControllerDelta(void*, float delta) noexcept {
    // PlayerMove runs inside the controller tick. Undoing focus here lets the
    // player run at full speed while every opponent receives the scaled delta.
    // Tracked head/hand poses and selector gestures use their own real clock.
    return delta;
}
float Adjust(void* world, void* info, float delta) noexcept {
    if (!world || world != frame.world || frame.adjusted || !decideFrame ||
        !std::isfinite(delta) || delta <= 0.0f) return delta;
    auto decision = decideFrame(world,info,delta);
    if (!std::isfinite(decision.scale) || decision.scale < 0.05f ||
        decision.scale > 1.0f || !decision.controller) decision = {};
    frame.decision = decision;
    frame.adjusted = true;
    return delta * decision.scale;
}
}
extern "C" float FocusAdjustSimulation(void* world, void* info, float delta) noexcept {
    return kf2vr::adapter::focus::Adjust(world,info,delta);
}
