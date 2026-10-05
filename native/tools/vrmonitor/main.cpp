// Background observer only: never submits, waits for poses, or changes settings.
#include <windows.h>
#include <openvr.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <map>

int wmain(int argc,wchar_t** argv) {
    if(argc!=4 && argc!=5) { std::fprintf(stderr,"usage: monitor <absolute openvr_api.dll> <output.csv> <seconds 1-600> [stop-file]\n");return 2; }
    wchar_t* end=nullptr;const auto seconds=std::wcstol(argv[3],&end,10);
    if(!end || *end || seconds<1 || seconds>600)return 2;
    const auto dll=LoadLibraryExW(argv[1],nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if(!dll){std::fprintf(stderr,"OpenVR loader error %lu\n",GetLastError());return 3;}
    const auto init=reinterpret_cast<decltype(&vr::VR_InitInternal2)>(GetProcAddress(dll,"VR_InitInternal2"));
    const auto shutdown=reinterpret_cast<decltype(&vr::VR_ShutdownInternal)>(GetProcAddress(dll,"VR_ShutdownInternal"));
    const auto get=reinterpret_cast<decltype(&vr::VR_GetGenericInterface)>(GetProcAddress(dll,"VR_GetGenericInterface"));
    if(!init || !shutdown || !get){FreeLibrary(dll);return 4;}
    vr::EVRInitError error=vr::VRInitError_None;
    init(&error,vr::VRApplication_Background,nullptr);
    if(error!=vr::VRInitError_None){std::fprintf(stderr,"OpenVR init error %d\n",error);FreeLibrary(dll);return 5;}
    auto* system=static_cast<vr::IVRSystem*>(get(vr::IVRSystem_Version,&error));
    auto* compositor=static_cast<vr::IVRCompositor*>(get(vr::IVRCompositor_Version,&error));
    if(!system || !compositor){std::fprintf(stderr,"OpenVR interface error %d\n",error);shutdown();FreeLibrary(dll);return 6;}
    FILE* output=nullptr;
    if(_wfopen_s(&output,argv[2],L"wb") || !output){shutdown();FreeLibrary(dll);return 7;}
    std::setvbuf(output,nullptr,_IOFBF,64*1024);
    std::fputs("observedTickMs,scenePid,frameIndex,systemSeconds,refreshHz,refreshError,recommendedWidth,recommendedHeight,motionSmoothingEnabled,motionSmoothingSupported,presents,misPresented,dropped,reprojectionFlags,throttled,predicted,preSubmitGpuMs,postSubmitGpuMs,totalRenderGpuMs,compositorGpuMs,compositorCpuMs,compositorIdleMs,clientIntervalMs,presentCpuMs,waitPresentCpuMs,submitMs,transferLatencyMs,firstObservedTickMs,firstPollGapMs\n",output);
    // Keep the latest revision of each entry in the small compositor history;
    // present/drop counters can change while a frame is still being displayed.
    struct Entry {vr::Compositor_FrameTiming frame;ULONGLONG tick;std::uint32_t pid,width,height;float hz;int hzError;bool smoothing,supported;ULONGLONG firstTick,firstPollGap;};
    std::map<std::uint32_t,Entry> pending;
    const auto write=[&](const Entry& e) {
        const auto& f=e.frame;
        std::fprintf(output,"%llu,%u,%u,%.9f,%.3f,%d,%u,%u,%d,%d,%u,%u,%u,%u,%u,%u,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%llu,%llu\n",
            e.tick,e.pid,f.m_nFrameIndex,f.m_flSystemTimeInSeconds,e.hz,e.hzError,e.width,e.height,e.smoothing,e.supported,
            f.m_nNumFramePresents,f.m_nNumMisPresented,f.m_nNumDroppedFrames,f.m_nReprojectionFlags,
            VR_COMPOSITOR_NUMBER_OF_THROTTLED_FRAMES(f),VR_COMPOSITOR_ADDITIONAL_PREDICTED_FRAMES(f),
            f.m_flPreSubmitGpuMs,f.m_flPostSubmitGpuMs,f.m_flTotalRenderGpuMs,f.m_flCompositorRenderGpuMs,
            f.m_flCompositorRenderCpuMs,f.m_flCompositorIdleCpuMs,f.m_flClientFrameIntervalMs,
            f.m_flPresentCallCpuMs,f.m_flWaitForPresentCpuMs,f.m_flSubmitFrameMs,f.m_flTransferLatencyMs,e.firstTick,e.firstPollGap);
    };
    const auto deadline=GetTickCount64()+static_cast<ULONGLONG>(seconds)*1000;
    std::uint32_t previousPid=0,lastEmitted=0;
    unsigned polls=0;
    auto previousPoll=GetTickCount64();
    while(GetTickCount64()<deadline) {
        if(argc==5 && GetFileAttributesW(argv[4])!=INVALID_FILE_ATTRIBUTES)break;
        const auto pid=compositor->GetCurrentSceneFocusProcess();
        const bool sceneChanged=pid!=previousPid;
        if(sceneChanged) { for(const auto& [index,e]:pending)write(e);pending.clear();lastEmitted=0;previousPid=pid; }
        std::uint32_t width=0,height=0;system->GetRecommendedRenderTargetSize(&width,&height);
        vr::ETrackedPropertyError propertyError=vr::TrackedProp_Success;
        const float hz=system->GetFloatTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd,vr::Prop_DisplayFrequency_Float,&propertyError);
        const bool smoothing=compositor->IsMotionSmoothingEnabled(),supported=compositor->IsMotionSmoothingSupported();
        if(polls==0)std::printf("{\"refreshHz\":%.3f,\"refreshError\":%d,\"recommendedWidth\":%u,\"recommendedHeight\":%u,\"motionSmoothingEnabled\":%s,\"motionSmoothingSupported\":%s,\"scenePid\":%u}\n",
            hz,propertyError,width,height,smoothing?"true":"false",supported?"true":"false",pid);
        std::array<vr::Compositor_FrameTiming,128> frames{};frames[0].m_nSize=sizeof(frames[0]);
        const auto count=compositor->GetFrameTimings(frames.data(),static_cast<std::uint32_t>(frames.size()));
        const auto tick=GetTickCount64();
        const auto pollGap=tick-previousPoll;previousPoll=tick;
        // The API has no per-frame PID. Skip the first history after a scene
        // switch to avoid attributing the previous app's frames to the game.
        if(sceneChanged && count>0 && count<=frames.size())lastEmitted=frames[count-1].m_nFrameIndex;
        for(std::uint32_t i=0;i<count && i<frames.size();++i) {
            const auto& frame=frames[i];
            if(frame.m_nFrameIndex<=lastEmitted)continue;
            const auto existing=pending.find(frame.m_nFrameIndex);
            const auto firstTick=existing==pending.end()?tick:existing->second.firstTick;
            const auto firstGap=existing==pending.end()?pollGap:existing->second.firstPollGap;
            pending[frame.m_nFrameIndex]={frame,tick,pid,width,height,hz,static_cast<int>(propertyError),smoothing,supported,firstTick,firstGap};
        }
        while(pending.size()>64) {auto first=pending.begin();write(first->second);lastEmitted=first->first;pending.erase(first);}
        if(++polls%4==0)std::fflush(output);
        Sleep(250);
    }
    for(const auto& [index,e]:pending)write(e);
    std::fclose(output);shutdown();FreeLibrary(dll);return 0;
}
