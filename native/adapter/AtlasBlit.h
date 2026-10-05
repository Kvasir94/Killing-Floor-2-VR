#pragma once
#include <memory>
#include <string>
#include "kf2vr/xr/OpenXrD3D11Backend.h"
#include "SpatialMenu.h"

struct ID3D11ShaderResourceView;

namespace kf2vr::adapter {
struct ComfortEffects {
    // Status/focus channels are retained for bridge compatibility and ignored.
    float puke=0,fire=0,damage=0,heal=0,energy=0,rage=0,flash=0,nightVision=0,focus=0,blood=0;
    // Existing teleport/spectator transition fade over the whole view.
    float blink=0;
};

// Transfers a rendered stereo atlas, or projects a full modal menu image at finite
// depth, into XR eye swapchains. It never infers game-world stereo from pixels.
// All methods must run on the supplied immediate context's render thread.
class AtlasBlit {
public:
    AtlasBlit();
    ~AtlasBlit();
    AtlasBlit(const AtlasBlit&) = delete;
    AtlasBlit& operator=(const AtlasBlit&) = delete;

    bool Initialise(ID3D11Device* device, ID3D11DeviceContext* context);
    // Snapshots the source and saves/swaps ALL D3D11 graphics/compute pipeline
    // state using ID3D11DeviceContext1. Hold this scope across the backend's
    // entire RenderEyes call, including its post-callback target unbinding.
    // A true result requires EndFrame; failure restores the game state itself.
    // sourceIsSrgb means source pixels are display-encoded sRGB. Decode through
    // the SRV, then let the XR sRGB RTV encode exactly once. Set false only for
    // known linear source pixels. Raw typeless/UNORM format cannot decide this.
    bool BeginFrame(ID3D11Texture2D* backBuffer, bool sourceIsSrgb = true, bool fullFrameDiagnostic = false);
    // Samples a completed, caller-owned stereo atlas directly, without a copy.
    // Requires a same-device, single-sample Texture2D SRV over mip 0 of a
    // single-mip/even-width texture, with the exact requested sRGB/linear format.
    // The caller must finish all writes before this call and leave the source
    // unchanged until EndFrame. The view/resource are retained only for this
    // frame; never use this path for a swapchain backbuffer or modal menu.
    // State preservation and failure cleanup match BeginFrame.
    bool BeginFrameView(ID3D11ShaderResourceView* atlasView, bool sourceIsSrgb = true);
    // Snapshot the stock menu image and retain a completed stereo world atlas.
    // The background has the same ownership/format requirements as BeginFrameView
    // and must remain unchanged through EndFrame. Each eye keeps its own world
    // image outside the opaque, finite-depth menu. Failure restores game state.
    bool BeginMenuFrame(ID3D11Texture2D* menuImage, ID3D11ShaderResourceView* stereoBackgroundView,
                        bool menuIsSrgb = true, bool backgroundIsSrgb = true);
    bool RenderEye(const xr::D3D11EyeTarget& target);
    // Only the existing teleport/spectator blink is applied. All custom
    // status overlays are retired; stock game effects arrive in the atlas.
    void SetComfortEffects(const xr::FrameState& frame, const ComfortEffects& effects);
    // Full viewport menu image on a tracking-space plane. Use BeginMenuFrame,
    // or BeginFrame(fullFrameDiagnostic=true) for the diagnostic dark surround.
    // The same geometry supplies pointer hit testing.
    bool RenderMenuEye(const xr::D3D11EyeTarget& target, const xr::FrameState& frame,
                       const SpatialMenuPanel& panel, const SpatialMenuPointer& pointer);
    void EndFrame();
    // Call before ResizeBuffers. Restores state and releases all owned source
    // snapshots/views and any active borrowed atlas; source backbuffer pointers
    // are never retained by BeginFrame.
    void OnResize();
    void Shutdown();
    const std::string& LastError() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace kf2vr::adapter
