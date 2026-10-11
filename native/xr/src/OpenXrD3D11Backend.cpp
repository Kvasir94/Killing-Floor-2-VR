#include "kf2vr/xr/OpenXrD3D11Backend.h"

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <utility>
#include <vector>

namespace kf2vr::xr {
namespace {
using Microsoft::WRL::ComPtr;
constexpr XrViewConfigurationType kStereo = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
struct Measure {
    double* total;
    std::chrono::steady_clock::time_point start;
    Measure(bool enabled,double& target):total(enabled?&target:nullptr) { if(total)start=std::chrono::steady_clock::now(); }
    ~Measure() { if(total)*total+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count(); }
};
constexpr XrPosef kIdentityPose{{0, 0, 0, 1}, {0, 0, 0}};
constexpr XrSpaceLocationFlags kValidPose = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
constexpr XrSpaceLocationFlags kTrackedPose = XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
constexpr XrViewStateFlags kValidViews = XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
constexpr XrViewStateFlags kTrackedViews = XR_VIEW_STATE_ORIENTATION_TRACKED_BIT | XR_VIEW_STATE_POSITION_TRACKED_BIT;

void CheckHR(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        char text[160];
        std::snprintf(text, sizeof(text), "%s failed (HRESULT 0x%08lX)", operation, static_cast<unsigned long>(result));
        throw std::runtime_error(text);
    }
}

template<typename T> bool Contains(const std::vector<T>& values, const T& value) {
    return std::find(values.begin(), values.end(), value) != values.end();
}

bool SameLuid(const LUID& a, const LUID& b) { return a.LowPart == b.LowPart && a.HighPart == b.HighPart; }

bool FinitePose(const XrPosef& p) {
    const auto& q = p.orientation;
    const auto& v = p.position;
    const float lengthSquared = q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w;
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
        std::isfinite(lengthSquared) && std::abs(lengthSquared - 1.f) < 0.02f;
}

bool ValidFov(const XrFovf& f) {
    constexpr float halfPi = 1.57079632679f;
    return std::isfinite(f.angleLeft) && std::isfinite(f.angleRight) &&
        std::isfinite(f.angleUp) && std::isfinite(f.angleDown) &&
        f.angleLeft > -halfPi && f.angleLeft < f.angleRight && f.angleRight < halfPi &&
        f.angleDown > -halfPi && f.angleDown < f.angleUp && f.angleUp < halfPi;
}

template<typename Frame> Transform<Frame, frames::Tracking> Pose(const XrPosef& p) {
    return {{p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w},
            {p.position.x, p.position.y, p.position.z}};
}

SessionState PublicState(XrSessionState state) {
    switch (state) {
    case XR_SESSION_STATE_READY: return SessionState::Ready;
    case XR_SESSION_STATE_SYNCHRONIZED: return SessionState::Synchronized;
    case XR_SESSION_STATE_VISIBLE: return SessionState::Visible;
    case XR_SESSION_STATE_FOCUSED: return SessionState::Focused;
    case XR_SESSION_STATE_STOPPING: return SessionState::Stopping;
    case XR_SESSION_STATE_EXITING: return SessionState::Exiting;
    case XR_SESSION_STATE_LOSS_PENDING: return SessionState::LossPending;
    default: return SessionState::Idle;
    }
}
} // namespace

struct OpenXrD3D11Backend::Impl {
    struct Swapchain {
        XrSwapchain handle = XR_NULL_HANDLE;
        std::uint32_t width = 0, height = 0;
        std::vector<XrSwapchainImageD3D11KHR> images;
        std::vector<ComPtr<ID3D11RenderTargetView>> targets;
        ComPtr<ID3D11Texture2D> depth;
        ComPtr<ID3D11DepthStencilView> depthView;
        bool acquired = false, waited = false;
    };
    XrInstance instance = XR_NULL_HANDLE;
    XrSystemId system = XR_NULL_SYSTEM_ID;
    XrSession session = XR_NULL_HANDLE;
    XrSpace trackingSpace = XR_NULL_HANDLE, viewSpace = XR_NULL_HANDLE;
    XrReferenceSpaceType trackingType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    XrSessionState sessionState = XR_SESSION_STATE_UNKNOWN;
    XrEnvironmentBlendMode blendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    XrActionSet actionSet = XR_NULL_HANDLE;
    XrAction gripPose = XR_NULL_HANDLE, aimPose = XR_NULL_HANDLE;
    XrAction trigger = XR_NULL_HANDLE, squeeze = XR_NULL_HANDLE, stick = XR_NULL_HANDLE;
    XrAction primary = XR_NULL_HANDLE, secondary = XR_NULL_HANDLE, stickClick = XR_NULL_HANDLE, menu = XR_NULL_HANDLE;
    XrAction menuHold = XR_NULL_HANDLE;
    XrAction vibration = XR_NULL_HANDLE;
    struct HapticPulse { float amplitude=0, duration=0; ULONGLONG queued=0; };
    SRWLOCK hapticLock = SRWLOCK_INIT;
    std::array<HapticPulse, 2> hapticPending{};
    std::array<bool, 2> hapticPlaying{};
    std::atomic<bool> hapticsAllowed{false};
    std::array<XrPath, 2> handPaths{};
    std::array<XrSpace, 2> gripSpaces{}, aimSpaces{};
    std::array<Swapchain, 2> swapchains;
    // Static loading plate. frameLock serialises the owner's wait/begin/end
    // calls with SubmitStaticQuadFrame on a foreign (loading movie) thread;
    // ownerFrameOpen tells that path the owner is mid-frame without the lock.
    SRWLOCK frameLock = SRWLOCK_INIT;
    std::atomic<bool> ownerFrameOpen{false};
    std::atomic<bool> quadReady{false};
    XrSwapchain quadChain = XR_NULL_HANDLE;
    XrCompositionLayerQuad quadLayer{XR_TYPE_COMPOSITION_LAYER_QUAD};
    std::atomic<std::uint64_t> quadFrames{0}, quadFailures{0};
    std::array<XrView, 2> views{{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}}};
    std::array<XrCompositionLayerProjectionView, 2> projectionViews{};
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    DXGI_FORMAT colorFormat = DXGI_FORMAT_UNKNOWN;
    bool initialised = false, running = false, quit = false;
    bool frameBegun = false, renderAttempted = false, rendered = false;
    XrTime displayTime = 0;
    std::vector<XrTime> pendingOriginChanges;
    std::uint64_t referenceSpaceEpoch = 0;
    FrameState frame;
    RuntimeInfo info;
    FrameCounters counters;
    bool collectTimings=false;
    std::string error;

    bool QueueHaptic(unsigned hand, float amplitude, float duration) {
        if (hand>=2 || !std::isfinite(amplitude) || !std::isfinite(duration) || amplitude<=0 || duration<=0 ||
            !hapticsAllowed.load(std::memory_order_acquire)) return false;
        const auto now=GetTickCount64();
        AcquireSRWLockExclusive(&hapticLock);
        if (!hapticsAllowed.load(std::memory_order_acquire)) {
            ReleaseSRWLockExclusive(&hapticLock);
            return false;
        }
        auto& pending=hapticPending[hand];
        if (now-pending.queued>400) pending={};
        pending.amplitude=std::max(pending.amplitude,std::clamp(amplitude,0.f,1.f));
        pending.duration=std::max(pending.duration,std::clamp(duration,.005f,.3f));
        pending.queued=now;
        ReleaseSRWLockExclusive(&hapticLock);
        return true;
    }

    void ClearHaptics() noexcept {
        hapticsAllowed.store(false,std::memory_order_release);
        AcquireSRWLockExclusive(&hapticLock);
        hapticPending={};
        ReleaseSRWLockExclusive(&hapticLock);
        for (unsigned hand=0;hand<2;++hand) {
            if (hapticPlaying[hand] && running && session!=XR_NULL_HANDLE && vibration!=XR_NULL_HANDLE) {
                XrHapticActionInfo action{XR_TYPE_HAPTIC_ACTION_INFO};
                action.action=vibration; action.subactionPath=handPaths[hand];
                xrStopHapticFeedback(session,&action);
            }
            hapticPlaying[hand]=false;
        }
    }

    void DrainHaptics() {
        const bool enabled=running && !quit && sessionState==XR_SESSION_STATE_FOCUSED &&
            frame.actionsSynced && frame.headPoseValid && frame.viewsValid;
        if (!enabled) { ClearHaptics(); return; }
        hapticsAllowed.store(true,std::memory_order_release);
        std::array<HapticPulse,2> pending{};
        AcquireSRWLockExclusive(&hapticLock);
        pending=hapticPending;
        hapticPending={};
        ReleaseSRWLockExclusive(&hapticLock);
        const auto now=GetTickCount64();
        for (unsigned hand=0;hand<2;++hand) {
            const bool valid=hand==0?frame.handLeft.poseValid:frame.handRight.poseValid;
            if (!valid && hapticPlaying[hand]) {
                XrHapticActionInfo action{XR_TYPE_HAPTIC_ACTION_INFO};
                action.action=vibration; action.subactionPath=handPaths[hand];
                xrStopHapticFeedback(session,&action);
                hapticPlaying[hand]=false;
            }
            if (!valid || pending[hand].amplitude<=0 || now-pending[hand].queued>250) continue;
            XrHapticActionInfo action{XR_TYPE_HAPTIC_ACTION_INFO};
            action.action=vibration; action.subactionPath=handPaths[hand];
            XrHapticVibration pulse{XR_TYPE_HAPTIC_VIBRATION};
            pulse.amplitude=pending[hand].amplitude;
            pulse.duration=static_cast<XrDuration>(pending[hand].duration*1e9);
            pulse.frequency=XR_FREQUENCY_UNSPECIFIED;
            // Unsupported/disconnected haptics never interrupt frame or game
            // work. A failed receipt is discarded and is never replayed later.
            hapticPlaying[hand]=XR_SUCCEEDED(xrApplyHapticFeedback(session,&action,
                reinterpret_cast<const XrHapticBaseHeader*>(&pulse)));
        }
    }

    void Check(XrResult result, const char* operation) {
        if (result == XR_SESSION_LOSS_PENDING) quit = true;
        if (XR_FAILED(result)) {
            char resultText[XR_MAX_RESULT_STRING_SIZE]{};
            if (instance != XR_NULL_HANDLE) xrResultToString(instance, result, resultText);
            throw std::runtime_error(std::string(operation) + " failed: " +
                (resultText[0] ? resultText : std::to_string(result)));
        }
    }

    bool Failure(const std::exception& exception, bool fatal = true) {
        error = exception.what();
        if (fatal) quit = true;
        return false;
    }

    XrPath Path(const std::string& path) {
        XrPath result = XR_NULL_PATH;
        Check(xrStringToPath(instance, path.c_str(), &result), "xrStringToPath");
        return result;
    }

    XrAction Action(const char* name, const char* label, XrActionType type) {
        XrActionCreateInfo create{XR_TYPE_ACTION_CREATE_INFO};
        std::snprintf(create.actionName, sizeof(create.actionName), "%s", name);
        std::snprintf(create.localizedActionName, sizeof(create.localizedActionName), "%s", label);
        create.actionType = type;
        create.countSubactionPaths = static_cast<std::uint32_t>(handPaths.size());
        create.subactionPaths = handPaths.data();
        XrAction action = XR_NULL_HANDLE;
        Check(xrCreateAction(actionSet, &create, &action), "xrCreateAction");
        return action;
    }

    void CreateActions() {
        handPaths = {Path("/user/hand/left"), Path("/user/hand/right")};
        XrActionSetCreateInfo create{XR_TYPE_ACTION_SET_CREATE_INFO};
        std::snprintf(create.actionSetName, sizeof(create.actionSetName), "kf2vr");
        std::snprintf(create.localizedActionSetName, sizeof(create.localizedActionSetName), "KF2 VR");
        Check(xrCreateActionSet(instance, &create, &actionSet), "xrCreateActionSet");
        gripPose = Action("grip_pose", "Grip pose", XR_ACTION_TYPE_POSE_INPUT);
        aimPose = Action("aim_pose", "Aim pose", XR_ACTION_TYPE_POSE_INPUT);
        trigger = Action("trigger", "Trigger", XR_ACTION_TYPE_FLOAT_INPUT);
        squeeze = Action("squeeze", "Squeeze", XR_ACTION_TYPE_FLOAT_INPUT);
        stick = Action("move", "Movement axis", XR_ACTION_TYPE_VECTOR2F_INPUT);
        primary = Action("primary", "Primary button", XR_ACTION_TYPE_BOOLEAN_INPUT);
        secondary = Action("secondary", "Secondary button", XR_ACTION_TYPE_BOOLEAN_INPUT);
        stickClick = Action("stick_click", "Movement axis click", XR_ACTION_TYPE_BOOLEAN_INPUT);
        menu = Action("menu", "Menu", XR_ACTION_TYPE_BOOLEAN_INPUT);
        menuHold = Action("menu_hold", "VR menu (hold)", XR_ACTION_TYPE_BOOLEAN_INPUT);
        vibration = Action("vibration", "Hand feedback", XR_ACTION_TYPE_VIBRATION_OUTPUT);

        // Core interaction profiles only: bindings are suggestions, so runtimes
        // and users can remap them. Unsupported profiles may be rejected alone.
        struct Profile { const char* path; const char* trigger; const char* squeeze; const char* stick; const char* click; };
        constexpr Profile profiles[] = {
            {"/interaction_profiles/khr/simple_controller", "/input/select/click", nullptr, nullptr, nullptr},
            {"/interaction_profiles/oculus/touch_controller", "/input/trigger/value", "/input/squeeze/value", "/input/thumbstick", "/input/thumbstick/click"},
            {"/interaction_profiles/valve/index_controller", "/input/trigger/value", "/input/squeeze/force", "/input/thumbstick", "/input/thumbstick/click"},
            {"/interaction_profiles/htc/vive_controller", "/input/trigger/value", "/input/squeeze/click", "/input/trackpad", "/input/trackpad/click"},
            {"/interaction_profiles/microsoft/motion_controller", "/input/trigger/value", "/input/squeeze/click", "/input/thumbstick", "/input/thumbstick/click"},
        };
        std::uint32_t accepted = 0;
        for (std::size_t p = 0; p < std::size(profiles); ++p) {
            const auto& profile = profiles[p];
            std::vector<XrActionSuggestedBinding> bindings;
            for (std::size_t hand = 0; hand < 2; ++hand) {
                const std::string prefix = hand == 0 ? "/user/hand/left" : "/user/hand/right";
                const auto bind = [&](XrAction action, const char* suffix) {
                    if (suffix) bindings.push_back({action, Path(prefix + suffix)});
                };
                bind(gripPose, "/input/grip/pose");
                bind(aimPose, "/input/aim/pose");
                bind(vibration, "/output/haptic");
                bind(trigger, profile.trigger);
                bind(squeeze, profile.squeeze);
                bind(stick, profile.stick);
                bind(stickClick, profile.click);
                if (p == 1) { // Touch X/Y on left, A/B on right; only left has menu.
                    bind(primary, hand == 0 ? "/input/x/click" : "/input/a/click");
                    bind(secondary, hand == 0 ? "/input/y/click" : "/input/b/click");
                    if (hand == 0) bind(menu, "/input/menu/click");
                } else if (p == 2) { // Index A/B on either hand; system reserved.
                    bind(primary, "/input/a/click");
                    bind(secondary, "/input/b/click");
                    // Index has no menu button: a held right trackpad press opens the VR menu.
                    if (hand == 1) bind(menuHold, "/input/trackpad/force");
                } else {
                    bind(menu, "/input/menu/click");
                }
            }
            XrInteractionProfileSuggestedBinding suggest{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
            suggest.interactionProfile = Path(profile.path);
            suggest.countSuggestedBindings = static_cast<std::uint32_t>(bindings.size());
            suggest.suggestedBindings = bindings.data();
            const XrResult result = xrSuggestInteractionProfileBindings(instance, &suggest);
            if (result == XR_ERROR_PATH_UNSUPPORTED) continue;
            Check(result, "xrSuggestInteractionProfileBindings");
            ++accepted;
        }
        if (accepted == 0) throw std::runtime_error("Runtime accepted none of the controller interaction profiles");

        for (std::size_t hand = 0; hand < 2; ++hand) {
            XrActionSpaceCreateInfo space{XR_TYPE_ACTION_SPACE_CREATE_INFO};
            space.subactionPath = handPaths[hand];
            space.poseInActionSpace = kIdentityPose;
            space.action = gripPose;
            Check(xrCreateActionSpace(session, &space, &gripSpaces[hand]), "xrCreateActionSpace(grip)");
            space.action = aimPose;
            Check(xrCreateActionSpace(session, &space, &aimSpaces[hand]), "xrCreateActionSpace(aim)");
        }
        XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
        attach.countActionSets = 1;
        attach.actionSets = &actionSet;
        Check(xrAttachSessionActionSets(session, &attach), "xrAttachSessionActionSets");
    }

    void CreateDevice(const D3D11Options& options) {
        PFN_xrGetD3D11GraphicsRequirementsKHR requirementsFn = nullptr;
        Check(xrGetInstanceProcAddr(instance, "xrGetD3D11GraphicsRequirementsKHR",
            reinterpret_cast<PFN_xrVoidFunction*>(&requirementsFn)), "xrGetInstanceProcAddr(D3D11 requirements)");
        if (!requirementsFn) throw std::runtime_error("OpenXR did not return the D3D11 requirements function");
        XrGraphicsRequirementsD3D11KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
        Check(requirementsFn(instance, system, &requirements), "xrGetD3D11GraphicsRequirementsKHR");
        info.adapterLuidLow = requirements.adapterLuid.LowPart;
        info.adapterLuidHigh = requirements.adapterLuid.HighPart;

        if (options.gameDevice) {
            ComPtr<IDXGIDevice> dxgiDevice;
            CheckHR(options.gameDevice->QueryInterface(IID_PPV_ARGS(&dxgiDevice)), "QueryInterface(IDXGIDevice)");
            ComPtr<IDXGIAdapter> adapter;
            CheckHR(dxgiDevice->GetAdapter(&adapter), "IDXGIDevice::GetAdapter");
            DXGI_ADAPTER_DESC desc{};
            CheckHR(adapter->GetDesc(&desc), "IDXGIAdapter::GetDesc");
            if (!SameLuid(desc.AdapterLuid, requirements.adapterLuid))
                throw std::runtime_error("Game D3D11 adapter LUID differs from OpenXR adapter; cross-adapter submission is disabled");
            if (options.gameDevice->GetFeatureLevel() < requirements.minFeatureLevel)
                throw std::runtime_error("Game D3D11 device does not meet the OpenXR minimum feature level");
            CheckHR(options.gameDevice->GetDeviceRemovedReason(), "Game D3D11 device health");
            device = options.gameDevice;
            device->GetImmediateContext(&context);
        } else {
            ComPtr<IDXGIFactory1> factory;
            CheckHR(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
            ComPtr<IDXGIAdapter1> matched;
            for (UINT index = 0;; ++index) {
                ComPtr<IDXGIAdapter1> adapter;
                const HRESULT result = factory->EnumAdapters1(index, &adapter);
                if (result == DXGI_ERROR_NOT_FOUND) break;
                CheckHR(result, "IDXGIFactory1::EnumAdapters1");
                DXGI_ADAPTER_DESC1 desc{};
                CheckHR(adapter->GetDesc1(&desc), "IDXGIAdapter1::GetDesc1");
                if (SameLuid(desc.AdapterLuid, requirements.adapterLuid)) { matched = adapter; break; }
            }
            if (!matched) throw std::runtime_error("OpenXR-required graphics adapter was not found");
            std::vector<D3D_FEATURE_LEVEL> levels{D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
            levels.erase(std::remove_if(levels.begin(), levels.end(), [&](auto level) {
                return level < requirements.minFeatureLevel;
            }), levels.end());
            if (levels.empty()) throw std::runtime_error("OpenXR requires an unsupported D3D11 feature level");
            UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
            if (options.enableD3D11Debug) flags |= D3D11_CREATE_DEVICE_DEBUG;
            HRESULT result = D3D11CreateDevice(matched.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags,
                levels.data(), static_cast<UINT>(levels.size()), D3D11_SDK_VERSION, &device, nullptr, &context);
            if (result == DXGI_ERROR_SDK_COMPONENT_MISSING && options.enableD3D11Debug) {
                flags &= ~D3D11_CREATE_DEVICE_DEBUG;
                result = D3D11CreateDevice(matched.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags,
                    levels.data(), static_cast<UINT>(levels.size()), D3D11_SDK_VERSION, &device, nullptr, &context);
            }
            // Never silently fall back to WARP or another physical adapter.
            CheckHR(result, "D3D11CreateDevice(OpenXR adapter)");
        }
        if (!context) throw std::runtime_error("D3D11 device returned no immediate context");
    }

    void CreateSpaces(const D3D11Options& options) {
        std::uint32_t count = 0;
        Check(xrEnumerateReferenceSpaces(session, 0, &count, nullptr), "xrEnumerateReferenceSpaces(count)");
        std::vector<XrReferenceSpaceType> spaces(count);
        Check(xrEnumerateReferenceSpaces(session, count, &count, spaces.data()), "xrEnumerateReferenceSpaces");
        spaces.resize(count);
        trackingType = options.preferStageSpace && Contains(spaces, XR_REFERENCE_SPACE_TYPE_STAGE)
            ? XR_REFERENCE_SPACE_TYPE_STAGE : XR_REFERENCE_SPACE_TYPE_LOCAL;
        if (!Contains(spaces, trackingType) || !Contains(spaces, XR_REFERENCE_SPACE_TYPE_VIEW))
            throw std::runtime_error("Required tracking/reference spaces are not supported");
        XrReferenceSpaceCreateInfo create{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        create.poseInReferenceSpace = kIdentityPose;
        create.referenceSpaceType = trackingType;
        Check(xrCreateReferenceSpace(session, &create, &trackingSpace), "xrCreateReferenceSpace(tracking)");
        create.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        Check(xrCreateReferenceSpace(session, &create, &viewSpace), "xrCreateReferenceSpace(view)");
        info.stageSpace = trackingType == XR_REFERENCE_SPACE_TYPE_STAGE;
    }

    void CreateSwapchains() {
        std::uint32_t count = 0;
        Check(xrEnumerateViewConfigurationViews(instance, system, kStereo, 0, &count, nullptr), "xrEnumerateViewConfigurationViews(count)");
        if (count != 2) throw std::runtime_error("OpenXR primary stereo must provide exactly two views");
        std::array<XrViewConfigurationView, 2> config{{{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}}};
        Check(xrEnumerateViewConfigurationViews(instance, system, kStereo, 2, &count, config.data()), "xrEnumerateViewConfigurationViews");
        if (count != 2) throw std::runtime_error("OpenXR view count changed during enumeration");
        Check(xrEnumerateSwapchainFormats(session, 0, &count, nullptr), "xrEnumerateSwapchainFormats(count)");
        std::vector<std::int64_t> formats(count);
        Check(xrEnumerateSwapchainFormats(session, count, &count, formats.data()), "xrEnumerateSwapchainFormats");
        formats.resize(count);
        constexpr DXGI_FORMAT preferred[] = {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB};
        for (const auto format : preferred) {
            if (Contains(formats, static_cast<std::int64_t>(format))) { colorFormat = format; break; }
        }
        // Shader outputs are linear. Requiring an sRGB target prevents silently
        // dark images on runtimes that expose only a different colour space.
        if (colorFormat == DXGI_FORMAT_UNKNOWN) throw std::runtime_error("No supported sRGB OpenXR colour swapchain format");

        for (std::size_t eye = 0; eye < 2; ++eye) {
            auto& chain = swapchains[eye];
            chain.width = config[eye].recommendedImageRectWidth;
            chain.height = config[eye].recommendedImageRectHeight;
            if (chain.width == 0 || chain.height == 0) throw std::runtime_error("OpenXR returned an empty eye extent");
            XrSwapchainCreateInfo create{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            create.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
            create.format = colorFormat;
            create.sampleCount = 1;
            create.width = chain.width;
            create.height = chain.height;
            create.faceCount = 1;
            create.arraySize = 1;
            create.mipCount = 1;
            Check(xrCreateSwapchain(session, &create, &chain.handle), "xrCreateSwapchain");
            Check(xrEnumerateSwapchainImages(chain.handle, 0, &count, nullptr), "xrEnumerateSwapchainImages(count)");
            if (count == 0) throw std::runtime_error("OpenXR created a swapchain without images");
            chain.images.resize(count, {XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR});
            Check(xrEnumerateSwapchainImages(chain.handle, count, &count,
                reinterpret_cast<XrSwapchainImageBaseHeader*>(chain.images.data())), "xrEnumerateSwapchainImages");
            chain.images.resize(count);
            chain.targets.resize(count);
            D3D11_RENDER_TARGET_VIEW_DESC target{};
            target.Format = colorFormat;
            target.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
            for (std::size_t i = 0; i < chain.images.size(); ++i)
                CheckHR(device->CreateRenderTargetView(chain.images[i].texture, &target, &chain.targets[i]), "CreateRenderTargetView");
            D3D11_TEXTURE2D_DESC depth{};
            depth.Width = chain.width;
            depth.Height = chain.height;
            depth.MipLevels = 1;
            depth.ArraySize = 1;
            depth.Format = DXGI_FORMAT_D32_FLOAT;
            depth.SampleDesc.Count = 1;
            depth.BindFlags = D3D11_BIND_DEPTH_STENCIL;
            CheckHR(device->CreateTexture2D(&depth, nullptr, &chain.depth), "CreateTexture2D(depth)");
            CheckHR(device->CreateDepthStencilView(chain.depth.Get(), nullptr, &chain.depthView), "CreateDepthStencilView");
        }
    }

    void Initialise(const D3D11Options& options) {
        std::uint32_t count = 0;
        Check(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr), "xrEnumerateInstanceExtensionProperties(count)");
        std::vector<XrExtensionProperties> extensions(count, {XR_TYPE_EXTENSION_PROPERTIES});
        Check(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, extensions.data()), "xrEnumerateInstanceExtensionProperties");
        const bool d3d11Supported = std::any_of(extensions.begin(), extensions.end(), [](const auto& extension) {
            return std::strcmp(extension.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0;
        });
        if (!d3d11Supported) throw std::runtime_error("OpenXR runtime does not support XR_KHR_D3D11_enable");
        const char* extension = XR_KHR_D3D11_ENABLE_EXTENSION_NAME;
        XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};
        std::snprintf(create.applicationInfo.applicationName, sizeof(create.applicationInfo.applicationName), "%s",
            options.applicationName ? options.applicationName : "KF2VR standalone");
        create.applicationInfo.applicationVersion = 1;
        std::snprintf(create.applicationInfo.engineName, sizeof(create.applicationInfo.engineName), "KF2VR");
        create.applicationInfo.engineVersion = 1;
        create.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        create.enabledExtensionCount = 1;
        create.enabledExtensionNames = &extension;
        Check(xrCreateInstance(&create, &instance), "xrCreateInstance");
        XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
        Check(xrGetInstanceProperties(instance, &properties), "xrGetInstanceProperties");
        info.name = properties.runtimeName;
        info.version = std::to_string(XR_VERSION_MAJOR(properties.runtimeVersion)) + "." +
            std::to_string(XR_VERSION_MINOR(properties.runtimeVersion)) + "." + std::to_string(XR_VERSION_PATCH(properties.runtimeVersion));
        XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
        systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        Check(xrGetSystem(instance, &systemInfo, &system), "xrGetSystem(HMD)");
        XrSystemProperties systemProperties{XR_TYPE_SYSTEM_PROPERTIES};
        Check(xrGetSystemProperties(instance, system, &systemProperties), "xrGetSystemProperties");
        info.system = systemProperties.systemName;
        Check(xrEnumerateEnvironmentBlendModes(instance, system, kStereo, 0, &count, nullptr), "xrEnumerateEnvironmentBlendModes(count)");
        std::vector<XrEnvironmentBlendMode> modes(count);
        Check(xrEnumerateEnvironmentBlendModes(instance, system, kStereo, count, &count, modes.data()), "xrEnumerateEnvironmentBlendModes");
        modes.resize(count);
        if (!Contains(modes, XR_ENVIRONMENT_BLEND_MODE_OPAQUE))
            throw std::runtime_error("An opaque PCVR environment blend mode is required");
        CreateDevice(options);
        XrGraphicsBindingD3D11KHR graphics{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR};
        graphics.device = device.Get();
        XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
        sessionInfo.next = &graphics;
        sessionInfo.systemId = system;
        Check(xrCreateSession(instance, &sessionInfo, &session), "xrCreateSession(D3D11)");
        CreateSpaces(options);
        CreateActions();
        CreateSwapchains();
        initialised = true;
    }

    void PollEvents() {
        for (;;) {
            XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
            const XrResult result = xrPollEvent(instance, &event);
            if (result == XR_EVENT_UNAVAILABLE) break;
            Check(result, "xrPollEvent");
            if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
                sessionState = XR_SESSION_STATE_LOSS_PENDING;
                quit = true;
            } else if (event.type == XR_TYPE_EVENT_DATA_EVENTS_LOST) {
                // Missing a session transition makes frame ownership ambiguous.
                throw std::runtime_error("OpenXR event queue overflow; restart the session");
            } else if (event.type == XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING) {
                const auto& changed = *reinterpret_cast<const XrEventDataReferenceSpaceChangePending*>(&event);
                if (changed.session == session && (changed.referenceSpaceType == trackingType ||
                    changed.referenceSpaceType == XR_REFERENCE_SPACE_TYPE_LOCAL)) {
                    ++counters.referenceSpaceChanges;
                    // System recenter may announce LOCAL even while we use STAGE.
                    // Treat it as an explicit eye-height/heading calibration,
                    // at changeTime, rather than baking the old origin into VR.
                    pendingOriginChanges.push_back(changed.changeTime);
                }
            } else if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                const auto& changed = *reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
                if (changed.session != session) continue;
                if (sessionState == XR_SESSION_STATE_FOCUSED && changed.state != XR_SESSION_STATE_FOCUSED) {
                    ++counters.focusLosses;
                    ClearHaptics();
                }
                sessionState = changed.state;
                if (sessionState == XR_SESSION_STATE_READY && !running) {
                    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO};
                    begin.primaryViewConfigurationType = kStereo;
                    Check(xrBeginSession(session, &begin), "xrBeginSession");
                    running = true;
                } else if (sessionState == XR_SESSION_STATE_STOPPING && running) {
                    Check(xrEndSession(session), "xrEndSession");
                    running = false;
                } else if (sessionState == XR_SESSION_STATE_EXITING || sessionState == XR_SESSION_STATE_LOSS_PENDING) {
                    quit = true;
                }
            }
        }
    }

    XrActionStateGetInfo ActionInfo(XrAction action, std::size_t hand) const {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};
        get.action = action;
        get.subactionPath = handPaths[hand];
        return get;
    }

    float FloatInput(XrAction action, std::size_t hand, bool& active) {
        const auto get = ActionInfo(action, hand);
        XrActionStateFloat value{XR_TYPE_ACTION_STATE_FLOAT};
        Check(xrGetActionStateFloat(session, &get, &value), "xrGetActionStateFloat");
        active = value.isActive && std::isfinite(value.currentState);
        return active ? std::clamp(value.currentState, 0.f, 1.f) : 0.f;
    }

    bool BoolInput(XrAction action, std::size_t hand, bool& active) {
        const auto get = ActionInfo(action, hand);
        XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
        Check(xrGetActionStateBoolean(session, &get, &value), "xrGetActionStateBoolean");
        active = value.isActive != XR_FALSE;
        return active && value.currentState;
    }

    bool PoseActive(XrAction action, std::size_t hand) {
        const auto get = ActionInfo(action, hand);
        XrActionStatePose value{XR_TYPE_ACTION_STATE_POSE};
        Check(xrGetActionStatePose(session, &get, &value), "xrGetActionStatePose");
        return value.isActive;
    }

    template<typename PoseFrame>
    void LocatePose(XrSpace space, Transform<PoseFrame, frames::Tracking>& pose, bool& valid, bool& tracked) {
        XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
        Check(xrLocateSpace(space, trackingSpace, displayTime, &location), "xrLocateSpace");
        valid = (location.locationFlags & kValidPose) == kValidPose && FinitePose(location.pose);
        tracked = valid && (location.locationFlags & kTrackedPose) == kTrackedPose;
        if (valid) pose = Pose<PoseFrame>(location.pose);
    }

    template<typename GripFrame, typename AimFrame>
    void LocateHand(std::size_t index, HandState<GripFrame, AimFrame>& hand) {
        if (PoseActive(gripPose, index))
            LocatePose(gripSpaces[index], hand.grip, hand.poseValid, hand.poseTracked);
        if (PoseActive(aimPose, index))
            LocatePose(aimSpaces[index], hand.aim, hand.aimPoseValid, hand.aimPoseTracked);
        hand.triggerAxis = FloatInput(trigger, index, hand.triggerActive);
        hand.gripAxis = FloatInput(squeeze, index, hand.gripActive);
        const auto get = ActionInfo(stick, index);
        XrActionStateVector2f axis{XR_TYPE_ACTION_STATE_VECTOR2F};
        Check(xrGetActionStateVector2f(session, &get, &axis), "xrGetActionStateVector2f");
        hand.stickActive = axis.isActive && std::isfinite(axis.currentState.x) && std::isfinite(axis.currentState.y);
        if (hand.stickActive) {
            hand.stickX = std::clamp(axis.currentState.x, -1.f, 1.f);
            hand.stickY = std::clamp(axis.currentState.y, -1.f, 1.f);
        }
        hand.primaryPressed = BoolInput(primary, index, hand.primaryActive);
        hand.secondaryPressed = BoolInput(secondary, index, hand.secondaryActive);
        hand.stickPressed = BoolInput(stickClick, index, hand.stickClickActive);
        hand.menuPressed = BoolInput(menu, index, hand.menuActive);
        hand.menuHoldPressed = BoolInput(menuHold, index, hand.menuHoldActive);
    }

    template<typename EyeFrame>
    void CopyEye(const XrView& source, EyeView<EyeFrame>& eye, bool tracked) {
        eye.poseValid = frame.viewsValid;
        eye.poseTracked = frame.viewsValid && tracked;
        if (eye.poseValid) {
            eye.pose = Pose<EyeFrame>(source.pose);
            eye.fov = {source.fov.angleLeft, source.fov.angleRight, source.fov.angleUp, source.fov.angleDown};
        }
    }

    void LocateFrame() {
        views = {{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}}};
        XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
        locate.viewConfigurationType = kStereo;
        locate.displayTime = displayTime;
        locate.space = trackingSpace;
        XrViewState viewState{XR_TYPE_VIEW_STATE};
        std::uint32_t count = 0;
        Check(xrLocateViews(session, &locate, &viewState, 2, &count, views.data()), "xrLocateViews");
        frame.viewsValid = count == 2 && (viewState.viewStateFlags & kValidViews) == kValidViews;
        for (const auto& view : views)
            frame.viewsValid = frame.viewsValid && FinitePose(view.pose) && ValidFov(view.fov);
        const bool tracked = (viewState.viewStateFlags & kTrackedViews) == kTrackedViews;
        CopyEye(views[0], frame.eyeLeft, tracked);
        CopyEye(views[1], frame.eyeRight, tracked);
        if (!frame.viewsValid) ++counters.invalidViews;
        LocatePose(viewSpace, frame.head, frame.headPoseValid, frame.headPoseTracked);

        // A freshly zero-initialised frame prevents stale input or poses after
        // focus loss, device disconnect, inactive action, or tracking failure.
        if (sessionState != XR_SESSION_STATE_FOCUSED) return;
        XrActiveActionSet active{actionSet, XR_NULL_PATH};
        XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
        sync.countActiveActionSets = 1;
        sync.activeActionSets = &active;
        const XrResult result = xrSyncActions(session, &sync);
        if (result == XR_SESSION_NOT_FOCUSED) return;
        Check(result, "xrSyncActions");
        if (quit) return;
        frame.actionsSynced = true;
        LocateHand(0, frame.handLeft);
        LocateHand(1, frame.handRight);
    }

    bool EndFrame(bool staticQuad = false) {
        if (!frameBegun) { error = "EndFrame called without a begun frame"; return false; }
        XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        layer.space = trackingSpace;
        layer.viewCount = 2;
        layer.views = projectionViews.data();
        const XrCompositionLayerBaseHeader* layers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&layer)
        };
        const XrCompositionLayerBaseHeader* quadLayers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quadLayer)
        };
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
        end.displayTime = displayTime;
        end.environmentBlendMode = blendMode;
        // The head-locked quad needs no located views; the stereo layer does.
        const bool quad = staticQuad && quadReady.load(std::memory_order_acquire);
        const bool submit = quad ? (frame.shouldRender && !quit)
                                 : (rendered && frame.shouldRender && frame.viewsValid && !quit);
        end.layerCount = submit ? 1u : 0u;
        end.layers = submit ? (quad ? quadLayers : layers) : nullptr;
        // Clear ownership before calling the runtime, even on submission error.
        // Retrying an uncertain xrEndFrame can violate its call-order contract.
        frameBegun = false;
        rendered = false;
        const XrResult result = [&] { Measure measure(collectTimings,counters.endFrameMs);return xrEndFrame(session, &end); }();
        try {
            Check(result, "xrEndFrame");
            ++counters.ended;
            if (submit) ++counters.submitted;
            return true;
        } catch (const std::exception& exception) { return Failure(exception); }
    }

    void Shutdown() noexcept {
        ClearHaptics();
        // No game-wide ClearState: the supplied device belongs to the caller.
        // Runtime texture references are unbound in RenderEyes itself.
        rendered = false;
        if (frameBegun) {
            try { EndFrame(); } catch (...) {}
        }
        ownerFrameOpen.store(false, std::memory_order_release);
        quadReady.store(false, std::memory_order_release);
        if (quadChain != XR_NULL_HANDLE) xrDestroySwapchain(quadChain);
        quadChain = XR_NULL_HANDLE;
        quadLayer = {XR_TYPE_COMPOSITION_LAYER_QUAD};
        for (auto& chain : swapchains) {
            chain.targets.clear();
            chain.depthView.Reset();
            chain.depth.Reset();
            chain.images.clear(); // Runtime owns these borrowed texture pointers.
            if (chain.handle != XR_NULL_HANDLE) xrDestroySwapchain(chain.handle);
            chain = {};
        }
        for (auto& space : aimSpaces) {
            if (space != XR_NULL_HANDLE) xrDestroySpace(space);
            space = XR_NULL_HANDLE;
        }
        for (auto& space : gripSpaces) {
            if (space != XR_NULL_HANDLE) xrDestroySpace(space);
            space = XR_NULL_HANDLE;
        }
        if (viewSpace != XR_NULL_HANDLE) xrDestroySpace(viewSpace);
        if (trackingSpace != XR_NULL_HANDLE) xrDestroySpace(trackingSpace);
        viewSpace = trackingSpace = XR_NULL_HANDLE;
        // xrEndSession is legal only in STOPPING. Destroying a running session
        // is allowed and avoids waiting indefinitely for exit state events.
        if (session != XR_NULL_HANDLE) xrDestroySession(session);
        session = XR_NULL_HANDLE;
        if (actionSet != XR_NULL_HANDLE) xrDestroyActionSet(actionSet);
        actionSet = XR_NULL_HANDLE;
        gripPose = aimPose = trigger = squeeze = stick = primary = secondary = stickClick = menu = menuHold = vibration = XR_NULL_HANDLE;
        if (instance != XR_NULL_HANDLE) xrDestroyInstance(instance);
        instance = XR_NULL_HANDLE;
        system = XR_NULL_SYSTEM_ID;
        context.Reset();
        device.Reset();
        sessionState = XR_SESSION_STATE_UNKNOWN;
        initialised = running = frameBegun = renderAttempted = rendered = false;
        frame = {};
    }
};

OpenXrD3D11Backend::OpenXrD3D11Backend() : impl_(std::make_unique<Impl>()) {}
OpenXrD3D11Backend::~OpenXrD3D11Backend() { impl_->Shutdown(); }
bool OpenXrD3D11Backend::Initialise() { return Initialise(D3D11Options{}); }
bool OpenXrD3D11Backend::Initialise(const D3D11Options& options) {
    impl_->Shutdown();
    impl_->error.clear();
    impl_->info = {};
    impl_->counters = {};
    impl_->collectTimings = options.collectTimings;
    impl_->quit = false;
    impl_->colorFormat = DXGI_FORMAT_UNKNOWN;
    try { impl_->Initialise(options); return true; }
    catch (const std::exception& exception) {
        impl_->Failure(exception);
        impl_->Shutdown();
        return false;
    }
}
void OpenXrD3D11Backend::Shutdown() {
    auto& p = *impl_;
    // Stop the loading-plate path first, then wait for any frame it holds.
    p.quadReady.store(false, std::memory_order_release);
    AcquireSRWLockExclusive(&p.frameLock);
    p.Shutdown();
    ReleaseSRWLockExclusive(&p.frameLock);
}
namespace {
struct FrameLockScope {
    SRWLOCK* lock;
    explicit FrameLockScope(SRWLOCK& l) : lock(&l) { AcquireSRWLockExclusive(lock); }
    ~FrameLockScope() { ReleaseSRWLockExclusive(lock); }
};
} // namespace
bool OpenXrD3D11Backend::RequestHaptic(unsigned hand, float amplitude, float durationSeconds) {
    return impl_->QueueHaptic(hand,amplitude,durationSeconds);
}

bool OpenXrD3D11Backend::BeginFrame(FrameState& out) {
    out = {};
    auto& p = *impl_;
    FrameLockScope frameLock(p.frameLock);
    if (!p.initialised || p.quit) return false;
    p.error.clear(); // Normal idle states never inherit an earlier recoverable error.
    if (p.frameBegun) { p.error = "BeginFrame called before previous EndFrame"; return false; }
    try {
        p.PollEvents();
        out.state = PublicState(p.sessionState);
        if (!p.running || p.quit) { p.ClearHaptics(); return false; }
        XrFrameWaitInfo wait{XR_TYPE_FRAME_WAIT_INFO};
        XrFrameState state{XR_TYPE_FRAME_STATE};
        { Measure measure(p.collectTimings,p.counters.waitFrameMs);p.Check(xrWaitFrame(p.session, &wait, &state), "xrWaitFrame"); }
        XrFrameBeginInfo begin{XR_TYPE_FRAME_BEGIN_INFO};
        { Measure measure(p.collectTimings,p.counters.beginFrameMs);p.Check(xrBeginFrame(p.session, &begin), "xrBeginFrame"); }
        p.frameBegun = true;
        p.ownerFrameOpen.store(true, std::memory_order_release);
        p.renderAttempted = p.rendered = false;
        p.displayTime = state.predictedDisplayTime;
        p.frame = {};
        p.frame.state = PublicState(p.sessionState);
        p.frame.shouldRender = state.shouldRender != XR_FALSE;
        p.frame.predictedDisplayTime = static_cast<double>(state.predictedDisplayTime) * 1e-9;
        p.frame.predictedDisplayPeriod = static_cast<double>(state.predictedDisplayPeriod) * 1e-9;
        p.frame.poseSampleId = ++p.counters.begun;
        const auto due = std::remove_if(p.pendingOriginChanges.begin(), p.pendingOriginChanges.end(),
            [&](XrTime time) { return time <= p.displayTime; });
        if (due != p.pendingOriginChanges.end()) ++p.referenceSpaceEpoch;
        p.pendingOriginChanges.erase(due, p.pendingOriginChanges.end());
        p.frame.referenceSpaceEpoch = p.referenceSpaceEpoch;
        { Measure measure(p.collectTimings,p.counters.locateMs);p.LocateFrame(); }
        p.DrainHaptics();
        out = p.frame;
        return true;
    } catch (const std::exception& exception) {
        p.ClearHaptics();
        p.Failure(exception);
        if (p.frameBegun) p.EndFrame();
        p.ownerFrameOpen.store(false, std::memory_order_release);
        out = {};
        out.state = PublicState(p.sessionState);
        return false;
    }
}

bool OpenXrD3D11Backend::RenderEyes(const EyeRenderCallback& render) {
    auto& p = *impl_;
    if (!p.frameBegun || p.renderAttempted) {
        p.error = "RenderEyes requires one begun frame and at most one render attempt";
        return false;
    }
    p.renderAttempted = true;
    if (!p.frame.shouldRender || !p.frame.viewsValid || p.quit) return true; // zero-layer frame
    if (!render) { p.error = "RenderEyes requires a render callback"; return false; }
    try {
        for (std::size_t eye = 0; eye < 2; ++eye) {
            auto& chain = p.swapchains[eye];
            XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
            std::uint32_t index = 0;
            { Measure measure(p.collectTimings,p.counters.acquireMs);p.Check(xrAcquireSwapchainImage(chain.handle, &acquire, &index), "xrAcquireSwapchainImage"); }
            chain.acquired = true;
            XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            wait.timeout = 1'000'000'000; // One second; a stuck runtime is a fatal diagnostic.
            const XrResult waitResult = [&] { Measure measure(p.collectTimings,p.counters.waitImageMs);return xrWaitSwapchainImage(chain.handle, &wait); }();
            if (waitResult == XR_TIMEOUT_EXPIRED) throw std::runtime_error("xrWaitSwapchainImage timed out after one second");
            p.Check(waitResult, "xrWaitSwapchainImage");
            chain.waited = true;
            if (index >= chain.images.size()) throw std::runtime_error("OpenXR returned an invalid swapchain image index");
            const D3D11EyeTarget target{eye == 0 ? Eye::Left : Eye::Right,
                chain.width, chain.height, p.colorFormat, chain.images[index].texture,
                chain.targets[index].Get(), chain.depthView.Get()};
            bool success = false;
            try { success = render(p.frame, target); }
            catch (const std::exception& exception) { p.error = std::string("Eye render callback threw: ") + exception.what(); }
            catch (...) { p.error = "Eye render callback threw an unknown exception"; }
            // Ensure neither the engine nor our context keeps writing to a
            // released XR colour image; caller restores its own pipeline.
            p.context->OMSetRenderTargets(0, nullptr, nullptr);
            XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            const XrResult released = [&] { Measure measure(p.collectTimings,p.counters.releaseMs);return xrReleaseSwapchainImage(chain.handle, &release); }();
            chain.acquired = chain.waited = false;
            p.Check(released, "xrReleaseSwapchainImage");
            if (!success) {
                if (p.error.empty()) p.error = "Eye render callback returned false; stereo layer dropped";
                return false;
            }
            auto& projection = p.projectionViews[eye];
            projection = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
            projection.pose = p.views[eye].pose;
            projection.fov = p.views[eye].fov;
            projection.subImage.swapchain = chain.handle;
            projection.subImage.imageRect.extent = {static_cast<std::int32_t>(chain.width), static_cast<std::int32_t>(chain.height)};
            projection.subImage.imageArrayIndex = 0;
        }
        CheckHR(p.device->GetDeviceRemovedReason(), "D3D11 device health after stereo render");
        p.rendered = true;
        return true;
    } catch (const std::exception& exception) {
        p.context->OMSetRenderTargets(0, nullptr, nullptr);
        // A successfully waited image must be released even if rendering fails.
        // Failed waits cannot be released; Shutdown destroys that swapchain.
        for (auto& chain : p.swapchains) {
            if (chain.acquired && chain.waited) {
                XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                xrReleaseSwapchainImage(chain.handle, &release);
                chain.acquired = chain.waited = false;
            }
        }
        p.rendered = false;
        return p.Failure(exception);
    }
}

bool OpenXrD3D11Backend::EndFrame() { return EndFrame(false); }
bool OpenXrD3D11Backend::EndFrame(bool staticQuad) {
    auto& p = *impl_;
    FrameLockScope frameLock(p.frameLock);
    const bool result = p.EndFrame(staticQuad);
    p.ownerFrameOpen.store(false, std::memory_order_release);
    return result;
}
bool OpenXrD3D11Backend::CreateStaticQuad(std::uint32_t width, std::uint32_t height, const std::uint8_t* rgba,
                                          float widthMetres, float distanceMetres) {
    auto& p = *impl_;
    FrameLockScope frameLock(p.frameLock);
    if (!p.initialised || p.quit || !rgba || width == 0 || height == 0 || !std::isfinite(widthMetres) ||
        !std::isfinite(distanceMetres) || widthMetres <= 0 || distanceMetres <= 0 || p.quadChain != XR_NULL_HANDLE ||
        !p.context) {
        p.error = "CreateStaticQuad: backend not ready, bad image or quad already created";
        return false;
    }
    XrSwapchain created = XR_NULL_HANDLE;
    try {
        XrSwapchainCreateInfo create{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        create.createFlags = XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT;
        create.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
        create.format = p.colorFormat;
        create.sampleCount = 1;
        create.width = width;
        create.height = height;
        create.faceCount = 1;
        create.arraySize = 1;
        create.mipCount = 1;
        p.Check(xrCreateSwapchain(p.session, &create, &created), "xrCreateSwapchain(static quad)");
        std::uint32_t count = 0;
        p.Check(xrEnumerateSwapchainImages(created, 0, &count, nullptr), "xrEnumerateSwapchainImages(static quad count)");
        if (count == 0) throw std::runtime_error("static quad swapchain has no images");
        std::vector<XrSwapchainImageD3D11KHR> images(count, {XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR});
        p.Check(xrEnumerateSwapchainImages(created, count, &count,
            reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data())), "xrEnumerateSwapchainImages(static quad)");
        // A static-image swapchain is acquired, written and released exactly once.
        XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        std::uint32_t index = 0;
        p.Check(xrAcquireSwapchainImage(created, &acquire, &index), "xrAcquireSwapchainImage(static quad)");
        XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
        wait.timeout = 1000000000; // 1 s
        p.Check(xrWaitSwapchainImage(created, &wait), "xrWaitSwapchainImage(static quad)");
        if (index >= images.size() || !images[index].texture) throw std::runtime_error("static quad image index out of range");
        // The chosen swapchain format is RGBA or BGRA sRGB; the plate is RGBA.
        std::vector<std::uint8_t> pixels(rgba, rgba + static_cast<std::size_t>(width) * height * 4);
        if (p.colorFormat == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
            for (std::size_t i = 0; i + 3 < pixels.size(); i += 4) std::swap(pixels[i], pixels[i + 2]);
        p.context->UpdateSubresource(images[index].texture, 0, nullptr, pixels.data(), width * 4, 0);
        XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        p.Check(xrReleaseSwapchainImage(created, &release), "xrReleaseSwapchainImage(static quad)");
        p.quadLayer = {XR_TYPE_COMPOSITION_LAYER_QUAD};
        p.quadLayer.layerFlags = 0;
        p.quadLayer.space = p.viewSpace;
        p.quadLayer.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
        p.quadLayer.subImage.swapchain = created;
        p.quadLayer.subImage.imageRect = {{0, 0}, {static_cast<std::int32_t>(width), static_cast<std::int32_t>(height)}};
        p.quadLayer.subImage.imageArrayIndex = 0;
        p.quadLayer.pose = {{0, 0, 0, 1}, {0, 0, -distanceMetres}};
        p.quadLayer.size = {widthMetres, widthMetres * static_cast<float>(height) / static_cast<float>(width)};
        p.quadChain = created;
        p.quadReady.store(true, std::memory_order_release);
        return true;
    } catch (const std::exception& exception) {
        if (created != XR_NULL_HANDLE) xrDestroySwapchain(created);
        return p.Failure(exception, false);
    }
}
OpenXrD3D11Backend::QuadFrame OpenXrD3D11Backend::SubmitStaticQuadFrame() {
    auto& p = *impl_;
    if (!p.quadReady.load(std::memory_order_acquire)) return QuadFrame::Unavailable;
    if (!TryAcquireSRWLockExclusive(&p.frameLock)) return QuadFrame::Busy;
    struct Release { SRWLOCK* lock; ~Release() { ReleaseSRWLockExclusive(lock); } } release{&p.frameLock};
    if (p.ownerFrameOpen.load(std::memory_order_acquire) || p.frameBegun || !p.initialised || !p.running || p.quit ||
        !p.quadReady.load(std::memory_order_acquire)) return QuadFrame::Busy;
    // No PollEvents and no FrameState writes: session transitions stay with the
    // owner, which polls them on its next BeginFrame.
    try {
        XrFrameWaitInfo wait{XR_TYPE_FRAME_WAIT_INFO};
        XrFrameState state{XR_TYPE_FRAME_STATE};
        p.Check(xrWaitFrame(p.session, &wait, &state), "xrWaitFrame(static quad)");
        XrFrameBeginInfo begin{XR_TYPE_FRAME_BEGIN_INFO};
        p.Check(xrBeginFrame(p.session, &begin), "xrBeginFrame(static quad)");
        const XrCompositionLayerBaseHeader* layers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&p.quadLayer)
        };
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
        end.displayTime = state.predictedDisplayTime;
        end.environmentBlendMode = p.blendMode;
        const bool submit = state.shouldRender != XR_FALSE;
        end.layerCount = submit ? 1u : 0u;
        end.layers = submit ? layers : nullptr;
        p.Check(xrEndFrame(p.session, &end), "xrEndFrame(static quad)");
        p.quadFrames.fetch_add(1, std::memory_order_relaxed);
        return QuadFrame::Submitted;
    } catch (const std::exception&) {
        // Not fatal: the owner's own frame loop decides session health. Give
        // up on the plate after repeated refusals so a failing runtime is not
        // hammered from the movie thread.
        if (p.quadFailures.fetch_add(1, std::memory_order_relaxed) + 1 >= 8)
            p.quadReady.store(false, std::memory_order_release);
        return QuadFrame::Failed;
    }
}
std::uint64_t OpenXrD3D11Backend::StaticQuadFrames() const { return impl_->quadFrames.load(std::memory_order_relaxed); }
std::uint64_t OpenXrD3D11Backend::StaticQuadFailures() const { return impl_->quadFailures.load(std::memory_order_relaxed); }
void OpenXrD3D11Backend::RequestExit() {
    auto& p = *impl_;
    if (!p.running || p.quit) { p.quit = true; return; }
    try { p.Check(xrRequestExitSession(p.session), "xrRequestExitSession"); }
    catch (const std::exception& exception) { p.Failure(exception); }
}
std::uint32_t OpenXrD3D11Backend::RecommendedWidth() const { return impl_->swapchains[0].width; }
std::uint32_t OpenXrD3D11Backend::RecommendedHeight() const { return impl_->swapchains[0].height; }
ID3D11Device* OpenXrD3D11Backend::Device() const { return impl_->device.Get(); }
ID3D11DeviceContext* OpenXrD3D11Backend::Context() const { return impl_->context.Get(); }
bool OpenXrD3D11Backend::ShouldQuit() const { return impl_->quit; }
SessionState OpenXrD3D11Backend::State() const { return PublicState(impl_->sessionState); }
const std::string& OpenXrD3D11Backend::LastError() const { return impl_->error; }
const RuntimeInfo& OpenXrD3D11Backend::Info() const { return impl_->info; }
const FrameCounters& OpenXrD3D11Backend::Counters() const { return impl_->counters; }
} // namespace kf2vr::xr


