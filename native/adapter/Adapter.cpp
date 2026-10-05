#include "ReplayInput.h"
#include <fstream>
#include "MotionClip.h"
#include "MotionRuntime.h"
#include "localtest/Bridge.h"
#include "IndependentLocomotion.h"
#include "FocusTiming.h"
#include "VRSessionInput.h"
#include "RingsideBell.h"
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <bcrypt.h>
#include <wrl/client.h>
#include <intrin.h>
#include <share.h>
#include <MinHook.h>
#include <atomic>
#include <array>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>
#include "kf2vr/adapter/VerifiedLayout.h"
#include "kf2vr/adapter/LocalWorldGate.h"
#include "kf2vr/xr/OpenXrD3D11Backend.h"
#include "AtlasBlit.h"
#include "LoadingPlate.h"
#include "StereoViews.h"
#include "XrGamepad.h"
#include "HeadAim.h"
#include "WeaponHaptics.h"
#include "HandWrist.h"
#include "PresentHandoff.h"
#include "GameScript.h"
#include "ScriptField.h"
#include "ScriptWriteBatch.h"
#include "FrameTiming.h"
#include "FrameDrilldown.h"
#include "RenderPassReadback.h"
#include "EyeResolution.h"
#include "GpuFrameTiming.h"
#include "../portal/PortalCapture.h"
#include "../portal/PortalHitscan.h"
#include "WeaponIsolation.h"
#include "WeaponContext.h"
#include "WeaponHandling.h"
#include "PerkContext.h"
#include "DamagePopupScore.h"
#include "ReloadMeshPop.h"
#include "WeaponRuntimeDispatch.h"
#include "VmCallbackFilter.h"
#include "VmEntryIdentity.h"
#include "VmSampleTiming.h"
#include "RPGBackBlast.h"
#include "ProjectileToss.h"
#include "MenuPointerInput.h"
#include "MenuNativeLayout.h"
#include "MenuCursor.h"
#include "MenuRenderLayers.h"
#include "SpatialHud.h"
#include "SpatialHudStockDraw.h"
#include "ForegroundDepth.h"
#include "HudTextAlpha.h"
#include "RenderCommand.h"
#include "kf2vr/Basis.h"
#include "../diagnostics/D3D11Capture.h"
#include "../diagnostics/RenderDocCapture.h"

using Microsoft::WRL::ComPtr;
namespace {
// Passive mode only records evidence. Explicit local stereo mode temporarily
// replaces the validated scene-family view list and publishes a virtual pad.
// Function ABIs and RVAs come from docs/re/01-render-integration-map.md and
// are enabled only after independently hashing this exact executable.
constexpr char kHash[]="77ab9c2cf43aeaa3038274fff3822064815a3ea02a1b3c81870cdc12a885c994";
FILE* logFile=nullptr;
SRWLOCK logLock=SRWLOCK_INIT;
uintptr_t gameBase=0;
std::atomic<unsigned long long> presents{},views{},families{};
std::atomic<unsigned long long> padPolls{},padActivePolls{};
std::atomic<DWORD> worldDrawThread{0};
std::atomic<HWND> replayProbeWindow{nullptr};
unsigned eyeRenderPercent=100; // Updated only on the XR owner thread before Canvas construction.
bool reuseVmIdentity=true; // Matched A/B build: disable only redundant-read removal.
bool fastVmIdentity=false; // Opt-in experiment; live VM entry arguments only.
bool batchHandWrites=false; // Opt-in experiment; one validated update per SupplyHands.
// Both eyes of an accepted render pair share one pose lease, so hands, weapon
// and spatial HUD are placed once, before the left eye. The switch restores the
// original repeat before the right eye for A/B comparison.
bool perEyePresentation=false;
FILE* benchmarkFile=nullptr;
bool renderPassReadbackVerified=false;
kf2vr::adapter::timing::FrameDrilldown frameDrilldown;
namespace pinned=kf2vr::adapter::pinned;
namespace xr=kf2vr::xr;
namespace adapter=kf2vr::adapter;
namespace menuNative=kf2vr::adapter::menu_native;
adapter::RenderCommandQueue renderQueue;
// Everything Present needs from the game side for one frame. The game thread
// fills it after the frame's last draw and hands it over through renderQueue,
// so it reaches the render side in draw order and Present never reads script.
struct FramePacket {
    xr::FrameState frame;
    bool atlasReady=false,menuFrame=false,menuBackdrop=true;
    bool needsEyes=false; // Both eye snapshots must have been copied.
    adapter::SpatialMenuPanel menuPanel;
    adapter::SpatialMenuPointer menuPointer;
    adapter::ComfortEffects effects;
    int benchmarkPhase=0;
    kf2vr::Vec3 pawnLocation{};
    std::array<kf2vr::adapter::RenderPassReadback,2> renderPasses{};
};
// Touched only by render commands and Present.
struct RenderSide {
    FramePacket packet;
    bool xrPending=false; // An XR frame is begun and not yet ended.
    std::uint64_t begunSample=0;
    std::array<bool,2> eyeCopied{};
    bool fault=false; // A command for the next packet failed.
};
// The game thread owns the rest, except the fields marked atomic; -onethread
// makes both sides one thread. Deliberately no global destructor calls into
// OpenXR under loader lock. Stop is explicit in Present.
struct DemoRuntime {
    xr::OpenXrD3D11Backend backend;
    adapter::AtlasBlit blit;
    adapter::StereoViews stereo;
    adapter::SpatialMenu menu;
    adapter::XrGamepad gamepad;
    adapter::HeadAim headAim;
    adapter::HeadAim::RenderPairLease renderPairLease;
    kf2vr::Vec3 renderWorldViewOffset{}; // Captured by the left eye; leased to its right eye.
    bool pairPresented=false; // The left eye placed hands/weapon/HUD for the current pair.
    adapter::GameScript script;
    xr::FrameState frame;
    RenderSide render;
    adapter::timing::GpuFrameTiming gpuTiming;
    std::atomic<bool> gpuTimingReady{false};
    std::uint64_t gpuTimingSample=0;
    unsigned gpuTimingWidth=0,gpuTimingHeight=0;
    double benchmarkLastPresent=0;
    std::uint64_t benchmarkLastSubmitted=0;
    int benchmarkLastPhase=0;
    bool benchmarkInvalid=false;
    bool benchmarkViewFrozen=false;
    xr::FrameState benchmarkView; // Level head at its first tracked position; eyes/hands relative to it.
    ULONGLONG sampleTick=0;
    // These are the only runtime ownership fields touched by other threads.
    std::atomic<DWORD> ownerThread{0};
    std::atomic<IDXGISwapChain*> ownerSwapchain{nullptr};
    std::atomic<bool> failureRequested{false};
    // Render-side events whose gameplay cleanup must run on the game thread.
    std::atomic<bool> gameStopRequested{false};
    std::atomic<std::uint64_t> resizeNotices{0};
    std::uint64_t resizeNoticesSeen=0;
    adapter::PresentHandoff presentHandoff;
    // Swapchain identity is borrowed and used only for pointer comparison.
    // pending: the game holds a begun XR frame for its current draw, until the
    // frame packet hands it to Present. RenderSide::xrPending is the XR state.
    bool attempted=false,pending=false,atlasReady=false;
    std::atomic<bool> ready{false},failed{false};
    // Static head-locked LOADING quad (LoadingPlate.h): submitted wherever the
    // game has no world to show, including from the loading movie's thread.
    std::atomic<bool> loadingPlate{false};
    std::uint64_t loadingPlateLogged=0;
    std::atomic<unsigned> width{0},height{0}; // Desktop backbuffer.
    std::atomic<std::uint64_t> resizeGeneration{0};
    std::uint64_t atlasDrops=0;
    bool captureAttempted=false;
    std::array<kf2vr::adapter::RenderPassReadback,2> renderPasses{};
    std::array<bool,11> nativeKeys{};
    void* nativeInputClient=nullptr;
    std::uint64_t nativeInputTicks=0;
    std::uint64_t weaponObservations=0;
    void* controlledPawn=nullptr;
    void* heldWeapon=nullptr;
    void* handsBridge=nullptr;
    void* session=nullptr; // Borrowed from the persistent, script-owned viewport.
    std::atomic<bool> sessionRegistered{false};
    std::atomic<bool> travelling{false};
    adapter::SessionMenuInput sessionMenuInput;
    adapter::SnapTurnInput snapTurn;
    float turnAxis=0;
    std::uint64_t sessionInputSample=0;
    void* controlledController=nullptr;
    bool handsValid=false;
    // The script's current lean allowance, read with the hands and reused by
    // the render pass so both eyes and hands share one bound.
    float leanMetres=adapter::kDefaultLeanMetres;
    unsigned aimScope=0;
    adapter::WeaponAimStack itemAim;
    adapter::WeaponHandlingStack weaponHandling;
    unsigned viewRotationScope=0;
    pinned::NativeRotator intendedViewDelta{};
    std::uint64_t handCapture=0,aimObservations=0;
    std::uint64_t walkBobSuppressions=0,forcedLookSuppressions=0;
    std::uint64_t recoilViewSuppressions=0,cameraEffectSuppressions=0;
    std::uint64_t roomMovementTicks=0;
    void* replayPawn=nullptr;
    kf2vr::Quat replayBody;
    int eyePass=-1;
    bool menuVisible=false,menuFrame=false,menuBackdrop=true;
    bool menuInputBlocked=false;
    adapter::MenuPointerInput menuInput;
    adapter::SpatialHud hud;
    void* menuTarget=nullptr;
    void* menuCursorViewport=nullptr;
    menuNative::Point menuCursor;
    bool menuCursorActive=false;
    std::uint64_t menuCursorReads=0;
    std::uint64_t menuInputRefusals=0;
    std::uint64_t menuFrames=0;
    ComPtr<ID3D11Texture2D> eyeAtlas;
    ComPtr<ID3D11ShaderResourceView> eyeAtlasView;
};
DemoRuntime* demo=nullptr;
void UpdateSession(void* session);
void* MenuOwner() { return demo ? (demo->session ? demo->session : demo->handsBridge) : nullptr; }
// Gameplay hooks act once XR is claimed, on the world's game thread. Present and
// render commands run on the owner (render) thread; -onethread makes them one.
bool GameOwnsXr() {
    return demo && demo->ownerThread.load(std::memory_order_acquire) &&
        GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire);
}
bool stereoRequested=false;
// -kf2vr-threaded-render without -onethread: UE3's render thread draws frame N
// while the game thread ticks N+1. Stereo only; replay and portals stay serial.
bool threadedRender=false;
bool networkRequested=false;
bool handReplayRequested=false;
bool inputReplayRequested=false;
adapter::ReplayInput replayInput;
static adapter::motion::Runtime motionRuntime;
static kf2vr::localtest::Bridge localTestControl;
bool portalRequested=false;
bool singleViewDiagnostic=false;
wchar_t stopRequestPath[32768]{};
wchar_t captureRootPath[32768]{};
wchar_t playablePath[32768]{};
PresentationCapture presentationCapture;
// Owned by the thread that executes render commands. Game-side code changes
// them only through renderQueue, so each change lands between the same draws.
adapter::ForegroundDepth foregroundDepth;
std::vector<adapter::ForegroundDepth> foregroundDepthStack;
adapter::HudTextAlpha hudTextAlpha;
bool OnRenderCommandThread() { return GetCurrentThreadId()==renderQueue.ExecutingThread(); }
using ClearColor=void(STDMETHODCALLTYPE*)(ID3D11DeviceContext*,ID3D11RenderTargetView*,const FLOAT*);
using SetTargets=void(STDMETHODCALLTYPE*)(ID3D11DeviceContext*,UINT,ID3D11RenderTargetView* const*,ID3D11DepthStencilView*);
using DrawIndexed=void(STDMETHODCALLTYPE*)(ID3D11DeviceContext*,UINT,UINT,INT);
ClearColor originalClearColor=nullptr;
SetTargets originalSetTargets=nullptr;
DrawIndexed originalDrawIndexed=nullptr;
std::uint64_t hudAlphaTargets=0;
std::uint64_t hudAlphaDraws=0;
// Bounded selector diagnostics: opaque notches can survive when every
// translucent tile loses coverage. Record the actual D3D path, not asset files.
bool selectorDiagnostics=false;
unsigned selectorRegistrations=0,selectorClears=0,selectorDraws=0;
using Draw=void(STDMETHODCALLTYPE*)(ID3D11DeviceContext*,UINT,UINT);
Draw originalDraw=nullptr;
void Log(const char* format,...);
void TraceSelectorTarget(ID3D11DeviceContext* context,ID3D11RenderTargetView* view,
    const char* phase,bool corrected,const FLOAT* clear=nullptr) {
    if(!view) return;
    ComPtr<ID3D11Resource> resource;view->GetResource(&resource);
    ComPtr<ID3D11Texture2D> texture;if(FAILED(resource.As(&texture))) return;
    D3D11_TEXTURE2D_DESC target{};texture->GetDesc(&target);
    if(target.Width!=768 || target.Height!=768) return;
    auto& count=clear ? selectorClears : selectorDraws;
    if(count>=64) return;
    ++count;
    if(clear) {
        Log("KF2VR_SELECTOR_GPU phase=%s sample=%u resource=%p format=%u rgba=%.3f,%.3f,%.3f,%.3f",
            phase,count,resource.Get(),target.Format,clear[0],clear[1],clear[2],clear[3]);return;
    }
    ComPtr<ID3D11BlendState> blend;FLOAT factors[4]{};UINT mask=0;
    context->OMGetBlendState(&blend,factors,&mask);
    D3D11_BLEND_DESC desc{};if(blend) blend->GetDesc(&desc);
    const auto& rt=desc.RenderTarget[0];
    ComPtr<ID3D11ShaderResourceView> srv;context->PSGetShaderResources(0,1,&srv);
    ComPtr<ID3D11Resource> source;ComPtr<ID3D11Texture2D> sourceTexture;
    D3D11_TEXTURE2D_DESC src{};
    if(srv) { srv->GetResource(&source);if(SUCCEEDED(source.As(&sourceTexture))) sourceTexture->GetDesc(&src); }
    Log("KF2VR_SELECTOR_GPU phase=%s sample=%u resource=%p format=%u corrected=%d blend=%d write=%u rgb=%u,%u,%u alpha=%u,%u,%u source=%p size=%ux%u mips=%u",
        phase,count,resource.Get(),target.Format,corrected,rt.BlendEnable,rt.RenderTargetWriteMask,
        rt.SrcBlend,rt.DestBlend,rt.BlendOp,rt.SrcBlendAlpha,rt.DestBlendAlpha,rt.BlendOpAlpha,
        source.Get(),src.Width,src.Height,src.MipLevels);
}
using ClearDepth=void(STDMETHODCALLTYPE*)(ID3D11DeviceContext*,ID3D11DepthStencilView*,UINT,FLOAT,UINT8);
ClearDepth originalClearDepth=nullptr;
std::uint64_t preservedForegroundDepth=0;
thread_local void* lastLocalFamily=nullptr;
thread_local void* lastLocalPlayer=nullptr;
thread_local void* lastLocalViewport=nullptr;
using CalcView=void*(*)(void*,void*,void*,void*,void*,void*);
using SubmitScene=void(*)(void*,void*);
using Present=HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*,UINT,UINT);
using Resize=HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*,UINT,UINT,UINT,DXGI_FORMAT,UINT);
CalcView originalCalc=nullptr;
SubmitScene originalSubmit=nullptr;
// Engine portal captures of VRPortal actors; idle unless one renders.
kf2vr::portal::PortalCapture portalCapture;
kf2vr::portal::PortalHitscan portalHitscan;
Present originalPresent=nullptr;
Resize originalResize=nullptr;
using ViewportDraw=void(*)(void*,void*,void*);
ViewportDraw originalViewportDraw=nullptr;
menuNative::GetMousePositionFn originalGetMousePosition=nullptr;
pinned::PlayerControllerTickFn originalControllerTick=nullptr;
using ProcessInternal=void(*)(void*,void*,void*);
ProcessInternal originalProcessInternal=nullptr;
using TraceStart=void(*)(void*,void*,void*);
TraceStart originalTraceStart=nullptr;
TraceStart originalPhysicalStart=nullptr;
adapter::WeaponViewRotationFn originalWeaponViewRotation=nullptr;
using GetPad=DWORD(WINAPI*)(DWORD,XINPUT_STATE*);
using GetPadCaps=DWORD(WINAPI*)(DWORD,DWORD,XINPUT_CAPABILITIES*);
GetPad originalGetPad=nullptr;
GetPadCaps originalGetPadCaps=nullptr;
std::atomic<bool> virtualPadEnabled=false;
void Log(const char* format,...) {
    if (!logFile) return;
    AcquireSRWLockExclusive(&logLock);
    std::fprintf(logFile,"tick_ms=%llu thread=%lu ",GetTickCount64(),GetCurrentThreadId());
    va_list args; va_start(args,format); std::vfprintf(logFile,format,args); va_end(args);
    std::fputc('\n',logFile); std::fflush(logFile);
    ReleaseSRWLockExclusive(&logLock);
}
bool HashFile(const wchar_t* path,std::string& result) {
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    if (file==INVALID_HANDLE_VALUE) return false;
    BCRYPT_ALG_HANDLE algorithm=nullptr;
    BCRYPT_HASH_HANDLE hash=nullptr;
    bool success=false;
    if (BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0 &&
        BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0) {
        std::array<unsigned char,65536> data{}; DWORD count=0;
        bool ok=true;
        for (;;) {
            if (!ReadFile(file,data.data(),static_cast<DWORD>(data.size()),&count,nullptr)) { ok=false; break; }
            if (!count) break;
            if (BCryptHashData(hash,data.data(),count,0)<0) { ok=false; break; }
        }
        std::array<unsigned char,32> digest{};
        if (ok && BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0)>=0) {
            char hex[65]{};
            for (unsigned i=0;i<32;++i) std::snprintf(hex+i*2,3,"%02x",digest[i]);
            result=hex; success=true;
        }
    }
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file); return success;
}
bool Interesting(unsigned long long count) { return count<6 || count%300==0; }
bool Readable(const void* pointer,size_t bytes) {
    const uintptr_t start=reinterpret_cast<uintptr_t>(pointer);
    if (!start || start+bytes<start) return false;
    uintptr_t cursor=start;
    while (cursor<start+bytes) {
        MEMORY_BASIC_INFORMATION region{};
        if (!VirtualQuery(reinterpret_cast<const void*>(cursor),&region,sizeof(region)) || region.State!=MEM_COMMIT ||
            (region.Protect&(PAGE_NOACCESS|PAGE_GUARD))) return false;
        const uintptr_t end=reinterpret_cast<uintptr_t>(region.BaseAddress)+region.RegionSize;
        if (end<=cursor) return false;
        cursor=end;
    }
    return true;
}
void DescribeView(void* family,void* view) {
    if (!Readable(family,pinned::family::kStaticPrefixSize) || !Readable(view,pinned::view::kAllocationSize)) {
        Log("View snapshot refused unreadable memory"); return;
    }
    pinned::FamilySnapshot f{}; pinned::ViewSnapshot v{};
    pinned::ReadFamily({static_cast<const std::byte*>(family),pinned::family::kStaticPrefixSize},f);
    pinned::ReadView({static_cast<const std::byte*>(view),pinned::view::kAllocationSize},v);
    Log("ViewFields family_count=%d capacity=%d target=%p scene=%p view_family=%p state=%p rect=%.1f,%.1f,%.1f,%.1f view_translation=%.3f,%.3f,%.3f projection_diag=%.5f,%.5f,%.5f,%.5f",
        f.count,f.capacity,reinterpret_cast<void*>(f.renderTarget),reinterpret_cast<void*>(f.scene),reinterpret_cast<void*>(v.family),reinterpret_cast<void*>(v.state),v.x,v.y,v.width,v.height,
        v.viewMatrix.m[3][0],v.viewMatrix.m[3][1],v.viewMatrix.m[3][2],v.projectionMatrix.m[0][0],v.projectionMatrix.m[1][1],v.projectionMatrix.m[2][2],v.projectionMatrix.m[3][3]);
}
void* HookCalc(void* player,void* family,void* location,void* rotation,void* viewport,void* drawer) {
    adapter::timing::Scope timing(adapter::timing::ViewSetup);
    void* result=originalCalc(player,family,location,rotation,viewport,drawer);
    const auto count=++views;
    if (result && reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase==0x676cca) {
        lastLocalFamily=family;
        lastLocalPlayer=player;
        lastLocalViewport=viewport;
        DWORD unclaimed=0;
        worldDrawThread.compare_exchange_strong(unclaimed,GetCurrentThreadId(),std::memory_order_release);
    }
    if (Interesting(count)) {
        Log("CalcSceneView count=%llu player=%p family=%p viewport=%p result=%p caller_rva=%llx",count,player,family,viewport,result,
            static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase));
        if (result) {
            if (demo && GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire)) {
                demo->script.Initialise(gameBase);
                auto* client=demo->script.Read<void*>(player,L"ViewportClient");
                Log("SessionViewport custom=%d session=%p",demo->script.IsClass(client,L"VRGameViewportClient"),
                    demo->script.Read<void*>(client,L"VRSession"));
            }
            DescribeView(family,result);
            pinned::LocalWorldSnapshot world{};
            const bool standalone=pinned::CheckStandaloneWorld(gameBase,reinterpret_cast<uintptr_t>(player),
                [](uintptr_t source,void* target,size_t bytes) {
                    if (!Readable(reinterpret_cast<void*>(source),bytes)) return false;
                    std::memcpy(target,reinterpret_cast<void*>(source),bytes); return true;
                },world);
            Log("LocalWorld standalone=%d status=%d mode=%u world=%p controller=%p netDriver=%p",standalone,
                static_cast<int>(world.status),world.netMode,reinterpret_cast<void*>(world.world),
                reinterpret_cast<void*>(world.controller),reinterpret_cast<void*>(world.netDriver));
        }
    }
    return result;
}
// Threaded UE3 can stop and recreate its render thread ("RenderingThread %i").
// Whichever thread drains the adapter's commands owns rendering; the previous
// one has exited, so nothing else holds render-side state.
void FollowRenderThread() {
    if (!threadedRender || !demo) return;
    DWORD owner=demo->ownerThread.load(std::memory_order_acquire);
    const DWORD current=GetCurrentThreadId();
    if (!owner || current==owner || current!=renderQueue.DrainingThread()) return;
    const DWORD previous=owner;
    if (demo->ownerThread.compare_exchange_strong(owner,current,std::memory_order_acq_rel))
        Log("Render thread changed owner=%lu previous=%lu",current,previous);
}
void RequestThreadFailure(const char* operation) {
    // Runtime objects belong to the published owner thread. Only the atomic
    // request and internally locked gamepad may be touched by another thread.
    if (!demo->failureRequested.exchange(true,std::memory_order_acq_rel))
        Log("Stereo failed: %s ran outside owner thread; stop requested",operation);
    demo->gamepad.Cancel();
}
bool LocalWorld(void* localPlayer,pinned::LocalWorldSnapshot& out) {
    const bool standalone=pinned::CheckStandaloneWorld(gameBase,reinterpret_cast<uintptr_t>(localPlayer),
        [](uintptr_t source,void* target,size_t bytes) {
            if (!Readable(reinterpret_cast<void*>(source),bytes)) return false;
            std::memcpy(target,reinterpret_cast<void*>(source),bytes); return true;
        },out);
    if (standalone) return true;
    // Explicit network launch plus the current owning controller's completed
    // package handshake. The memory walk still proves local-player/world identity.
    // Never apply an XR pose to another controller or a dedicated-server world.
    if (!networkRequested || !demo || out.status!=pinned::LocalWorldStatus::NetworkMode ||
        out.netMode!=3 || !out.netDriver) return false;
    auto& script=demo->script;
    script.Initialise(gameBase);
    auto* controller=reinterpret_cast<void*>(out.controller);
    return pinned::IsAdmittedNetworkClient(out,networkRequested,
        script.IsClass(controller,L"KF2VRNetPlayerController"),
        script.Read<int>(controller,L"NativeNetworkReady"));
}
bool ReadRotation(void* controller,pinned::NativeRotator& out) {
    auto* rotation=static_cast<std::byte*>(controller)+pinned::kActorRotation;
    if (!Readable(rotation,sizeof(out))) return false;
    std::memcpy(&out,rotation,sizeof(out)); return true;
}
adapter::pinned::NativeRotator RotationFromQuat(const kf2vr::Quat& q) {
    const auto forward=q.Rotate({1,0,0}),right=q.Rotate({0,1,0}),up=q.Rotate({0,0,1});
    constexpr double units=65536.0/6.283185307179586;
    return {static_cast<int>(std::lround(std::atan2(forward.z,std::hypot(forward.x,forward.y))*units)),
        static_cast<int>(std::lround(std::atan2(forward.y,forward.x)*units)),
        static_cast<int>(std::lround(std::atan2(-right.z,up.z)*units))};
}
void SupplyLockTargets(void* bridge);
std::uint64_t SupplyHands(void* bridge) {
    auto& script=demo->script;
    if (script.Read<void*>(bridge,L"PC")!=demo->controlledController || !demo->controlledPawn) return 0;
    const int previousGrips=script.Read<int>(bridge,L"NativeGripMask");
    const int previousTriggers=script.Read<int>(bridge,L"NativeTriggerMask");
    demo->handsBridge=bridge;
    if (demo->session) script.Write(demo->session,L"Hands",bridge);
    script.Invoke(bridge,script.FindFunction(bridge,L"RefreshEyeBase"),nullptr);
    const auto eyeBase=script.Read<kf2vr::Vec3>(bridge,L"NativeEyeBase");
    adapter::ScriptWriteBatch writes(script,bridge,batchHandWrites);
    const auto commitWrites=[&] {
        if (writes.Commit()) return true;
        Log("HandWriteBatch invalid=1 reason=update-refused");
        demo->handsValid=false;
        demo->failureRequested.store(true,std::memory_order_release);
        return false;
    };
    adapter::pinned::NativeRotator current{};
    ReadRotation(demo->controlledController,current);
    adapter::AppliedHeadAim aim{};
    auto frame=demo->frame;
    if (inputReplayRequested) {
        if (demo->replayPawn!=demo->controlledPawn) {
            demo->replayPawn=demo->controlledPawn;
            demo->replayBody=adapter::NativeActorRotation({0,current.yaw,0});
        }
        aim.reference={}; aim.bodyRotation=demo->replayBody;
        frame=replayInput.Next(reinterpret_cast<uintptr_t>(bridge),reinterpret_cast<uintptr_t>(demo->controlledPawn));
        demo->frame=frame;
        Log("ReplayInput sample=%llu time=%.6f epoch=%llu focused=%d synced=%d finished=%d left=%.3f right=%.3f active=%d,%d valid=%d,%d",
            static_cast<unsigned long long>(frame.poseSampleId),frame.predictedDisplayTime,
            static_cast<unsigned long long>(frame.referenceSpaceEpoch),frame.state==xr::SessionState::Focused,
            frame.actionsSynced,replayInput.Finished(),frame.handLeft.triggerAxis,frame.handRight.triggerAxis,
            frame.handLeft.triggerActive,frame.handRight.triggerActive,frame.handLeft.poseValid,frame.handRight.poseValid);
    } else if (handReplayRequested) {
        // Explicit offline fixture: same tracking conversion as real OpenXR.
        // Never enabled by a headset focus loss or normal play.
        if (demo->replayPawn!=demo->controlledPawn) {
            demo->replayPawn=demo->controlledPawn;
            demo->replayBody=adapter::NativeActorRotation({0,current.yaw,0});
        }
        aim.reference={}; aim.bodyRotation=demo->replayBody;
        frame.state=xr::SessionState::Focused; frame.actionsSynced=true;
        frame.headPoseValid=frame.headPoseTracked=true;
        frame.shouldRender=frame.viewsValid=true;
        frame.handLeft.poseTracked=frame.handRight.poseTracked=true;
        frame.handLeft.poseValid=frame.handLeft.aimPoseValid=true;
        frame.handRight.poseValid=frame.handRight.aimPoseValid=true;
        frame.handLeft.grip.pos={-.2f,-.25f,-.65f};
        frame.handRight.grip.pos={.2f,-.25f,-.25f};
        frame.handLeft.aim.rot={}; frame.handRight.aim.rot={};
        // The deterministic HUD fixture intentionally inspects both palms.
        frame.handLeft.grip.rot=kf2vr::Quat::FromAxisAngle({0,0,1},1.5707963f);
        frame.handRight.grip.rot=kf2vr::Quat::FromAxisAngle({0,0,1},-1.5707963f);
        // No XR session supplies display time here. Advance it with real time
        // so time-gated consumers (the 120 ms wrist-reveal dwell) can complete.
        frame.predictedDisplayTime=static_cast<double>(GetTickCount64())/1000.0;
        frame.handLeft.gripAxis=frame.handRight.gripAxis=0;
        frame.handLeft.triggerAxis=frame.handRight.triggerAxis=0;
        frame.handLeft.primaryPressed=frame.handLeft.secondaryPressed=false;
        if(wcsstr(GetCommandLineW(),L"-kf2vr-motion-fixture")) {
            // Explicit non-XR validation publishes the SAME authored input sample.
            frame.poseSampleId=GetTickCount64();
            frame.handLeft.aim.pos=frame.handLeft.grip.pos;
            frame.handRight.aim.pos=frame.handRight.grip.pos;
            frame.handLeft.triggerActive=frame.handRight.triggerActive=true;
            frame.handLeft.gripActive=frame.handRight.gripActive=true;
            frame.handLeft.primaryActive=frame.handRight.primaryActive=true;
            frame.handLeft.triggerAxis=(frame.poseSampleId/150)%2?1.f:0.f;
            frame.handRight.primaryPressed=(frame.poseSampleId/200)%2!=0;
            frame.referenceSpaceEpoch=(frame.poseSampleId/600)%2;
            const float motionPhase=script.Read<float>(bridge,L"MotionFixtureElapsed");
            frame.handLeft.gripAxis=motionPhase>.8f&&motionPhase<3.f?1.f:0.f;
            frame.handRight.aim.rot=(kf2vr::Quat::FromAxisAngle({0,1,0},.25f*std::sin(motionPhase*1.7f))
                *kf2vr::Quat::FromAxisAngle({0,0,1},.5f*std::sin(motionPhase*1.3f))).Normalized();
            frame.handRight.grip.rot=frame.handRight.aim.rot;
            frame.head.rot=kf2vr::Quat::FromAxisAngle({0,1,0},.18f*std::sin(motionPhase*.8f));
            frame.head.pos={.04f*std::sin(motionPhase),.02f*std::cos(motionPhase),0};
            frame.handLeft.grip.pos.x += .12f*std::sin(motionPhase*2.f);
            frame.handRight.grip.pos.y += .18f*std::cos(motionPhase*2.f);
            frame.handLeft.aim.pos=frame.handLeft.grip.pos; frame.handRight.aim.pos=frame.handRight.grip.pos;
            demo->frame=frame;demo->sampleTick=GetTickCount64();
        }
    }
    if ((inputReplayRequested && (frame.state!=xr::SessionState::Focused || !frame.actionsSynced || !frame.headPoseValid)) ||
        (!handReplayRequested && (!demo->ready || demo->failed || !demo->sampleTick || GetTickCount64()-demo->sampleTick>250 ||
        demo->headAim.SpaceChanged(frame) ||
        !demo->headAim.RenderState(reinterpret_cast<uintptr_t>(demo->controlledController),current,aim) ||
        frame.state!=xr::SessionState::Focused || !frame.actionsSynced || !frame.headPoseValid))) {
        writes.Write(L"NativeConnection",handReplayRequested?2:1);
        writes.Write(L"NativeHeadTracked",0);
        writes.Write(L"NativeValidMask",0);
        writes.Write(L"NativeGripMask",0);
        writes.Write(L"NativeTriggerMask",0);
        writes.Write(L"NativeGripActiveMask",0);
        writes.Write(L"NativeTriggerActiveMask",0);
        writes.Write(L"NativeButtonActiveMask",0);
        writes.Write(L"NativeButtonMask",0);
        writes.Write(L"NativePhysicalButtonMask",0);
        writes.Write(L"NativePhysicalButtonActiveMask",0);
        writes.Write(L"NativeStickActiveMask",0);
        writes.Write(L"NativeMoveX",0.f);
        writes.Write(L"NativeMoveY",0.f);
        writes.Write(L"NativeTurnX",0.f);
        writes.Write(L"NativeStickClickMask",0);
        writes.Write(L"NativeStickClickActiveMask",0);
        writes.Write(L"NativeHapticMask",0);
        writes.Write(L"NativeHandHapticMask",0);
        writes.Write(L"LeftGripValue",0.f);
        writes.Write(L"RightGripValue",0.f);
        writes.Write(L"LeftTriggerValue",0.f);
        writes.Write(L"RightTriggerValue",0.f);
        writes.Write(L"NativeHudMask",0); writes.Write(L"NativeHudDetail",0); demo->hud.Reset();
        demo->handsValid=false;
        commitWrites();
        return 0;
    }
    demo->leanMetres=adapter::SanitiseLeanMetres(script.Read<float>(bridge,L"NativeLeanAllowance"));
    if (!handReplayRequested) adapter::BoundRoomView(aim,frame,demo->leanMetres);
    if(script.Read<int>(bridge,L"MotionPlayback") && script.Read<int>(bridge,L"MotionNetwork")) {
        frame.handLeft.triggerAxis=frame.handRight.triggerAxis=0;
        frame.handLeft.gripAxis=frame.handRight.gripAxis=0;
        frame.handLeft.primaryPressed=frame.handRight.primaryPressed=false;
        frame.handLeft.secondaryPressed=frame.handRight.secondaryPressed=false;
        frame.handLeft.stickX=frame.handLeft.stickY=frame.handRight.stickX=frame.handRight.stickY=0;
    }
    int valid=0,grips=0,triggers=0,gripActive=0,triggerActive=0;
    const auto referenceInverse=aim.reference.rot.Inverse();
    // Grip origin -> wrist joint, per the script's controller profile.
    const auto wristOffset=script.Read<kf2vr::Vec3>(bridge,L"NativeWristOffset");
    const auto convert=[&](const auto& hand,unsigned index,const wchar_t* posField,const wchar_t* rotField) {
        const auto* gripField=index==0?L"LeftGripValue":L"RightGripValue";
        const auto* triggerField=index==0?L"LeftTriggerValue":L"RightTriggerValue";
        writes.Write(gripField,0.f);
        writes.Write(triggerField,0.f);
        if (!hand.poseValid || !hand.aimPoseValid) return;
        const auto finite=[](float value) { return std::isfinite(value); };
        if (!finite(hand.grip.pos.x) || !finite(hand.grip.pos.y) || !finite(hand.grip.pos.z) ||
            !finite(hand.aim.rot.x) || !finite(hand.aim.rot.y) || !finite(hand.aim.rot.z) || !finite(hand.aim.rot.w) ||
            std::abs(hand.aim.rot.LengthSq()-1.f)>.02f) return;
        auto grip=hand.grip;
        grip.pos=referenceInverse.Rotate(grip.pos-aim.reference.pos);
        grip.rot=(referenceInverse*hand.aim.rot).Normalized();
        const auto local=kf2vr::ToUnreal(grip);
        // OpenXR's grip origin is the palm centroid; every script consumer of
        // this position expects the wrist joint the drawn hand hangs from.
        const auto position=eyeBase+aim.bodyRotation.Rotate(
            adapter::WristFromGrip(local.pos,local.rot,wristOffset,index));
        const auto rotation=RotationFromQuat((aim.bodyRotation*local.rot).Normalized());
        writes.Write(posField,position); writes.Write(rotField,rotation);
        // Expose the actual grip frame separately. The established fields above
        // intentionally retain OpenXR aim orientation for current weapon input.
        // A missing grip orientation falls back to the CURRENT valid aim frame,
        // never a stale wrist from a prior sample. This does not change aim input.
        writes.Write(index==0?L"NativeLeftGripRotation":L"NativeRightGripRotation",rotation);
        if (finite(hand.grip.rot.x) && finite(hand.grip.rot.y) && finite(hand.grip.rot.z) &&
            finite(hand.grip.rot.w) && std::abs(hand.grip.rot.LengthSq()-1.f)<.02f) {
            auto actualGrip=hand.grip;
            actualGrip.rot=(referenceInverse*hand.grip.rot).Normalized();
            const auto localGrip=kf2vr::ToUnreal(actualGrip);
            writes.Write(index==0?L"NativeLeftGripRotation":L"NativeRightGripRotation",
                RotationFromQuat((aim.bodyRotation*localGrip.rot).Normalized()));
        }
        const float gripValue=hand.gripActive && finite(hand.gripAxis) ? std::clamp(hand.gripAxis,0.f,1.f) : 0.f;
        const float triggerValue=hand.triggerActive && finite(hand.triggerAxis) ? std::clamp(hand.triggerAxis,0.f,1.f) : 0.f;
        writes.Write(gripField,gripValue);
        writes.Write(triggerField,triggerValue);
        valid|=1<<index;
        // Carry and fire remain latched through ordinary analog pressure
        // jitter. Invalid/inactive samples clear the latch and cannot count
        // as the physical release required by the script's rearm gate.
        const int bit=1<<index;
        if (hand.gripActive && finite(hand.gripAxis)) {
            gripActive|=bit;
            if ((previousGrips&bit) ? hand.gripAxis>.2f : hand.gripAxis>=.65f) grips|=bit;
        }
        if (hand.triggerActive && finite(hand.triggerAxis)) {
            triggerActive|=bit;
            if ((previousTriggers&bit) ? hand.triggerAxis>.1f : hand.triggerAxis>=.55f) triggers|=bit;
        }
    };
    convert(frame.handLeft,0,L"LeftPosition",L"LeftRotation");
    convert(frame.handRight,1,L"RightPosition",L"RightRotation");
    const auto headRelative=kf2vr::BasisXrToUnreal(referenceInverse.Rotate(frame.head.pos-aim.reference.pos))*kf2vr::kProvisionalUnrealUnitsPerMetre;
    writes.Write(L"NativeHeadHeight",frame.head.pos.y);
    writes.Write(L"NativeStandingHeight",demo->headAim.StandingHeight());
    const auto& headQ=frame.head.rot;
    const bool headOrientationValid=std::isfinite(headQ.x) && std::isfinite(headQ.y) &&
        std::isfinite(headQ.z) && std::isfinite(headQ.w) && std::abs(headQ.LengthSq()-1.f)<.02f;
    writes.Write(L"NativeHeadTracked",int(frame.headPoseTracked &&
        std::isfinite(frame.head.pos.x) && std::isfinite(frame.head.pos.y) &&
        std::isfinite(frame.head.pos.z) && headOrientationValid));
    writes.Write(L"HeadPosition",eyeBase+aim.bodyRotation.Rotate(headRelative));
    auto relativeHead=frame.head;
    relativeHead.rot=headOrientationValid?(referenceInverse*frame.head.rot).Normalized():kf2vr::Quat{};
    const auto localHead=kf2vr::ToUnreal(relativeHead);
    writes.Write(L"NativeHeadRotation",RotationFromQuat((aim.bodyRotation*localHead.rot).Normalized()));
    writes.Write(L"BodyRotation",RotationFromQuat(aim.bodyRotation));
    writes.Write(L"NativeConnection",handReplayRequested?2:1);
    writes.Write(L"NativeDepthSupported",1);
    writes.Write(L"NativeValidMask",valid); writes.Write(L"NativeGripMask",grips);
    writes.Write(L"NativeTriggerMask",triggers);
    writes.Write(L"NativeGripActiveMask",gripActive);
    writes.Write(L"NativeTriggerActiveMask",triggerActive);
    const auto buttons=adapter::MapHandWeaponButtons(frame,valid);
    writes.Write(L"NativeButtonActiveMask",buttons.activeMask);
    writes.Write(L"NativeButtonMask",buttons.pressedMask);
    // Independent controls receive physical X/Y/B/A without the prototype's
    // right-grip + X flashlight chord consuming the other hand's lower button.
    int physicalButtons=0,physicalActive=0;
    const auto physicalButton=[&](int bit, bool active, bool pressed) {
        if (active) { physicalActive|=bit; if (pressed) physicalButtons|=bit; }
    };
    physicalButton(1,(valid&1) && frame.handLeft.primaryActive,frame.handLeft.primaryPressed);
    physicalButton(2,(valid&1) && frame.handLeft.secondaryActive,frame.handLeft.secondaryPressed);
    physicalButton(4,(valid&2) && frame.handRight.secondaryActive,frame.handRight.secondaryPressed);
    physicalButton(8,(valid&2) && frame.handRight.primaryActive,frame.handRight.primaryPressed);
    writes.Write(L"NativePhysicalButtonMask",physicalButtons);
    writes.Write(L"NativePhysicalButtonActiveMask",physicalActive);
    int stickActive=0;
    const auto writeStick=[&](const auto& hand,int index,const wchar_t* x,const wchar_t* y) {
        const bool active=(valid&(1<<index)) && hand.stickActive && std::isfinite(hand.stickX) && std::isfinite(hand.stickY);
        if (active) stickActive|=1<<index;
        writes.Write(x,active?std::clamp(hand.stickX,-1.f,1.f):0.f);
        writes.Write(y,active?std::clamp(hand.stickY,-1.f,1.f):0.f);
    };
    writeStick(frame.handLeft,0,L"LeftStickX",L"LeftStickY");
    writeStick(frame.handRight,1,L"RightStickX",L"RightStickY");
    writes.Write(L"NativeStickActiveMask",stickActive);
    const int clickActive=((valid&1) && frame.handLeft.stickClickActive?1:0) |
        ((valid&2) && frame.handRight.stickClickActive?2:0);
    const int clickMask=(frame.handLeft.stickPressed?1:0) | (frame.handRight.stickPressed?2:0);
    writes.Write(L"NativeStickClickActiveMask",clickActive);
    writes.Write(L"NativeStickClickMask",clickMask&clickActive);
    const int hapticMask=script.Read<int>(bridge,L"NativeHapticMask");
    const int handHapticMask=script.Read<int>(bridge,L"NativeHandHapticMask");
    // Drain both request lanes even during replay/menu suppression. Old
    // contact feedback must not fire when tracking or gameplay resumes.
    writes.Write(L"NativeHapticMask",0);
    writes.Write(L"NativeHandHapticMask",0);
    if (!handReplayRequested && !demo->menuVisible && ((hapticMask|handHapticMask)&valid&3)) {
        const auto pulses=adapter::ResolveScriptHaptics(valid,hapticMask,
            {script.Read<float>(bridge,L"NativeHapticStrength"),script.Read<float>(bridge,L"NativeHapticDuration")},
            handHapticMask,
            {script.Read<float>(bridge,L"NativeLeftHapticStrength"),script.Read<float>(bridge,L"NativeLeftHapticDuration")},
            {script.Read<float>(bridge,L"NativeRightHapticStrength"),script.Read<float>(bridge,L"NativeRightHapticDuration")});
        for (unsigned hand=0;hand<pulses.size();++hand)
            if (pulses[hand].amplitude>0.f && pulses[hand].duration>0.f)
                demo->backend.RequestHaptic(hand,pulses[hand].amplitude,pulses[hand].duration);
    }
    if (const int bell=script.Read<int>(bridge,L"NativeBellRequest")) {
        writes.Write(L"NativeBellRequest",0);
        if (!handReplayRequested) adapter::PlayRingsideBell(bell);
    }
    const auto owningHand=script.Read<int>(bridge,L"WeaponHand");
    adapter::SpatialHudSettings hudSettings;
    hudSettings.followMode=script.Read<int>(bridge,L"TopHudFollowMode");
    hudSettings.distance=script.Read<float>(bridge,L"TopHudDistance");
    hudSettings.height=script.Read<float>(bridge,L"TopHudHeight");
    hudSettings.scale=script.Read<float>(bridge,L"TopHudScale");
    hudSettings.yawDeadZoneDegrees=script.Read<float>(bridge,L"TopHudYawDeadZoneDegrees");
    hudSettings.pitchDeadZoneDegrees=script.Read<float>(bridge,L"TopHudPitchDeadZoneDegrees");
    hudSettings.translationDeadZone=script.Read<float>(bridge,L"TopHudTranslationDeadZone");
    hudSettings.detailLookDegrees=script.Read<float>(bridge,L"TopHudDetailLookDegrees");
    demo->hud.Update(frame,script.Read<int>(bridge,L"PreferredWeaponHand"),script.Read<int>(bridge,L"HudWeaponMask"),!demo->menuVisible,
        script.Read<int>(bridge,L"NativeHudSuppressMask"),script.Read<int>(bridge,L"NativeSelectorCapture")!=0,hudSettings);
    constexpr const wchar_t* hudPositions[]{L"HudStatusPosition",L"HudLeftAmmoPosition",L"HudRightAmmoPosition",L"HudSessionPosition",L"HudAlertPosition"};
    constexpr const wchar_t* hudRotations[]{L"HudStatusRotation",L"HudLeftAmmoRotation",L"HudRightAmmoRotation",L"HudSessionRotation",L"HudAlertRotation"};
    constexpr const wchar_t* hudSizes[]{L"HudStatusSize",L"HudLeftAmmoSize",L"HudRightAmmoSize",L"HudSessionSize",L"HudAlertSize"};
    int hudMask=0;
    for (unsigned i=0;i<5;++i) {
        const auto& p=demo->hud.Panels()[i];
        if (!p.valid) continue;
        auto pose=frame.head;
        pose.pos=referenceInverse.Rotate(p.center-aim.reference.pos);
        pose.rot=referenceInverse*p.rotation;
        const auto local=kf2vr::ToUnreal(pose);
        const kf2vr::Vec3 size{p.width*kf2vr::kProvisionalUnrealUnitsPerMetre,
            p.height*kf2vr::kProvisionalUnrealUnitsPerMetre,0};
        if (writes.Write(hudPositions[i],eyeBase+aim.bodyRotation.Rotate(local.pos)) &&
            writes.Write(hudRotations[i],RotationFromQuat(aim.bodyRotation*local.rot)) &&
            writes.Write(hudSizes[i],size)) hudMask|=1<<i;
    }
    writes.Write(L"NativeHudMask",hudMask);
    writes.Write(L"NativeHudDetail",demo->hud.DetailVisible()?1:0);
    if (!commitWrites()) return 0;
    script.Invoke(bridge,script.FindFunction(bridge,L"RecordHUDSample"),nullptr);
    SupplyLockTargets(bridge);
    demo->handsValid=owningHand>=0 && owningHand<2 && (valid&(1<<owningHand))!=0 &&
        script.Read<int>(bridge,L"NativeWeaponReady")!=0;
    return valid ? frame.poseSampleId : 0;
}
// Seeker Six / HRG Locust keep their lock list in a protected script array
// that only the stock flat DrawHUD reads. Copy it into the bridge's public
// LockTarget slots so the VR HUD can mark the locked Zeds in the world.
void SupplyLockTargets(void* bridge) {
    auto& script=demo->script;
    constexpr const wchar_t* slots[]{L"LockTarget0",L"LockTarget1",L"LockTarget2",L"LockTarget3",L"LockTarget4",L"LockTarget5"};
    struct ScriptArray { void** data; std::int32_t count,max; };
    void* weapon=script.Read<void*>(bridge,L"LockSource");
    int count=0;
    if (weapon && (script.IsClass(weapon,L"KFWeap_RocketLauncher_Seeker6") || script.IsClass(weapon,L"KFWeap_HRG_Locust"))) {
        const auto offset=script.FieldOffset(adapter::GameScript::ObjectClass(weapon),script.Intern(L"LockedTargets"));
        const auto list=offset ? adapter::GameScript::At<ScriptArray>(weapon,offset) : ScriptArray{};
        if (list.data && list.count>0 && list.count<=64 &&
            adapter::GameScript::Accessible(list.data,sizeof(void*)*list.count)) {
            for (int i=0;i<list.count && count<6;++i) {
                void* pawn=adapter::GameScript::At<void*>(list.data,sizeof(void*)*i);
                if (pawn && script.IsClass(pawn,L"Pawn")) script.Write(bridge,slots[count++],pawn);
            }
        }
    }
    for (int i=count;i<6;++i) script.Write(bridge,slots[i],static_cast<void*>(nullptr));
    script.Write(bridge,L"NativeLockCount",count);
}
bool LocalComfortActive() {
    if (!demo || GetCurrentThreadId()!=worldDrawThread.load(std::memory_order_acquire) ||
        !demo->controlledPawn || !demo->controlledController) return false;
    if (stereoRequested) {
        if (!demo->ready || demo->failed || demo->failureRequested.load(std::memory_order_acquire) ||
            !GameOwnsXr()) return false;
    } else if (!handReplayRequested) return false;
    pinned::LocalWorldSnapshot world{};
    return LocalWorld(lastLocalPlayer,world) &&
        world.controller==reinterpret_cast<uintptr_t>(demo->controlledController) &&
        demo->script.Read<void*>(demo->controlledController,L"Pawn")==demo->controlledPawn;
}
void ForwardProcessInternal(void* object,void* stack,void* result) {
    adapter::timing::VmBodySample sample;
    adapter::timing::Scope timing(adapter::timing::ScriptBody);
    originalProcessInternal(object,stack,result);
}
void HookProcessInternal(void* object,void* stack,void* result) {
    adapter::timing::VmSampleScope sample;
    adapter::timing::Scope timing(adapter::timing::ScriptDispatch);
    // Reuse only within this invocation. Each At/ObjectName validates memory;
    // rereading both for session, portal and weapon dispatch doubled that work
    // for virtually every VM call. No identity survives a callback or GC.
    void* function=nullptr;
    adapter::GameScript::Name name=0;
    if (demo && (stereoRequested || handReplayRequested)) {
        // This callback originates in GameViewportClient.Tick, before a pawn
        // exists. Keep lookup thread-local until its viewport/world validate.
        static thread_local adapter::GameScript sessionLookup(gameBase);
        static thread_local const auto sessionName=sessionLookup.Intern(L"NativeSessionUpdate");
        if (fastVmIdentity) {
            if (!adapter::ReadVmEntryIdentity(stack,function,name)) {
                ForwardProcessInternal(object,stack,result);return;
            }
        } else {
            function=adapter::GameScript::At<void*>(stack,0x14);
            name=adapter::GameScript::ObjectName(function);
        }
        if (name==sessionName &&
            sessionLookup.IsClass(object,L"VRSessionUI") &&
            sessionLookup.FindFunction(object,L"NativeSessionUpdate")==function) {
            UpdateSession(object);
            ForwardProcessInternal(object,stack,result); return;
        }
    }
    const bool worldThread=GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire);
    if (!demo || !worldThread || !demo->controlledController) {
        ForwardProcessInternal(object,stack,result); return;
    }
    auto& script=demo->script;
    if (!reuseVmIdentity || !function) {
        function=adapter::GameScript::At<void*>(stack,0x14);
        name=adapter::GameScript::ObjectName(function);
    }
    static thread_local const auto commandoHudName=script.Intern(L"DrawSpecialPerkHUD");
    if (stereoRequested && name==commandoHudName &&
        adapter::SuppressCommandoHud(script,object,function,demo->handsBridge,demo->controlledController)) return;
    static thread_local const auto lockIconName=script.Intern(L"DrawTargetingIcon");
    if (stereoRequested && name==lockIconName && LocalComfortActive() &&
        adapter::SuppressLockOnIcon(script,object,function,adapter::GameScript::At<void*>(stack,0x2c),
                                    demo->handsBridge,demo->controlledController)) return;
    // Coordinated local test hook: exact owned callback, existing validated
    // world/game thread only. No property writes or general console dispatch.
    static thread_local const auto localTestName=script.Intern(L"NativeLocalTestPoll");
    if (name==localTestName && script.IsClass(object,L"VRLocalTestControl") &&
        script.FindFunction(object,L"NativeLocalTestPoll")==function) {
        localTestControl.Poll(script,object);
        ForwardProcessInternal(object,stack,result);return;
    }
    static thread_local const auto motionName=script.Intern(L"NativeMotionUpdate");
    if (name==motionName && script.IsClass(object,L"KF2VRNetHandsBridge") &&
        script.Read<void*>(object,L"PC")==demo->controlledController &&
        script.FindFunction(object,L"NativeMotionUpdate")==function) {
        adapter::AppliedHeadAim origin{};
        pinned::NativeRotator facing{};
        const bool originValid=ReadRotation(demo->controlledController,facing) &&
            demo->headAim.RenderState(reinterpret_cast<uintptr_t>(demo->controlledController),facing,origin);
        motionRuntime.Update(script,object,demo->controlledController,demo->frame,
            origin.reference,origin.bodyRotation,originValid,stereoRequested,handReplayRequested,
            demo->sampleTick?GetTickCount64()-demo->sampleTick:UINT64_MAX);
        if(script.Read<int>(object,L"MotionPlayback") && script.Read<int>(object,L"MotionNetwork"))
            Log("MotionNetwork sample=%d clip_time=%.6f clock=%.6f paused=%d",script.Read<int>(object,L"MotionSampleIndex"),
                script.Read<float>(object,L"MotionClipSeconds"),script.Read<float>(object,L"MotionClockSeconds"),script.Read<int>(object,L"MotionPaused"));
        ForwardProcessInternal(object,stack,result);return;
    }

    const auto positionName=*reinterpret_cast<const std::uint64_t*>(gameBase+0x22340d8);
    using Vm=adapter::VmCallbackFilter;
    using Callback=Vm::Callback;
    static thread_local Vm callbackFilter;
    const auto callback=callbackFilter.Lookup(name,positionName,[&](const wchar_t* text) { return script.Intern(text); });
    if (callback==Callback::Unrelated) {
        ForwardProcessInternal(object,stack,result); return;
    }
    if (portalRequested && callback==Callback::NativePortalShotsUpdate &&
        script.IsClass(object,L"VRWeap_PortalGun") &&
        script.FindFunction(object,L"NativePortalShotsUpdate")==function)
        portalHitscan.Refresh(lastLocalPlayer,object);
    if (portalRequested && callback==Callback::CalcWeaponFire && portalHitscan.Route(object,stack,result)) return;
    if (portalRequested && callback==Callback::HitWall && portalHitscan.ProjectileWall(object,stack)) return;
    const auto groups=Vm::Groups(callback);
    auto* locals=adapter::GameScript::At<void*>(stack,0x2c);
    if (callback==Callback::NativeMagazineFeedEvent &&
        adapter::RouteMagazineFeedEvent(script,demo->handsBridge,demo->controlledPawn,object,function,locals,result)) return;
    if (callback==Callback::RenderDisplay && demo->handsBridge) {
        const bool panel=script.IsClass(object,L"VRHUDPanel");
        const bool selector=!panel && script.IsClass(object,L"VRHandSelector");
        if(panel || selector) {
            const auto canvas=adapter::GameScript::At<void*>(locals,0);
            const auto width=script.Read<float>(canvas,L"ClipX"),height=script.Read<float>(canvas,L"ClipY");
            const void* owner=nullptr;const void* expected=nullptr;int index=-1,slot=-1;
            if(panel) {
                index=slot=script.Read<int>(object,L"PanelIndex");
                owner=script.Read<void*>(object,L"DisplayOwner");
                expected=script.Read<void*>(demo->handsBridge,L"SpatialHUD");
            } else {
                const auto inventory=script.Read<void*>(demo->handsBridge,L"HandInventory");
                expected=script.Read<void*>(inventory,L"Input");
                index=script.Read<int>(object,L"Hand");
                owner=script.Read<void*>(object,L"InputOwner");
                if(index>=0 && index<static_cast<int>(adapter::HudTextAlpha::SelectorCount))
                    slot=static_cast<int>(adapter::HudTextAlpha::PanelCount)+index;
            }
            // The panel's clear is already queued and its draws follow this
            // callback, so registration lands between them on the render side.
            renderQueue.Enqueue([=] {
                const bool registered=panel ? hudTextAlpha.RegisterPanel(index,owner,expected,width,height) :
                    hudTextAlpha.RegisterSelector(index,owner,expected,width,height);
                if(selectorDiagnostics && !panel && selectorRegistrations++<16)
                    Log("KF2VR_SELECTOR_REGISTER hand=%d owner=%p expected=%p canvas=%.0fx%.0f registered=%d",
                        index,owner,expected,width,height,registered);
                if (Interesting(++hudAlphaTargets)) Log("HUD text alpha target=%llu registered=%d kind=%s slot=%d",
                    static_cast<unsigned long long>(hudAlphaTargets),registered,panel?"panel":"selector",slot);
            });
        }
    }
    const bool walkBob=object==demo->controlledPawn && callback==Callback::UpdateWalkBob && LocalComfortActive();
    // KFPlayerInput adds these forced yaw/pitch deltas after raw player input.
    // Leave those out parameters untouched: physical head motion and intended
    // stick/mouse turns still flow through normal UpdateRotation, as do grab
    // movement restrictions, damage and release. Friction instead scales the
    // stick turn by up to half whenever the head view crosses a zed, which
    // reads as stutter; skipping it leaves CurrTurn/CurrLookUp as the stick set
    // them. Scope this to the local VR input object, including when a
    // weapon/hand pose is temporarily absent.
    const bool forcedLook=callback==Callback::ApplyForceLookAtPawn ||
        callback==Callback::ApplyAutoTarget || callback==Callback::ApplyTargetAdhesion ||
        callback==Callback::ApplyTargetFriction;
    if (forcedLook && object==script.Read<void*>(demo->controlledController,L"PlayerInput") && LocalComfortActive()) {
        if (Interesting(++demo->forcedLookSuppressions)) Log("VRComfort forcedLookSuppressed=%llu",
            static_cast<unsigned long long>(demo->forcedLookSuppressions));
        return;
    }
    const bool processView=callback==Callback::ProcessViewRotation;
    const bool cameraEffect=processView || callback==Callback::PlayCameraShake ||
        callback==Callback::ClientPlayCameraAnim || callback==Callback::PlayCameraAnim ||
        callback==Callback::ShakeView || callback==Callback::ViewShake ||
        callback==Callback::LandingShake;
    if (cameraEffect && LocalComfortActive()) {
        auto* camera=script.Read<void*>(demo->controlledController,L"PlayerCamera");
        const bool specialMove=script.IsClass(object,L"KFSpecialMove") &&
            script.Read<void*>(object,L"KFPOwner")==demo->controlledPawn;
        const bool localWeapon=script.IsClass(object,L"KFWeapon") &&
            script.Read<void*>(object,L"Instigator")==demo->controlledPawn;
        const bool suppress=(object==camera && (processView || callback==Callback::PlayCameraShake)) ||
            (specialMove && (processView || callback==Callback::PlayCameraAnim)) ||
            (localWeapon && (callback==Callback::PlayCameraAnim || callback==Callback::ShakeView)) ||
            (object==demo->controlledController && (callback==Callback::ClientPlayCameraAnim ||
                callback==Callback::ViewShake || callback==Callback::LandingShake));
        if (suppress) {
            // Block visual effects at their local destination. The caller still
            // runs damage, grab/release, animation notifies and force feedback.
            if (result && callback==Callback::PlayCameraAnim) {
                void* noAnimation=nullptr; std::memcpy(result,&noAnimation,sizeof(noAnimation));
            }
            if (result && callback==Callback::LandingShake) {
                const std::int32_t noShake=0; std::memcpy(result,&noShake,sizeof(noShake));
            }
            if (Interesting(++demo->cameraEffectSuppressions)) Log("VRComfort cameraEffectSuppressed=%llu",
                static_cast<unsigned long long>(demo->cameraEffectSuppressions));
            return;
        }
    }
    // KFPlayerController calls native WeaponProcessViewRotation and then the
    // scripted Engine.PlayerController super with its modified DeltaRot. Keep
    // all native recoil/buffer/timer work, but give the super only the incoming
    // intentional input. Zero recoil scales alone miss buffer saturation and
    // suppression recoil. This scope is independent of hand/weapon readiness.
    bool viewScope=false;
    if (processView && object==demo->controlledController && LocalComfortActive()) {
        const auto deltaOffset=script.FieldOffset(function,script.Intern(L"DeltaRot"));
        auto* deltaAddress=locals ? static_cast<std::byte*>(locals)+deltaOffset : nullptr;
        if (deltaOffset && Readable(deltaAddress,sizeof(pinned::NativeRotator))) {
            pinned::NativeRotator delta{};
            std::memcpy(&delta,deltaAddress,sizeof(delta));
            if (demo->viewRotationScope) {
                std::memcpy(deltaAddress,&demo->intendedViewDelta,sizeof(delta));
                if (std::memcmp(&delta,&demo->intendedViewDelta,sizeof(delta)) &&
                    Interesting(++demo->recoilViewSuppressions)) Log("VRComfort recoilViewSuppressed=%llu",
                        static_cast<unsigned long long>(demo->recoilViewSuppressions));
            } else demo->intendedViewDelta=delta;
            ++demo->viewRotationScope;
            viewScope=true;
        }
    }
    if (callback==Callback::NativeHandsUpdate && script.IsClass(object,L"VRHandsBridge") &&
        !script.IsClass(object,L"VRWeaponPresenter")) SupplyHands(object);
    // Pending fire belongs to the exact registered actor, even when tracking
    // is lost: cancellation must still clear its state. This opt-in registry
    // is currently created only by the standalone dual-wield feasibility probe.
    if ((groups & Vm::PendingFire) && adapter::RouteItemPendingFire(script,demo->handsBridge,demo->controlledPawn,
                                      object,function,locals,result)) return;
    if (((groups & Vm::Lifecycle) && adapter::RouteManagedWeaponLifecycle(script,demo->handsBridge,demo->controlledPawn,object,function,locals)) ||
        ((groups & Vm::Sprint) && adapter::RouteManagedSprint(script,demo->handsBridge,demo->controlledPawn,object,function,locals)) ||
        ((groups & Vm::Melee) && adapter::RouteManagedMelee(script,demo->handsBridge,demo->controlledPawn,object,function,locals,result))) return;
    // Medic acquisition has its own camera-based trace, separate from the
    // actual shot hooks. Dispatch the local timer with the held item's pose;
    // the helper retains stock eligibility, cadence and lock state callbacks.
    if (demo->handsBridge && callback==Callback::CheckTargetLock && script.IsClass(object,L"KFWeap_MedicBase")) {
        void* presenter=nullptr;
        const bool managed=adapter::ResolveItemPresenter(script,demo->handsBridge,demo->controlledPawn,object,presenter);
        if (managed && !presenter) return;
        if (!managed && demo->handsValid && object==demo->heldWeapon) presenter=demo->handsBridge;
        struct MedicLockParameters { void* weapon; } parameters{object};
        if (presenter && script.Invoke(presenter,script.FindFunction(presenter,L"UpdateMedicTargetLock"),&parameters)) return;
    }
    // The stock RPG custom shot keeps its projectile and backblast explosion;
    // only the camera-derived pose is replaced by its tracked exhaust socket.
    if (demo->handsBridge && callback==Callback::GetBackBlastLocationAndRotation &&
        script.IsClass(object,L"KFWeap_RocketLauncher_RPG7")) {
        void* presenter=nullptr;
        const bool managed=adapter::ResolveItemPresenter(script,demo->handsBridge,demo->controlledPawn,object,presenter);
        if (!managed && demo->handsValid && object==demo->heldWeapon) presenter=demo->handsBridge;
        if (presenter && adapter::RouteRPGBackBlast(script,presenter,object,function,stack)) return;
    }
    const bool melee=demo->handsValid && (callback==Callback::GetMeleeAimRotation || callback==Callback::GetMeleeStartTraceLocation) &&
        object==script.Read<void*>(demo->heldWeapon,L"MeleeAttackHelper");
    const bool aiming=demo->handsValid && ((object==demo->controlledController && callback==Callback::GetAdjustedAimFor) ||
        (melee && callback==Callback::GetMeleeAimRotation));
    // Gun animation and recoil still run. A flat-screen camera shake must not
    // rotate the player's HMD when they fire, reload or use the syringe.
    if (demo->handsValid && object==demo->heldWeapon &&
        (callback==Callback::ShakeView || callback==Callback::EnableIronSightsDoF)) return;
    adapter::WeaponAimStack::Scope itemAimScope(demo->itemAim);
    bool rejectShot=false;
    if (groups & Vm::BeginAim) adapter::BeginItemAim(script,demo->itemAim,itemAimScope,demo->handsBridge,demo->controlledPawn,
                         object,function,locals,rejectShot);
    if (rejectShot) return;
    adapter::WeaponHandlingStack::Scope handlingScope(demo->weaponHandling,script);
    if (groups & Vm::Handling) adapter::BeginWeaponHandling(script,demo->weaponHandling,handlingScope,demo->handsBridge,
                                demo->controlledPawn,demo->controlledController,object,function);
    adapter::WeaponEffectsScope effectsScope(script);
    if (groups & Vm::Effects) effectsScope.Enter(demo->handsBridge,demo->controlledPawn,object,function,locals);
    // Innermost, so stock perk code sees the acting item and its grip while
    // the outer item scopes still own aim, handling and effect receipts.
    adapter::PerkScope perkScope(script);
    if (groups & Vm::Perk) adapter::EnterLocalPerk(script,perkScope,demo->handsBridge,demo->controlledPawn,
                            object,function,locals);
    if (aiming) ++demo->aimScope;
    // KFWeapon.PlayWeaponAnimation calls SetAnim/PlayAnim, which can issue a
    // time-zero sound before the ordinary reload update. Let script restore
    // its previous instance-only notify flags before the stock clip changes.
    // Arming belongs to the reload owner's fully validated session, not here.
    // Query the gate in script: Unreal bools share packed storage, so reading
    // bInteractiveReloads/bReloadAudioOwned as native integers is not valid.
    struct ReloadAnimationParameters { void* W; adapter::GameScript::Name Sequence; } reloadParameters{object,0};
    if (callback==Callback::PlayWeaponAnimation && demo->handsBridge && demo->controlledPawn &&
        script.IsClass(object,L"KFWeapon") && script.Read<void*>(object,L"Instigator")==demo->controlledPawn &&
        script.FindFunction(object,L"PlayWeaponAnimation")==function &&
        script.Read<void*>(demo->handsBridge,L"PC")==demo->controlledController &&
        script.Read<void*>(demo->handsBridge,L"Human")==demo->controlledPawn) {
        struct ReloadGateParameters { std::int32_t ReturnValue=0; } gateParameters;
        auto* gate=script.FindFunction(demo->handsBridge,L"ReloadAudioHookGate");
        adapter::ScriptField gateResult;
        if (adapter::FindScriptField(gate,script.Intern(L"ReturnValue"),gateResult) &&
            gateResult.offset==0 && gateResult.size==sizeof(gateParameters) &&
            script.Invoke(demo->handsBridge,gate,&gateParameters) && gateParameters.ReturnValue==1) {
            adapter::ReadScriptLocal(function,locals,script.Intern(L"Sequence"),reloadParameters.Sequence);
            // An unreadable sequence still passes None to Before for cleanup;
            // no replacement clip is armed. Cleanup also runs when a menu,
            // replay or a newly disabled feature prevents new ownership.
            script.Invoke(demo->handsBridge,script.FindFunction(demo->handsBridge,L"BeforeReloadAnimation"),&reloadParameters);
        }
    }
    const bool portalEffects=portalRequested && callback==Callback::WeaponFired && portalHitscan.Effects(object,stack);
    if (!portalEffects) ForwardProcessInternal(object,stack,result);
    // Kismet HandleTeleport and Teleporter.Accept replace the controller's
    // rotation through ClientSetRotation. Remote relocation also does so in
    // ClientSetLocation, even without a requested destination-facing update.
    // Repair only that explicit overwrite boundary after stock moves the pawn;
    // comfort teleport, stick turns, recenter and ordinary head ticks bypass it.
    if ((callback==Callback::ClientSetRotation || callback==Callback::ClientSetLocation) &&
        object==demo->controlledController && LocalComfortActive() &&
        script.FindFunction(object,callback==Callback::ClientSetRotation ? L"ClientSetRotation" : L"ClientSetLocation")==function &&
        script.IsClass(demo->controlledPawn,L"KFPawn_Human") &&
        !script.IsClass(demo->controlledPawn,L"KFPawn_Customization") &&
        script.Read<int>(demo->controlledPawn,L"Health")>0) {
        pinned::NativeRotator destination{},level{},actual{};
        if (ReadRotation(object,destination) &&
            demo->headAim.WorldUpTransition(reinterpret_cast<uintptr_t>(object),destination,level)) {
            demo->renderPairLease={};
            const auto setRotation=reinterpret_cast<pinned::ActorSetRotationFn>(gameBase+pinned::kActorSetRotationRva);
            if (!setRotation(object,&level) || !ReadRotation(object,actual) ||
                actual.pitch!=level.pitch || actual.yaw!=level.yaw || actual.roll!=level.roll) {
                demo->headAim.Suspend(); demo->failed=true; demo->gamepad.Cancel();
                Log("HeadAim failed: map transition rotation rejected");
            }
        }
    }
    if (callback==Callback::ScoreDamage)
        adapter::ForwardSoloDamagePopup(script,demo->handsBridge,demo->controlledController,
            demo->controlledPawn,object,function,locals);
    if (callback==Callback::FireAmmunition)
        adapter::CompleteMagazineShot(script,demo->handsBridge,demo->controlledPawn,object,function);
    if (!handReplayRequested && !demo->menuVisible && callback==Callback::HandleRecoil) {
        const auto* shot=demo->itemAim.Current();
        if (shot && shot->weapon==object && shot->managed && shot->ready) {
            int support=-1;
            const auto hand=adapter::ManagedRecoilHand(script,demo->handsBridge,demo->controlledPawn,object,function,&support);
            if (hand>=0 && hand<=1) {
                const auto pulse=adapter::RecoilHapticsFor(static_cast<float>(script.Read<int>(object,L"maxRecoilPitch")),support>=0);
                demo->backend.RequestHaptic(static_cast<unsigned>(hand),pulse.primary.amplitude,pulse.primary.duration);
                if (support>=0) demo->backend.RequestHaptic(static_cast<unsigned>(support),pulse.support.amplitude,pulse.support.duration);
                // Kill/decapitation confirmation goes to the hand that last fired.
                script.Write(demo->handsBridge,L"NativeStrikeMask",(1<<hand)|(support>=0?1<<support:0));
            }
        }
    }
    if (viewScope) --demo->viewRotationScope;
    if (callback==Callback::UpdateCamera && demo->handsBridge &&
        object==script.Read<void*>(demo->controlledController,L"PlayerCamera") && LocalComfortActive()) {
        script.Invoke(demo->handsBridge,script.FindFunction(demo->handsBridge,L"EnforceCameraComfort"),nullptr);
    }
    if (callback==Callback::UpdateCamera && demo->session && stereoRequested && demo->ready && !demo->failed &&
        object==script.Read<void*>(demo->controlledController,L"PlayerCamera")) {
        pinned::LocalWorldSnapshot cameraWorld{};
        if (LocalWorld(lastLocalPlayer,cameraWorld) &&
            cameraWorld.controller==reinterpret_cast<uintptr_t>(demo->controlledController))
            script.Invoke(demo->session,script.FindFunction(demo->session,L"EnforceCameraComfort"),nullptr);
    }
    if (walkBob) {
        // KFPawn.UpdateEyeHeight retains stair/crouch/ceiling smoothing, then
        // calls UpdateWalkBob. Clear only its synthetic walking displacement
        // before GetPawnViewLocation consumes it; never remove pawn movement
        // or headset translation. bWeaponBob alone does not stop camera bob.
        if (script.Write(object,L"WalkBob",kf2vr::Vec3{}) && Interesting(++demo->walkBobSuppressions))
            Log("VRComfort walkBobSuppressed=%llu",static_cast<unsigned long long>(demo->walkBobSuppressions));
    }
    if (aiming) --demo->aimScope;
    if (demo->handsBridge && demo->controlledPawn && callback==Callback::SetPosition &&
        adapter::GameScript::At<void*>(locals,0)==demo->controlledPawn) {
        demo->heldWeapon=object;
        if (!handReplayRequested) SupplyHands(demo->handsBridge);
        script.Invoke(demo->handsBridge,script.FindFunction(demo->handsBridge,L"PlaceWeapon"),nullptr);
        script.Invoke(demo->handsBridge,script.FindFunction(demo->handsBridge,L"UpdateSpatialHUD"),nullptr);
    }
    if ((groups & Vm::FinishAim) && adapter::FinishItemAim(script,demo->itemAim,demo->handsBridge,demo->controlledPawn,
                              object,function,locals,result)) return;
    if (!demo->handsValid || !demo->handsBridge) return;
    if (object==demo->heldWeapon && callback==Callback::GetMuzzleLoc && result) {
        const auto location=script.Read<kf2vr::Vec3>(demo->handsBridge,L"FireLocation");
        std::memcpy(result,&location,sizeof(location));
    }
    // The stock function has already spawned this projectile and run its Init,
    // so the object return is the finished shot. Script decides whether its
    // world-Z toss belongs on a tracked, laser-aimed weapon.
    if (callback==Callback::SpawnProjectile && result && script.IsClass(object,L"KFWeapon")) {
        auto* projectile=*static_cast<void**>(result);
        if (script.IsClass(projectile,L"KFProjectile"))
            adapter::ClearProjectileToss(script,demo->handsBridge,object,projectile);
    }
    if (object==demo->controlledPawn && callback==Callback::GetWeaponStartTraceLocation && result) {
        const auto location=script.Read<kf2vr::Vec3>(demo->handsBridge,L"FireLocation");
        std::memcpy(result,&location,sizeof(location));
    }
    if (melee && callback==Callback::GetMeleeStartTraceLocation && result) {
        const auto hand=script.Read<int>(demo->handsBridge,L"WeaponHand");
        const auto location=script.Read<kf2vr::Vec3>(demo->handsBridge,hand==0?L"LeftPosition":L"RightPosition");
        std::memcpy(result,&location,sizeof(location));
    }
    if (demo->aimScope && object==demo->controlledPawn && callback==Callback::GetBaseAimRotation && result) {
        const auto rotation=script.Read<adapter::pinned::NativeRotator>(demo->handsBridge,L"FireRotation");
        std::memcpy(result,&rotation,sizeof(rotation));
        if (networkRequested) script.Write(demo->controlledController,L"NativeAimCalls",
            script.Read<int>(demo->controlledController,L"NativeAimCalls")+1);
        if (Interesting(++demo->aimObservations)) Log("HandAim sample=%llu pitch=%d yaw=%d cameraYaw=%d",
            static_cast<unsigned long long>(demo->aimObservations),rotation.pitch,rotation.yaw,
            adapter::GameScript::At<adapter::pinned::NativeRotator>(demo->controlledController,pinned::kActorRotation).yaw);
    }
}
void HookWeaponViewRotation(void* weapon,void* controller,float delta,pinned::NativeRotator* rotation) {
    if (demo && GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire) &&
        adapter::SuppressManagedRecoil(demo->script,demo->handsBridge,demo->controlledPawn,weapon,controller)) return;
    originalWeaponViewRotation(weapon,controller,delta,rotation);
}
void HookTraceStart(void* object,void* stack,void* result) {
    originalTraceStart(object,stack,result);
    if (demo && GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire) &&
        adapter::RouteItemTraceOrigin(demo->script,demo->itemAim,demo->handsBridge,
                                     demo->controlledPawn,object,result)) return;
    if (demo && demo->handsValid && demo->handsBridge && object==demo->heldWeapon && result &&
        GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire)) {
        const auto location=demo->script.Read<kf2vr::Vec3>(demo->handsBridge,L"FireLocation");
        std::memcpy(result,&location,sizeof(location));
        if (networkRequested) demo->script.Write(demo->controlledController,L"NativeTraceCalls",
            demo->script.Read<int>(demo->controlledController,L"NativeTraceCalls")+1);
    }
}
void HookPhysicalStart(void* object,void* stack,void* result) {
    // Engine Weapon.execGetPhysicalFireStartLoc, RVA47e3c0: consume its
    // optional vector normally, then replace the FVector return. Shotgun
    // pellets and Zed-time pistol projectiles must leave the held muzzle too.
    originalPhysicalStart(object,stack,result);
    if (demo && GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire) &&
        adapter::RouteItemTraceOrigin(demo->script,demo->itemAim,demo->handsBridge,
                                     demo->controlledPawn,object,result)) return;
    if (demo && demo->handsValid && object==demo->heldWeapon && result &&
        GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire)) {
        const auto location=demo->script.Read<kf2vr::Vec3>(demo->handsBridge,L"FireLocation");
        std::memcpy(result,&location,sizeof(location));
    }
}
void EnsureEyeResolution() {
    auto* viewport=lastLocalViewport;
    if (!Readable(viewport,0xbc)) return;
    const unsigned width=adapter::ScaledEyeExtent(demo->backend.RecommendedWidth(),eyeRenderPercent);
    const unsigned height=adapter::ScaledEyeExtent(demo->backend.RecommendedHeight(),eyeRenderPercent);
    if (!width || !height) return;
    unsigned currentWidth=0,currentHeight=0;
    std::memcpy(&currentWidth,static_cast<std::byte*>(viewport)+0xb4,4);
    std::memcpy(&currentHeight,static_cast<std::byte*>(viewport)+0xb8,4);
    if (currentWidth==width && currentHeight==height) return;
    // Resize before the engine constructs this frame's Canvas. Inside Draw,
    // that Canvas still owns the old backbuffer and DXGI rejects ResizeBuffers.
    // FWindowsViewport's RHI helper also resizes shared scene targets, without
    // the desktop work-area clamp in its outer window-resize function.
    using ResizeRhi=void(*)(void*,unsigned,unsigned,std::int32_t,std::int32_t,std::int32_t);
    const auto resize=reinterpret_cast<ResizeRhi>(gameBase+0xd1ef30);
    resize(static_cast<std::byte*>(viewport)-8,width,height,0,0,0);
    DXGI_SWAP_CHAIN_DESC actual{};
    auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
    if (!swapchain || FAILED(swapchain->GetDesc(&actual)) ||
        actual.BufferDesc.Width!=width || actual.BufferDesc.Height!=height) {
        Log("Eye resize failed requested=%ux%u actual=%ux%u",width,height,actual.BufferDesc.Width,actual.BufferDesc.Height);
        resize(static_cast<std::byte*>(viewport)-8,currentWidth,currentHeight,0,0,0);
        demo->failed=true; demo->gamepad.Cancel(); return;
    }
    Log("Eye render target resized=%ux%u runtimeRecommended=%d eyeRenderPercent=%u xrOutput=%ux%u desktop window unchanged",
        width,height,eyeRenderPercent==100,eyeRenderPercent,demo->backend.RecommendedWidth(),demo->backend.RecommendedHeight());
}
bool RefreshMenuState();
void PumpNativeInput(float delta,bool neutral=false) {
    if (!lastLocalViewport || !Readable(lastLocalViewport,0x4c) || !std::isfinite(delta) || delta<0) return;
    void* client=nullptr;
    std::memcpy(&client,static_cast<std::byte*>(lastLocalViewport)+0x44,sizeof(client));
    if (!Readable(client,sizeof(void*))) return;
    auto** table=*reinterpret_cast<void***>(client);
    if (!Readable(table,0x40)) return;
    // Exact stock WinDrv dispatch at D1BAA5 and D1C27x: FName is 8 bytes
    // by value; float axis/delta time and gamepad flag follow on the stack.
    using AxisFn=std::int32_t(*)(void*,void*,std::int32_t,std::uint64_t,float,float,std::int32_t);
    using KeyFn=std::int32_t(*)(void*,void*,std::int32_t,std::uint64_t,std::int32_t,float,std::int32_t);
    const auto axis=reinterpret_cast<AxisFn>(table[0x38/8]);
    const auto key=reinterpret_cast<KeyFn>(table[0x28/8]);
    static void* isolationProbedController=nullptr;
    static bool isolationCharPending=false, isolationAxesUnchanged=false;
    static int isolationCharBaseline=0, isolationBlockedKeys=0, isolationBlockedAxes=0;
    static ULONGLONG isolationCharDeadline=0;
    if (isolationCharPending && demo->controlledController==isolationProbedController) {
        auto& script=demo->script;
        void* scriptViewport=lastLocalPlayer?script.Read<void*>(lastLocalPlayer,L"ViewportClient"):nullptr;
        void* gate=scriptViewport?script.Read<void*>(scriptViewport,L"DiagnosticInputGate"):nullptr;
        const int blockedChars=gate?script.Read<int>(gate,L"BlockedChars")-isolationCharBaseline:0;
        if (blockedChars>0 || GetTickCount64()>=isolationCharDeadline) {
            const bool passed=isolationBlockedKeys==6 && isolationBlockedAxes==2 && blockedChars==1 && isolationAxesUnchanged;
            Log("ReplayInputIsolationProbe passed=%d blockedKeys=%d blockedAxes=%d blockedChars=%d stockAxesUnchanged=%d",passed,isolationBlockedKeys,isolationBlockedAxes,blockedChars,isolationAxesUnchanged);
            isolationCharPending=false;
        }
    }
    if (handReplayRequested && !neutral && demo->controlledPawn && demo->controlledController &&
        isolationProbedController!=demo->controlledController &&
        wcsstr(GetCommandLineW(),L"-kf2vr-input-isolation-probe")) {
        auto& script=demo->script;
        void* scriptViewport=lastLocalPlayer?script.Read<void*>(lastLocalPlayer,L"ViewportClient"):nullptr;
        void* gate=scriptViewport?script.Read<void*>(scriptViewport,L"DiagnosticInputGate"):nullptr;
        void* input=script.Read<void*>(demo->controlledController,L"PlayerInput");
        const HWND probeWindow=replayProbeWindow.load();
        DWORD probeOwner=0;
        if (probeWindow) GetWindowThreadProcessId(probeWindow,&probeOwner);
        if (gate && input && IsWindow(probeWindow) && probeOwner==GetCurrentProcessId()) {
            isolationProbedController=demo->controlledController;
            const int keys=script.Read<int>(gate,L"BlockedKeys"), axes=script.Read<int>(gate,L"BlockedAxes"), chars=script.Read<int>(gate,L"BlockedChars");
            constexpr const wchar_t* names[]{L"aTurn",L"aLookUp",L"aForward",L"aStrafe"};
            std::array<float,4> before{};
            for (int i=0;i<4;++i) before[i]=script.Read<float>(input,names[i]);
            axis(client,lastLocalViewport,0,script.Intern(L"MouseX"),500.f,delta,0);
            axis(client,lastLocalViewport,0,script.Intern(L"MouseY"),500.f,delta,0);
            for (auto name:{L"W",L"LeftMouseButton",L"Tilde"}) {
                key(client,lastLocalViewport,0,script.Intern(name),0,1.f,0);
                key(client,lastLocalViewport,0,script.Intern(name),1,1.f,0);
            }
            bool unchanged=true;
            for (int i=0;i<4;++i) unchanged=unchanged && before[i]==script.Read<float>(input,names[i]);
            isolationBlockedKeys=script.Read<int>(gate,L"BlockedKeys")-keys;
            isolationBlockedAxes=script.Read<int>(gate,L"BlockedAxes")-axes;
            isolationAxesUnchanged=unchanged;
            isolationCharBaseline=chars;
            isolationCharDeadline=GetTickCount64()+2000;
            // Exercise the actual owned window character route, without an
            // unverified native vtable slot or global input/focus changes.
            isolationCharPending=true;
            const bool posted=PostMessageW(probeWindow,WM_CHAR,L'w',1)!=0;
            Log("ReplayInputIsolationChar posted=%d hwnd=%p owner_pid=%lu",posted,probeWindow,probeOwner);
        }
    }
    if (client!=demo->nativeInputClient) { demo->nativeKeys={}; demo->nativeInputClient=client; }
    // Input runs before Draw updates menuVisible. Query the live session too,
    // including its native shell and scoreboard, before consuming this sample.
    const bool menuInput=RefreshMenuState() || demo->menuVisible ||
        (demo->handsBridge && demo->script.Read<int>(demo->handsBridge,L"NativeMenuInputBlocked")==1);
    if (menuInput!=demo->menuInputBlocked) {
        // Clear held stock keys on open and require a physical release after
        // close, even when both transitions happen between viewport draws.
        demo->gamepad.Cancel();
        if (demo->handsBridge) demo->script.Invoke(demo->handsBridge,
            demo->script.FindFunction(demo->handsBridge,L"ReleaseControls"),nullptr);
        demo->menuInputBlocked=menuInput;
    }
    XINPUT_STATE state{};
    if (!neutral) demo->gamepad.GetState(0,&state);
    auto& pad=state.Gamepad;
    // Session menus consume Start on their own tick, never as a stock key.
    if (demo->session) pad.wButtons &= ~XINPUT_GAMEPAD_START;
    if (menuInput) {
        // Modal menus own trigger/pointer input; only the menu button remains.
        const WORD menuButton=pad.wButtons&XINPUT_GAMEPAD_START;
        pad={}; pad.wButtons=menuButton;
    }
    const bool independentHands=demo->handsBridge && demo->script.Read<int>(demo->handsBridge,L"NativeIndependentHands")==1;
    if (demo->handsBridge && (independentHands || demo->script.Read<int>(demo->handsBridge,L"NativeControlsEnabled"))) {
        // The hand bridge owns weapon actions. Keep locomotion, use, jump and
        // bash on the stock input path; never emit a second trigger/grenade.
        adapter::RemoveScriptWeaponActions(pad);
        if (independentHands) {
            pad.wButtons &= ~(XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_LEFT_THUMB | XINPUT_GAMEPAD_RIGHT_THUMB);
            // The latched selector owns hand/trigger actions, not thumbsticks.
            // Modal session menus are still blocked by the live-input gate.
            const int movementHand=demo->script.Read<int>(demo->handsBridge,L"MovementHand")==1?1:0;
            const auto motion=adapter::MapIndependentLocomotion(
                !neutral && !menuInput && demo->sampleTick && GetTickCount64()-demo->sampleTick<=250,
                demo->script.Read<int>(demo->handsBridge,L"NativeValidMask"),movementHand,
                demo->script.Read<float>(demo->handsBridge,L"NativeMoveX"),
                demo->script.Read<float>(demo->handsBridge,L"NativeMoveY"),
                demo->script.Read<float>(demo->handsBridge,L"NativeTurnX"));
            pad.sThumbLX=static_cast<SHORT>(std::lround(motion.x*32767.f));
            pad.sThumbLY=static_cast<SHORT>(std::lround(motion.y*32767.f));
            pad.sThumbRX=static_cast<SHORT>(std::lround(motion.turn*32767.f));

        }
    }
    // Apply recorded stick intent after both legacy and independent-hand
    // mappings: the latter otherwise replaces it with the absent XR axis.
    // Live XR never reads this explicit no-headset diagnostic input.
    if (networkRequested && handReplayRequested && !neutral && !menuInput && demo->handsBridge) {
        const auto intent=demo->script.Read<float>(demo->controlledController,L"NativeDiagnosticMoveY");
        if (std::isfinite(intent)) pad.sThumbLY=static_cast<SHORT>(std::clamp(intent,-1.f,1.f)*32767.f);
    }
    demo->turnAxis=pad.sThumbRX/32767.f;
    if (demo->session) {
        if (demo->script.Read<int>(demo->session,L"NativeSnapTurn")) pad.sThumbRX=0;
        else {
            const auto speed=demo->script.Read<float>(demo->session,L"SmoothTurnScale");
            pad.sThumbRX=static_cast<SHORT>(std::lround(kf2vr::adapter::ScaleSmoothTurnAxis(pad.sThumbRX/32767.f,speed)*32767.f));
        }
    }
    const float values[]{pad.sThumbLX/32767.f,pad.sThumbLY/32767.f,pad.sThumbRX/32767.f,0.f,
        pad.bLeftTrigger/255.f,pad.bRightTrigger/255.f};
    unsigned accepted=0;
    for (unsigned i=0;i<6 && (!demo->menuVisible || neutral);++i) {
        std::uint64_t name=0;
        std::memcpy(&name,reinterpret_cast<void*>(gameBase+0x2219338+i*8),sizeof(name));
        accepted+=axis(client,lastLocalViewport,0,name,values[i],delta,1)!=0;
    }
    if (networkRequested && handReplayRequested && accepted && std::abs(values[1])>.1f)
        demo->script.Write(demo->controlledController,L"NativeMovementDispatches",
            demo->script.Read<int>(demo->controlledController,L"NativeMovementDispatches")+1);
    constexpr uintptr_t keyRvas[]{0x22193d0,0x22193d8,0x22193e0,0x22193e8,0x22193f0,0x22193f8,
        0x22193a0,0x22193a8,0x22193c8,0x2219400,0x2219408};
    constexpr WORD masks[]{XINPUT_GAMEPAD_A,XINPUT_GAMEPAD_B,XINPUT_GAMEPAD_X,XINPUT_GAMEPAD_Y,
        XINPUT_GAMEPAD_LEFT_SHOULDER,XINPUT_GAMEPAD_RIGHT_SHOULDER,XINPUT_GAMEPAD_LEFT_THUMB,
        XINPUT_GAMEPAD_RIGHT_THUMB,XINPUT_GAMEPAD_START};
    for (unsigned i=0;i<demo->nativeKeys.size();++i) {
        const bool down=i<9 ? (pad.wButtons&masks[i])!=0 : (i==9?pad.bLeftTrigger:pad.bRightTrigger)>30;
        if (down!=demo->nativeKeys[i]) {
            std::uint64_t name=0;
            std::memcpy(&name,reinterpret_cast<void*>(gameBase+keyRvas[i]),sizeof(name));
            key(client,lastLocalViewport,0,name,down?0:1,1.f,1);
            demo->nativeKeys[i]=down;
        }
    }
    if (Interesting(++demo->nativeInputTicks)) Log("NativeGamepad tick=%llu axesAccepted=%u left=%.3f,%.3f right=%.3f buttons=%x neutral=%d",
        static_cast<unsigned long long>(demo->nativeInputTicks),accepted,values[0],values[1],values[2],pad.wButtons,neutral);
}
bool RefreshMenuState() {
    auto* owner=MenuOwner();
    if (!owner || demo->script.Read<void*>(owner,L"PC")!=demo->controlledController) return false;
    pinned::LocalWorldSnapshot world{};
    if (!LocalWorld(lastLocalPlayer,world) || reinterpret_cast<void*>(world.controller)!=demo->controlledController) return false;
    auto& script=demo->script;
    return script.Invoke(owner,script.FindFunction(owner,L"RefreshMenuState"),nullptr) &&
        script.Read<int>(owner,L"NativeMenuContextValid")==1 &&
        script.Read<int>(owner,L"NativeMenuActive")==1;
}
thread_local void* focusFrameBridge=nullptr;
thread_local void* focusFrameController=nullptr;
adapter::focus::Decision DecideInventoryFocus(void* tickingWorld,void* info,float delta) noexcept {
    focusFrameBridge=nullptr; focusFrameController=nullptr;
    if (!demo || !demo->ready || demo->failed || demo->failureRequested.load(std::memory_order_acquire) ||
        !GameOwnsXr() || !std::isfinite(delta) || delta<=0 || !demo->handsBridge || !demo->controlledPawn) return {};
    pinned::LocalWorldSnapshot world{};
    auto& script=demo->script;
    if (!LocalWorld(lastLocalPlayer,world) || world.world!=reinterpret_cast<uintptr_t>(tickingWorld) ||
        world.worldInfo!=reinterpret_cast<uintptr_t>(info) ||
        world.controller!=reinterpret_cast<uintptr_t>(demo->controlledController) ||
        script.Read<void*>(demo->controlledController,L"Pawn")!=demo->controlledPawn ||
        script.Read<void*>(demo->handsBridge,L"PC")!=demo->controlledController ||
        script.Read<void*>(demo->handsBridge,L"Human")!=demo->controlledPawn) return {};
    // Refuse an unverified world-clock layout before preparing compensation.
    for (const auto& field:std::array<std::pair<const wchar_t*,std::uint32_t>,5>{{
        {L"TimeDilation",0x5dc},{L"TimeSeconds",0x5e4},{L"RealTimeSeconds",0x5e8},
        {L"AudioTimeSeconds",0x5ec},{L"DeltaSeconds",0x5f0}}}) {
        adapter::ScriptField reflected{};
        if (!adapter::FindScriptField(adapter::GameScript::ObjectClass(info),script.Intern(field.first),reflected) ||
            reflected.offset!=field.second || reflected.size!=sizeof(float)) return {};
    }
    if (!demo->sampleTick || GetTickCount64()-demo->sampleTick>250 ||
        demo->frame.state!=xr::SessionState::Focused || !demo->frame.actionsSynced ||
        !demo->frame.headPoseValid || !demo->frame.headPoseTracked || RefreshMenuState()) return {};
    focusFrameBridge=demo->handsBridge; focusFrameController=demo->controlledController;
    if (!script.Invoke(focusFrameBridge,script.FindFunction(focusFrameBridge,L"PrepareInventoryFocus"),nullptr)) {
        focusFrameBridge=nullptr; focusFrameController=nullptr; return {};
    }
    return {script.Read<float>(focusFrameBridge,L"NativeFocusScale"),focusFrameController};
}
void FinishInventoryFocus() noexcept {
    auto* bridge=focusFrameBridge; auto* controller=focusFrameController;
    focusFrameBridge=nullptr; focusFrameController=nullptr;
    // Never restore compensation through a successor's bridge after travel.
    if (demo && bridge && demo->handsBridge==bridge && demo->controlledController==controller &&
        demo->script.Read<void*>(bridge,L"PC")==controller)
        demo->script.Invoke(bridge,demo->script.FindFunction(bridge,L"FinishInventoryFocus"),nullptr);
}
void HookGetMousePosition(void* viewport,menuNative::Point* point) {
    if (GameOwnsXr() && demo->menuCursorActive && viewport==demo->menuCursorViewport && point) {
        *point=demo->menuCursor; ++demo->menuCursorReads; return;
    }
    originalGetMousePosition(viewport,point);
    if (!point || !GameOwnsXr() || viewport!=lastLocalViewport || !Readable(viewport,menuNative::WindowsViewportHwnd+sizeof(HWND))) return;
    auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
    DXGI_SWAP_CHAIN_DESC desc{};
    if (!swapchain || FAILED(swapchain->GetDesc(&desc))) return;
    const HWND hwnd=adapter::GameScript::At<HWND>(viewport,menuNative::WindowsViewportHwnd);
    RECT client{};
    if (!hwnd || hwnd!=desc.OutputWindow || !GetClientRect(hwnd,&client)) return;
    const auto width=adapter::GameScript::At<unsigned>(viewport,0xb4);
    const auto height=adapter::GameScript::At<unsigned>(viewport,0xb8);
    if (width!=desc.BufferDesc.Width || height!=desc.BufferDesc.Height || width>16384 || height>16384) return;
    menuNative::Point mapped;
    if (adapter::MapDesktopMenuPoint(*point,client.right-client.left,client.bottom-client.top,
        static_cast<int>(width),static_cast<int>(height),mapped)) *point=mapped;
}
struct GameMenuSink final : adapter::MenuInputSink {
    void* interaction=nullptr;
    void* engine=nullptr;
    void* viewport=nullptr;
    menuNative::InputKeyFn key=nullptr;
    menuNative::InputAxisFn axis=nullptr;
    const char* refusal="none";
    bool Refuse(const char* reason) { refusal=reason; return false; }
    bool Resolve() {
        auto& script=demo->script;
        // UGameViewportClient and its FViewportClient interface are different
        // subobjects. Reflection starts from the real LocalPlayer UObject.
        auto* client=script.Read<void*>(lastLocalPlayer,L"ViewportClient");
        interaction=script.Read<void*>(client,L"ScaleformInteraction");
        if (!script.IsClass(interaction,L"GFxInteraction")) return Refuse("gfx-interaction");
        auto* table=adapter::GameScript::At<void*>(interaction,0);
        key=adapter::GameScript::At<menuNative::InputKeyFn>(table,menuNative::GfxInputKeySlot);
        axis=adapter::GameScript::At<menuNative::InputAxisFn>(table,menuNative::GfxInputAxisSlot);
        const auto focus=adapter::GameScript::At<menuNative::FocusMovieFn>(table,menuNative::GfxGetFocusMovieSlot);
        if (reinterpret_cast<uintptr_t>(key)!=gameBase+menuNative::GfxInputKeyRva ||
            reinterpret_cast<uintptr_t>(axis)!=gameBase+menuNative::GfxInputAxisRva ||
            reinterpret_cast<uintptr_t>(focus)!=gameBase+menuNative::GfxGetFocusMovieRva) return Refuse("gfx-interface");
        auto* movie=script.Read<void*>(demo->controlledController,L"MyGFxManager");
        if (demo->session && script.Read<int>(demo->session,L"NativeScoreboardActive"))
            movie=script.Read<void*>(script.Read<void*>(demo->controlledController,L"MyGFxHUD"),L"GfxScoreBoardPlayer");
        if (!movie || focus(interaction,0)!=movie) return Refuse("gfx-focus-movie");
        engine=adapter::GameScript::At<void*>(reinterpret_cast<void*>(gameBase+menuNative::GfxEngineGlobalRva),0);
        if (!Readable(engine,menuNative::EngineMousePosition+sizeof(menuNative::Point))) return Refuse("gfx-engine");
        viewport=adapter::GameScript::At<void*>(engine,menuNative::EngineViewport);
        DXGI_SWAP_CHAIN_DESC desc{};
        auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
        if (!swapchain || FAILED(swapchain->GetDesc(&desc)) ||
            adapter::GameScript::At<HWND>(viewport,menuNative::WindowsViewportHwnd)!=desc.OutputWindow)
            return Refuse("gfx-viewport-owner");
        return true;
    }
    bool Move(int x,int y) override {
        if (!Resolve()) return false;
        demo->menuCursor={x,y}; demo->menuCursorViewport=viewport;
        auto& cache=*reinterpret_cast<menuNative::Point*>(static_cast<std::byte*>(engine)+menuNative::EngineMousePosition);
        adapter::ScopedMenuCursor cursor(demo->menuCursorActive,cache,demo->menuCursor);
        const auto reads=demo->menuCursorReads;
        // The non-gamepad branch reads both coordinates through GetMousePos,
        // updates GFx's cache, and dispatches a real mouse move to the movie.
        const bool accepted=axis(interaction,0,demo->script.Intern(L"MouseX"),0.f,0.f,0)!=0;
        const auto observed=adapter::GameScript::At<menuNative::Point>(engine,menuNative::EngineMousePosition);
        const bool matched=demo->menuCursorReads>reads && observed.x==x && observed.y==y;
        if (!matched || Interesting(demo->frame.poseSampleId)) Log("SpatialMenu virtualCursor=%d,%d matched=%d accepted=%d desktopWarp=0",x,y,matched,accepted);
        return accepted && matched ? true : Refuse(matched ? "gfx-move-unaccepted" : "gfx-cursor-receipt");
    }
    bool Button(bool down) override {
        if (!Resolve()) return false;
        if (viewport!=demo->menuCursorViewport) return Refuse("gfx-button-cursor-owner");
        auto& cache=*reinterpret_cast<menuNative::Point*>(static_cast<std::byte*>(engine)+menuNative::EngineMousePosition);
        adapter::ScopedMenuCursor cursor(demo->menuCursorActive,cache,demo->menuCursor);
        const bool accepted=key(interaction,0,demo->script.Intern(L"LeftMouseButton"),down?0:1,down?1.f:0.f,0)!=0;
        Log("SpatialMenu buttonDown=%d accepted=%d gfxOnly=1 sample=%llu",down,accepted,
            static_cast<unsigned long long>(demo->frame.poseSampleId));
        return accepted;
    }
    bool Wheel(int steps) override {
        if (!Resolve() || (steps!=1 && steps!=-1)) return false;
        if (viewport!=demo->menuCursorViewport) return Refuse("gfx-wheel-cursor-owner");
        auto& cache=*reinterpret_cast<menuNative::Point*>(static_cast<std::byte*>(engine)+menuNative::EngineMousePosition);
        adapter::ScopedMenuCursor cursor(demo->menuCursorActive,cache,demo->menuCursor);
        const auto name=demo->script.Intern(steps>0 ? L"MouseScrollUp" : L"MouseScrollDown");
        const bool accepted=key(interaction,0,name,0,1.f,0)!=0;
        key(interaction,0,name,1,0.f,0);
        Log("SpatialMenu scroll=%d accepted=%d gfxOnly=1",steps,accepted);
        return accepted;
    }
    bool Cancel() override {
        if (!Resolve()) return false;
        // Mouse-up carries its own coordinates. Set those outside BEFORE up,
        // without sending an out-of-bounds drag move that could snap a slider
        // to its endpoint. Hover is cleared only after the button is released.
        const menuNative::Point outside{-10000,-10000};
        demo->menuCursor=outside; demo->menuCursorViewport=viewport;
        const bool released=Button(false);
        if (released) Move(outside.x,outside.y);
        return released;
    }
};
void CancelMenuPointer() {
    if (demo->session) {
        demo->script.Write(demo->session,L"NativePointerCancelled",1);
        demo->script.Invoke(demo->session,demo->script.FindFunction(demo->session,L"UpdatePointer"),nullptr);
    }
    GameMenuSink sink;
    if (demo->menuInput.Cancel(sink) && demo->menuCursorViewport && demo->menuCursor.x!=-10000)
        sink.Move(-10000,-10000);
    demo->menuCursorActive=false;
}
bool MenuWindowFocused() {
    DXGI_SWAP_CHAIN_DESC desc{};
    auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
    return swapchain && SUCCEEDED(swapchain->GetDesc(&desc)) && desc.OutputWindow==GetForegroundWindow();
}
void PumpMenuPointer() {
    const auto& pointer=demo->menu.Pointer();
    // XR focus owns controller interaction. The desktop window may be behind
    // SteamVR/Codex while the runtime still grants this application focus.
    // GFx dispatch stays on the verified local movie/viewport and never sends
    // OS mouse input or falls through to gameplay.
    if (!pointer.hit || pointer.cancelled || !RefreshMenuState()) {
        CancelMenuPointer(); demo->menu.DisarmInput(); return;
    }
    auto& script=demo->script;
    if (demo->session) {
        script.Write(demo->session,L"NativePointerU",pointer.u);
        script.Write(demo->session,L"NativePointerV",pointer.v);
        script.Write(demo->session,L"NativePointerPressed",int(pointer.pressed));
        script.Write(demo->session,L"NativePointerReleased",int(pointer.released));
        script.Write(demo->session,L"NativePointerCancelled",0);
        // A stock slider/button keeps its capture when dragged over Resume.
        script.Write(demo->session,L"NativeStockPointerHeld",int(demo->menuInput.Held()));
        script.Invoke(demo->session,script.FindFunction(demo->session,L"UpdatePointer"),nullptr);
        if (script.Read<int>(demo->session,L"NativeShellActive")) return;
        if (script.Read<int>(demo->session,L"NativePointerConsumed")) {
            // The Resume footer belongs to the session, not the stock movie.
            // Release any old GFx capture without cancelling this new button.
            GameMenuSink sink;
            demo->menuInput.Cancel(sink);
            if (demo->menuCursorViewport && demo->menuCursor.x!=-10000) sink.Move(-10000,-10000);
            demo->menuCursorActive=false;
            return;
        }
    }
    auto* owner=MenuOwner();
    if (!script.Invoke(owner,script.FindFunction(owner,L"PrepareMenuInput"),nullptr)) {
        CancelMenuPointer(); demo->menu.DisarmInput();
        if (Interesting(++demo->menuInputRefusals)) Log("SpatialMenu input refused: reason=script-prepare triggerDisarmed=1");
        return;
    }
    GameMenuSink sink;
    if (!demo->menuInput.Update(pointer,static_cast<int>(demo->width),static_cast<int>(demo->height),true,sink)) {
        demo->menu.DisarmInput();
        if (Interesting(++demo->menuInputRefusals)) Log("SpatialMenu input refused: reason=%s triggerDisarmed=1 beamRetained=1",sink.refusal);
    }
}
bool BeginDemoFrame(xr::FrameState& frame);
void RunDeferredGameWork();
// Render side: end a begun XR frame with zero layers and drop the eye atlas.
bool DiscardRenderFrame() {
    demo->gpuTiming.End(demo->backend.Context(),false);
    bool ended=true;
    if (demo->render.xrPending) { ended=demo->backend.EndFrame(); demo->render.xrPending=false; }
    if (demo->ready) demo->blit.OnResize();
    demo->eyeAtlasView.Reset(); demo->eyeAtlas.Reset();
    demo->render.packet.atlasReady=false;
    return ended;
}
// CPU time this thread actually ran since the previous call, in ms. Thread
// cycle time is TSC-based on current Windows, so the TSC rate over the same
// interval converts it; blocking waits are excluded, spin-waits are not.
double ThreadCpuMs(std::array<double,3>& last) {
    ULONG64 cycles=0;
    QueryThreadCycleTime(GetCurrentThread(),&cycles);
    const double tsc=static_cast<double>(__rdtsc()),now=adapter::timing::Now();
    const double ms=last[1] && tsc>last[1] && now>last[2] ?
        (static_cast<double>(cycles)-last[0])*(now-last[2])/(tsc-last[1]) : 0;
    last={static_cast<double>(cycles),tsc,now};
    return ms;
}
// Threaded rendering: the present-side FrameTiming is the render thread's, so
// the game thread logs its own window at each frame's XR request.
void GameThreadFrame() {
    if (!adapter::timing::enabled) return;
    using namespace adapter::timing;
    auto& t=Current();t.Advance();++t.presents;
    const auto elapsed=t.last-t.since;
    if (elapsed<5000) return;
    static std::array<double,3> cpu{};
    Log("GameThreadTiming revision=1 elapsedMs=%.3f frames=%llu cpuMs=%.3f otherMs=%.3f controllerMs=%.3f simulationMs=%.3f leftMs=%.3f rightMs=%.3f worldMs=%.3f renderWaitMs=%.3f viewSetupMs=%.3f sceneSetupMs=%.3f viewportSetupMs=%.3f",
        elapsed,static_cast<unsigned long long>(t.presents),ThreadCpuMs(cpu),t.milliseconds[Other],t.milliseconds[Controller],
        t.milliseconds[Simulation],t.milliseconds[LeftView],t.milliseconds[RightView],t.milliseconds[WorldScene],
        t.milliseconds[XrBegin],t.milliseconds[ViewSetup],t.milliseconds[SceneSetup],t.milliseconds[ViewportSetup]);
    t.milliseconds={};t.calls={};t.presents=0;t.since=t.last;
}
// Begin the XR frame this draw renders. Every XR frame call belongs to the
// render side: under -onethread this runs inline; otherwise the game waits
// while the render thread drains the previous frame and the runtime's wait.
bool AcquireFrame(std::string& error) {
    struct Request {
        HANDLE done=nullptr;
        bool ok=false;
        xr::FrameState frame;
        std::string error;
        ~Request() { if (done) CloseHandle(done); }
    };
    auto request=std::make_shared<Request>();
    const bool queued=renderQueue.Threaded();
    if (queued && !(request->done=CreateEventW(nullptr,TRUE,FALSE,nullptr))) { error="frame request event"; return false; }
    renderQueue.Enqueue([request] {
        auto& render=demo->render;
        if (render.xrPending) {
            // A begun frame whose draw never reached Present.
            demo->gpuTiming.End(demo->backend.Context(),false);
            const bool ended=demo->backend.EndFrame();
            render.xrPending=false;
            Log("XR unpresented frame ended sample=%llu ended=%d zeroLayers=1",
                static_cast<unsigned long long>(render.begunSample),ended);
        }
        auto& frame=request->done ? request->frame : demo->frame;
        request->ok=BeginDemoFrame(frame);
        if (request->ok) { render.xrPending=true; render.begunSample=frame.poseSampleId; }
        else request->error=demo->backend.LastError();
        if (request->done) SetEvent(request->done);
    });
    if (queued) {
        adapter::timing::Scope timing(adapter::timing::XrBegin);
        if (WaitForSingleObject(request->done,2000)!=WAIT_OBJECT_0) {
            Log("XR frame request timed out; this draw stays mono and unsubmitted");
            return false;
        }
        if (request->ok) demo->frame=request->frame;
    }
    if (queued) GameThreadFrame();
    error=request->error;
    return request->ok;
}
bool PrepareOwnerAfterMovie() {
    std::uint64_t ticket=0;
    // UE3 draws the world while its loading movie still owns presentation.
    // Let that stock draw finish the delayed movie-stop lifecycle before XR
    // resumes; a momentary gap between movie Presents is not completion.
    auto* engine=demo->script.Read<void*>(demo->session,L"SessionEngine");
    const bool loadingMovie=engine &&
        demo->script.Read<double>(engine,L"LoadingMovieStartTime")>0.0;
    const auto action=demo->presentHandoff.Action(ticket,loadingMovie);
    if (action==adapter::PresentHandoff::OwnerAction::Continue) return true;
    if (action==adapter::PresentHandoff::OwnerAction::Wait) return false;
    if (action==adapter::PresentHandoff::OwnerAction::UnsafeOverlap) {
        if (!demo->failureRequested.exchange(true,std::memory_order_acq_rel))
            Log("Stereo failed: movie Present overlapped active owner rendering; stop requested");
        return false;
    }
    adapter::PresentOwnerScope ownerWork(demo->presentHandoff);
    if (!ownerWork) return false;
    // Called only inside an owner scope after the movie's engine Present has
    // returned. No XR image is rendered until owner Present, so a pending
    // pre-load frame can be balanced with zero layers, never reused as an atlas.
    demo->gamepad.Cancel();
    CancelMenuPointer(); demo->menu.CancelInput();
    demo->sessionMenuInput.Reset(); demo->snapTurn.Reset();
    demo->sampleTick=0; demo->renderPairLease={}; demo->renderWorldViewOffset={};
    demo->pending=false; demo->atlasReady=false; demo->menuFrame=false; demo->eyePass=-1;
    if (demo->ready) {
        ++demo->resizeGeneration;
        renderQueue.Enqueue([ticket] {
            const bool discarded=demo->render.xrPending;
            if (!DiscardRenderFrame()) {
                demo->failed=true;
                Log("XR movie frame cancellation failed: %s",demo->backend.LastError().c_str());
            } else Log("XR movie handoff resumed generation=%llu discardedPending=%d ownerOnly=1 freshFrameRequired=1",
                static_cast<unsigned long long>(ticket),discarded);
        });
        if (demo->failed) return false;
    } else Log("XR movie handoff resumed generation=%llu discardedPending=0 ownerOnly=1 freshFrameRequired=1",
        static_cast<unsigned long long>(ticket));
    demo->presentHandoff.Complete(ticket);
    const auto plateFrames=demo->backend.StaticQuadFrames();
    if (plateFrames!=demo->loadingPlateLogged) {
        Log("LoadingPlate movie frames=%llu failures=%llu",static_cast<unsigned long long>(plateFrames),
            static_cast<unsigned long long>(demo->backend.StaticQuadFailures()));
        demo->loadingPlateLogged=plateFrames;
    }
    return true;
}
// Whether an owner frame with no world should carry the loading plate: before
// the local world is admitted (startup, the network handshake), across travel
// and while UE3's loading movie owns presentation. An in-match Present with no
// world family keeps zero layers so a stock menu is never covered.
bool ShowLoadingPlate() {
    if (!demo->loadingPlate.load(std::memory_order_acquire)) return false;
    if (demo->travelling.load(std::memory_order_acquire) || !demo->controlledController) return true;
    auto* engine=demo->session ? demo->script.Read<void*>(demo->session,L"SessionEngine") : nullptr;
    return engine && demo->script.Read<double>(engine,L"LoadingMovieStartTime")>0.0;
}
void UpdateSession(void* session) {
    auto& script=demo->script;
    script.Initialise(gameBase);
    auto* viewport=script.Read<void*>(session,L"Viewport");
    if (!script.IsClass(viewport,L"VRGameViewportClient") || script.Read<void*>(viewport,L"VRSession")!=session) return;
    const DWORD thread=GetCurrentThreadId();
    DWORD expected=0;
    worldDrawThread.compare_exchange_strong(expected,thread,std::memory_order_acq_rel);
    if (worldDrawThread.load(std::memory_order_acquire)!=thread) return;
    demo->session=session; demo->sessionRegistered.store(true,std::memory_order_release);
    if (!PrepareOwnerAfterMovie()) return;
    if (script.Read<int>(session,L"NativeTravelPending")) {
        if (!demo->travelling.exchange(true,std::memory_order_acq_rel)) {
            CancelMenuPointer(); demo->gamepad.Cancel(); demo->sessionMenuInput.Reset(); demo->snapTurn.Reset();
            demo->menu.Reset(); demo->headAim.Reset(); demo->renderPairLease={};
            demo->handsBridge=nullptr; demo->heldWeapon=nullptr; demo->handsValid=false;
            demo->controlledPawn=nullptr; demo->controlledController=nullptr;
            Log("SessionTravel world references released replay=%d",handReplayRequested);
            // Dismiss the last projected scene before a blocking engine load.
            // The runtime keeps tracking; never show a frozen game camera.
            if (demo->ready) {
                demo->pending=false; demo->atlasReady=false; ++demo->resizeGeneration;
                renderQueue.Enqueue([] {
                    DiscardRenderFrame();
                    xr::FrameState dismissal;
                    if (BeginDemoFrame(threadedRender ? dismissal : demo->frame))
                        demo->backend.EndFrame(demo->loadingPlate.load(std::memory_order_acquire));
                });
            }
        }
        return;
    }
    auto* pc=script.Read<void*>(session,L"PC");
    auto* player=script.Read<void*>(pc,L"Player");
    pinned::LocalWorldSnapshot world{};
    if (!script.IsClass(player,L"LocalPlayer") || script.Read<void*>(player,L"ViewportClient")!=viewport ||
        !LocalWorld(player,world) || reinterpret_cast<void*>(world.controller)!=pc) return;
    lastLocalPlayer=player;
    demo->controlledController=pc;
    if (demo->travelling.exchange(false,std::memory_order_acq_rel)) {
        DXGI_SWAP_CHAIN_DESC desc{};
        auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
        if (swapchain && SUCCEEDED(swapchain->GetDesc(&desc))) {
            demo->width=desc.BufferDesc.Width; demo->height=desc.BufferDesc.Height;
        }
    }
    script.Write(session,L"NativeConnection",demo->ready && !demo->failed ? 1 : 0);
    if (!demo->ready || demo->failed || !GameOwnsXr()) return;
    script.Invoke(session,script.FindFunction(session,L"EnforceRenderSettings"),nullptr);
    const int requestedPercent=script.Read<int>(session,L"EyeRenderPercent");
    if (requestedPercent>=50 && requestedPercent<=100) eyeRenderPercent=static_cast<unsigned>(requestedPercent);
    EnsureEyeResolution();
    if (demo->failed) return;
    script.Write(session,L"NativeEyeRenderPercent",static_cast<int>(eyeRenderPercent));
    script.Write(session,L"NativeEyeWidth",static_cast<int>(adapter::ScaledEyeExtent(demo->backend.RecommendedWidth(),eyeRenderPercent)));
    script.Write(session,L"NativeEyeHeight",static_cast<int>(adapter::ScaledEyeExtent(demo->backend.RecommendedHeight(),eyeRenderPercent)));
    const bool fresh=demo->sampleTick && GetTickCount64()-demo->sampleTick<=250 &&
        demo->frame.state==xr::SessionState::Focused && demo->frame.actionsSynced &&
        demo->frame.headPoseValid && demo->frame.headPoseTracked;
    script.Write(session,L"NativeHeadTracked",int(fresh));
    if (!fresh) { CancelMenuPointer(); demo->sessionMenuInput.Reset(); demo->snapTurn.Reset(); return; }
    if (demo->sessionInputSample==demo->frame.poseSampleId) return;
    demo->sessionInputSample=demo->frame.poseSampleId;
    const auto& left=demo->frame.handLeft;
    const auto& right=demo->frame.handRight;
    const bool menuDown=(left.menuActive && left.menuPressed) || (right.menuActive && right.menuPressed);
    const bool chordActive=left.stickClickActive && right.stickClickActive && left.stickActive && right.stickActive &&
        left.aimPoseTracked && right.aimPoseTracked && left.triggerActive && right.triggerActive;
    const bool chord=chordActive && left.stickPressed && right.stickPressed && left.triggerAxis<.1f && right.triggerAxis<.1f &&
        std::abs(left.stickX)<.2f && std::abs(left.stickY)<.2f && std::abs(right.stickX)<.2f && std::abs(right.stickY)<.2f;
    if (demo->sessionMenuInput.Update(fresh,left.menuActive || right.menuActive,menuDown,chordActive,chord,demo->frame.predictedDisplayTime)) {
        CancelMenuPointer(); demo->menu.Recenter(); script.Write(session,L"NativeToggleRequested",1);
        return;
    }
    if (demo->menuVisible) PumpMenuPointer();
}
std::int32_t HookControllerTick(void* controller,float delta,std::int32_t tickType) {
    RunDeferredGameWork();
    if (GameOwnsXr() && !PrepareOwnerAfterMovie()) {
        demo->gamepad.Cancel();
        return originalControllerTick(controller,delta,tickType);
    }
    delta=adapter::focus::ControllerDelta(controller,delta);
    adapter::timing::Scope timing(adapter::timing::Controller);
    adapter::AppliedHeadAim beforeTurn{};
    bool pivotTurn=false;
    if (demo && GetCurrentThreadId()==worldDrawThread.load(std::memory_order_acquire)) {
        pinned::LocalWorldSnapshot world{};
        if (LocalWorld(lastLocalPlayer,world) && reinterpret_cast<uintptr_t>(controller)==world.controller) {
            demo->script.Initialise(gameBase);
            const auto nextPawn=demo->script.Read<void*>(controller,L"Pawn");
            if (controller!=demo->controlledController || nextPawn!=demo->controlledPawn) {
                demo->renderPairLease={};
                CancelMenuPointer(); demo->menu.Reset(); demo->menuVisible=false; demo->hud.Reset();
                // A different controller belongs to a new world/session. Its
                // predecessor's script actors may already have been collected;
                // their Destroyed handlers own cleanup, so only forget them.
                if (demo->handsBridge && controller==demo->controlledController) {
                    demo->script.Write(demo->handsBridge,L"NativeHudMask",0);
                    demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"SuspendSpatialHUD"),nullptr);
                }
                demo->menuInput.Reset(); demo->menuCursorActive=false; demo->menuTarget=nullptr;
                demo->handsBridge=nullptr; demo->heldWeapon=nullptr; demo->handsValid=false;
                // Unpossession on death keeps the current head reference. A
                // new pawn or controller starts a new gameplay calibration.
                if (controller!=demo->controlledController || nextPawn) demo->headAim.Reset();
            }
            demo->controlledController=controller;
            demo->controlledPawn=nextPawn;
            if (networkRequested && handReplayRequested && demo->handsBridge) PumpNativeInput(delta);
        }
    }
    if (GameOwnsXr() && demo->ready && !demo->failed && !demo->failureRequested.load(std::memory_order_acquire)) {
        pinned::LocalWorldSnapshot world{};
        if (LocalWorld(lastLocalPlayer,world) && reinterpret_cast<uintptr_t>(controller)==world.controller) {
            demo->script.Initialise(gameBase);
            demo->controlledPawn=demo->script.Read<void*>(controller,L"Pawn");
            // GSA can restore desktop graphics after our isolated INI was
            // loaded. Correct/read back the VR settings before any Canvas
            // holds the backbuffer, then restore the runtime eye dimensions.
            if (MenuOwner()) {
                auto& script=demo->script;
                script.Invoke(MenuOwner(),script.FindFunction(MenuOwner(),L"EnforceRenderSettings"),nullptr);
            }
            EnsureEyeResolution();
            if (demo->failed) return originalControllerTick(controller,delta,tickType);
            // A completed eye pair may be older than the input deadline.
            // Release cached stock axes/buttons before dispatching this tick;
            // cancelling only afterward leaves one stale movement tick queued.
            const bool staleInput=!demo->sampleTick || GetTickCount64()-demo->sampleTick>250;
            if (staleInput) demo->gamepad.Cancel();
            PumpNativeInput(delta,staleInput);
            // Menus still need head/reference maintenance for their stereo
            // world backdrop, including recentering. PumpNativeInput already
            // leaves only the menu button active; room movement stays gated.
            pinned::NativeRotator current{};
            if (!demo->sampleTick || GetTickCount64()-demo->sampleTick>250 || !ReadRotation(controller,current)) {
                // A load hitch or diagnostic PNG readback can exceed 250 ms.
                // Neutralize stale input, but keep the calibrated body and
                // applied HMD deltas so the next sample cannot tilt/recenter
                // the world. Pawn/controller changes above explicitly reset.
                if (demo->headAim.Suspend()) Log("HeadAim suspended staleSample=1 referencePreserved=1");
                demo->gamepad.Cancel();
            } else {
                const auto setRotation=reinterpret_cast<pinned::ActorSetRotationFn>(gameBase+pinned::kActorSetRotationRva);
                const bool explicitRecenter=(MenuOwner() && demo->script.Read<int>(MenuOwner(),L"NativeRecenterRequested")) ||
                    (demo->handsBridge && demo->script.Read<int>(demo->handsBridge,L"NativeRecenterRequested"));
                if ((demo->headAim.SpaceChanged(demo->frame) || explicitRecenter) &&
                    demo->frame.headPoseValid && demo->frame.headPoseTracked && demo->frame.state==xr::SessionState::Focused) {
                    // Preserve virtual facing, discard the old HMD pitch and
                    // calibrate current physical height at the pawn's eye.
                    const pinned::NativeRotator level{0,current.yaw,0};
                    if (!setRotation(controller,&level) || !ReadRotation(controller,current)) {
                        demo->failed=true; demo->gamepad.Cancel();
                        return originalControllerTick(controller,delta,tickType);
                    }
                    demo->headAim.Reset();
                    demo->menu.Reset();
                    if (demo->handsBridge) demo->script.Write(demo->handsBridge,L"NativeRecenterRequested",0);
                    if (demo->session) demo->script.Write(demo->session,L"NativeRecenterRequested",0);
                    Log("RoomScale recentered epoch=%llu stage=%d",static_cast<unsigned long long>(demo->frame.referenceSpaceEpoch),int(demo->backend.Info().stageSpace));
                }
                adapter::HeadAimRequest request{};
                const auto status=demo->headAim.Prepare(world.controller,current,demo->frame,request);
                // Floor match needs absolute heights, so only a STAGE space;
                // the bridge publishes 0 for seated play.
                demo->headAim.SetFloorEye(demo->backend.Info().stageSpace && demo->handsBridge ?
                    demo->script.Read<float>(demo->handsBridge,L"NativeFloorEyeHeight") : 0.f);
                if (status==adapter::HeadAimStatus::ReferenceEstablished) {
                    if (demo->handsBridge) demo->script.Write(demo->handsBridge,L"NativeCalibrationEpoch",
                        demo->script.Read<int>(demo->handsBridge,L"NativeCalibrationEpoch")+1);
                    // Spawn/respawn may retain the previous pawn's tracked
                    // pitch. Never calibrate that into the new body's gravity.
                    if (current.pitch || current.roll) {
                        const pinned::NativeRotator level{0,current.yaw,0};
                        if (!setRotation(controller,&level) || !ReadRotation(controller,current)) {
                            demo->headAim.Reset(); demo->failed=true; demo->gamepad.Cancel();
                            Log("HeadAim failed: neutral body rotation rejected");
                        }
                    }
                    Log("HeadAim reference sample=%llu controller=%p",static_cast<unsigned long long>(demo->frame.poseSampleId),controller);
                } else if (status==adapter::HeadAimStatus::RotationRequested) {
                    pinned::NativeRotator actual{};
                    if (!setRotation(controller,&request.rotation) || !ReadRotation(controller,actual) || !demo->headAim.Commit(request,actual)) {
                        demo->headAim.Reset(); demo->failed=true; demo->gamepad.Cancel();
                        Log("HeadAim failed: stock rotation update/readback rejected");
                    } else if (Interesting(request.poseSampleId)) Log("HeadAim applied sample=%llu pitch=%d yaw=%d priorFrameSample=1",
                        static_cast<unsigned long long>(request.poseSampleId),actual.pitch,actual.yaw);
                }
                if (!demo->menuVisible && !demo->failed && ReadRotation(controller,current) &&
                    demo->headAim.RenderState(world.controller,current,beforeTurn)) {
                    if (demo->handsBridge) {
                        const auto requested=adapter::RoomMovementRequest(beforeTurn,demo->frame,delta);
                        if (requested.LengthSq()>0) {
                            auto& script=demo->script;
                            script.Write(demo->handsBridge,L"RoomMoveRequested",requested);
                            script.Write(demo->handsBridge,L"RoomMoveAccepted",kf2vr::Vec3{});
                            script.Invoke(demo->handsBridge,script.FindFunction(demo->handsBridge,L"ApplyRoomMovement"),nullptr);
                            const auto accepted=script.Read<kf2vr::Vec3>(demo->handsBridge,L"RoomMoveAccepted");
                            demo->headAim.ConsumeRoomMovement(accepted,beforeTurn);
                            if (Interesting(++demo->roomMovementTicks)) Log("RoomScale move=%llu requested=%.3f,%.3f accepted=%.3f,%.3f",
                                static_cast<unsigned long long>(demo->roomMovementTicks),requested.x,requested.y,accepted.x,accepted.y);
                        }
                    }
                    pivotTurn=ReadRotation(controller,current) && demo->headAim.RenderState(world.controller,current,beforeTurn);
                }
            }
        } else if (world.controller==reinterpret_cast<uintptr_t>(controller) || !world.controller) {
            demo->headAim.Reset(); demo->gamepad.Cancel();
        }
    }
    if (GameOwnsXr() && demo->session && controller==demo->controlledController) {
        const bool allowed=pivotTurn && !demo->menuVisible && demo->sampleTick && GetTickCount64()-demo->sampleTick<=250 &&
            demo->frame.state==xr::SessionState::Focused && demo->script.Read<int>(demo->session,L"NativeSnapTurn");
        const int turn=demo->snapTurn.Update(demo->turnAxis,allowed,demo->script.Read<float>(demo->session,L"SnapTurnDegrees"));
        pinned::NativeRotator current{};
        if (turn && ReadRotation(controller,current)) {
            current.yaw+=turn;
            reinterpret_cast<pinned::ActorSetRotationFn>(gameBase+pinned::kActorSetRotationRva)(controller,&current);
        }
    }
    // Preserve the original simulation, input, recoil and camera update path.
    const auto result=[&] {
        adapter::timing::Scope simulation(adapter::timing::Simulation);
        return originalControllerTick(controller,delta,tickType);
    }();
    if (pivotTurn) {
        pinned::NativeRotator current{};
        adapter::AppliedHeadAim afterTurn{};
        if (ReadRotation(controller,current) &&
            demo->headAim.RenderState(reinterpret_cast<uintptr_t>(controller),current,afterTurn))
            demo->headAim.PivotTurn(demo->frame,beforeTurn,afterTurn);
    }
    return result;
}
void HookPortalRender(void* probe,void* renderer) {
    adapter::timing::Scope timing(adapter::timing::PortalCapture);
    portalCapture.Render(probe,renderer);
}
kf2vr::portal::CaptureMatrix* HookPortalClip(kf2vr::portal::CaptureMatrix* out,
    const kf2vr::portal::CaptureMatrix* projection,const kf2vr::portal::CapturePlane* plane) {
    return portalCapture.Clip(out,projection,plane);
}
void SubmitEye(void* canvas,void* family) {
    if (benchmarkFile && renderPassReadbackVerified && demo && demo->eyePass>=0 && demo->eyePass<2)
        demo->renderPasses[demo->eyePass]=adapter::ReadRenderPassSettings(gameBase);
    // Portal captures, when a pair is open, render inside this submission.
    adapter::timing::Scope world(adapter::timing::drilldownEnabled && demo ?
        (demo->eyePass==1?adapter::timing::RightScene:adapter::timing::LeftScene):adapter::timing::WorldScene);
    originalSubmit(canvas,family);
}
// Benchmarks render one fixed, level view with neutral controllers so headset,
// controller or desk movement cannot change the workload. Tracking, focus and
// visibility are still live and still invalidate the capture when lost.
void FreezeBenchmarkView(xr::FrameState& frame) {
    auto& fixed=demo->benchmarkView;
    if (!demo->benchmarkViewFrozen) {
        if (!frame.viewsValid || !frame.headPoseValid || !frame.headPoseTracked) return;
        const kf2vr::HeadInTracking level{kf2vr::Quat{},frame.head.pos};
        const auto rebase=[&](const auto& pose) { return pose.Then(frame.head.Inverse()).Then(level); };
        fixed=frame;
        fixed.head=level;
        fixed.eyeLeft.pose=rebase(frame.eyeLeft.pose);
        fixed.eyeRight.pose=rebase(frame.eyeRight.pose);
        // Same neutral hands as the offline hand fixture, placed from the level head.
        const auto place=[&](auto& hand,const kf2vr::Vec3& offset) {
            hand.grip.pos=level.pos+offset;hand.aim.pos=hand.grip.pos;hand.aim.rot={};
        };
        place(fixed.handLeft,{-.2f,-.25f,-.65f});
        place(fixed.handRight,{.2f,-.25f,-.25f});
        fixed.handLeft.grip.rot=kf2vr::Quat::FromAxisAngle({0,0,1},1.5707963f);
        fixed.handRight.grip.rot=kf2vr::Quat::FromAxisAngle({0,0,1},-1.5707963f);
        demo->benchmarkViewFrozen=true;
        Log("BenchmarkView frozen head=%.3f,%.3f,%.3f",level.pos.x,level.pos.y,level.pos.z);
    }
    frame.head=fixed.head;
    frame.eyeLeft.pose=fixed.eyeLeft.pose;frame.eyeRight.pose=fixed.eyeRight.pose;
    frame.eyeLeft.fov=fixed.eyeLeft.fov;frame.eyeRight.fov=fixed.eyeRight.fov;
    const auto hold=[](auto& live,const auto& still) {
        const bool valid=live.poseValid,tracked=live.poseTracked,aimValid=live.aimPoseValid,aimTracked=live.aimPoseTracked;
        live=still;
        live.poseValid=valid;live.poseTracked=tracked;live.aimPoseValid=aimValid;live.aimPoseTracked=aimTracked;
        live.triggerAxis=live.gripAxis=live.stickX=live.stickY=0;
        live.primaryPressed=live.secondaryPressed=live.stickPressed=live.menuPressed=false;
    };
    hold(frame.handLeft,fixed.handLeft);hold(frame.handRight,fixed.handRight);
}
bool BeginDemoFrame(xr::FrameState& frame) {
    adapter::timing::Scope timing(adapter::timing::XrBegin);
    if (!demo->backend.BeginFrame(frame)) return false;
    if (benchmarkFile) FreezeBenchmarkView(frame);
    return true;
}
void HookSubmit(void* canvas,void* family) {
    adapter::timing::Scope timing(adapter::timing::SceneSetup);
    // The scene's own depth clears run wherever its draw executes; bracket them
    // in command order so a nested submission restores the outer state.
    struct DepthScope {
        DepthScope() { renderQueue.Enqueue([] {
            foregroundDepthStack.push_back(std::move(foregroundDepth)); foregroundDepth.Begin(false); }); }
        ~DepthScope() { renderQueue.Enqueue([] {
            foregroundDepth=std::move(foregroundDepthStack.back()); foregroundDepthStack.pop_back(); }); }
    } depthScope;
    const auto keepWorldDepth=[](bool keep) { renderQueue.Enqueue([keep] { foregroundDepth.Begin(keep); }); };
    const auto count=++families;
    if (Interesting(count)) Log("SubmitScene count=%llu canvas=%p family=%p caller_rva=%llx",count,canvas,family,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase));
    // The UI-only menu pass owns no world view. Its two background eye passes
    // below use the same coherent XR frame as the anchored menu and beam.
    if (GameOwnsXr() && demo->menuFrame && demo->eyePass<0) {
        if (MenuOwner() && demo->script.Read<int>(MenuOwner(),L"NativeMenuRenderStage")==2 &&
            reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase==0x677831) {
            demo->atlasReady=false;
            Log("SpatialMenu image refused unexpected world submission");
            return;
        }
        originalSubmit(canvas,family); return;
    }
    const bool localScene=demo && lastLocalFamily==family &&
        reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase==0x677831;
    bool presentationFinalized=false;
    // reuseLeft: the right eye of an accepted pair keeps the left eye's
    // placement. Nothing ticks between the eyes and FinishRenderPair has
    // proven the same pose sample, camera, hands and display time.
    const auto finalizePresentation=[&](bool reuseLeft=false) {
        if (presentationFinalized || !localScene || !demo->handsBridge || !LocalComfortActive()) return;
        presentationFinalized=true;
        if (reuseLeft) {
            keepWorldDepth(demo->script.Read<int>(demo->handsBridge,L"NativeKeepWorldDepth")!=0);
            return;
        }
        // Actor timers and skeletal evaluation can advance after SetPosition.
        // Stereo must acquire its current XR frame BEFORE this final placement:
        // placing here before BeginFrame gave the left eye the preceding hand
        // pose while the right eye and both cameras used the new one.
        // Independent presentation also owns empty hands and items held only
        // in the other hand. Legacy primary-weapon readiness cannot gate it.
        const bool independentHands=demo->script.Read<int>(demo->handsBridge,L"NativeIndependentHands")==1;
        if (demo->handsValid || independentHands) {
            const auto suppliedSample=handReplayRequested ? 0 : SupplyHands(demo->handsBridge);
            demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"PlaceWeapon"),nullptr);
            demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"UpdateSpatialHUD"),nullptr);
            // Script has hidden the spare magazine and published its pop scale
            // by now. Composed bones only survive to submission if they are
            // written after this final placement, never during the VM tick.
            ApplyReloadMeshPop(demo->script,demo->handsBridge,demo->heldWeapon);
            if (stereoRequested && Interesting(demo->frame.poseSampleId))
                Log("TrackedPresentation sample=%llu eye=%d suppliedSample=%llu xrPending=%d",
                    static_cast<unsigned long long>(demo->frame.poseSampleId),demo->eyePass,
                    static_cast<unsigned long long>(suppliedSample),demo->pending);
        }
        // Keep world depth even when input tracking is temporarily unavailable.
        keepWorldDepth(demo->script.Read<int>(demo->handsBridge,L"NativeKeepWorldDepth")!=0);
    };
    if (stereoRequested && demo && lastLocalFamily==family &&
        reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase==0x677831) {
        lastLocalFamily=nullptr;
        const DWORD owner=demo->ownerThread.load(std::memory_order_acquire);
        if (owner && !GameOwnsXr()) {
            RequestThreadFailure("world scene submission");
        } else if (owner) {
            if (!PrepareOwnerAfterMovie()) {
                originalSubmit(canvas,family); return;
            }
            // All non-atomic DemoRuntime fields below are owner-thread-only.
            if (demo->failureRequested.load(std::memory_order_acquire)) demo->failed=true;
            if (demo->ready && !demo->failed) {
                pinned::LocalWorldSnapshot world{};
                const bool local=LocalWorld(lastLocalPlayer,world);
                if (!local) {
                    demo->renderPairLease={};
                    demo->gamepad.Cancel();
                    demo->stereo.ResetReference();
                    if (!networkRequested && (world.status==pinned::LocalWorldStatus::NetworkMode || world.status==pinned::LocalWorldStatus::NetworkDriver)) {
                        Log("Stereo refused: standalone world required mode=%u netDriver=%p",world.netMode,reinterpret_cast<void*>(world.netDriver));
                        demo->failed=true;
                    } else if (Interesting(count)) Log("Stereo waiting for local world status=%d",static_cast<int>(world.status));
                    finalizePresentation();
                    originalSubmit(canvas,family);
                    return;
                }
                std::string beginError;
                if (!threadedRender && demo->render.xrPending && demo->eyePass!=1 && !demo->menuFrame) {
                    Log("Stereo refused: previous frame did not reach Present");
                    demo->gamepad.Cancel();
                    demo->failed=true;
                } else if (demo->pending || AcquireFrame(beginError)) {
                    if (demo->eyePass!=1) { demo->sampleTick=GetTickCount64(); demo->pairPresented=false; }
                    demo->pending=true; demo->atlasReady=false;
                    std::string error;
                    const auto generation=demo->resizeGeneration.load();
                    adapter::AppliedHeadAim applied{};
                    pinned::NativeRotator rotation{};
                    bool aimReady=!demo->headAim.SpaceChanged(demo->frame) &&
                        ReadRotation(reinterpret_cast<void*>(world.controller),rotation);
                    if (aimReady) aimReady=demo->eyePass==1 ?
                        demo->headAim.FinishRenderPair(world.controller,rotation,demo->frame,demo->renderPairLease,applied) :
                        demo->headAim.BeginRenderPair(world.controller,rotation,demo->frame,
                            GetTickCount64()-demo->sampleTick,demo->renderPairLease,applied);
                    if (aimReady) {
                        adapter::BoundRoomView(applied,demo->frame,demo->leanMetres);
                        finalizePresentation(demo->eyePass==1 && demo->pairPresented && !perEyePresentation);
                        if (demo->eyePass!=1) demo->pairPresented=presentationFinalized;
                    }
                    if (demo->eyePass!=1) {
                        // Presentation only: neither CameraCache nor pawn/hand
                        // poses move. Capture once so a late right eye cannot
                        // receive a different utility offset from its left eye.
                        demo->renderWorldViewOffset={};
                        if (aimReady && demo->session &&
                            demo->script.Read<int>(demo->session,L"NativeConnection")==1 &&
                            demo->script.Read<int>(demo->session,L"NativeTravelPending")==0 &&
                            demo->script.Read<int>(demo->session,L"NativeShellActive")==0 &&
                            demo->script.Read<int>(demo->session,L"NativeSelfViewActive")==1) {
                            const auto offset=demo->script.Read<kf2vr::Vec3>(demo->session,L"NativeSelfViewOffset");
                            if (adapter::IsValidWorldViewOffset(offset)) demo->renderWorldViewOffset=offset;
                        } else if (aimReady && networkRequested && world.netMode==3 &&
                            world.controller==reinterpret_cast<uintptr_t>(demo->controlledController) &&
                            demo->script.Read<int>(demo->controlledController,L"NativeSelfViewActive")==1) {
                            const auto offset=demo->script.Read<kf2vr::Vec3>(
                                demo->controlledController,L"NativeSelfViewOffset");
                            if (adapter::IsValidWorldViewOffset(offset)) demo->renderWorldViewOffset=offset;
                        }
                    }
                    demo->stereo.SetSingleViewDiagnostic(true,demo->eyePass==1?1:0);
                    if (demo->gpuTimingReady && demo->eyePass==0 && !demo->menuFrame && aimReady &&
                        demo->frame.shouldRender && demo->frame.viewsValid && demo->frame.poseSampleId%30==0) {
                        renderQueue.Enqueue([sample=demo->frame.poseSampleId,width=demo->width.load(),height=demo->height.load()] {
                            if (!demo->gpuTiming.Begin(demo->backend.Context())) return;
                            demo->gpuTimingSample=sample;demo->gpuTimingWidth=width;demo->gpuTimingHeight=height;
                        });
                    }
                    if (aimReady && demo->frame.shouldRender && demo->frame.viewsValid &&
                        demo->stereo.SubmitStereoPair(family,demo->frame,SubmitEye,canvas,gameBase,error,&applied,
                            demo->renderWorldViewOffset)) {
                        // Resize can be reentrant inside engine submission. It
                        // already ended that frame; never revive its old atlas.
                        demo->atlasReady=demo->pending && generation==demo->resizeGeneration;
                        // The presentation lease can finish a slow pair, but
                        // cannot renew its captured controller sample as input.
                        if (demo->atlasReady && demo->sampleTick && GetTickCount64()-demo->sampleTick<=250)
                            demo->gamepad.SetFrame(demo->frame,static_cast<double>(demo->sampleTick)*.001);
                        else demo->gamepad.Cancel();
                        if (singleViewDiagnostic && Interesting(demo->frame.poseSampleId)) Log("StereoPair sample=%llu eyeCount=1 oneSubmit=1 atlasReady=%d",
                            static_cast<unsigned long long>(demo->frame.poseSampleId),demo->atlasReady);
                        return; // The engine already submitted once, even if resized.
                    }
                    demo->gamepad.Cancel();
                    if (!error.empty()) { Log("Stereo view fallback: %s",error.c_str()); demo->failed=true; }
                } else {
                    demo->gamepad.Cancel();
                    if (!beginError.empty()) {
                        Log("XR BeginFrame failed: %s",beginError.c_str()); demo->failed=true;
                    }
                }
            }
        }
    }
    finalizePresentation();
    originalSubmit(canvas,family);
}
bool SnapshotEye(unsigned eye) {
    adapter::timing::Scope timing(adapter::timing::EyeCopy);
    if (!demo->ready) return false; // Queued before a stop that released the device.
    auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
    ComPtr<ID3D11Texture2D> source;
    if (!swapchain || FAILED(swapchain->GetBuffer(0,IID_PPV_ARGS(&source)))) return false;
    D3D11_TEXTURE2D_DESC sourceDesc{}; source->GetDesc(&sourceDesc);
    if (eye>1 || sourceDesc.SampleDesc.Count!=1 || !sourceDesc.Width || !sourceDesc.Height || sourceDesc.Width>8192) return false;
    // Own a shader-readable atlas so XR can sample the two completed copies
    // directly. The pixels retain the existing display-encoded sRGB policy;
    // typeless storage permits the explicit sRGB view without another copy.
    DXGI_FORMAT storageFormat=DXGI_FORMAT_UNKNOWN, viewFormat=DXGI_FORMAT_UNKNOWN;
    switch (sourceDesc.Format) {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS:
    case DXGI_FORMAT_R8G8B8A8_UNORM:
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        storageFormat=DXGI_FORMAT_R8G8B8A8_TYPELESS; viewFormat=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; break;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS:
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        storageFormat=DXGI_FORMAT_B8G8R8A8_TYPELESS; viewFormat=DXGI_FORMAT_B8G8R8A8_UNORM_SRGB; break;
    case DXGI_FORMAT_B8G8R8X8_TYPELESS:
    case DXGI_FORMAT_B8G8R8X8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
        storageFormat=DXGI_FORMAT_B8G8R8X8_TYPELESS; viewFormat=DXGI_FORMAT_B8G8R8X8_UNORM_SRGB; break;
    default: return false;
    }
    D3D11_TEXTURE2D_DESC atlasDesc{};
    if (demo->eyeAtlas) demo->eyeAtlas->GetDesc(&atlasDesc);
    if (!demo->eyeAtlas || !demo->eyeAtlasView || atlasDesc.Width!=sourceDesc.Width*2 || atlasDesc.Height!=sourceDesc.Height || atlasDesc.Format!=storageFormat) {
        atlasDesc=sourceDesc; atlasDesc.Width*=2; atlasDesc.MipLevels=1; atlasDesc.ArraySize=1;
        atlasDesc.Format=storageFormat; atlasDesc.SampleDesc={1,0};
        atlasDesc.Usage=D3D11_USAGE_DEFAULT; atlasDesc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        atlasDesc.CPUAccessFlags=0; atlasDesc.MiscFlags=0;
        ComPtr<ID3D11Texture2D> atlas;
        ComPtr<ID3D11ShaderResourceView> view;
        if (FAILED(demo->backend.Device()->CreateTexture2D(&atlasDesc,nullptr,&atlas))) return false;
        D3D11_SHADER_RESOURCE_VIEW_DESC srv{};
        srv.Format=viewFormat; srv.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D; srv.Texture2D.MipLevels=1;
        if (FAILED(demo->backend.Device()->CreateShaderResourceView(atlas.Get(),&srv,&view))) return false;
        demo->eyeAtlasView=view;
        demo->eyeAtlas=atlas;
    }
    demo->backend.Context()->CopySubresourceRegion(demo->eyeAtlas.Get(),0,eye*sourceDesc.Width,0,0,source.Get(),0,nullptr);
    return SUCCEEDED(demo->backend.Device()->GetDeviceRemovedReason());
}
// The copy follows the eye's own draw commands; Present checks the result.
void QueueEyeSnapshot(unsigned eye) {
    renderQueue.Enqueue([eye] {
        demo->render.eyeCopied[eye]=SnapshotEye(eye);
        if (!demo->render.eyeCopied[eye]) Log("Eye snapshot failed: %s",eye?"right":"left");
    });
}
// Hand this frame's game-side state to Present, behind every draw it describes.
void QueueFramePacket(bool needsEyes) {
    FramePacket packet;
    packet.frame=demo->frame;
    packet.atlasReady=demo->atlasReady;
    packet.menuFrame=demo->menuFrame; packet.menuBackdrop=demo->menuBackdrop; packet.needsEyes=needsEyes;
    packet.menuPanel=demo->menu.Panel(); packet.menuPointer=demo->menu.Pointer();
    packet.renderPasses=demo->renderPasses;
    auto& script=demo->script;
    auto& effects=packet.effects;
    if (packet.atlasReady && demo->session && !demo->menuFrame) {
        effects.puke=script.Read<float>(demo->session,L"NativePukeFX");
        effects.fire=script.Read<float>(demo->session,L"NativeFireFX");
        effects.damage=script.Read<float>(demo->session,L"NativeDamageFX");
        effects.blood=script.Read<float>(demo->session,L"NativeBloodFX");
        effects.heal=script.Read<float>(demo->session,L"NativeHealFX");
        effects.energy=script.Read<float>(demo->session,L"NativeEnergyFX");
        effects.rage=script.Read<float>(demo->session,L"NativeRageFX");
        effects.flash=script.Read<float>(demo->session,L"NativeFlashFX");
        effects.blink=script.Read<float>(demo->session,L"NativeBlinkFX");
        effects.nightVision=float(script.Read<int>(demo->session,L"NativeNightVision"));
    }
    if (packet.atlasReady && demo->handsBridge && !demo->menuFrame)
        effects.focus=script.Read<float>(demo->handsBridge,L"NativeFocusFX");
    if (benchmarkFile) {
        packet.benchmarkPhase=demo->handsBridge?script.Read<int>(demo->handsBridge,L"NativeBenchmarkPhase"):0;
        packet.pawnLocation=script.Read<kf2vr::Vec3>(demo->controlledPawn,L"Location");
    }
    demo->pending=false;
    renderQueue.Enqueue([packet] {
        auto& render=demo->render;
        render.packet=packet;
        render.packet.atlasReady=packet.atlasReady && !render.fault &&
            (!packet.needsEyes || (render.eyeCopied[0] && render.eyeCopied[1]));
        render.eyeCopied={}; render.fault=false;
    });
}
struct GameMenuRenderSink final : adapter::MenuRenderSink {
    void* client;
    void* viewport;
    void* canvas;
    void* bridge;
    std::uint64_t generation;
    unsigned worldEyes=0;
    bool drewViewport=false,imageDrawn=false,restored=false;
    GameMenuRenderSink(void* c,void* v,void* drawCanvas) : client(c),viewport(v),canvas(drawCanvas),
        bridge(MenuOwner()),generation(demo->resizeGeneration) {}
    bool Stage(const wchar_t* function,int expected) {
        return bridge && demo->script.Invoke(bridge,demo->script.FindFunction(bridge,function),nullptr) &&
            demo->script.Read<int>(bridge,L"NativeMenuRenderStage")==expected;
    }
    bool BeginWorld() override {
        demo->renderPairLease={};
        return Stage(L"BeginMenuWorldRender",1);
    }
    bool WorldEye(unsigned eye) override {
        demo->eyePass=static_cast<int>(eye); demo->atlasReady=false;
        drewViewport=true;
        {
            adapter::timing::Scope timing(eye?adapter::timing::RightView:adapter::timing::LeftView);
            originalViewportDraw(client,viewport,canvas);
        }
        const bool okay=demo->pending && demo->atlasReady && !demo->failed && generation==demo->resizeGeneration;
        if (okay) { QueueEyeSnapshot(eye); ++worldEyes; }
        return okay;
    }
    bool BeginImage() override {
        demo->eyePass=-1;
        if (!Stage(L"BeginMenuImageRender",2)) return false;
        // A disabled-world viewport may retain its previous contents. Clear
        // this owned backbuffer so the menu can never include the right eye's
        // world image as an accidental flat background.
        renderQueue.Enqueue([] {
            if (!demo->ready) return;
            auto* swapchain=demo->ownerSwapchain.load(std::memory_order_acquire);
            ComPtr<ID3D11Texture2D> buffer;
            ComPtr<ID3D11RenderTargetView> target;
            if (!swapchain || FAILED(swapchain->GetBuffer(0,IID_PPV_ARGS(&buffer))) ||
                FAILED(demo->backend.Device()->CreateRenderTargetView(buffer.Get(),nullptr,&target))) {
                demo->render.fault=true; Log("SpatialMenu image clear failed"); return;
            }
            const FLOAT transparent[]{0,0,0,0};
            demo->backend.Context()->ClearRenderTargetView(target.Get(),transparent);
        });
        return true;
    }
    bool Image() override {
        drewViewport=imageDrawn=true;
        originalViewportDraw(client,viewport,canvas);
        return demo->pending && demo->atlasReady && !demo->failed && generation==demo->resizeGeneration;
    }
    bool Restore() noexcept override {
        demo->eyePass=-1;
        restored=Stage(L"EndMenuRender",0);
        return restored;
    }
};
void HookViewportDraw(void* client,void* viewport,void* canvas) {
    adapter::timing::Scope viewportTiming(adapter::timing::ViewportSetup);
    RunDeferredGameWork();
    if (!GameOwnsXr() || !demo->ready || demo->failed || demo->failureRequested.load(std::memory_order_acquire)) {
        originalViewportDraw(client,viewport,canvas); return;
    }
    if (singleViewDiagnostic) {
        // One native submission; Present reads the swapchain backbuffer.
        originalViewportDraw(client,viewport,canvas);
        QueueFramePacket(false); return;
    }
    if (!PrepareOwnerAfterMovie()) {
        originalViewportDraw(client,viewport,canvas); return;
    }
    if (benchmarkFile) demo->renderPasses={};
    if (demo->gpuTimingReady) renderQueue.Enqueue([] {
        double ms=0;
        const auto result=demo->gpuTiming.Poll(demo->backend.Context(),ms);
        if (result==adapter::timing::GpuFrameTiming::Result::Ready)
            Log("GpuTiming sample=%llu stereoSpanMs=%.3f sceneEye=%ux%u includesSubmissionBubbles=1 compositorIncluded=0",
                static_cast<unsigned long long>(demo->gpuTimingSample),ms,demo->gpuTimingWidth,demo->gpuTimingHeight);
        else if (result==adapter::timing::GpuFrameTiming::Result::Error) {
            demo->gpuTimingReady=false;
            Log("GpuTiming disabled: asynchronous query readback failed");
        } else if (result==adapter::timing::GpuFrameTiming::Result::Discarded)
            Log("GpuTiming sample=%llu discarded=1",static_cast<unsigned long long>(demo->gpuTimingSample));
    });
    // Destroyed after the comfort scope ends, as Present used to read it.
    bool needsEyes=false;
    struct PacketScope { bool& needsEyes; ~PacketScope() { QueueFramePacket(needsEyes); } } packetScope{needsEyes};
    struct ComfortScope {
        void* session;
        explicit ComfortScope(void* s):session(s) {
            if (session) demo->script.Invoke(session,demo->script.FindFunction(session,L"BeginComfortFrame"),nullptr);
        }
        ~ComfortScope() {
            if (session) demo->script.Invoke(session,demo->script.FindFunction(session,L"EndComfortFrame"),nullptr);
        }
    } comfort(demo->session);
    const bool menu=RefreshMenuState();
    auto* menuTarget=menu ? demo->script.Read<void*>(MenuOwner(),L"NativeMenuTarget") : nullptr;
    if (menu && demo->menuVisible && menuTarget!=demo->menuTarget) {
        CancelMenuPointer(); demo->menu.CancelInput();
        Log("SpatialMenu content changed: pointer capture cancelled, anchor preserved");
    }
    demo->menuTarget=menuTarget;
    if (menu!=demo->menuVisible) {
        demo->hud.Reset();
        if (demo->handsBridge) {
            demo->script.Write(demo->handsBridge,L"NativeHudMask",0);
            demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"SuspendSpatialHUD"),nullptr);
        }
        CancelMenuPointer(); demo->menu.Reset(); demo->gamepad.Cancel();
        PumpNativeInput(0.f,true);
        if (demo->handsBridge) demo->script.Invoke(demo->handsBridge,
            demo->script.FindFunction(demo->handsBridge,L"ReleaseControls"),nullptr);
        demo->menuVisible=menu;
        if (!menu) demo->menuCursorActive=false;
        // Signal completion only after ReleaseControls. Script opens calibration
        // on the next game tick, never while the render transition owns cleanup.
        if (demo->session) {
            const auto epoch=static_cast<unsigned>(demo->script.Read<int>(demo->session,L"NativeMenuTransitionEpoch"));
            demo->script.Write(demo->session,L"NativeMenuTransitionEpoch",static_cast<int>((epoch+1u)&0x7fffffffu));
        }
        Log("SpatialMenu active=%d distanceMetres=1.5 rightAimRay=1 source=stockMovie stereoWorld=1",menu);
    }
    if (menu) {
        if (!threadedRender && demo->render.xrPending) {
            // Loading may draw the viewport again without an owner Present.
            // Balance the abandoned frame without submitting its old image;
            // keep the stock draw running so delayed loading can complete.
            demo->atlasReady=false;
            const bool ended=demo->backend.EndFrame();
            demo->render.xrPending=false; demo->pending=false; demo->sampleTick=0;
            demo->renderPairLease={}; demo->gamepad.Cancel();
            if (!ended) demo->failed=true;
            Log("SpatialMenu abandoned frame cancelled ended=%d zeroLayers=1",ended);
            originalViewportDraw(client,viewport,canvas); return;
        }
        demo->menuFrame=true;
        demo->menuBackdrop=!demo->session || demo->script.Read<int>(demo->session,L"NativeMenuBackdrop")==1;
        demo->menu.SetCurved(!demo->menuBackdrop);
        const auto generation=demo->resizeGeneration.load();
        if (MenuOwner()) {
            const float dist=demo->script.Read<float>(MenuOwner(),L"SpatialMenuDistance");
            const float height=demo->script.Read<float>(MenuOwner(),L"SpatialMenuHeight");
            const float scale=demo->script.Read<float>(MenuOwner(),L"SpatialMenuScale");
            demo->menu.Configure(dist,height,scale);
            if (demo->script.Read<int>(MenuOwner(),L"NativeRecenterRequested")) {
                demo->menu.Reset();
            }
        }
        std::string beginError;
        if (AcquireFrame(beginError)) {
            demo->pending=true; demo->sampleTick=GetTickCount64();
            const auto& inputFrame=demo->frame;
            demo->atlasReady=demo->menu.Update(inputFrame,true,
                demo->height ? static_cast<float>(demo->width)/demo->height : 0.f,
                demo->session ? demo->script.Read<int>(demo->session,L"NativeMenuHand") : 1);
            demo->gamepad.SetFrame(inputFrame,static_cast<double>(demo->sampleTick)*.001);
            if (!demo->session) {
                PumpNativeInput(static_cast<float>(demo->frame.predictedDisplayPeriod));
                PumpMenuPointer();
            }
            if (Interesting(++demo->menuFrames)) {
                const auto& hand=inputFrame.handRight;
                const auto& pointer=demo->menu.Pointer();
                Log("SpatialMenu pointer sample=%llu xrFocused=%d actions=%d headTracked=%d rightAimValid=%d rightAimTracked=%d triggerActive=%d trigger=%.3f ray=%d hit=%d down=%d desktopFocused=%d desktopFocusRequired=0",
                    static_cast<unsigned long long>(inputFrame.poseSampleId),inputFrame.state==xr::SessionState::Focused,
                    inputFrame.actionsSynced,inputFrame.headPoseTracked,hand.aimPoseValid,hand.aimPoseTracked,
                    hand.triggerActive,hand.triggerAxis,pointer.rayVisible,pointer.hit,pointer.down,MenuWindowFocused());
            }
        } else {
            demo->atlasReady=false; demo->gamepad.Cancel(); CancelMenuPointer();
            if (!beginError.empty()) {
                demo->failed=true; Log("SpatialMenu XR begin failed: %s",beginError.c_str());
            }
        }
        if (demo->atlasReady && demo->pending && generation==demo->resizeGeneration) {
            GameMenuRenderSink sink(client,viewport,canvas);
            needsEyes=demo->menuBackdrop;
            demo->atlasReady=adapter::RenderMenuLayers(sink,demo->menuBackdrop);
            // The manager's root can arrive asynchronously on its first draw.
            // Do not starve that stock initialization while waiting for it.
            if (!sink.drewViewport) originalViewportDraw(client,viewport,canvas);
            if (Interesting(demo->menuFrames)) Log("SpatialMenu layers ready=%d worldEyes=%u menuImage=%d menuImageWorld=0 scopedFlagsRestored=%d",
                demo->atlasReady,sink.worldEyes,sink.imageDrawn,sink.restored);
        } else {
            // Keep the stock movie lifecycle drawing while XR is not visible.
            originalViewportDraw(client,viewport,canvas);
            demo->atlasReady=false;
        }
        return;
    }
    demo->menuFrame=false;
    // Render the entire viewport (world, postprocessing, Canvas and GFx) once
    // per eye, with one native scene view each time. Simulation is not ticked.
    // KF2's simultaneous two-view path loses world lighting in this build.
    const auto generation=demo->resizeGeneration.load();
    demo->renderPairLease={};
    demo->eyePass=0;
    {
        adapter::timing::Scope timing(adapter::timing::LeftView);
        originalViewportDraw(client,viewport,canvas);
    }
    if (!demo->pending || !demo->atlasReady || generation!=demo->resizeGeneration) {
        demo->eyePass=-1; demo->atlasReady=false; return;
    }
    needsEyes=true;
    QueueEyeSnapshot(0);
    demo->eyePass=1; demo->atlasReady=false;
    {
        adapter::timing::Scope timing(adapter::timing::RightView);
        originalViewportDraw(client,viewport,canvas);
    }
    const bool pair=demo->pending && demo->atlasReady && generation==demo->resizeGeneration;
    if (pair) QueueEyeSnapshot(1);
    demo->eyePass=-1; demo->atlasReady=pair;
    if (!pair) { demo->failed=true; Log("Sequential eye submission failed: right"); }
    else if (Interesting(demo->frame.poseSampleId)) Log("StereoPair sample=%llu eyeCount=2 nativeSubmits=2 atlasReady=1",
        static_cast<unsigned long long>(demo->frame.poseSampleId));
}
DWORD WINAPI HookGetPad(DWORD index,XINPUT_STATE* state) {
    if (index==0 && virtualPadEnabled.load(std::memory_order_acquire)) {
        if (!state) return ERROR_BAD_ARGUMENTS;
        *state={}; // Native callbacks own VR input; avoid duplicate pad events.
        const auto result=ERROR_SUCCESS;
        const auto count=++padPolls;
        if (result==ERROR_SUCCESS && state) {
            const auto& pad=state->Gamepad;
            if (pad.sThumbLX || pad.sThumbLY || pad.sThumbRX || pad.wButtons || pad.bRightTrigger || pad.bLeftTrigger) ++padActivePolls;
            if (Interesting(count)) Log("Gamepad poll=%llu activePolls=%llu left=%d,%d right=%d buttons=%x",
                count,padActivePolls.load(),pad.sThumbLX,pad.sThumbLY,pad.sThumbRX,pad.wButtons);
        }
        return result;
    }
    return originalGetPad(index,state);
}
DWORD WINAPI HookGetPadCaps(DWORD index,DWORD flags,XINPUT_CAPABILITIES* caps) {
    if (index==0 && virtualPadEnabled.load(std::memory_order_acquire)) return demo->gamepad.GetCapabilities(index,flags,caps);
    return originalGetPadCaps(index,flags,caps);
}
// Gameplay half of a stop: menus, HUD, head aim and held stock input.
void StopGameSide() {
    demo->gamepad.Cancel();
    CancelMenuPointer(); demo->menu.Reset(); demo->menuVisible=false; demo->menuFrame=false;
    demo->hud.Reset();
    if (demo->handsBridge) {
        demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"EndMenuRender"),nullptr);
        demo->script.Write(demo->handsBridge,L"NativeHudMask",0);
        demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"SuspendSpatialHUD"),nullptr);
    }
    demo->menuCursorActive=false; demo->menuCursorViewport=nullptr; demo->menuTarget=nullptr;
    demo->headAim.Reset();
    pinned::LocalWorldSnapshot world{};
    if (LocalWorld(lastLocalPlayer,world)) PumpNativeInput(0.f,true);
    demo->pending=false; demo->atlasReady=false;
}
// Owner (render) thread. With threaded rendering the gameplay half is left to
// the game thread's next hook; script must not run on the render thread.
void StopDemoRuntime() {
    if (!demo || GetCurrentThreadId()!=demo->ownerThread.load(std::memory_order_acquire)) return;
    demo->gpuTiming.End(demo->backend.Context(),false);
    if (benchmarkFile) { std::fclose(benchmarkFile);benchmarkFile=nullptr; }
    if (frameDrilldown.file) { std::fclose(frameDrilldown.file);frameDrilldown.file=nullptr; }
    if (frameDrilldown.spans) { std::fclose(frameDrilldown.spans);frameDrilldown.spans=nullptr; }
    if (threadedRender) { demo->gamepad.Cancel(); demo->gameStopRequested.store(true,std::memory_order_release); }
    else StopGameSide();
    if (!demo->ready) return;
    if (demo->render.xrPending) {
        if (!demo->backend.EndFrame()) Log("XR shutdown frame end failed: %s",demo->backend.LastError().c_str());
        demo->render.xrPending=false;
    }
    demo->render.packet.atlasReady=false;
    demo->blit.Shutdown();
    demo->eyeAtlasView.Reset();
    demo->eyeAtlas.Reset();
    demo->backend.Shutdown(); demo->ready=false;
    // Keep the virtual pad connected but neutral to balance held input release.
    Log("XR shutdown completed; virtual gamepad neutral; stock scene submission restored");
}
// Game thread: cleanup the render thread could not do itself.
void RunDeferredGameWork() {
    if (!threadedRender || !demo || GetCurrentThreadId()!=worldDrawThread.load(std::memory_order_acquire)) return;
    if (demo->gameStopRequested.exchange(false,std::memory_order_acq_rel)) StopGameSide();
    const auto notices=demo->resizeNotices.load(std::memory_order_acquire);
    if (notices==demo->resizeNoticesSeen) return;
    demo->resizeNoticesSeen=notices;
    CancelMenuPointer(); demo->menu.CancelInput();
    demo->hud.Reset();
    if (demo->handsBridge) {
        demo->script.Write(demo->handsBridge,L"NativeHudMask",0);
        demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"SuspendSpatialHUD"),nullptr);
    }
    demo->pending=false; demo->atlasReady=false;
}
bool AtlasMatchesBackbuffer(const adapter::StereoAtlas& atlas,const D3D11_TEXTURE2D_DESC& buffer) {
    if (singleViewDiagnostic) return atlas.left.x==0 && atlas.left.y==0 && atlas.left.width==buffer.Width && atlas.left.height==buffer.Height;
    if (buffer.Width<2 || (buffer.Width&1) || !buffer.Height || buffer.ArraySize!=1 || buffer.MipLevels!=1) return false;
    const auto half=buffer.Width/2;
    return atlas.left.x==0 && atlas.left.y==0 && atlas.left.width==half && atlas.left.height==buffer.Height &&
        atlas.right.x==half && atlas.right.y==0 && atlas.right.width==half && atlas.right.height==buffer.Height;
}
void PresentDemo(IDXGISwapChain* swapchain) {
    if (!demo || !stereoRequested) return;
    const DWORD current=GetCurrentThreadId();
    DWORD owner=demo->ownerThread.load(std::memory_order_acquire);
    if (!owner && !demo->sessionRegistered.load(std::memory_order_acquire) &&
        playablePath[0] && GetFileAttributesW(playablePath)==INVALID_FILE_ATTRIBUTES) return;
    // Startup/loading movies Present this same swapchain from a temporary
    // thread even with -onethread. Claim XR only after a normal world camera
    // was observed, on that exact game's drawing thread, or with threaded
    // rendering on the render thread that drains the adapter's commands.
    const DWORD drawThread=worldDrawThread.load(std::memory_order_acquire);
    if (!owner && (!drawThread || current!=(threadedRender ? renderQueue.DrainingThread() : drawThread))) return;
    if (owner && current!=owner) {
        // HookPresent handles movie handoff before any owner-only work.
        return;
    }
    DXGI_SWAP_CHAIN_DESC desc{}; DWORD windowOwner=0;
    if (FAILED(swapchain->GetDesc(&desc))) return;
    GetWindowThreadProcessId(desc.OutputWindow,&windowOwner);
    if (windowOwner!=GetCurrentProcessId()) return;
    if (!owner) {
        DWORD unclaimed=0;
        if (!demo->ownerThread.compare_exchange_strong(unclaimed,current,std::memory_order_acq_rel)) return;
        demo->ownerSwapchain.store(swapchain,std::memory_order_release);
        owner=current;
    }
    if (swapchain!=demo->ownerSwapchain.load(std::memory_order_acquire)) return;
    adapter::PresentOwnerScope ownerWork(demo->presentHandoff);
    if (!ownerWork) return;
    // Ownership is established before touching any mutable runtime flag.
    if (stopRequestPath[0] && GetFileAttributesW(stopRequestPath)!=INVALID_FILE_ATTRIBUTES) {
        demo->attempted=true;
        StopDemoRuntime();
        return;
    }
    if (demo->failureRequested.load(std::memory_order_acquire)) {
        demo->attempted=true; demo->failed=true;
        StopDemoRuntime();
        return;
    }
    // Threaded: the game thread discards across movies, ahead of its next draw.
    if (!threadedRender && !PrepareOwnerAfterMovie()) {
        if (demo->failed || demo->failureRequested.load(std::memory_order_acquire)) StopDemoRuntime();
        // The owner is presenting under an active loading movie: keep the plate
        // up rather than leaving the compositor without frames.
        else if (demo->ready.load(std::memory_order_acquire) && demo->loadingPlate.load(std::memory_order_acquire))
            demo->backend.SubmitStaticQuadFrame();
        return;
    }
    if (!demo->attempted) {
        demo->attempted=true;
        demo->width=desc.BufferDesc.Width; demo->height=desc.BufferDesc.Height;
        ComPtr<ID3D11Device> device;
        if (FAILED(swapchain->GetDevice(IID_PPV_ARGS(&device)))) { Log("Game XR init failed: no D3D11 device"); demo->failed=true; return; }
        xr::D3D11Options options; options.gameDevice=device.Get(); options.preferStageSpace=true; options.applicationName="KF2VR local Support demo";
        options.collectTimings=adapter::timing::enabled;
        if (!demo->backend.Initialise(options)) { Log("Game XR init failed: %s",demo->backend.LastError().c_str()); demo->failed=true; return; }
        if (!demo->blit.Initialise(device.Get(),demo->backend.Context())) { Log("Atlas init failed: %s",demo->blit.LastError().c_str()); demo->backend.Shutdown(); demo->failed=true; return; }
        demo->ready=true;
        {
            const auto plate=adapter::GenerateLoadingPlate(1024,512);
            const bool created=plate.width>0 && demo->backend.CreateStaticQuad(plate.width,plate.height,plate.rgba.data(),1.6f,2.0f);
            demo->loadingPlate.store(created,std::memory_order_release);
            Log("LoadingPlate ready=%d size=%ux%u quad=1.6m@2.0m%s%s",created,plate.width,plate.height,
                created?"":" error=",created?"":demo->backend.LastError().c_str());
        }
        if (adapter::timing::enabled) {
            demo->gpuTimingReady=demo->gpuTiming.Initialise(device.Get());
            Log("GpuTiming available=%d sampleEvery=30 nonblocking=1",demo->gpuTimingReady.load());
        }
        virtualPadEnabled.store(true,std::memory_order_release);
        Log("Game XR ready thread=%lu atlas=%ux%u runtime=%s version=%s system=%s recommendedEye=%ux%u",owner,demo->width.load(),demo->height.load(),
            demo->backend.Info().name.c_str(),demo->backend.Info().version.c_str(),demo->backend.Info().system.c_str(),
            demo->backend.RecommendedWidth(),demo->backend.RecommendedHeight());
    }
    if (!demo->ready) return;
    if (demo->failureRequested.load(std::memory_order_acquire)) demo->failed=true;
    if (demo->render.xrPending) {
        auto& packet=demo->render.packet;
        bool okay=true, captureThisFrame=false;
        std::array<bool,2> captured{};
        const auto submittedBefore=demo->backend.Counters().submitted;
        // A packet describes the frame it was drawn for, never a later begin.
        if (packet.frame.poseSampleId!=demo->render.begunSample) packet.atlasReady=false;
        if (packet.atlasReady && !demo->failed) {
            ComPtr<ID3D11Texture2D> buffer;
            HRESULT getBuffer=S_OK;
            if (singleViewDiagnostic || packet.menuFrame) getBuffer=swapchain->GetBuffer(0,IID_PPV_ARGS(&buffer));
            else { buffer=demo->eyeAtlas; if (!buffer) getBuffer=E_FAIL; }
            if (FAILED(getBuffer)) {
                Log("Game XR backbuffer retrieval failed: HRESULT=%lx",static_cast<unsigned long>(getBuffer));
                okay=false;
            } else {
                D3D11_TEXTURE2D_DESC bufferDesc{}; buffer->GetDesc(&bufferDesc);
                const auto& atlas=demo->stereo.LastAtlas();
                if (singleViewDiagnostic && !AtlasMatchesBackbuffer(atlas,bufferDesc)) {
                    packet.atlasReady=false;
                    demo->gamepad.Cancel();
                    if (Interesting(++demo->atlasDrops)) Log("Atlas extent mismatch: buffer=%ux%u left=%u,%u,%u,%u right=%u,%u,%u,%u; zero-layer frame",
                        bufferDesc.Width,bufferDesc.Height,atlas.left.x,atlas.left.y,atlas.left.width,atlas.left.height,
                        atlas.right.x,atlas.right.y,atlas.right.width,atlas.right.height);
                } else {
                    okay=packet.menuFrame ? (packet.menuBackdrop ? demo->blit.BeginMenuFrame(buffer.Get(),demo->eyeAtlasView.Get()) :
                        demo->blit.BeginFrame(buffer.Get(),true,true)) :
                        (singleViewDiagnostic ? demo->blit.BeginFrame(buffer.Get(),true,true) :
                            demo->blit.BeginFrameView(demo->eyeAtlasView.Get(),true));
                    if (okay) {
                        demo->blit.SetComfortEffects(packet.frame,packet.effects);
                        captureThisFrame=captureRootPath[0] && !demo->captureAttempted && submittedBefore>=120;
                        if (captureThisFrame) demo->captureAttempted=true;
                        okay=demo->backend.RenderEyes([&](const xr::FrameState& sample,const xr::D3D11EyeTarget& target) {
                            const bool rendered=packet.menuFrame ?
                                demo->blit.RenderMenuEye(target,sample,packet.menuPanel,packet.menuPointer) :
                                demo->blit.RenderEye(target);
                            if (!rendered) return false;
                            if (captureThisFrame) {
                                const unsigned eye=target.eye==xr::Eye::Left?0u:1u;
                                std::string captureError;
                                try {
                                    const auto file=std::filesystem::path(captureRootPath)/(eye==0?"left.png":"right.png");
                                    captured[eye]=kf2vr::diagnostics::CaptureTexture(demo->backend.Context(),target.colorTexture,file,captureError,nullptr);
                                } catch (const std::exception& error) { captureError=error.what(); }
                                catch (...) { captureError="unknown diagnostic capture exception"; }
                                Log("GameXRCapture sample=%llu eye=%s success=%d pendingSubmission=1 error=%s",
                                    static_cast<unsigned long long>(sample.poseSampleId),eye==0?"left":"right",captured[eye],captureError.c_str());
                            }
                            return true; // Diagnostic capture failure never cancels rendering.
                        });
                        demo->blit.EndFrame();
                    }
                }
            }
        }
        demo->gpuTiming.End(demo->backend.Context(),okay && packet.atlasReady && !demo->failed && !captureThisFrame);
        const bool ended=demo->backend.EndFrame();
        if (captureThisFrame) {
            const bool submitted=ended && demo->backend.Counters().submitted==submittedBefore+1;
            Log("GameXRCaptureFrame sample=%llu endSucceeded=%d stereoLayerSubmitted=%d left=%d right=%d pairEvidenceValid=%d gpuStallDiagnostic=1",
                static_cast<unsigned long long>(packet.frame.poseSampleId),ended,submitted,captured[0],captured[1],submitted && captured[0] && captured[1]);
        }
        if (!okay || !ended) {
            Log("Game XR frame failed: xr=%s blit=%s",demo->backend.LastError().c_str(),demo->blit.LastError().c_str()); demo->failed=true;
        }
        if (Interesting(packet.frame.poseSampleId)) Log("GameXREnd sample=%llu atlas=%d submitted=%llu",
            static_cast<unsigned long long>(packet.frame.poseSampleId),packet.atlasReady,
            static_cast<unsigned long long>(demo->backend.Counters().submitted));
        if (Interesting(packet.frame.poseSampleId)) Log("GameXRInput sample=%llu focused=%d leftPose=%d stickActive=%d stick=%.3f,%.3f padPolls=%llu activePolls=%llu",
            static_cast<unsigned long long>(packet.frame.poseSampleId),packet.frame.state==xr::SessionState::Focused,
            packet.frame.handLeft.poseValid,packet.frame.handLeft.stickActive,packet.frame.handLeft.stickX,packet.frame.handLeft.stickY,
            padPolls.load(),padActivePolls.load());
        demo->render.xrPending=false; packet.atlasReady=false;
    } else if (!demo->failed && !demo->backend.ShouldQuit()) {
        // Loading screens and menus may not submit a world family. Keep XR
        // events/session timing alive without rendering or advancing gameplay;
        // show the loading plate while there is genuinely nothing to show.
        demo->gamepad.Cancel();
        const bool plate=ShowLoadingPlate();
        xr::FrameState idle;
        if (BeginDemoFrame(idle)) {
            if (!demo->backend.EndFrame(plate)) {
                Log("XR idle frame end failed: %s",demo->backend.LastError().c_str()); demo->failed=true;
            } else if (Interesting(idle.poseSampleId)) {
                Log("GameXRIdle sample=%llu zeroLayers=%d plate=%d",static_cast<unsigned long long>(idle.poseSampleId),!plate,plate);
            }
        } else if (!demo->backend.LastError().empty()) {
            Log("XR idle frame begin failed: %s",demo->backend.LastError().c_str()); demo->failed=true;
        }
    }
    if (demo->failed || demo->backend.ShouldQuit() || demo->failureRequested.load(std::memory_order_acquire)) StopDemoRuntime();
}
HRESULT STDMETHODCALLTYPE HookPresent(IDXGISwapChain* swapchain,UINT interval,UINT flags) {
    FollowRenderThread();
    if (demo && stereoRequested) {
        const auto owner=demo->ownerThread.load(std::memory_order_acquire);
        if (owner && GetCurrentThreadId()!=owner) {
            // UE3 starts its loading movie before NativeTravelPending reaches
            // script. Only atomics and the original engine Present are legal
            // here: skip metadata, screenshots, timers and every XR/D3D helper.
            const bool movie=!(flags&DXGI_PRESENT_TEST) &&
                swapchain==demo->ownerSwapchain.load(std::memory_order_acquire);
            if (movie) demo->presentHandoff.BeginForeign();
            const HRESULT result=originalPresent(swapchain,interval,flags);
            if (movie) demo->presentHandoff.EndForeign();
            // The movie thread is the only presenter while the owner is blocked
            // in LoadMap. A static quad frame needs no D3D or owner state, and
            // the backend skips it whenever the owner holds a begun frame.
            if (movie && demo->ready.load(std::memory_order_acquire) && !demo->failed.load(std::memory_order_acquire) &&
                demo->loadingPlate.load(std::memory_order_acquire)) demo->backend.SubmitStaticQuadFrame();
            return result;
        }
    }
    const auto count=++presents;
    if (Interesting(count) && !(flags&DXGI_PRESENT_TEST)) {
        DXGI_SWAP_CHAIN_DESC desc{};
        ComPtr<ID3D11Device> device;
        ComPtr<IDXGIDevice> dxgiDevice;
        ComPtr<IDXGIAdapter> adapter;
        DXGI_ADAPTER_DESC gpu{};
        DWORD windowProcess=0;
        if (SUCCEEDED(swapchain->GetDesc(&desc))) {
            GetWindowThreadProcessId(desc.OutputWindow,&windowProcess);
            if (windowProcess==GetCurrentProcessId()) replayProbeWindow.store(desc.OutputWindow);
        }
        if (SUCCEEDED(swapchain->GetDevice(IID_PPV_ARGS(&device))) && SUCCEEDED(device.As(&dxgiDevice)) &&
            SUCCEEDED(dxgiDevice->GetAdapter(&adapter)) && SUCCEEDED(adapter->GetDesc(&gpu))) {
            Log("Present count=%llu swapchain=%p device=%p hwnd=%p owner_pid=%lu size=%ux%u format=%u samples=%u feature=%x luid=%08x:%08x views=%llu families=%llu caller_rva=%llx",
                count,swapchain,device.Get(),desc.OutputWindow,windowProcess,desc.BufferDesc.Width,desc.BufferDesc.Height,
                static_cast<unsigned>(desc.BufferDesc.Format),desc.SampleDesc.Count,static_cast<unsigned>(device->GetFeatureLevel()),
                static_cast<unsigned>(gpu.AdapterLuid.HighPart),gpu.AdapterLuid.LowPart,views.load(),families.load(),
                static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(_ReturnAddress())-gameBase));
        }
    }
    if (!(flags&DXGI_PRESENT_TEST)) {
        adapter::timing::Scope timing(adapter::timing::XrSubmit);
        PresentDemo(swapchain);
    }
    if (handReplayRequested && demo && captureRootPath[0] && demo->handsBridge &&
        LocalComfortActive()) {
        demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"SampleRenderedHands"),nullptr);
        const auto slot=static_cast<std::uint64_t>(demo->script.Read<int>(demo->handsBridge,L"ReplayCapture"));
        if (presentationCapture.Tick(static_cast<int>(slot),demo->script.Read<int>(demo->handsBridge,L"NativePresentationCapture")!=0))
            Log("Presentation RenderDoc capture requested slot=%llu",static_cast<unsigned long long>(slot));
        // The original three-item replay uses slots below 500; the hunting
        // shotgun uses 700/800; AA12 uses 1100/1200, HUD preview 1400-1403.
        if (slot>demo->handCapture && (slot<900 || (slot>=1100 && slot<1300) || (slot>=1400 && slot<=1403))) {
            demo->handCapture=slot;
            ComPtr<ID3D11Device> captureDevice; ComPtr<ID3D11DeviceContext> captureContext;
            ComPtr<ID3D11Texture2D> buffer; std::string error;
            if (SUCCEEDED(swapchain->GetDevice(IID_PPV_ARGS(&captureDevice))) &&
                SUCCEEDED(swapchain->GetBuffer(0,IID_PPV_ARGS(&buffer)))) {
                captureDevice->GetImmediateContext(&captureContext);
                const auto path=std::filesystem::path(captureRootPath)/(L"hands-"+std::to_wstring(slot)+L".png");
                Log("HandCapture slot=%llu ok=%d",static_cast<unsigned long long>(slot),
                    kf2vr::diagnostics::CaptureTexture(captureContext.Get(),buffer.Get(),path,error,nullptr));
                // Opt-in watch art fixture: retain the actual owned Canvas target
                // separately from the world image to diagnose missing glyphs.
                if (slot>=886 && slot<=888) {
                    ComPtr<ID3D11Texture2D> watchTexture;
                    auto* resource=hudTextAlpha.PanelResource(0);
                    if (resource && SUCCEEDED(resource->QueryInterface(IID_PPV_ARGS(&watchTexture)))) {
                        const auto face=std::filesystem::path(captureRootPath)/(L"watch-face-"+std::to_wstring(slot)+L".png");
                        Log("WatchFaceCapture slot=%llu ok=%d",static_cast<unsigned long long>(slot),
                            kf2vr::diagnostics::CaptureTexture(captureContext.Get(),watchTexture.Get(),face,error,nullptr));
                    }
                }
            }
        }
    }
    HRESULT presentResult;
    {
        adapter::timing::Scope timing(adapter::timing::DesktopPresent);
        presentResult=originalPresent(swapchain,interval,flags);
    }
    if (benchmarkFile && demo && !(flags&DXGI_PRESENT_TEST) &&
        swapchain==demo->ownerSwapchain.load(std::memory_order_acquire) &&
        GetCurrentThreadId()==demo->ownerThread.load(std::memory_order_acquire)) {
        const double now=adapter::timing::Now();
        const auto submitted=demo->backend.Counters().submitted;
        const auto& packet=demo->render.packet;
        const int phase=packet.benchmarkPhase;
        const auto& f=packet.frame;
        if (!demo->benchmarkInvalid && (phase==2 || phase==4) &&
            (!f.shouldRender || !f.viewsValid || !f.headPoseValid || !f.headPoseTracked ||
             f.state!=xr::SessionState::Focused || packet.menuFrame)) {
            demo->benchmarkInvalid=true;
            std::fflush(benchmarkFile);
            Log("BenchmarkCapture invalid=1 reason=tracking-focus-or-visibility phase=%d",phase);
        }
        const auto& pawn=packet.pawnLocation;
        if (phase>=1 && phase<=4 && demo->benchmarkLastPresent && phase==demo->benchmarkLastPhase)
            std::fprintf(benchmarkFile,"%.3f,%.6f,%d,%llu,%d,%d,%d,%d,%u,%u,%.6f,%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f,%.3f,%.3f,%.3f,%d,%d,%d,%d\n",
                now,now-demo->benchmarkLastPresent,phase,
                static_cast<unsigned long long>(submitted-demo->benchmarkLastSubmitted),
                f.shouldRender && f.viewsValid && f.headPoseValid,f.state==xr::SessionState::Focused,
                f.headPoseTracked,packet.menuFrame,demo->width.load(),demo->height.load(),f.predictedDisplayPeriod*1000,
                f.head.pos.x,f.head.pos.y,f.head.pos.z,f.head.rot.x,f.head.rot.y,f.head.rot.z,f.head.rot.w,
                pawn.x,pawn.y,pawn.z,packet.renderPasses[0].depthPrepass,
                packet.renderPasses[1].depthPrepass,packet.renderPasses[0].constructorOverride,
                packet.renderPasses[1].constructorOverride);
        if (phase!=demo->benchmarkLastPhase) {
            std::fflush(benchmarkFile);
            Log("BenchmarkCapture phase=%d previous=%d",phase,demo->benchmarkLastPhase);
        }
        demo->benchmarkLastPresent=now;demo->benchmarkLastSubmitted=submitted;demo->benchmarkLastPhase=phase;
    }
    // Always-on pacing for tester logs: one steady_clock read per headset
    // present and one line every 5 s, so "what frame rate did you get" is
    // answered without the opt-in stage timers or GPU queries. Owner-thread
    // only, like the full timers, so plain statics are safe.
    if (!adapter::timing::enabled && !(flags&DXGI_PRESENT_TEST) && stereoRequested && demo &&
        swapchain==demo->ownerSwapchain.load(std::memory_order_acquire) &&
        GetCurrentThreadId()==demo->ownerThread.load(std::memory_order_acquire)) {
        static adapter::timing::Intervals pacing;
        static double previous=0,since=0;
        static std::uint64_t presents=0,over90Total=0;
        const double now=adapter::timing::Now();
        if (!since) since=now;
        if (previous) pacing.Add(now-previous);
        previous=now;++presents;
        if (now-since>=5000) {
            over90Total+=pacing.over90;
            const auto total=pacing.count+pacing.overflow;
            Log("FramePacing mode=lite intervals=%llu overflow=%llu meanMs=%.3f p50Ms=%.3f p95Ms=%.3f p99Ms=%.3f maxMs=%.3f over90=%llu over120=%llu presents=%llu over90Total=%llu runtimePeriodMs=%.3f",
                static_cast<unsigned long long>(pacing.count),static_cast<unsigned long long>(pacing.overflow),
                total ? pacing.total/static_cast<double>(total) : 0,pacing.Percentile(.50),pacing.Percentile(.95),
                pacing.Percentile(.99),pacing.maximum,static_cast<unsigned long long>(pacing.over90),
                static_cast<unsigned long long>(pacing.over120),static_cast<unsigned long long>(presents),
                static_cast<unsigned long long>(over90Total),demo->render.packet.frame.predictedDisplayPeriod*1000);
            pacing={};since=now;
        }
    }
    if (adapter::timing::enabled && !(flags&DXGI_PRESENT_TEST) &&
        (!stereoRequested || (demo && swapchain==demo->ownerSwapchain.load(std::memory_order_acquire) &&
        GetCurrentThreadId()==demo->ownerThread.load(std::memory_order_acquire)))) {
        auto& t=adapter::timing::Current();t.Advance();++t.presents;
        const auto boundary=t.last;
        if(frameDrilldown.file) {
            const auto previousStage=t.active;t.active=adapter::timing::DiagnosticOutput;
            frameDrilldown.Capture(t,demo?demo->benchmarkLastPhase:0);
            if(frameDrilldown.failed) Log("FrameDrilldown invalid=1 reason=write-failed");
            t.Advance();t.active=previousStage;
        }
        if(t.previousPresent) t.intervals.Add(boundary-t.previousPresent);
        t.previousPresent=boundary;
        const auto elapsed=t.last-t.since;
        adapter::timing::Scope diagnosticOutput(adapter::timing::DiagnosticOutput);
        if(elapsed>=5000) {
            using namespace adapter::timing;
            Log("FrameTiming elapsedMs=%.3f presents=%llu otherMs=%.3f controllerMs=%.3f simulationMs=%.3f vmDispatchMs=%.3f vmCalls=%llu vmBodyMs=%.3f leftMs=%.3f rightMs=%.3f portalMs=%.3f worldMs=%.3f xrBeginMs=%.3f xrSubmitMs=%.3f presentMs=%.3f",
                elapsed,t.presents,t.milliseconds[Other],t.milliseconds[Controller],t.milliseconds[Simulation],
                t.milliseconds[ScriptDispatch],t.calls[ScriptDispatch],t.milliseconds[ScriptBody],
                t.milliseconds[LeftView],t.milliseconds[RightView],t.milliseconds[PortalCapture],t.milliseconds[WorldScene],
                t.milliseconds[XrBegin],t.milliseconds[XrSubmit],t.milliseconds[DesktopPresent]);
            auto& intervals=t.intervals;
            Log("FramePacing mode=%s intervals=%llu overflow=%llu meanMs=%.3f p50Ms=%.3f p95Ms=%.3f p99Ms=%.3f maxMs=%.3f over90=%llu over120=%llu eyeCopyMs=%.3f runtimePeriodMs=%.3f lastMenu=%d",
                scriptEnabled?"vm":"coarse",static_cast<unsigned long long>(intervals.count),intervals.overflow,
                intervals.count+intervals.overflow ? intervals.total/static_cast<double>(intervals.count+intervals.overflow) : 0,
                intervals.Percentile(.50),intervals.Percentile(.95),intervals.Percentile(.99),intervals.maximum,
                intervals.over90,intervals.over120,t.milliseconds[EyeCopy],demo?demo->render.packet.frame.predictedDisplayPeriod*1000:0,
                demo?demo->render.packet.menuFrame:0);
            Log("FrameDetail revision=1 presents=%llu viewSetupMs=%.3f sceneSetupMs=%.3f viewportSetupMs=%.3f",
                static_cast<unsigned long long>(t.presents),t.milliseconds[ViewSetup],t.milliseconds[SceneSetup],t.milliseconds[ViewportSetup]);
            static std::array<double,3> presentCpu{};
            Log("ThreadCpu revision=1 presentThreadCpuMs=%.3f threaded=%d",ThreadCpuMs(presentCpu),renderQueue.Threaded() ? 1 : 0);
            if(drilldownEnabled) Log("FrameDrilldown revision=1 worldTickMs=%.3f leftSceneMs=%.3f rightSceneMs=%.3f diagnosticOutputMs=%.3f",
                t.milliseconds[WorldTick],t.milliseconds[LeftScene],t.milliseconds[RightScene],t.milliseconds[DiagnosticOutput]);
            if(demo) {
                const auto& x=demo->backend.Counters();
                Log("XrDetail revision=1 cumulative=1 begun=%llu waitFrameMs=%.3f beginFrameMs=%.3f locateMs=%.3f acquireMs=%.3f waitImageMs=%.3f releaseMs=%.3f endFrameMs=%.3f",
                    static_cast<unsigned long long>(x.begun),x.waitFrameMs,x.beginFrameMs,x.locateMs,x.acquireMs,x.waitImageMs,x.releaseMs,x.endFrameMs);
            }
            if(vmSamplingEnabled) {
                auto& s=VmSamples();
                Log("VmSample revision=1 calls=%llu samples=%llu dispatchMs=%.6f bodyMs=%.6f probability=0.00390625 exclusiveOfOriginalBody=1",
                    static_cast<unsigned long long>(s.calls),static_cast<unsigned long long>(s.samples),s.dispatchMs,s.bodyMs);
                s.ResetTotals();
            }
            if(adapter::scriptFieldCacheEnabled) {
                const auto& c=adapter::CurrentScriptFields();
                Log("MetadataCache revision=1 cumulative=1 hits=%llu misses=%llu invalidations=%llu",
                    static_cast<unsigned long long>(c.hits),static_cast<unsigned long long>(c.misses),
                    static_cast<unsigned long long>(c.invalidations));
            }
            if (adapter::guardedScriptReads)
                Log("GuardedReads revision=1 cumulative=1 faults=%llu",
                    static_cast<unsigned long long>(adapter::guardedReadFaults));
            if (batchHandWrites) {
                const auto& c=adapter::HandWriteCounts();
                Log("HandWriteBatch revision=1 cumulative=1 commits=%llu rangeQueries=%llu writes=%llu failures=%llu",
                    static_cast<unsigned long long>(c.commits),static_cast<unsigned long long>(c.rangeQueries),
                    static_cast<unsigned long long>(c.writes),static_cast<unsigned long long>(c.failures));
            }
            t.milliseconds={};t.calls={};t.presents=0;t.since=t.last;t.intervals={};
        }
    }
    return presentResult;
}
HRESULT STDMETHODCALLTYPE HookResize(IDXGISwapChain* swapchain,UINT count,UINT width,UINT height,DXGI_FORMAT format,UINT flags) {
    Log("ResizeBuffers swapchain=%p size=%ux%u format=%u",swapchain,width,height,static_cast<unsigned>(format));
    bool owned=false,onGame=false;
    if (demo) {
        const DWORD owner=demo->ownerThread.load(std::memory_order_acquire);
        if (owner && swapchain==demo->ownerSwapchain.load(std::memory_order_acquire)) {
            const DWORD current=GetCurrentThreadId();
            onGame=current==worldDrawThread.load(std::memory_order_acquire);
            // Threaded UE3 resizes with its render thread suspended, or from a
            // render thread it has just recreated; either way nothing renders.
            if (current==owner || threadedRender) owned=true;
            else if (!demo->travelling.load(std::memory_order_acquire)) RequestThreadFailure("owned swapchain ResizeBuffers");
        }
    }
    if (owned) {
        demo->gpuTiming.End(demo->backend.Context(),false);
        ++demo->resizeGeneration;
        if (onGame) {
            CancelMenuPointer(); demo->menu.CancelInput();
            demo->hud.Reset();
            if (demo->handsBridge) {
                demo->script.Write(demo->handsBridge,L"NativeHudMask",0);
                demo->script.Invoke(demo->handsBridge,demo->script.FindFunction(demo->handsBridge,L"SuspendSpatialHUD"),nullptr);
            }
            demo->pending=false; demo->atlasReady=false;
        } else demo->resizeNotices.fetch_add(1,std::memory_order_acq_rel);
        demo->blit.OnResize();
        demo->eyeAtlasView.Reset();
        demo->eyeAtlas.Reset();
        demo->gamepad.Cancel();
        // A frame built for the old surface can never sample the resized one.
        // No eye image has been rendered before Present, so this ends zero layers.
        if (demo->render.xrPending) {
            if (!demo->backend.EndFrame()) {
                Log("XR resize frame cancellation failed: %s",demo->backend.LastError().c_str()); demo->failed=true;
            }
            demo->render.xrPending=false;
        }
        demo->render.packet.atlasReady=false;
        // Keep the HMD reference: changing window size is not a user recenter.
    }
    const HRESULT result=originalResize(swapchain,count,width,height,format,flags);
    if (owned && SUCCEEDED(result)) {
        DXGI_SWAP_CHAIN_DESC resized{};
        if (SUCCEEDED(swapchain->GetDesc(&resized))) {
            demo->width=resized.BufferDesc.Width; demo->height=resized.BufferDesc.Height;
        }
    }
    Log("ResizeBuffers result=%lx",static_cast<unsigned long>(result));
    return result;
}
void STDMETHODCALLTYPE HookClearDepth(ID3D11DeviceContext* context,ID3D11DepthStencilView* view,UINT flags,FLOAT depth,UINT8 stencil) {
    if (OnRenderCommandThread() && foregroundDepth.Filter(context,view,flags,depth,stencil) &&
        Interesting(++preservedForegroundDepth))
        Log("Foreground world depth preserved count=%llu",static_cast<unsigned long long>(preservedForegroundDepth));
    originalClearDepth(context,view,flags,depth,stencil);
}
void STDMETHODCALLTYPE HookClearColor(ID3D11DeviceContext* context,ID3D11RenderTargetView* view,const FLOAT* rgba) {
    if (OnRenderCommandThread()) {
        if(selectorDiagnostics && selectorClears<64) TraceSelectorTarget(context,view,"clear",false,rgba);
        hudTextAlpha.Clear(context,view,rgba);
    }
    originalClearColor(context,view,rgba);
}
void STDMETHODCALLTYPE HookSetTargets(ID3D11DeviceContext* context,UINT count,ID3D11RenderTargetView* const* targets,ID3D11DepthStencilView* depth) {
    if (OnRenderCommandThread()) hudTextAlpha.Targets(context,count,targets);
    originalSetTargets(context,count,targets,depth);
}
void STDMETHODCALLTYPE HookDrawIndexed(ID3D11DeviceContext* context,UINT count,UINT start,INT base) {
    adapter::HudTextAlpha::DrawScope alpha;
    if (OnRenderCommandThread()) {
        hudTextAlpha.BeforeDraw(context,alpha);
        if(selectorDiagnostics && selectorDraws<64) {
            ComPtr<ID3D11RenderTargetView> target;context->OMGetRenderTargets(1,&target,nullptr);
            TraceSelectorTarget(context,target.Get(),"draw-indexed",alpha.context!=nullptr);
        }
    }
    if (alpha.context && Interesting(++hudAlphaDraws)) Log("HUD text alpha corrected draw=%llu",static_cast<unsigned long long>(hudAlphaDraws));
    originalDrawIndexed(context,count,start,base);
}
// KFGame's FBatchedElements quad path (0x8bc6cd) calls RHI slot 0x758.
// The D3D11 DrawPrimitiveUP backend (0xcc1e60) ends at context slot 13,
// Draw, rather than DrawIndexed. Texture tiles need the same owned-target
// alpha repair as indexed glyph/mesh batches; otherwise only opaque marks
// contribute coverage to a transparent selector surface.
void STDMETHODCALLTYPE HookDraw(ID3D11DeviceContext* context,UINT count,UINT start) {
    adapter::HudTextAlpha::DrawScope alpha;
    if(OnRenderCommandThread()) {
        hudTextAlpha.BeforeDraw(context,alpha);
        if(selectorDiagnostics && selectorDraws<64) {
            ComPtr<ID3D11RenderTargetView> target;context->OMGetRenderTargets(1,&target,nullptr);
            TraceSelectorTarget(context,target.Get(),"draw",alpha.context!=nullptr);
        }
    }
    originalDraw(context,count,start);
}
bool InstallHooks(HINSTANCE module) {
    // The EXE hash is already verified. Refuse pre-existing detours or a
    // mismatched ABI before preparing any of this adapter's hooks.
    if (portalRequested && !portalCapture.ValidateCode()) return false;
    const wchar_t* className=L"KF2VRPassiveDeviceDiscovery";
    WNDCLASSW wc{}; wc.lpfnWndProc=DefWindowProcW; wc.hInstance=module; wc.lpszClassName=className;
    if (!RegisterClassW(&wc)) { Log("RegisterClass failed %lu",GetLastError()); return false; }
    HWND window=CreateWindowW(className,L"KF2VR device discovery",WS_OVERLAPPEDWINDOW,0,0,64,64,nullptr,nullptr,module,nullptr);
    if (!window) { UnregisterClassW(className,module); return false; }
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain> swapchain;
    DXGI_SWAP_CHAIN_DESC desc{}; desc.BufferDesc.Width=64; desc.BufferDesc.Height=64;
    desc.BufferDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count=1;
    desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount=1;
    desc.OutputWindow=window; desc.Windowed=TRUE; desc.SwapEffect=DXGI_SWAP_EFFECT_DISCARD;
    const HRESULT hr=D3D11CreateDeviceAndSwapChain(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,
        D3D11_SDK_VERSION,&desc,&swapchain,&device,nullptr,&context);
    bool success=false;
    if (SUCCEEDED(hr)) {
        void** table=*reinterpret_cast<void***>(swapchain.Get());
        void** contextTable=*reinterpret_cast<void***>(context.Get());
        struct Hook { void* target; void* detour; void** trampoline; };
        std::vector<Hook> hooks{
            {reinterpret_cast<void*>(gameBase+0x6746a0),reinterpret_cast<void*>(&HookCalc),reinterpret_cast<void**>(&originalCalc)},
            {reinterpret_cast<void*>(gameBase+0x903380),reinterpret_cast<void*>(&HookSubmit),reinterpret_cast<void**>(&originalSubmit)},
            {table[8],reinterpret_cast<void*>(&HookPresent),reinterpret_cast<void**>(&originalPresent)},
            {table[13],reinterpret_cast<void*>(&HookResize),reinterpret_cast<void**>(&originalResize)},
            {contextTable[53],reinterpret_cast<void*>(&HookClearDepth),reinterpret_cast<void**>(&originalClearDepth)},
            {contextTable[50],reinterpret_cast<void*>(&HookClearColor),reinterpret_cast<void**>(&originalClearColor)},
            {contextTable[33],reinterpret_cast<void*>(&HookSetTargets),reinterpret_cast<void**>(&originalSetTargets)},
            {contextTable[12],reinterpret_cast<void*>(&HookDrawIndexed),reinterpret_cast<void**>(&originalDrawIndexed)}};
        hooks.push_back({contextTable[13],
            reinterpret_cast<void*>(&HookDraw),reinterpret_cast<void**>(&originalDraw)});
        if (portalRequested) {
            using Capture=kf2vr::portal::PortalCapture;
            hooks.push_back({reinterpret_cast<void*>(gameBase+Capture::RenderRva),
                reinterpret_cast<void*>(&HookPortalRender),reinterpret_cast<void**>(&portalCapture.originalRender)});
            hooks.push_back({reinterpret_cast<void*>(gameBase+Capture::ClipRva),
                reinterpret_cast<void*>(&HookPortalClip),reinterpret_cast<void**>(&portalCapture.originalClip)});
        }
        if (stereoRequested) hooks.push_back({reinterpret_cast<void*>(gameBase+menuNative::GetMousePositionRva),
            reinterpret_cast<void*>(&HookGetMousePosition),reinterpret_cast<void**>(&originalGetMousePosition)});
        if (stereoRequested || handReplayRequested) {
            hooks.push_back({reinterpret_cast<void*>(gameBase+pinned::kViewportDrawRva),
                reinterpret_cast<void*>(&HookViewportDraw),reinterpret_cast<void**>(&originalViewportDraw)});
            hooks.push_back({reinterpret_cast<void*>(gameBase+pinned::kPlayerControllerTickRva),
                reinterpret_cast<void*>(&HookControllerTick),reinterpret_cast<void**>(&originalControllerTick)});
            hooks.push_back({reinterpret_cast<void*>(gameBase+0xd350a0),
                reinterpret_cast<void*>(&HookTraceStart),reinterpret_cast<void**>(&originalTraceStart)});
            hooks.push_back({reinterpret_cast<void*>(gameBase+0x47e3c0),
                reinterpret_cast<void*>(&HookPhysicalStart),reinterpret_cast<void**>(&originalPhysicalStart)});
            hooks.push_back({reinterpret_cast<void*>(gameBase+adapter::kWeaponViewRotationRva),
                reinterpret_cast<void*>(&HookWeaponViewRotation),reinterpret_cast<void**>(&originalWeaponViewRotation)});
            HMODULE input=LoadLibraryExW(L"xinput1_3.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
            if (!input) { Log("XInput unavailable"); DestroyWindow(window); UnregisterClassW(className,module); return false; }
            hooks.push_back({reinterpret_cast<void*>(GetProcAddress(input,"XInputGetState")),reinterpret_cast<void*>(&HookGetPad),reinterpret_cast<void**>(&originalGetPad)});
            hooks.push_back({reinterpret_cast<void*>(GetProcAddress(input,"XInputGetCapabilities")),reinterpret_cast<void*>(&HookGetPadCaps),reinterpret_cast<void**>(&originalGetPadCaps)});
        }
        if (stereoRequested || handReplayRequested)
            hooks.push_back({reinterpret_cast<void*>(gameBase+0x7aed0),
                reinterpret_cast<void*>(&HookProcessInternal),reinterpret_cast<void**>(&originalProcessInternal)});
        if (MH_Initialize()==MH_OK) {
            success=true;
            for (const auto& hook:hooks) {
                const auto status=MH_CreateHook(hook.target,hook.detour,hook.trampoline);
                if (status!=MH_OK) { Log("Prepare hook failed: %s",MH_StatusToString(status)); success=false; break; }
            }
            if (success && stereoRequested && !adapter::focus::CreateHooks(gameBase,&DecideInventoryFocus,&FinishInventoryFocus)) {
                Log("Inventory Focus timing ABI gate refused"); success=false;
            }
            if (success) {
                for (const auto& hook:hooks) if (MH_QueueEnableHook(hook.target)!=MH_OK) success=false;
                if (stereoRequested && (MH_QueueEnableHook(reinterpret_cast<void*>(gameBase+adapter::focus::WorldTickRva))!=MH_OK ||
                    MH_QueueEnableHook(reinterpret_cast<void*>(gameBase+adapter::focus::SimulationDeltaRva))!=MH_OK)) success=false;
                if (success && MH_ApplyQueued()!=MH_OK) success=false;
            }
            if (!success) { MH_DisableHook(MH_ALL_HOOKS); MH_Uninitialize(); }
        }
    } else Log("Discovery D3D11 WARP creation failed HRESULT=%lx",static_cast<unsigned long>(hr));
    swapchain.Reset(); context.Reset(); device.Reset();
    DestroyWindow(window); UnregisterClassW(className,module);
    return success;
}
}
DWORD WINAPI AdapterMain(void* parameter) {
    const HINSTANCE module=static_cast<HINSTANCE>(parameter);
    wchar_t modulePath[32768]{},gamePath[32768]{};
    if (!GetModuleFileNameW(module,modulePath,32768) || !GetModuleFileNameW(nullptr,gamePath,32768)) return 1;
    // Launcher sets an explicit workspace path. No default write in the game
    // installation or user profile, and no public IPC endpoint.
    wchar_t logPath[32768]{};
    if (!GetEnvironmentVariableW(L"KF2VR_LOG_PATH",logPath,32768)) return 2;
    GetEnvironmentVariableW(L"KF2VR_STOP_PATH",stopRequestPath,32768);
    const DWORD captureLength=GetEnvironmentVariableW(L"KF2VR_CAPTURE_ROOT",captureRootPath,32768);
    if (!captureLength || captureLength>=32768) captureRootPath[0]=0;
    const DWORD playableLength=GetEnvironmentVariableW(L"KF2VR_PLAYABLE_PATH",playablePath,32768);
    if (!playableLength || playableLength>=32768) playablePath[0]=0;
    logFile=_wfsopen(logPath,L"wb",_SH_DENYWR); // Live fixture readers share this log.
    if (!logFile) return 3;
    selectorDiagnostics=wcsstr(GetCommandLineW(),L"-kf2vr-selector-diagnostic")!=nullptr;
    const bool oneThread=wcsstr(GetCommandLineW(),L"-onethread")!=nullptr;
    threadedRender=!oneThread && wcsstr(GetCommandLineW(),L"-kf2vr-threaded-render")!=nullptr;
    stereoRequested=wcsstr(GetCommandLineW(),L"-kf2vr-stereo")!=nullptr && (oneThread || threadedRender);
    threadedRender=threadedRender && stereoRequested;
    handReplayRequested=wcsstr(GetCommandLineW(),L"-kf2vr-hand-replay")!=nullptr && wcsstr(GetCommandLineW(),L"-onethread")!=nullptr;
    networkRequested=wcsstr(GetCommandLineW(),L"-kf2vr-network")!=nullptr && (stereoRequested || handReplayRequested);
    inputReplayRequested=wcsstr(GetCommandLineW(),L"-kf2vr-input-replay")!=nullptr;
    if (inputReplayRequested) {
        wchar_t path[32768]{};
        const auto length=GetEnvironmentVariableW(L"KF2VR_INPUT_REPLAY",path,32768);
        if (!handReplayRequested || stereoRequested || networkRequested || !length || length>=32768 ||
            wcsstr(GetCommandLineW(),L"-kf2vr-motion-fixture")) {
            Log("ReplayInput refused: requires offline hand-replay/onethread and KF2VR_INPUT_REPLAY; no stereo/network/motion fixture");
            return 3;
        }
        std::ifstream input{std::filesystem::path(path)};
        std::string error;
        if (!replayInput.Load(input,error)) { Log("ReplayInput refused: %s",error.c_str()); return 3; }
        Log("ReplayInput schema=1 seed=%llu owner=first-local-bridge clock=bridge-tick",
            static_cast<unsigned long long>(replayInput.Seed()));
    }
    portalRequested=!networkRequested && wcsstr(GetCommandLineW(),L"-kf2vr-no-portals")==nullptr &&
        (stereoRequested || wcsstr(GetCommandLineW(),L"-kf2vr-portal")!=nullptr)
        && wcsstr(GetCommandLineW(),L"-onethread")!=nullptr;
    adapter::timing::scriptEnabled=wcsstr(GetCommandLineW(),L"-kf2vr-vm-timings")!=nullptr;
    reuseVmIdentity=wcsstr(GetCommandLineW(),L"-kf2vr-no-identity-reuse")==nullptr;
    fastVmIdentity=wcsstr(GetCommandLineW(),L"-kf2vr-fast-vm-identity")!=nullptr;
    batchHandWrites=wcsstr(GetCommandLineW(),L"-kf2vr-batch-hand-writes")!=nullptr;
    adapter::scriptFieldCacheEnabled=wcsstr(GetCommandLineW(),L"-kf2vr-no-metadata-cache")==nullptr;
    adapter::guardedScriptReads=wcsstr(GetCommandLineW(),L"-kf2vr-checked-reads")==nullptr;
    perEyePresentation=wcsstr(GetCommandLineW(),L"-kf2vr-per-eye-presentation")!=nullptr;
    adapter::timing::enabled=adapter::timing::scriptEnabled || wcsstr(GetCommandLineW(),L"-kf2vr-frame-timings")!=nullptr;
    adapter::timing::vmSamplingEnabled=adapter::timing::enabled && !adapter::timing::scriptEnabled;
    adapter::timing::drilldownEnabled=wcsstr(GetCommandLineW(),L"-kf2vr-frame-drilldown")!=nullptr;
    wchar_t percentText[16]{};
    const auto percentLength=GetEnvironmentVariableW(L"KF2VR_EYE_RENDER_PERCENT",percentText,16);
    if (percentLength && (percentLength>=16 || !adapter::ParseEyeRenderPercent(percentText,eyeRenderPercent))) {
        Log("Eye render percentage refused: expected an integer from 50 to 100");return 5;
    }
    Log("RenderPerformance eyeRenderPercent=%u frameTimings=%d vmTimings=%d",eyeRenderPercent,
        adapter::timing::enabled,adapter::timing::scriptEnabled);
    Log("RenderExperiment revision=1 identityReuse=%d",reuseVmIdentity);
    Log("VmEntryExperiment revision=1 fastIdentity=%d",fastVmIdentity);
    Log("HandWriteExperiment revision=1 batched=%d",batchHandWrites);
    Log("MetadataExperiment revision=1 fieldCache=%d",adapter::scriptFieldCacheEnabled);
    Log("ReadExperiment revision=1 guardedReads=%d",adapter::guardedScriptReads);
    Log("PresentationExperiment revision=1 perEyeFinalize=%d",perEyePresentation);
    Log("ThreadedRender revision=1 requested=%d",threadedRender);
    Log("KF2VR_ADAPTER revision=2 mode=%s pid=%lu",stereoRequested?"local-stereo-experiment":handReplayRequested?"local-hand-replay":"passive",GetCurrentProcessId());
    std::string digest;
    if (!HashFile(gamePath,digest) || digest!=kHash) { Log("Build gate refused sha256=%s",digest.c_str()); return 4; }
    // Avoid a trailing -benchmark token: UE3 can parse that suffix as its
    // engine benchmark switch, advancing simulation with a fixed timestep.
    if (wcsstr(GetCommandLineW(),L"-kf2vr-perf-capture")) {
        wchar_t benchmarkPath[32768]{};
        const auto length=GetEnvironmentVariableW(L"KF2VR_BENCHMARK_PATH",benchmarkPath,32768);
        if (!stereoRequested || !length || length>=32768 ||
            !(benchmarkFile=_wfsopen(benchmarkPath,L"wb",_SH_DENYWR))) {
            Log("Benchmark capture refused: stereo and owned CSV path required");return 6;
        }
        std::setvbuf(benchmarkFile,nullptr,_IOFBF,1024*1024);
        std::fputs("tickMs,intervalMs,phase,submitted,renderable,focused,headTracked,menu,width,height,periodMs,headX,headY,headZ,headQx,headQy,headQz,headQw,pawnX,pawnY,pawnZ,depthPrepassLeft,depthPrepassRight,prepassOverrideLeft,prepassOverrideRight\n",benchmarkFile);
    }
    gameBase=reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    renderQueue.Initialise(gameBase);
    if (benchmarkFile) {
        renderPassReadbackVerified=adapter::VerifyRenderPassReadback(gameBase);
        Log("RenderPassReadback revision=1 verified=%d",renderPassReadbackVerified);
    }
    if(adapter::timing::drilldownEnabled) {
        wchar_t path[32768]{};
        const auto length=GetEnvironmentVariableW(L"KF2VR_FRAME_DETAIL_PATH",path,32768);
        if(!benchmarkFile || !adapter::timing::enabled || !length || length>=32768 ||
            !(frameDrilldown.file=_wfsopen(path,L"wb",_SH_DENYWR))) {
            Log("FrameDrilldown refused: benchmark, timings and owned output required");return 6;
        }
        const auto spanPath=std::filesystem::path(path).parent_path()/L"frame-spans.csv";
        frameDrilldown.spans=_wfsopen(spanPath.c_str(),L"wb",_SH_DENYWR);
        if(!frameDrilldown.spans) { Log("FrameDrilldown refused: span output unavailable");return 6; }
        std::setvbuf(frameDrilldown.file,nullptr,_IOFBF,1024*1024);
        std::setvbuf(frameDrilldown.spans,nullptr,_IOFBF,1024*1024);frameDrilldown.Header();
        Log("FrameDrilldown enabled=1 revision=1 cpuCounter=GetThreadTimes perFrame=1");
    }
    if (portalRequested) { portalCapture.Initialize(gameBase,&Log); portalHitscan.Initialise(gameBase,&Log); }
    if (stereoRequested || handReplayRequested) {
        demo=new DemoRuntime();
        // KF2 caches a disconnected XInput slot and then skips polling it.
        // Advertise a neutral controller before engine startup, not only once
        // XR becomes ready. Real actions still require focused, fresh XR input.
        virtualPadEnabled.store(true,std::memory_order_release);
        singleViewDiagnostic=wcsstr(GetCommandLineW(),L"-kf2vr-singleview")!=nullptr;
        demo->stereo.SetSingleViewDiagnostic(singleViewDiagnostic);
        if (singleViewDiagnostic) Log("Diagnostic mode: one native view displayed to both eyes; not binocular stereo");
    }
    Log("Build verified sha256=%s base=%p",digest.c_str(),reinterpret_cast<void*>(gameBase));
    presentationCapture.Initialize(handReplayRequested,captureRootPath);
    if (!InstallHooks(module)) { Log("Hook setup failed; original game continues"); return 5; }
    Log("Hooks enabled together; mode=%s portals=%d",stereoRequested?"local stereo experiment":handReplayRequested?"local hand replay; stock renderer; no XR session":portalRequested?"local portal gameplay; stock renderer; no XR session":"passive; no engine fields mutated; no XR session",portalRequested);
    return 0;
}
