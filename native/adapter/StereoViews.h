#pragma once

#include <array>
#include <cstdint>
#include <string>
#include "kf2vr/adapter/VerifiedLayout.h"
#include "kf2vr/xr/XrBackend.h"

namespace kf2vr::adapter {

struct EyeRect {
    std::uint32_t x{}, y{}, width{}, height{};
};
struct StereoAtlas { EyeRect left, right; };
struct EyeMatrices {
    pinned::NativeMatrix4 view{}, projection{};
};
// The tracked reference shared with gameplay aim, and the orientation already
// included by the stock camera. cameraRotation uses native camera axes
// (+X right,+Y up,+Z forward), not XR or Unreal actor axes.
struct AppliedHeadAim {
    HeadInTracking reference;
    Quat cameraRotation;
    Quat bodyRotation;
};

// Optional local inspection offset, in Unreal WORLD axes/units. This never
// changes the gameplay camera, tracked reference, controller poses or FOV.
inline constexpr float kMaxWorldViewOffset = 400.0f;
bool IsValidWorldViewOffset(const Vec3& offset) noexcept;

// Game thread only: a second persistent FSceneViewState for the right eye of
// a single-pass pair, allocated once like the player's own (never freed).
void* AllocateRightEyeViewState(std::uintptr_t baseAddress);

// Pure calculation, exposed for offline validation. Matrices use UE3's
// row-vector camera convention (+X right, +Y up, +Z forward). Native depth
// projection coefficients remain unchanged. World scale is provisional.
bool BuildStereoMatrices(const pinned::NativeMatrix4& baseView,
                         const pinned::NativeMatrix4& baseProjection,
                         const HeadInTracking& initialHead,
                         const xr::FrameState& frame,
                         std::array<EyeMatrices, 2>& out, std::string& error,
                         const Quat& appliedCameraRotation = {},
                         const Vec3& worldViewOffset = {});

// One instance, used/reset only on the verified game thread. The adapter must
// already have verified the pinned executable hash and normal family identity.
class StereoViews {
public:
    // false: no submission occurred; caller can run the original stock path.
    // true: originalSubmit was called exactly once, with two copied eye views.
    // Engine exceptions propagate; RAII restores the family during unwinding.
    bool SubmitStereoPair(void* family, const xr::FrameState& frame,
                          pinned::SubmitSceneFamilyFn originalSubmit,
                          void* canvas, std::uintptr_t baseAddress,
                          std::string& error, const AppliedHeadAim* appliedAim = nullptr,
                          const Vec3& worldViewOffset = {});
    void ResetReference() noexcept;
    void SetSingleViewDiagnostic(bool enabled, unsigned eye=0) noexcept { singleViewDiagnostic_=enabled; singleEye_=eye?1:0; }
    bool ReferenceReady() const noexcept { return referenceReady_; }
    const StereoAtlas& LastAtlas() const noexcept { return lastAtlas_; }
    // DLSS sub-pixel sample offset (render pixels, x right, y down) for the
    // next submissions; zero disables. Applied to the submitted projections.
    void SetJitter(float x, float y) noexcept { jitterX_=x; jitterY_=y; }
    // Unjittered matrices of the most recent single-eye submission.
    const EyeMatrices& LastSubmitted() const noexcept { return lastSubmitted_; }
    bool LastSubmittedValid() const noexcept { return lastSubmittedValid_; }
    // Unjittered matrices of the most recent two-view (single-pass) submission.
    const std::array<EyeMatrices, 2>& LastPair() const noexcept { return lastPair_; }
    bool LastPairValid() const noexcept { return lastPairValid_; }
    // Single-pass stereo: submit the two eye views of one viewport draw as two
    // one-view scene submissions (one renderer each, as in sequential passes)
    // instead of one two-view family. The callbacks run on the game thread
    // around each eye's submission.
    using EyeSubmitCallback = void(*)(unsigned eye);
    void SetSplitSubmit(bool enabled, EyeSubmitCallback before = nullptr, EyeSubmitCallback after = nullptr) noexcept {
        splitSubmit_=enabled; beforeEye_=before; afterEye_=after;
    }
    // Single-pass stereo: give the right eye of a two-view family its own
    // persistent view state (occlusion history, per-frame lists, exposure),
    // instead of sharing the stock one with the left eye.
    void SetSeparateRightState(bool enabled) noexcept { separateRightState_=enabled; }

private:
    HeadInTracking initialHead_{};
    bool referenceReady_ = false;
    StereoAtlas lastAtlas_{};
    bool singleViewDiagnostic_=false;
    unsigned singleEye_=0;
    float jitterX_=0, jitterY_=0;
    EyeMatrices lastSubmitted_{};
    bool lastSubmittedValid_=false;
    std::array<EyeMatrices, 2> lastPair_{};
    bool lastPairValid_=false;
    bool splitSubmit_=false;
    bool separateRightState_=false;
    EyeSubmitCallback beforeEye_=nullptr, afterEye_=nullptr;
};

} // namespace kf2vr::adapter
