#pragma once
#include <cstdint>

namespace kf2vr::adapter::menu_native {
// Pinned offline evidence: docs/re/04-menu-input.md. All use is behind the
// existing executable hash/standalone/thread gates; live acceptance is pending.
inline constexpr std::uintptr_t GetMousePositionRva=0xd179c0;
inline constexpr std::uintptr_t GfxEngineGlobalRva=0x222d9c8;
inline constexpr std::uintptr_t GfxInputKeyRva=0xc2ad00;
inline constexpr std::uintptr_t GfxInputAxisRva=0xc2a3d0;
inline constexpr std::uintptr_t GfxGetFocusMovieRva=0xc22f40;
inline constexpr std::uintptr_t GfxInputKeySlot=0x270;
inline constexpr std::uintptr_t GfxInputAxisSlot=0x278;
inline constexpr std::uintptr_t GfxGetFocusMovieSlot=0x298;
inline constexpr std::uintptr_t EngineViewport=0x6c;
inline constexpr std::uintptr_t EngineMousePosition=0x208;
inline constexpr std::uintptr_t WindowsViewportHwnd=0xcc;
struct Point { std::int32_t x=0,y=0; };
static_assert(sizeof(Point)==8);
using GetMousePositionFn=void(*)(void*,Point*);
using InputKeyFn=std::int32_t(*)(void*,std::int32_t,std::uint64_t,std::int32_t,float,std::int32_t);
using InputAxisFn=std::int32_t(*)(void*,std::int32_t,std::uint64_t,float,float,std::int32_t);
using FocusMovieFn=void*(*)(void*,std::int32_t);
}
