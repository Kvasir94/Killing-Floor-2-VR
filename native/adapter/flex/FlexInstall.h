#pragma once
// Routes KF2's FleX imports to the portable solver and lifts the engine's
// CUDA-only gate so every GPU vendor gets the authored FleX gore. KF2 still
// decides whether FleX runs from Engine.Engine PhysXLevel (0 off, 1 gibs,
// 2 gibs and fluids). KF2VR_FLEX_BACKEND=nvidia keeps NVIDIA's own FleX.
#include <cstdint>
#include <vector>

namespace kf2vr::flex {

struct EngineHook { void* target; void* detour; void** trampoline; };

using InstallLog=void(*)(const char* format,...);

// Call before the adapter enables its hook set and before engine startup
// reaches PhysX initialization. Returns the engine hooks to create alongside
// the adapter's own; an empty list means stock FleX behaviour is kept.
std::vector<EngineHook> PreparePortableFlex(std::uintptr_t gameBase,InstallLog log);

// Restore every changed import when adapter hook installation fails. Call only
// after removing any engine detours; an unrecoverable rollback fails closed.
// Safe to call when preparation was declined or a previous rollback completed.
void RollbackPortableFlex(InstallLog log,bool engineHooksRemoved=true);

} // namespace kf2vr::flex
