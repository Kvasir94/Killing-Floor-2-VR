#include "include/kf2vr/adapter/GameBuild.h"
#include "StereoViews.h"
#include "Dlss.h"
#include "kf2vr/Basis.h"

#include <windows.h>
#include <DirectXMath.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace kf2vr::adapter {
namespace {
namespace dx = DirectX;
constexpr float kProvisionalUnitsPerMetre = kProvisionalUnrealUnitsPerMetre;
constexpr float kSmall = 1.0e-5f;

bool Finite(float value) { return std::isfinite(value); }
bool FiniteMatrix(const pinned::NativeMatrix4& value) {
    for (const auto& row : value.m)
        for (float element : row) if (!Finite(element)) return false;
    return true;
}
template<class From>
bool ValidPose(const Transform<From, frames::Tracking>& pose) {
    return Finite(pose.pos.x) && Finite(pose.pos.y) && Finite(pose.pos.z) &&
        Finite(pose.rot.x) && Finite(pose.rot.y) && Finite(pose.rot.z) &&
        Finite(pose.rot.w) && std::abs(pose.rot.LengthSq() - 1.0f) < 0.02f &&
        Finite(pose.scale) && std::abs(pose.scale - 1.0f) < kSmall;
}
dx::XMMATRIX Load(const pinned::NativeMatrix4& value) {
    dx::XMFLOAT4X4 stored;
    std::memcpy(&stored, value.m, sizeof(stored));
    return dx::XMLoadFloat4x4(&stored);
}
pinned::NativeMatrix4 Store(dx::FXMMATRIX matrix) {
    dx::XMFLOAT4X4 stored;
    dx::XMStoreFloat4x4(&stored, matrix);
    pinned::NativeMatrix4 result;
    std::memcpy(result.m, &stored, sizeof(stored));
    return result;
}
bool Invert(dx::FXMMATRIX source, dx::XMMATRIX& inverse) {
    dx::XMVECTOR determinant;
    inverse = dx::XMMatrixInverse(&determinant, source);
    const float d = dx::XMVectorGetX(determinant);
    return Finite(d) && std::abs(d) > kSmall && FiniteMatrix(Store(inverse));
}

bool MakeProjection(const pinned::NativeMatrix4& stock, const xr::FovRadians& fov,
                    pinned::NativeMatrix4& out) {
    constexpr float limit = 1.5607963f; // keep finite and away from tan(pi/2)
    if (!Finite(fov.angleLeft) || !Finite(fov.angleRight) ||
        !Finite(fov.angleUp) || !Finite(fov.angleDown) ||
        std::abs(fov.angleLeft) >= limit || std::abs(fov.angleRight) >= limit ||
        std::abs(fov.angleUp) >= limit || std::abs(fov.angleDown) >= limit ||
        fov.angleLeft >= fov.angleRight || fov.angleDown >= fov.angleUp)
        return false;
    const float left = std::tan(fov.angleLeft), right = std::tan(fov.angleRight);
    const float down = std::tan(fov.angleDown), up = std::tan(fov.angleUp);
    const float width = right - left, height = up - down;
    if (width < kSmall || height < kSmall) return false;
    out = {};
    // Clip.w = stock[2][3] * camera.z. For LH row-vector matrices the
    // asymmetric terms have negative summed tangents in row 2.
    const float w = stock.m[2][3];
    out.m[0][0] = 2.0f * w / width;
    out.m[1][1] = 2.0f * w / height;
    out.m[2][0] = -(right + left) * w / width;
    out.m[2][1] = -(up + down) * w / height;
    out.m[2][2] = stock.m[2][2];
    out.m[2][3] = w;
    out.m[3][2] = stock.m[3][2];
    out.m[3][3] = stock.m[3][3];
    return FiniteMatrix(out);
}

template<class Eye>
bool MakeEye(const Transform<Eye, frames::Tracking>& eye, const xr::FovRadians& fov,
             const HeadInTracking& reference, dx::FXMMATRIX baseInverseView,
             const pinned::NativeMatrix4& stockProjection, EyeMatrices& out) {
    const Quat referenceInverse = reference.rot.Normalized().Inverse();
    const Quat relative = (referenceInverse * eye.rot.Normalized()).Normalized();
    const Vec3 position = referenceInverse.Rotate(eye.pos - reference.pos);
    // Reflect XR's -Z-forward axes into +Z-forward native camera axes.
    // An improper basis change conjugates the rotation: (-qx,-qy,qz,qw).
    const auto quaternion = dx::XMVectorSet(-relative.x, -relative.y, relative.z, relative.w);
    const auto eyeLocal = dx::XMMatrixRotationQuaternion(quaternion) *
        dx::XMMatrixTranslation(position.x * kProvisionalUnitsPerMetre,
                                position.y * kProvisionalUnitsPerMetre,
                               -position.z * kProvisionalUnitsPerMetre);
    dx::XMMATRIX worldToEye;
    if (!Invert(eyeLocal * baseInverseView, worldToEye)) return false;
    out.view = Store(worldToEye);
    return MakeProjection(stockProjection, fov, out.projection);
}

bool Accessible(const void* pointer, std::size_t size, bool writable = false) {
    const auto start = reinterpret_cast<std::uintptr_t>(pointer);
    if (!start || size > (std::numeric_limits<std::uintptr_t>::max)() - start) return false;
    const auto stop = start + size;
    auto cursor = start;
    while (cursor < stop) {
        MEMORY_BASIC_INFORMATION region{};
        if (!VirtualQuery(reinterpret_cast<const void*>(cursor), &region, sizeof(region)) ||
            region.State != MEM_COMMIT || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)))
            return false;
        const DWORD access = region.Protect & 0xff;
        const bool write = access == PAGE_READWRITE || access == PAGE_WRITECOPY ||
            access == PAGE_EXECUTE_READWRITE || access == PAGE_EXECUTE_WRITECOPY;
        const bool read = write || access == PAGE_READONLY || access == PAGE_EXECUTE_READ;
        if (!read || (writable && !write)) return false;
        const auto regionStart = reinterpret_cast<std::uintptr_t>(region.BaseAddress);
        if (region.RegionSize > (std::numeric_limits<std::uintptr_t>::max)() - regionStart)
            return false;
        const auto end = regionStart + region.RegionSize;
        if (end <= cursor) return false;
        cursor = end;
    }
    return true;
}
bool Executable(std::uintptr_t address) {
    MEMORY_BASIC_INFORMATION region{};
    if (!VirtualQuery(reinterpret_cast<void*>(address), &region, sizeof(region)) ||
        region.State != MEM_COMMIT || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return false;
    const DWORD access = region.Protect & 0xff;
    return access == PAGE_EXECUTE_READ || access == PAGE_EXECUTE_READWRITE ||
        access == PAGE_EXECUTE_WRITECOPY;
}
bool PixelValue(float value, std::uint32_t& out) {
    if (!Finite(value) || value < 0 || value > 16384 ||
        std::abs(value - std::round(value)) > 0.01f) return false;
    out = static_cast<std::uint32_t>(std::round(value));
    return true;
}
using CopyView = void* (*)(void*, const void*);
using DestroyView = void (*)(void*);
using InitializeView = void (*)(void*, std::int32_t);

class ViewCopy {
public:
    explicit ViewCopy(DestroyView destroy) : destroy_(destroy) {}
    ~ViewCopy() { if (constructed_) destroy_(bytes_.data()); }
    ViewCopy(const ViewCopy&) = delete;
    ViewCopy& operator=(const ViewCopy&) = delete;
    void Construct(CopyView copy, const void* source) {
        copy(bytes_.data(), source);
        constructed_ = true;
    }
    void* Data() { return bytes_.data(); }
    template<class T> void Set(std::size_t offset, const T& value) {
        static_assert(std::is_trivially_copyable_v<T>);
        std::memcpy(bytes_.data() + offset, &value, sizeof(value));
    }
private:
    alignas(16) std::array<std::byte, pinned::view::kAllocationSize> bytes_{};
    DestroyView destroy_;
    bool constructed_ = false;
};

class FamilyViewsRestore {
public:
    explicit FamilyViewsRestore(void* family) : family_(family) {
        std::memcpy(original_.data(), family_, original_.size());
    }
    ~FamilyViewsRestore() { Restore(); }
    FamilyViewsRestore(const FamilyViewsRestore&) = delete;
    FamilyViewsRestore& operator=(const FamilyViewsRestore&) = delete;
    void Set(void** views, std::int32_t pairCount=2) {
        // Armed before the first write, so C++ unwinding always restores.
        changed_ = true;
        std::memcpy(family_, &views, sizeof(views));
        auto* bytes = static_cast<std::byte*>(family_);
        std::memcpy(bytes + pinned::family::kViewCount, &pairCount, sizeof(pairCount));
        std::memcpy(bytes + pinned::family::kViewCapacity, &pairCount, sizeof(pairCount));
    }
    void Restore() noexcept {
        if (changed_) {
            std::memcpy(family_, original_.data(), original_.size());
            changed_ = false;
        }
    }
private:
    void* family_;
    std::array<std::byte, 16> original_{};
    bool changed_ = false;
};

void ConfigureEye(ViewCopy& copy, const EyeMatrices& matrices, const EyeRect& rect,
                  const std::array<float, 2>& random, InitializeView initialize) {
    // Prototype experiment: preserve the stock view state, including exposure
    // and rendering history. Null state produced a visibly dark headset image.
    // Separate persistent eye states are still needed for temporal correctness.
    copy.Set(pinned::view::kViewMatrix, matrices.view);
    copy.Set(pinned::view::kProjectionMatrix, matrices.projection);
    copy.Set(pinned::view::kX, static_cast<float>(rect.x));
    copy.Set(pinned::view::kY, static_cast<float>(rect.y));
    copy.Set(pinned::view::kClipX, static_cast<float>(rect.x));
    copy.Set(pinned::view::kClipY, static_cast<float>(rect.y));
    copy.Set(pinned::view::kWidth, static_cast<float>(rect.width));
    copy.Set(pinned::view::kHeight, static_cast<float>(rect.height));
    initialize(copy.Data(), 0);
    // Init consumes two global rand() calls; this makes the view-local sample
    // coherent across eyes, without claiming to restore the global generator.
    copy.Set(0x1a8, random);
}
} // namespace

bool IsValidWorldViewOffset(const Vec3& offset) noexcept {
    return Finite(offset.x) && Finite(offset.y) && Finite(offset.z) &&
        offset.LengthSq() <= kMaxWorldViewOffset * kMaxWorldViewOffset;
}

bool BuildStereoMatrices(const pinned::NativeMatrix4& baseView,
                         const pinned::NativeMatrix4& baseProjection,
                         const HeadInTracking& initialHead,
                         const xr::FrameState& frame,
                         std::array<EyeMatrices, 2>& out, std::string& error,
                         const Quat& appliedCameraRotation,
                         const Vec3& worldViewOffset) {
    error.clear();
    if (!IsValidWorldViewOffset(worldViewOffset)) {
        error = "Rendering-only view offset must be finite and within 400 Unreal units";
        return false;
    }
    if (!frame.shouldRender || !frame.viewsValid || !frame.headPoseValid ||
        !frame.eyeLeft.poseValid || !frame.eyeRight.poseValid ||
        !ValidPose(initialHead) || !ValidPose(frame.head) ||
        !ValidPose(frame.eyeLeft.pose) || !ValidPose(frame.eyeRight.pose)) {
        error = "Stereo requires one valid coherent head and eye sample";
        return false;
    }
    if (!Finite(appliedCameraRotation.x) || !Finite(appliedCameraRotation.y) ||
        !Finite(appliedCameraRotation.z) || !Finite(appliedCameraRotation.w) ||
        std::abs(appliedCameraRotation.LengthSq() - 1.0f) >= 0.02f) {
        error = "Applied gameplay head rotation is invalid";
        return false;
    }
    if (!FiniteMatrix(baseView) || !FiniteMatrix(baseProjection) ||
        baseProjection.m[2][3] <= kSmall || std::abs(baseProjection.m[3][3]) > kSmall ||
        std::abs(baseProjection.m[0][3]) > kSmall || std::abs(baseProjection.m[1][3]) > kSmall ||
        std::abs(baseProjection.m[3][2]) <= kSmall) {
        error = "Stock projection is not a finite supported perspective camera";
        return false;
    }
    dx::XMMATRIX inverseView;
    if (!Invert(Load(baseView), inverseView)) {
        error = "Stock view matrix is singular";
        return false;
    }
    // Stock camera-to-world = appliedHeadRow * bodyCameraToWorld. Remove the
    // orientation already used by gameplay before applying the latest full
    // eye sample. Translation remains an eye/lean offset and is applied once.
    const Quat inverseApplied = appliedCameraRotation.Normalized().Inverse();
    inverseView = dx::XMMatrixRotationQuaternion(dx::XMVectorSet(
        inverseApplied.x, inverseApplied.y, inverseApplied.z, inverseApplied.w)) * inverseView;
    // Row-vector composition: post-translate in WORLD axes, after the stock
    // camera's rotation. Both full eye poses inherit precisely this offset.
    // Avoid an extra operation for the ordinary first-person/default path.
    if (worldViewOffset.x != 0 || worldViewOffset.y != 0 || worldViewOffset.z != 0)
        inverseView = inverseView * dx::XMMatrixTranslation(
            worldViewOffset.x, worldViewOffset.y, worldViewOffset.z);
    std::array<EyeMatrices, 2> result;
    if (!MakeEye(frame.eyeLeft.pose, frame.eyeLeft.fov, initialHead, inverseView, baseProjection, result[0]) ||
        !MakeEye(frame.eyeRight.pose, frame.eyeRight.fov, initialHead, inverseView, baseProjection, result[1])) {
        error = "Eye pose or asymmetric field of view cannot produce a finite matrix";
        return false;
    }
    out = result;
    return true;
}

bool StereoViews::SubmitStereoPair(void* familyPointer, const xr::FrameState& frame,
                                  pinned::SubmitSceneFamilyFn originalSubmit,
                                  void* canvas, std::uintptr_t baseAddress, std::string& error,
                                  const AppliedHeadAim* appliedAim, const Vec3& worldViewOffset) {
    lastSubmittedValid_ = false;
    error.clear();
    if (!baseAddress || !originalSubmit || !canvas ||
        !Accessible(familyPointer, pinned::family::kStaticPrefixSize, true)) {
        error = "Stereo family or submission boundary is unavailable";
        return false;
    }
    pinned::FamilySnapshot family;
    if (!pinned::ReadFamily({static_cast<const std::byte*>(familyPointer), pinned::family::kStaticPrefixSize}, family) ||
        family.count != 1 || family.capacity < 1 || family.capacity > 1024 || !family.scene ||
        !family.renderTarget || !Accessible(reinterpret_cast<void*>(family.views), sizeof(void*))) {
        error = "Stereo requires the validated single-view world family";
        return false;
    }
    void* source = nullptr;
    std::memcpy(&source, reinterpret_cast<void*>(family.views), sizeof(source));
    if (!Accessible(source, pinned::view::kAllocationSize)) {
        error = "Stock scene view is not readable";
        return false;
    }
    const auto bytes = std::span(static_cast<const std::byte*>(source), pinned::view::kAllocationSize);
    pinned::ViewSnapshot view;
    if (!pinned::ReadView(bytes, view) || view.family != reinterpret_cast<std::uintptr_t>(familyPointer)) {
        error = "Scene-view family backlink did not validate";
        return false;
    }
    std::uint32_t x, y, width, height;
    std::int32_t targetWidth = 0, targetHeight = 0;
    if (!PixelValue(view.x, x) || !PixelValue(view.y, y) || !PixelValue(view.width, width) ||
        !PixelValue(view.height, height) || width < 4 || height < 4 ||
        !pinned::ReadField(bytes, pinned::view::kRenderTargetWidth, targetWidth) ||
        !pinned::ReadField(bytes, pinned::view::kRenderTargetHeight, targetHeight) ||
        targetWidth <= 0 || targetHeight <= 0 || x + width > static_cast<unsigned>(targetWidth) ||
        y + height > static_cast<unsigned>(targetHeight)) {
        error = "Scene-view rectangle does not fit the native render target";
        return false;
    }
    std::array<EyeMatrices, 2> matrices;
    const HeadInTracking candidateReference = appliedAim ? appliedAim->reference :
        (referenceReady_ ? initialHead_ : frame.head);
    if (!BuildStereoMatrices(view.viewMatrix, view.projectionMatrix, candidateReference, frame, matrices, error,
                             appliedAim ? appliedAim->cameraRotation : Quat{}, worldViewOffset))
        return false;
    if (baseAddress > (std::numeric_limits<std::uintptr_t>::max)() - build::Rva(pinned::kSceneViewCopyConstructRva) ||
        !Executable(baseAddress+build::Rva(pinned::kSceneViewCopyConstructRva)) ||
        !Executable(baseAddress+build::Rva(pinned::kSceneViewDestructRva)) ||
        !Executable(baseAddress+build::Rva(pinned::kSceneViewInitializeRva))) {
        error = "Pinned view functions are not executable";
        return false;
    }
    const StereoAtlas atlas=singleViewDiagnostic_ ? StereoAtlas{{x,y,width,height},{x,y,width,height}} :
        StereoAtlas{{x, y, width / 2, height}, {x + width / 2, y, width - width / 2, height}};
    auto copy = reinterpret_cast<CopyView>(baseAddress+build::Rva(pinned::kSceneViewCopyConstructRva));
    auto destroy = reinterpret_cast<DestroyView>(baseAddress+build::Rva(pinned::kSceneViewDestructRva));
    auto initialize = reinterpret_cast<InitializeView>(baseAddress+build::Rva(pinned::kSceneViewInitializeRva));
    std::array<float, 2> random{};
    pinned::ReadField(bytes, 0x1a8, random);
    ViewCopy left(destroy), right(destroy);
    left.Construct(copy, source);
    // Sequential stereo submits one selected eye here. Do not copy or
    // initialize an unused second view, including its engine-global effects.
    if (!singleViewDiagnostic_) right.Construct(copy, source);
    lastSubmitted_ = matrices[singleViewDiagnostic_?singleEye_:0];
    // DLSS: the engine draws with the jittered projection; the recorded pair
    // stays unjittered so motion vectors exclude the jitter.
    std::array<EyeMatrices, 2> drawn = matrices;
    if (jitterX_ != 0.0f || jitterY_ != 0.0f) {
        ApplyDlssJitter(drawn[0].projection, {jitterX_, jitterY_}, atlas.left.width, atlas.left.height);
        ApplyDlssJitter(drawn[1].projection, {jitterX_, jitterY_}, atlas.right.width, atlas.right.height);
    }
    ConfigureEye(left, drawn[singleViewDiagnostic_?singleEye_:0], atlas.left, random, initialize);
    if (!singleViewDiagnostic_) ConfigureEye(right, drawn[1], atlas.right, random, initialize);
    void* eyes[]{left.Data(), singleViewDiagnostic_?nullptr:right.Data()};
    // Declared after the copies: on every C++ unwind, restore family ownership
    // before destructing any copied view or its inner engine allocations.
    FamilyViewsRestore restore(familyPointer);
    restore.Set(eyes,singleViewDiagnostic_?1:2);
    originalSubmit(canvas, familyPointer);
    restore.Restore();
    initialHead_ = candidateReference;
    referenceReady_ = true;
    lastAtlas_ = atlas;
    lastSubmittedValid_ = singleViewDiagnostic_;
    return true;
}

void StereoViews::ResetReference() noexcept {
    initialHead_ = {};
    referenceReady_ = false;
    lastAtlas_ = {};
    lastSubmittedValid_ = false;
}
} // namespace kf2vr::adapter
