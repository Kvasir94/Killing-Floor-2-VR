#pragma once

// Static binary evidence for exactly the pinned KFGame.exe, not a general UE3
// SDK. See docs/re/01-render-integration-map.md and 02-scene-view-layout.md.
// These offsets must first be observed in passive live diagnostics. The caller
// owns build validation, readable-memory validation, and object lifetime.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <type_traits>

namespace kf2vr::adapter::pinned {

static_assert(sizeof(std::uintptr_t) == 8, "Pinned KFGame layout is x64 only");

inline constexpr char kSha256[] =
    "77AB9C2CF43AEAA3038274FFF3822064815A3EA02A1B3C81870CDC12A885C994";

inline constexpr std::uintptr_t kCalcSceneViewRva = 0x6746a0;
inline constexpr std::uintptr_t kViewportDrawRva = 0x676350;
inline constexpr std::uintptr_t kSubmitSceneFamilyRva = 0x903380;
inline constexpr std::uintptr_t kRendererConstructRva = 0x8fea50;
inline constexpr std::uintptr_t kSceneViewConstructRva = 0x8d6180;
inline constexpr std::uintptr_t kSceneViewCopyConstructRva = 0x8ff130;
inline constexpr std::uintptr_t kSceneViewInitializeRva = 0x8e9760;
inline constexpr std::uintptr_t kSceneViewDestructRva = 0x8d91b0;
// AllocateViewState: no arguments, returns new FSceneViewState (0x4a0 bytes,
// constructor 0x8d66e0). Callers include ULocalPlayer (state at +0xcc) and
// the scene capture components.
inline constexpr std::uintptr_t kAllocateViewStateRva = 0x8ded90;

struct NativeVector3 { float x, y, z; };
struct NativeRotator { std::int32_t pitch, yaw, roll; };
struct NativeMatrix4 { float m[4][4]; };
static_assert(sizeof(NativeVector3) == 12);
static_assert(sizeof(NativeRotator) == 12);
static_assert(sizeof(NativeMatrix4) == 64);

// Windows x64 ABI: RCX=this, RDX=family, R8=outLocation, R9=outRotation,
// stack +0x28=viewport, +0x30=drawer at callee entry. RAX returns view or null.
using CalcSceneViewFn = void* (*)(void* localPlayer, void* family,
    NativeVector3* outLocation, NativeRotator* outRotation,
    void* viewport, void* viewDrawer);
using SubmitSceneFamilyFn = void (*)(void* canvas, void* family);

namespace family {
inline constexpr std::size_t kViewsData = 0x00;       // pointer to view pointers
inline constexpr std::size_t kViewCount = 0x08;       // int32
inline constexpr std::size_t kViewCapacity = 0x0c;    // int32
inline constexpr std::size_t kRenderTarget = 0x10;    // FRenderTarget interface
inline constexpr std::size_t kScene = 0x18;           // FSceneInterface pointer
inline constexpr std::size_t kStaticPrefixSize = 0x20;
}

namespace view {
inline constexpr std::size_t kAllocationSize = 0x640;
inline constexpr std::size_t kFamily = 0x00;
inline constexpr std::size_t kState = 0x08;
inline constexpr std::size_t kX = 0x54;               // float, viewport pixels
inline constexpr std::size_t kY = 0x58;               // float, viewport pixels
inline constexpr std::size_t kClipX = 0x5c;           // float; original pre-constraint X
inline constexpr std::size_t kClipY = 0x60;           // float; original pre-constraint Y
inline constexpr std::size_t kWidth = 0x64;           // float, viewport pixels
inline constexpr std::size_t kHeight = 0x68;          // float, viewport pixels
inline constexpr std::size_t kRenderTargetX = 0x6c;   // int32, adjusted by renderer
inline constexpr std::size_t kRenderTargetY = 0x70;   // int32, adjusted by renderer
inline constexpr std::size_t kRenderTargetWidth = 0x74; // int32
inline constexpr std::size_t kRenderTargetHeight = 0x78; // int32
inline constexpr std::size_t kViewMatrix = 0x80;
inline constexpr std::size_t kProjectionMatrix = 0xc0;
inline constexpr std::size_t kPreViewTranslation = 0x310; // 3 floats
inline constexpr std::size_t kViewProjectionMatrix = 0x330;
inline constexpr std::size_t kInverseProjectionMatrix = 0x370;
inline constexpr std::size_t kInverseViewMatrix = 0x3b0;
inline constexpr std::size_t kInverseViewProjectionMatrix = 0x3f0;
inline constexpr std::size_t kViewOrigin = 0x430;      // 4 floats (xyz,w)
}

// Read from an already captured/validated byte region, never probe arbitrary
// process pointers here. These helpers perform no engine writes or calls.
template<class T>
bool ReadField(std::span<const std::byte> bytes, std::size_t offset, T& out) {
    static_assert(std::is_trivially_copyable_v<T>);
    if (offset > bytes.size() || bytes.size() - offset < sizeof(T)) return false;
    std::memcpy(&out, bytes.data() + offset, sizeof(T));
    return true;
}

struct FamilySnapshot {
    std::uintptr_t views{}, renderTarget{}, scene{};
    std::int32_t count{}, capacity{};
};

inline bool ReadFamily(std::span<const std::byte> bytes, FamilySnapshot& out) {
    FamilySnapshot value;
    if (!ReadField(bytes, family::kViewsData, value.views) ||
        !ReadField(bytes, family::kViewCount, value.count) ||
        !ReadField(bytes, family::kViewCapacity, value.capacity) ||
        !ReadField(bytes, family::kRenderTarget, value.renderTarget) ||
        !ReadField(bytes, family::kScene, value.scene)) return false;
    out = value;
    return true;
}

struct ViewSnapshot {
    std::uintptr_t family{}, state{};
    float x{}, y{}, width{}, height{};
    NativeMatrix4 viewMatrix{}, projectionMatrix{};
};

inline bool ReadView(std::span<const std::byte> bytes, ViewSnapshot& out) {
    ViewSnapshot value;
    if (!ReadField(bytes, view::kFamily, value.family) ||
        !ReadField(bytes, view::kState, value.state) ||
        !ReadField(bytes, view::kX, value.x) ||
        !ReadField(bytes, view::kY, value.y) ||
        !ReadField(bytes, view::kWidth, value.width) ||
        !ReadField(bytes, view::kHeight, value.height) ||
        !ReadField(bytes, view::kViewMatrix, value.viewMatrix) ||
        !ReadField(bytes, view::kProjectionMatrix, value.projectionMatrix)) return false;
    out = value;
    return true;
}

} // namespace kf2vr::adapter::pinned
