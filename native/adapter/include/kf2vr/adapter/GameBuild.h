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
    {0xd350a0, 0xd40890, 0x5d}, // WeaponTraceStart
    {0x47e3c0, 0x47e770, 0xcf}, // PhysicalFireStartLoc
    {0x7aed0, 0x7cdf0, 0x249}, // ProcessInternal
    {0xc4990, 0xc64a0, 0x25}, // ConstructName
    {0xc9de0, 0xcba60, 0x16b}, // FindFunction
    {0x4bd7b0, 0x4bd8d0, 0x2238}, // InputGlobals
    {0xd67810, 0xd72330, 0x35f6}, // PositionName
    {0x656720, 0x655ee0, 0x62}, // FlexHardwareSupported
    {0x657960, 0x657120, 0x60}, // FlexHardwareLevel
    {0x6561d0, 0x655990, 0x62}, // FlexInitialize
    {0x64c960, 0x64c0d0, 0x3a}, // FlexAcquireGpuContext
    {0xde2810, 0xded520, 0x406}, // ApplyNativeGraphicsSettings (menu and GSA startup)
    {0xdb42d0, 0xdbeed0, 0x362}, // GsaStartup
    // Single-pass stereo and DLSS object motion: docs/re/EPIC_SINGLE_PASS.md.
    {0x90ef10, 0x910e10, 0x473}, // RenderScene (single-pass)
    {0x911620, 0x913520, 0x1d0}, // RenderLighting (single-pass)
    {0x909480, 0x90b4f0, 0x1ec4}, // InitViews (single-pass)
    {0x902560, 0x904580, 0xe12}, // BeginOcclusionTests (single-pass)
    {0xcd61d0, 0xce10c0, 0xa0}, // ViewConstants (single-pass)
    {0x2a50f0, 0x2a72f0, 0x42}, // FlareOcclusion (single-pass)
    {0xcb60e0, 0xcc1850, 0xa5a}, // RhiClear (single-pass)
    {0x3605d0, 0x360990, 0x2b9}, // SsrCompute (single-pass)
    {0x8e1bb0, 0x8e36f0, 0x406}, // Quad (single-pass)
    {0x935340, 0x936fe0, 0x3a3}, // ShadowProjection (single-pass)
    {0xcd03b0, 0xcdb2c0, 0x322}, // HbaoRhi (single-pass)
    {0x36b490, 0x36b950, 0x11a7}, // Visibility (single-pass InitViews)
    {0x360a30, 0x360df0, 0xbe9}, // ViewSetup (single-pass InitViews)
    {0x950320, 0x951e10, 0x115}, // SortTranslucency (single-pass InitViews)
    {0x904df0, 0x906e90, 0x7cf}, // FamilyStep (single-pass InitViews)
    {0x8f95e0, 0x8fb370, 0x4a}, // LightGate (single-pass InitViews)
    {0x949970, 0x94b240, 0xcc1}, // PerLightVisibility (single-pass InitViews)
    {0x8c2a20, 0x8c3470, 0xcf9}, // FinishInitViews (single-pass InitViews)
    {0x94d240, 0x94ed00, 0xc22}, // RenderVelocities (DLSS object motion)
    {0x94b270, 0x94cc20, 0x3af}, // PrimeVelocities (DLSS object motion)
    {0x91be70, 0x91ddb0, 0x9f}, // BeginVelocities (DLSS object motion)
    {0x94e140, 0x94fc30, 0x169}, // VelocityScale (DLSS object motion)
    {0x34a3c0, 0x34ac30, 0x58d}, // TileMaxBlur (DLSS object motion)
    {0x34ad20, 0x34b590, 0x274}, // LegacyBlur (DLSS object motion)
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
    {0x221ad20, 0x236d560, 1}, // FleX initialized flag
    {0x22174c8, 0x2369d08, 1}, // GEngine
    {0x1ec2398, 0x2013398, 1}, // HiZ enable (single-pass)
    {0x1fbafec, 0x210d83c, 1}, // view gate off (single-pass)
    {0x1ec2388, 0x2013388, 1}, // view gate on (single-pass)
    {0x2225590, 0x2377de0, 1}, // foreground velocity flag (object motion)
    {0x21f6ed0, 0x2349710, 1}, // RHI pointer (object motion)
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
