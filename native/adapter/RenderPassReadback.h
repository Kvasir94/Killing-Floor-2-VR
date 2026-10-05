#pragma once
#include <cstdint>
#include <cstring>

namespace kf2vr::adapter {
// Read-only evidence for the SHA-pinned shipping executable. The settings table
// binds DepthPrepass to this DWORD; FSceneRenderer's constructor copies it to
// +0xec unless its override is active. RenderPrePassView tests +0xec before the
// geometry draws, while retaining depth clears and RHI state setup.
// See tools/re/audit_depth_prepass.py. No engine function is called or patched.
inline bool VerifyRenderPassReadback(std::uintptr_t base) {
    constexpr unsigned char copy[] = {0x83,0x3d,0x58,0xa2,0x8f,0x01,0x00,0x75,0x0d,
        0x8b,0x0d,0xe8,0xbe,0x5d,0x01,0x41,0x89,0x8f,0xec,0x00,0x00,0x00};
    return std::memcmp(reinterpret_cast<const void*>(base+0x8ff0b9),copy,sizeof(copy))==0 &&
        *reinterpret_cast<const std::uintptr_t*>(base+0x1eda1a4)==base+0x171ec98 &&
        *reinterpret_cast<const std::uintptr_t*>(base+0x1eda1ac)==base+0x1edafb0 &&
        std::memcmp(reinterpret_cast<const void*>(base+0x171ec98),L"DepthPrepass",sizeof(L"DepthPrepass"))==0;
}
struct RenderPassReadback {
    int depthPrepass=-1;
    int constructorOverride=-1;
};
inline RenderPassReadback ReadRenderPassSettings(std::uintptr_t base) {
    return {*reinterpret_cast<const int*>(base+0x1edafb0),
            *reinterpret_cast<const int*>(base+0x21f9318)};
}
}
