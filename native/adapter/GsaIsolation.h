#pragma once
// Keeps NVIDIA GeForce Experience (Game Settings Access) out of KF2VR sessions.
// Stock KF2 starts GSA during engine init and, when it loads, applies the
// options in Documents\My Games\KillingFloor2\KFGame\Config\GFXSettings.KFGame.xml
// (resolution, quality presets, motion blur, FleX level) over the session INIs.
#include <cstdint>
#include <vector>

namespace kf2vr::adapter::gsa {

struct EngineHook { void* target; void* detour; void** trampoline; };
using Log=void(*)(const char* format,...);

// Hooks KF2's GSA startup so it reports "not started": the caller then skips
// the GSA apply, and later GSA writes go to an uninitialized SDK and do nothing.
std::vector<EngineHook> PrepareIsolation(std::uintptr_t gameBase,Log log);

} // namespace kf2vr::adapter::gsa
