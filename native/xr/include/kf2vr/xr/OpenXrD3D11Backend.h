#pragma once
#include <functional>
#include <memory>
#include <string>
#include "kf2vr/xr/XrBackend.h"
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
struct ID3D11RenderTargetView;
struct ID3D11DepthStencilView;
namespace kf2vr::xr {
enum class Eye : std::uint8_t { Left, Right };
struct D3D11Options {
    // Retained until Shutdown. Game integration must supply its own device;
    // null is for standalone tools and creates on the XR-required adapter.
    ID3D11Device* gameDevice=nullptr;
    bool preferStageSpace=true;
    bool enableD3D11Debug=false;
    bool collectTimings=false;
    const char* applicationName="KF2VR standalone";
};
struct D3D11EyeTarget {
    Eye eye=Eye::Left;
    std::uint32_t width=0, height=0;
    // Borrowed until callback returns. Single sample, local D32_FLOAT depth.
    std::int64_t colorFormat=0; // DXGI_FORMAT value
    ID3D11Texture2D* colorTexture=nullptr;
    ID3D11RenderTargetView* colorView=nullptr;
    ID3D11DepthStencilView* depthView=nullptr;
};
struct RuntimeInfo {
    std::string name, version;
    std::string system; // XrSystemProperties::systemName, the headset the runtime reports
    std::uint32_t adapterLuidLow=0;
    std::int32_t adapterLuidHigh=0;
    bool stageSpace=false;
};
struct FrameCounters {
    std::uint64_t begun=0, ended=0, submitted=0, invalidViews=0, focusLosses=0, referenceSpaceChanges=0;
    double waitFrameMs=0,beginFrameMs=0,locateMs=0,acquireMs=0,waitImageMs=0,releaseMs=0,endFrameMs=0;
};
// Single render-thread API. Caller owns D3D11 pipeline state and must save/
// restore game state around RenderEyes before any future game integration.
class OpenXrD3D11Backend final : public IXrBackend {
public:
    using EyeRenderCallback=std::function<bool(const FrameState&,const D3D11EyeTarget&)>;
    OpenXrD3D11Backend();
    ~OpenXrD3D11Backend() override;
    OpenXrD3D11Backend(const OpenXrD3D11Backend&)=delete;
    OpenXrD3D11Backend& operator=(const OpenXrD3D11Backend&)=delete;
    const char* Name() const override { return "OpenXR D3D11"; }
    bool Initialise() override;
    bool Initialise(const D3D11Options& options);
    void Shutdown() override;
    bool BeginFrame(FrameState& out) override;
    // Once per begun frame: acquire/wait/render/release each eye. Callback
    // failure or exception drops the whole stereo layer. Never submit one eye.
    bool RenderEyes(const EyeRenderCallback& render);
    bool EndFrame() override;
    // Loading plate: a display-encoded sRGB RGBA8 image baked once into a
    // static-image swapchain and shown as a head-locked quad while the game has
    // no world to submit. Owner thread only, after Initialise. Failure is not
    // fatal to the session; LastError holds the reason.
    bool CreateStaticQuad(std::uint32_t width, std::uint32_t height, const std::uint8_t* rgba,
                          float widthMetres, float distanceMetres);
    // Ends a begun frame with the static quad instead of the stereo layer, or
    // with zero layers when no quad exists.
    bool EndFrame(bool staticQuad);
    enum class QuadFrame { Submitted, Busy, Unavailable, Failed };
    // A complete wait/begin/end frame carrying only the static quad. Callable
    // from any thread: it is skipped (Busy) while the owner holds a begun frame
    // or another thread is inside the frame calls, polls no events and touches
    // no D3D state. Used while UE3's loading movie owns presentation.
    QuadFrame SubmitStaticQuadFrame();
    std::uint64_t StaticQuadFrames() const;
    std::uint64_t StaticQuadFailures() const;
    void RequestExit();
    // Thread-safe receipt only: the next focused XR frame applies the pulse
    // on the session owner thread. Left=0, right=1; durations are seconds.
    bool RequestHaptic(unsigned hand, float amplitude, float durationSeconds);
    std::uint32_t RecommendedWidth() const override;
    std::uint32_t RecommendedHeight() const override;
    ID3D11Device* Device() const;
    ID3D11DeviceContext* Context() const;
    bool ShouldQuit() const;
    SessionState State() const;
    const std::string& LastError() const;
    const RuntimeInfo& Info() const;
    const FrameCounters& Counters() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
