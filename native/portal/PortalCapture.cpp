#include "../adapter/include/kf2vr/adapter/GameBuild.h"
#include "PortalCapture.h"
#include <cstring>

namespace kf2vr::portal {
namespace {
using Script=adapter::GameScript;
// FSceneCaptureProbe for SceneCapturePortalComponent (portal-capture-probe
// export): owner actor, target, last capture time, cadence, transform
// premultiplied onto the parent view, destination actor and clip plane.
constexpr std::uintptr_t ProbeVtableRva=0x1831850;
constexpr std::size_t ProbeBytes=0xf0,Owner=0x08,LastCapture=0x60,Interval=0x64;
constexpr std::size_t Transform=0x90,ClipPlane=0xe0;
// FSceneRenderer: views array and count (portal-capture-render export).
constexpr std::size_t RendererViews=0x08,RendererViewCount=0x10,RendererWorldTime=0x38;
constexpr std::size_t ViewMatrix=0x80,ProjectionMatrix=0xc0;
constexpr std::size_t ActorLocation=0x80,ActorRotation=0x8c;
// Past the aperture (+0.5) and rim/fill (+0.6) the exit's own surfaces sit on.
constexpr float NearOffset=0.8f,MinimumWindowDepth=1.f;
template<class T> void Put(void* object,std::size_t offset,const T& value) {
    std::memcpy(static_cast<std::byte*>(object)+offset,&value,sizeof(T));
}
struct ProbeRestore {
    void* probe;
    CaptureMatrix transform;
    CapturePlane plane;
    explicit ProbeRestore(void* p):probe(p),transform(Script::At<CaptureMatrix>(p,Transform)),
        plane(Script::At<CapturePlane>(p,ClipPlane)) {}
    ~ProbeRestore() { Put(probe,Transform,transform); Put(probe,ClipPlane,plane); }
};
}

void PortalCapture::Initialize(std::uintptr_t gameBase,LogFn log) {
    base_=gameBase; log_=log; script_.Initialise(gameBase);
}
bool PortalCapture::ValidateCode() const {
    struct Entry { std::uintptr_t rva; unsigned char bytes[16]; };
    constexpr Entry entries[]{
        {RenderRva,{0x48,0x8b,0xc4,0x55,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x8d}},
        {ClipRva,{0x48,0x83,0xec,0x58,0x0f,0x28,0x02,0x0f,0x29,0x74,0x24,0x40,0xf3,0x0f,0x10,0x35}},
    };
    if (!base_) return false;
    for (const auto& entry:entries) {
        auto* address=reinterpret_cast<const void*>(base_+adapter::build::Rva(entry.rva));
        MEMORY_BASIC_INFORMATION region{};
        if (!Script::Accessible(address,sizeof(entry.bytes))
            ||!VirtualQuery(address,&region,sizeof(region))
            ||!(region.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))
            ||std::memcmp(address,entry.bytes,sizeof(entry.bytes))!=0) {
            if (log_) log_("PortalCapture ABI refused rva=%llx",static_cast<unsigned long long>(entry.rva));
            return false;
        }
    }
    return true;
}
bool PortalCapture::IsPortal(void* actor) {
    if (!actor) return false;
    auto* type=Script::ObjectClass(actor);
    if (type && type==portalClass_) return true;
    if (!script_.IsClass(actor,L"VRPortal")) return false;
    portalClass_=type;
    return true;
}
void PortalCapture::Render(void* probe,void* renderer) {
    if (!originalRender) return;
    if (!Script::Accessible(probe,ProbeBytes)||Script::At<std::uintptr_t>(probe,0)!=base_+adapter::build::Rva(ProbeVtableRva)) {
        originalRender(probe,renderer); return;
    }
    auto* entry=Script::At<void*>(probe,Owner);
    if (!IsPortal(entry)) { originalRender(probe,renderer); return; }
    // Recursion cutoff (Portal 2's max depth): a portal seen inside another
    // portal's capture shows its fill mesh; its aperture is hidden there.
    if (depth_) return;
    auto* exit=script_.Read<void*>(entry,L"LinkedPortal");
    if (!exit||!IsPortal(exit)||!Script::Accessible(renderer,0x40)
        ||Script::At<int>(renderer,RendererViewCount)!=1) return;
    auto* views=Script::At<void**>(renderer,RendererViews);
    auto* parent=Script::Accessible(views,sizeof(void*))?views[0]:nullptr;
    if (!Script::Accessible(parent,0x100)) return;
    const auto view=Script::At<CaptureMatrix>(parent,ViewMatrix);
    const auto projection=Script::At<CaptureMatrix>(parent,ProjectionMatrix);
    const auto entryLocation=Script::At<CaptureVector>(entry,ActorLocation);
    const auto entryRotation=Script::At<CaptureRotation>(entry,ActorRotation);
    const auto exitLocation=Script::At<CaptureVector>(exit,ActorLocation);
    const auto exitRotation=Script::At<CaptureRotation>(exit,ActorRotation);
    const float halfWidth=script_.Read<float>(entry,L"HalfWidth"),halfHeight=script_.Read<float>(entry,L"HalfHeight");
    // Portal 2 only renders portals that are open and visible in this view.
    const auto visibility=ClassifyAperture(entryLocation,entryRotation,halfWidth,halfHeight,view,projection);
    if (visibility!=ApertureVisibility::PotentiallyVisible) { ++culled_; return; }
    const int mode=script_.Read<int>(entry,L"CaptureMode");
    CaptureMatrix transform; CapturePlane plane{};
    if (mode==0) {
        CaptureMatrix inverseView;
        WindowCapture window;
        if (!Invert(view,inverseView)
            ||!MakeWindowCapture(entryLocation,entryRotation,exitLocation,exitRotation,halfWidth,halfHeight,
                TransformPoint({},inverseView),projection,NearOffset,MinimumWindowDepth,window)) { ++rejected_; return; }
        // The engine builds the capture view as Transform x ParentView.
        transform=Multiply(window.view,inverseView);
        windowProjection_=window.projection;
    } else if (!MakePortalTransform(entryLocation,entryRotation,exitLocation,exitRotation,transform,plane)) {
        ++rejected_; return;
    }
    const float worldTime=Script::At<float>(renderer,RendererWorldTime),interval=Script::At<float>(probe,Interval);
    if (!std::isfinite(worldTime)||!std::isfinite(interval)) { ++rejected_; return; }
    ProbeRestore restore(probe);
    Put(probe,Transform,transform); Put(probe,ClipPlane,plane);
    // Each eye is its own family at the same world time. Rearm the engine's
    // cadence test so every eye (and the desktop view) captures its own view.
    Put(probe,LastCapture,std::nextafter(worldTime-std::max(.01f,interval*2.f),-std::numeric_limits<float>::infinity()));
    thread_=GetCurrentThreadId();
    windowClip_=mode==0; clipPending_=true;
    ++depth_;
    originalRender(probe,renderer);
    --depth_;
    clipPending_=false;
    ++captures_;
    script_.Write<int>(entry,L"NativeCaptures",script_.Read<int>(entry,L"NativeCaptures")+1);
    if (log_&&(!lastLog_||GetTickCount64()-lastLog_>=5000)) {
        lastLog_=GetTickCount64();
        log_("PortalCapture captured=%llu culled=%llu rejected=%llu lastMode=%d",
            static_cast<unsigned long long>(captures_),static_cast<unsigned long long>(culled_),
            static_cast<unsigned long long>(rejected_),mode);
    }
}
CaptureMatrix* PortalCapture::Clip(CaptureMatrix* out,const CaptureMatrix* projection,const CapturePlane* plane) {
    // Exactly one clip per owned capture (one parent view). Nested reflection
    // or foreign captures fall through to the engine unchanged.
    if (!depth_||!clipPending_||GetCurrentThreadId()!=thread_||!Script::Accessible(out,sizeof(*out)))
        return originalClip(out,projection,plane);
    clipPending_=false;
    if (windowClip_) { *out=windowProjection_; return out; }
    if (!Script::Accessible(projection,sizeof(*projection))||!Script::Accessible(plane,sizeof(*plane))
        ||!MakeOblique(*projection,*plane,*out)) return originalClip(out,projection,plane);
    return out;
}
}
