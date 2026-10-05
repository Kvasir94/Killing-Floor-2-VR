#pragma once

#include "PortalCapturePolicy.h"
#include "../adapter/GameScript.h"

namespace kf2vr::portal {

// Owns KF2's own portal renderer for VRPortal actors only. The engine renders
// a SceneCapturePortalComponent inside every parent view (each XR eye, or the
// desktop view); this bridge replaces that capture's camera with Portal 2's
// view through the pair (docs/re/PORTAL2_REFERENCE.md):
//   CaptureMode 0: window capture, target covers exactly the exit rectangle;
//   CaptureMode 1: screen-space capture with an oblique clip (close range).
// Nothing is discovered or scanned: work happens only when the engine asks an
// enabled VRPortal capture to render. All RVAs refer exclusively to the hash
// in adapter::pinned::kSha256.
class PortalCapture {
public:
    using RenderFn=void(*)(void*,void*);
    using ClipFn=CaptureMatrix*(*)(CaptureMatrix*,const CaptureMatrix*,const CapturePlane*);
    using LogFn=void(*)(const char*,...);
    static constexpr std::uintptr_t RenderRva=0x693430;
    static constexpr std::uintptr_t ClipRva=0x68c850;
    RenderFn originalRender{};
    ClipFn originalClip{};
    void Initialize(std::uintptr_t gameBase,LogFn log);
    bool ValidateCode() const;
    void Render(void* probe,void* renderer);
    CaptureMatrix* Clip(CaptureMatrix* out,const CaptureMatrix* projection,const CapturePlane* plane);
private:
    bool IsPortal(void* actor);
    std::uintptr_t base_{};
    LogFn log_{};
    adapter::GameScript script_;
    void* portalClass_{};
    DWORD thread_{};
    unsigned depth_{};
    bool clipPending_{};
    bool windowClip_{};
    CaptureMatrix windowProjection_{};
    ULONGLONG lastLog_{};
    std::uint64_t captures_{},culled_{},rejected_{};
};
}
