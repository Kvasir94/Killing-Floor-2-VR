#pragma once
#include <cstdint>
#include <cstdlib>
#include <string_view>

namespace kf2vr::adapter::build {
enum class Store { Unknown, Steam, Epic };
inline constexpr std::string_view SteamHash = "77ab9c2cf43aeaa3038274fff3822064815a3ea02a1b3c81870cdc12a885c994";
inline constexpr std::string_view EpicHash = "80ce504f73dbc76c06e3888abaa5b69df6ae6e7c23c39abb778d3c47b508db9a";
constexpr Store Identify(std::string_view hash) noexcept {
    return hash==SteamHash ? Store::Steam : hash==EpicHash ? Store::Epic : Store::Unknown;
}
// Selected once by the client hash gate, before any hook/thread is published.
// Existing standalone math tests and the separately pinned server use Steam.
inline Store selected = Store::Steam;
inline bool Select(std::string_view hash) noexcept {
    selected=Identify(hash); return selected!=Store::Unknown;
}
struct Range { std::uintptr_t steam, epic, size; };
// Complete function bodies matched by tools/re/epic_binary_map.py. Internal
// branches and all object/stack offsets are retained; only external branch and
// RIP-relative relocations differ. Ranges also cover verified call-site RVAs.
inline constexpr Range functions[]{
    {0x6746a0, 0x673cf0, 0x1280}, // CalcSceneView
    {0x676350, 0x6759a0, 0x2741}, // ViewportDraw
    {0x903380, 0x9053a0, 0xb1e}, // SubmitSceneFamily
    {0x8fea50, 0x9007e0, 0x6de}, // RendererConstruct
    {0x8d6180, 0x8d7bf0, 0x3a3}, // SceneViewConstruct
    {0x8ff130, 0x900ec0, 0xcfa}, // SceneViewCopyConstruct
    {0x8e9760, 0x8eb280, 0x10f8}, // SceneViewInitialize
    {0x8d91b0, 0x8dac40, 0xea}, // SceneViewDestruct
    {0x582000, 0x581460, 0x175}, // PlayerControllerTick
    {0x6f43c0, 0x6f3630, 0xbe}, // ActorSetRotation
    {0x582550, 0x5819b0, 0x1e93}, // WorldTick
    {0xd179c0, 0xd22f30, 0x45}, // GetMousePosition
    {0xc2ad00, 0xc32e60, 0x3c}, // GfxInputKey
    {0xc2a3d0, 0xc32530, 0x50}, // GfxInputAxis
    {0xc22f40, 0xc2b0b0, 0x3e}, // GfxGetFocusMovie
    {0xe3f0, 0xf7c0, 0x83}, // RenderAllocate
    {0x102d0, 0x11550, 0x62}, // RenderCommit
    {0xe000c0, 0xe0af30, 0xb0}, // WeaponViewRotation
    {0xd1ef30, 0xd2a4a0, 0x251}, // ResizeRhi
    {0xd350a0, 0xd40890, 0x5d}, // CanvasDraw
    {0x47e3c0, 0x47e770, 0xcf}, // PhysicalFireStartLoc
    {0x7aed0, 0x7cdf0, 0x249}, // ProcessInternal
    {0xc4990, 0xc64a0, 0x25}, // ConstructName
    {0xc9de0, 0xcba60, 0x16b}, // FindFunction
    {0x693430, 0x692db0, 0x91a}, // PortalRender
    {0x68c850, 0x68c170, 0x127}, // PortalClip
    {0x4bd7b0, 0x4bd8d0, 0x2238}, // InputGlobals
    {0xd67810, 0xd72330, 0x35f6}, // PositionName
    {0x695880, 0x6951f0, 0x6fb}, // PortalProbeConstruct
};
// Globals cross-referenced by uniquely matched functions; settings table/string
// additionally verified directly in both PE images. No assumed global delta.
inline constexpr Range globals[]{
    {0x21f8da0, 0x234b5e0, 1},
    {0x21f8f38, 0x234b778, 1},
    {0x166bc30, 0x1740660, 1},
    {0x221c080, 0x236e8d0, 1},
    {0x22340d8, 0x2386088, 1},
    {0x2219338, 0x236bb78, 1},
    {0x222d9c8, 0x2380268, 1},
    {0x1edafb0, 0x202bfa0, 1},
    {0x21f9318, 0x234bb58, 1},
    {0x1831850, 0x19065a0, 1},
    {0x22193d0, 0x236bc10, 1},
    {0x22193d8, 0x236bc18, 1},
    {0x22193e0, 0x236bc20, 1},
    {0x22193e8, 0x236bc28, 1},
    {0x22193f0, 0x236bc30, 1},
    {0x22193f8, 0x236bc38, 1},
    {0x22193a0, 0x236bbe0, 1},
    {0x22193a8, 0x236bbe8, 1},
    {0x22193c8, 0x236bc08, 1},
    {0x2219400, 0x236bc40, 1},
    {0x2219408, 0x236bc48, 1},
    {0x1eda1a4, 0x202b194, 1},
    {0x1eda1ac, 0x202b19c, 1},
    {0x171ec98, 0x17f3238, 1},
};
constexpr std::uintptr_t Translate(Store store, std::uintptr_t steam) noexcept {
    if (store==Store::Steam) return steam;
    if (store!=Store::Epic) return 0;
    for (const auto& r:functions)
        if (steam>=r.steam && steam-r.steam<r.size) return r.epic+(steam-r.steam);
    for (const auto& r:globals)
        if (steam==r.steam) return r.epic;
    return 0;
}
inline std::uintptr_t Rva(std::uintptr_t steam) noexcept {
    const auto result=Translate(selected,steam);
    // Programming error must never silently fall back to Steam addresses.
    if (!result) std::abort();
    return result;
}
} // namespace kf2vr::adapter::build
