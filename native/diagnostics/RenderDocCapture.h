// Optional local presentation investigation. The normal adapter never loads
// RenderDoc. Its documented API provides a complete frame and shader inputs.
#pragma once
#if __has_include("../../third_party/renderdoc/RenderDoc_1.46_64/renderdoc_app.h")
#include "../../third_party/renderdoc/RenderDoc_1.46_64/renderdoc_app.h"

class PresentationCapture {
    RENDERDOC_API_1_6_0* api_=nullptr;
    unsigned next_=0;
public:
    void Initialize(bool replay, const wchar_t* captureRoot) {
        wchar_t requested[32768]{};
        if (!replay || !captureRoot[0] || !GetEnvironmentVariableW(
            L"KF2VR_DIAGNOSTIC_RENDERDOC",requested,32768)) return;
        // Explicit diagnostic path only; no DLL search in the game directory.
        const auto path=std::filesystem::path(requested);
        if (!path.is_absolute() || path.filename()!=L"renderdoc.dll") return;
        const auto module=LoadLibraryExW(requested,nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module) return;
        const auto getApi=reinterpret_cast<pRENDERDOC_GetAPI>(GetProcAddress(module,"RENDERDOC_GetAPI"));
        if (!getApi || !getApi(eRENDERDOC_API_Version_1_6_0,reinterpret_cast<void**>(&api_))) return;
        api_->MaskOverlayBits(0,0);
        api_->SetCaptureFilePathTemplate((std::filesystem::path(captureRoot)/L"presentation").string().c_str());
    }
    bool Tick(int slot, bool presentationProbe) {
        constexpr int slots[]={104,116,136};
        if (!api_ || !presentationProbe || next_>=3 || slot<slots[next_]) return false;
        api_->TriggerCapture();
        ++next_;
        return true;
    }
};
#else
class PresentationCapture {
public:
    void Initialize(bool,const wchar_t*) {}
    bool Tick(int,bool) { return false; }
};
#endif
