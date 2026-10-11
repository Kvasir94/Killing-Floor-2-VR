#pragma once
#include <d3d11.h>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include "kf2vr/adapter/VerifiedLayout.h"

namespace kf2vr::adapter {
// NVIDIA DLSS Super Resolution for the sequential eye passes. Each eye pass
// renders the whole viewport at the mode's input size with a sub-pixel
// projection jitter. When the pass completes, Evaluate converts the scene depth
// and the eye's unjittered current/previous camera into motion vectors, runs
// the eye's own DLSS feature (separate histories) and writes the output-size
// image. Motion vectors describe camera motion only; Zeds and hands rely on
// DLSS's own colour rejection.
enum class DlssMode { Off, Dlaa, Quality, Balanced, Performance, UltraPerformance };

bool ParseDlssMode(std::wstring_view text, DlssMode& mode) noexcept;
const char* DlssModeName(DlssMode mode) noexcept;
// Per-axis input/output ratio of NVIDIA's standard modes.
double DlssRenderRatio(DlssMode mode) noexcept;
unsigned DlssRenderExtent(unsigned output, DlssMode mode) noexcept;

// Halton(2,3) sample offset for one jitter phase, in render pixels, [-0.5,0.5),
// x right, y down: pixel (x,y) shows the scene at (x+0.5+sx, y+0.5+sy).
struct DlssJitter { float x=0, y=0; };
DlssJitter DlssJitterForPhase(std::uint32_t phase, unsigned renderWidth, unsigned outputWidth) noexcept;
// Shifts a UE3 row-vector projection so a width x height viewport samples at
// the offset: clip.x += ax*clip.w, clip.y += ay*clip.w.
inline void ApplyDlssJitter(pinned::NativeMatrix4& projection, DlssJitter jitter,
                            unsigned width, unsigned height) noexcept {
    if (!width || !height) return;
    // Content moves by minus the sample offset; NDC y is up, pixel y is down.
    const float ax=-2.0f*jitter.x/static_cast<float>(width);
    const float ay=2.0f*jitter.y/static_cast<float>(height);
    for (int r=0;r<4;++r) {
        projection.m[r][0]+=ax*projection.m[r][3];
        projection.m[r][1]+=ay*projection.m[r][3];
    }
}
// Row-vector current-clip -> previous-clip mapping, computed in double:
// inverse(viewCur*projCur) * viewPrev*projPrev. False if not invertible.
bool DlssReprojection(const pinned::NativeMatrix4& viewCur, const pinned::NativeMatrix4& projCur,
                      const pinned::NativeMatrix4& viewPrev, const pinned::NativeMatrix4& projPrev,
                      float out[4][4]) noexcept;
// Camera origin of a UE3 view matrix (row vectors: p*R + t = 0 at the origin).
void DlssViewOrigin(const pinned::NativeMatrix4& view, double origin[3]) noexcept;

struct DlssEyeInput {
    pinned::NativeMatrix4 view{}, projection{}; // Unjittered, as given to the engine.
    DlssJitter jitter{};
    // The eye's rectangle in the colour and depth targets: (0,0) for a
    // sequential eye pass, (eye*width,0) for a single-pass stereo pair.
    unsigned renderX=0, renderY=0;
    unsigned renderWidth=0, renderHeight=0;
    bool valid=false;
};

class DlssUpscaler {
public:
    DlssUpscaler();
    ~DlssUpscaler();
    DlssUpscaler(const DlssUpscaler&)=delete;
    DlssUpscaler& operator=(const DlssUpscaler&)=delete;

    // Startup, before any render work. ngxDirectory holds nvngx_dlss.dll.
    void Configure(DlssMode mode, std::wstring ngxDirectory, std::wstring dataDirectory);
    // Post-DLSS AMD FidelityFX CAS sharpening, 0 (off) to 1 (maximum).
    // DLSS 2.5.1+ ignores its own sharpness parameter, so this replaces it.
    void SetSharpness(float sharpness) noexcept { sharpness_=sharpness<0 ? 0.0f : (sharpness>1 ? 1.0f : sharpness); }
    float Sharpness() const noexcept { return sharpness_; }
    DlssMode Mode() const noexcept { return mode_; }
    // Requested and not failed. Read by the game thread to size the eye passes.
    bool Active() const noexcept { return mode_!=DlssMode::Off && !failed_.load(std::memory_order_acquire); }
    // Render thread. color: the completed eye image (render size, top-left).
    // depth: the scene depth texture (D24S8 family, at least render size).
    // output: output-size texture in the colour's UNORM format with UAV binding.
    bool Evaluate(ID3D11Device* device, ID3D11DeviceContext* context, unsigned eye,
                  ID3D11Texture2D* color, ID3D11Texture2D* depth, ID3D11Texture2D* output,
                  const DlssEyeInput& input, std::string& error);
    // Drop both histories (resize, menu, travel). Render thread.
    void Reset() noexcept;
    // Render thread, with the device still alive.
    void Shutdown() noexcept;
    // Marks DLSS unusable; the game thread returns to ordinary sizing.
    void Fail(const std::string& why);
    const std::string& FailureReason() const noexcept { return failure_; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    DlssMode mode_=DlssMode::Off;
    std::atomic<bool> failed_{false};
    float sharpness_=0.0f;
    std::string failure_;
};
} // namespace kf2vr::adapter
