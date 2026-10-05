#pragma once
#include <cstdint>

namespace kf2vr::adapter::focus {
// Called on the world tick thread, after stock real/audio clock advancement and
// delta clamping, before simulation time, actor ticks and scene physics.
struct Decision { float scale = 1.0f; void* controller = nullptr; };
using Decide = Decision(*)(void* world, void* worldInfo, float delta) noexcept;
using Finish = void(*)() noexcept;
// Caller must first verify the executable hash and initialise MinHook. Hooks
// are created disabled; the caller's normal MH_EnableHook step enables them.
bool CreateHooks(std::uintptr_t gameBase, Decide decide, Finish finish) noexcept;
float ControllerDelta(void* controller, float delta) noexcept;
inline constexpr std::uintptr_t WorldTickRva = 0x582550;
inline constexpr std::uintptr_t SimulationDeltaRva = 0x582ad8;
}
