// xrprobe -- the M1 measurement that decides ADR-0002.
//
// Reports, per candidate runtime, the facts the M0 intake record lists as "not
// established": the graphics adapter the XR runtime wants us on (its LUID), the
// recommended per-eye resolution and sample count, the display refresh rate,
// and the runtime's own name and version.
//
// WHAT IT DELIBERATELY DOES NOT DO: create a session, create a swapchain, or
// render. It goes as far as instance + system + view configuration and stops.
// That keeps it a measurement rather than a miniature engine, and keeps the
// footprint small enough to reason about.
//
// It WILL start the XR runtime (SteamVR) as a side effect of asking, so do not
// run it during a game session. Build it now; run it when the machine is free.
//
// Usage:  xrprobe --openxr
//         xrprobe --openvr
//
// One backend per invocation, on purpose. The research pack: "Choose one for
// the first game integration; do not debug two runtime backends
// simultaneously." Probing them in separate processes keeps that honest.

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int Usage() {
    std::printf("usage: xrprobe --openxr | --openvr\n");
    return 2;
}

static void Row(const char* k, const std::string& v) {
    std::printf("  %-28s %s\n", k, v.c_str());
}

// ===========================================================================
// Adapter enumeration. Independent of any XR runtime.
//
// This box has two GPUs -- a discrete RTX 3080 Ti and the Ryzen's integrated
// Radeon -- so "which adapter" is a real question, not a formality. The XR
// runtime names the adapter it wants by LUID; if our D3D11 device is created on
// a different one, every submitted eye texture needs a cross-adapter copy. That
// is a silent throughput cliff, not an error, which is exactly the kind of
// problem that gets misdiagnosed as "VR is just slow".
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_6.h>
#pragma comment(lib, "dxgi.lib")

static int ListAdapters(const char* wantLuid) {
    IDXGIFactory1* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)))) {
        std::printf("CreateDXGIFactory1 failed\n");
        return 1;
    }
    std::printf("dxgi adapters\n");
    IDXGIAdapter1* a = nullptr;
    for (UINT i = 0; factory->EnumAdapters1(i, &a) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 d{};
        a->GetDesc1(&d);
        char luid[32];
        std::snprintf(luid, sizeof luid, "%08lX:%08lX",
                      static_cast<unsigned long>(d.AdapterLuid.HighPart),
                      static_cast<unsigned long>(d.AdapterLuid.LowPart));
        char name[256];
        std::snprintf(name, sizeof name, "%ws", d.Description);
        const bool match = wantLuid && _stricmp(luid, wantLuid) == 0;
        std::printf("  [%u] %-34s LUID %s  VRAM %5.0f MB  %s%s\n", i, name, luid,
                    d.DedicatedVideoMemory / 1048576.0,
                    (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? "(software) " : "",
                    match ? "  <== XR runtime wants this one" : "");
        a->Release();
    }
    factory->Release();
    return 0;
}

// ===========================================================================
#if KF2VR_WITH_OPENXR

#define XR_USE_GRAPHICS_API_D3D11
#define XR_USE_PLATFORM_WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

static std::string XrStr(XrResult r) {
    return "XrResult(" + std::to_string(static_cast<int>(r)) + ")";
}

static int ProbeOpenXr() {
    std::printf("openxr probe\n");

    uint32_t extCount = 0;
    xrEnumerateInstanceExtensionProperties(nullptr, 0, &extCount, nullptr);
    std::vector<XrExtensionProperties> exts(extCount, {XR_TYPE_EXTENSION_PROPERTIES});
    xrEnumerateInstanceExtensionProperties(nullptr, extCount, &extCount, exts.data());

    bool haveD3D11 = false;
    for (const auto& e : exts) {
        if (std::strcmp(e.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0) {
            haveD3D11 = true;
        }
    }

    Row("extensions", std::to_string(extCount));
    Row("KHR_D3D11_enable", haveD3D11 ? "yes" : "NO -- blocks the D3D11 path");
    if (!haveD3D11) return 1;

    const char* enabled[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo ici{XR_TYPE_INSTANCE_CREATE_INFO};
    // snprintf, not strncpy: strncpy is deprecated under /W4 here, and this
    // always NUL-terminates within the fixed-size array.
    std::snprintf(ici.applicationInfo.applicationName,
                  XR_MAX_APPLICATION_NAME_SIZE, "%s", "kf2vr-xrprobe");
    ici.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    ici.enabledExtensionCount = 1;
    ici.enabledExtensionNames = enabled;

    XrInstance inst = XR_NULL_HANDLE;
    XrResult r = xrCreateInstance(&ici, &inst);
    if (XR_FAILED(r)) {
        Row("xrCreateInstance", "FAILED " + XrStr(r));
        std::printf("  (no runtime available, or it refused the D3D11 extension)\n");
        return 1;
    }

    XrInstanceProperties ip{XR_TYPE_INSTANCE_PROPERTIES};
    xrGetInstanceProperties(inst, &ip);
    Row("runtime", ip.runtimeName);
    Row("runtime version",
        std::to_string(XR_VERSION_MAJOR(ip.runtimeVersion)) + "." +
        std::to_string(XR_VERSION_MINOR(ip.runtimeVersion)) + "." +
        std::to_string(XR_VERSION_PATCH(ip.runtimeVersion)));

    XrSystemGetInfo sgi{XR_TYPE_SYSTEM_GET_INFO};
    sgi.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId sys = XR_NULL_SYSTEM_ID;
    r = xrGetSystem(inst, &sgi, &sys);
    if (XR_FAILED(r)) {
        Row("xrGetSystem", "FAILED " + XrStr(r) + " (headset off or absent?)");
        xrDestroyInstance(inst);
        return 1;
    }

    XrSystemProperties sp{XR_TYPE_SYSTEM_PROPERTIES};
    xrGetSystemProperties(inst, sys, &sp);
    Row("system", sp.systemName);
    Row("max swapchain", std::to_string(sp.graphicsProperties.maxSwapchainImageWidth) + " x " +
                         std::to_string(sp.graphicsProperties.maxSwapchainImageHeight));
    Row("orientation tracking", sp.trackingProperties.orientationTracking ? "yes" : "no");
    Row("position tracking",    sp.trackingProperties.positionTracking ? "yes" : "no");

    // The adapter LUID. This is the answer to "which GPU must our D3D11 device
    // be created on" -- get it wrong and every submitted texture needs a
    // cross-adapter copy, which is a silent performance cliff rather than an
    // error. KF2's device is created by the game, so if this LUID is not the
    // game's adapter, that is a finding, not a detail.
    PFN_xrGetD3D11GraphicsRequirementsKHR getReq = nullptr;
    xrGetInstanceProcAddr(inst, "xrGetD3D11GraphicsRequirementsKHR",
                          reinterpret_cast<PFN_xrVoidFunction*>(&getReq));
    if (getReq) {
        XrGraphicsRequirementsD3D11KHR req{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
        if (XR_SUCCEEDED(getReq(inst, sys, &req))) {
            char luid[64];
            std::snprintf(luid, sizeof luid, "%08lX:%08lX",
                          static_cast<unsigned long>(req.adapterLuid.HighPart),
                          static_cast<unsigned long>(req.adapterLuid.LowPart));
            Row("adapter LUID", luid);
            Row("min feature level", std::to_string(static_cast<int>(req.minFeatureLevel)));
        }
    }

    uint32_t viewCount = 0;
    xrEnumerateViewConfigurationViews(inst, sys,
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &viewCount, nullptr);
    std::vector<XrViewConfigurationView> views(viewCount, {XR_TYPE_VIEW_CONFIGURATION_VIEW});
    xrEnumerateViewConfigurationViews(inst, sys,
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, viewCount, &viewCount, views.data());
    Row("stereo views", std::to_string(viewCount));
    for (uint32_t i = 0; i < viewCount; ++i) {
        const std::string k = "  view[" + std::to_string(i) + "] recommended";
        Row(k.c_str(), std::to_string(views[i].recommendedImageRectWidth) + " x " +
                       std::to_string(views[i].recommendedImageRectHeight) +
                       ", " + std::to_string(views[i].recommendedSwapchainSampleCount) + "x MSAA");
    }

    xrDestroyInstance(inst);
    std::printf("  (no session created; nothing rendered)\n");
    return 0;
}
#else
static int ProbeOpenXr() { std::printf("built without OpenXR\n"); return 3; }
#endif

// ===========================================================================
#if KF2VR_WITH_OPENVR
#include <openvr.h>

static std::string VrString(vr::IVRSystem* s, vr::TrackedDeviceIndex_t dev,
                            vr::ETrackedDeviceProperty prop) {
    vr::ETrackedPropertyError err = vr::TrackedProp_Success;
    const uint32_t n = s->GetStringTrackedDeviceProperty(dev, prop, nullptr, 0, &err);
    if (n == 0) return "(none)";
    std::vector<char> buf(n + 1, 0);
    s->GetStringTrackedDeviceProperty(dev, prop, buf.data(), n, &err);
    return std::string(buf.data());
}

static int ProbeOpenVr() {
    std::printf("openvr probe\n");

    vr::EVRInitError err = vr::VRInitError_None;
    // VRApplication_Background: attach without taking the scene from whatever
    // else is running. A probe has no business becoming the presenting app.
    vr::IVRSystem* sys = vr::VR_Init(&err, vr::VRApplication_Background);
    if (!sys) {
        Row("VR_Init", std::string("FAILED ") + vr::VR_GetVRInitErrorAsEnglishDescription(err));
        return 1;
    }

    Row("driver",  VrString(sys, vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_TrackingSystemName_String));
    Row("model",   VrString(sys, vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_ModelNumber_String));
    Row("manufacturer", VrString(sys, vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_ManufacturerName_String));

    uint32_t w = 0, h = 0;
    sys->GetRecommendedRenderTargetSize(&w, &h);
    Row("recommended per-eye", std::to_string(w) + " x " + std::to_string(h));

    vr::ETrackedPropertyError perr = vr::TrackedProp_Success;
    const float hz = sys->GetFloatTrackedDeviceProperty(
        vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_DisplayFrequency_Float, &perr);
    if (perr == vr::TrackedProp_Success) {
        char buf[80];
        std::snprintf(buf, sizeof buf, "%.2f Hz  (%.2f ms per interval)",
                      hz, hz > 0.f ? 1000.f / hz : 0.f);
        Row("display frequency", buf);
    }

    int32_t adapter = -1;
    sys->GetDXGIOutputInfo(&adapter);
    Row("DXGI adapter index", std::to_string(adapter));

    vr::VR_Shutdown();
    std::printf("  (background app; no scene taken, nothing rendered)\n");
    return 0;
}
#else
static int ProbeOpenVr() { std::printf("built without OpenVR\n"); return 3; }
#endif

// ===========================================================================
int main(int argc, char** argv) {
    if (argc < 2) return Usage();
    if (std::strcmp(argv[1], "--openxr") == 0) return ProbeOpenXr();
    if (std::strcmp(argv[1], "--openvr") == 0) return ProbeOpenVr();
    if (std::strcmp(argv[1], "--adapters") == 0) return ListAdapters(argc > 2 ? argv[2] : nullptr);
    return Usage();
}
