#include "Dlss.h"

#include <d3d11_1.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwctype>

#include <nvsdk_ngx.h>
#include <nvsdk_ngx_helpers.h>

namespace kf2vr::adapter {
namespace {
using Microsoft::WRL::ComPtr;
// Arbitrary, stable NGX project identity for this mod.
constexpr char kProjectId[]="6d3c0f52-8a1e-4b7d-9f2e-4b2f6c1a9e30";

// Depth -> R32F depth and previous-minus-current UV motion, render size.
constexpr char kMotionShader[]=R"(
cbuffer Reprojection : register(b0) {
    row_major float4x4 PrevFromCur;
    float2 Size;
    float2 InvSize;
    float Valid;
    float3 Padding;
};
Texture2D<float> SceneDepth : register(t0);
RWTexture2D<float2> Motion : register(u0);
RWTexture2D<float> DepthOut : register(u1);
[numthreads(8,8,1)]
void CS(uint3 id : SV_DispatchThreadID) {
    if (id.x >= (uint)Size.x || id.y >= (uint)Size.y) return;
    const float depth = SceneDepth.Load(int3(id.xy, 0));
    DepthOut[id.xy] = depth;
    float2 motion = 0;
    if (Valid > 0.5) {
        const float2 uv = (float2(id.xy) + 0.5) * InvSize;
        const float4 current = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
        const float4 previous = mul(current, PrevFromCur);
        if (previous.w > 1e-6) {
            const float2 ndc = previous.xy / previous.w;
            const float2 previousUv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
            motion = previousUv - uv;
            if (any(!(abs(motion) < 4.0))) motion = 0;
        }
    }
    Motion[id.xy] = motion;
}
)";

// AMD FidelityFX CAS (MIT), no-scaling path of ffx_cas.h, exact reciprocals.
// The DLSS output is display-encoded; CAS shapes contrast in that space.
constexpr char kSharpenShader[]=R"(
cbuffer Sharpen : register(b0) {
    float Peak;       // -1 / lerp(8, 5, sharpness)
    float3 Padding;
    uint2 Size;
    uint2 Padding2;
};
Texture2D<float4> Source : register(t0);
RWTexture2D<float4> Target : register(u0);
float3 Tap(int2 p) { return Source.Load(int3(clamp(p, int2(0, 0), int2(Size) - 1), 0)).rgb; }
[numthreads(8,8,1)]
void CS(uint3 id : SV_DispatchThreadID) {
    if (id.x >= Size.x || id.y >= Size.y) return;
    const int2 p = int2(id.xy);
    const float3 a = Tap(p + int2(-1,-1)), b = Tap(p + int2(0,-1)), c = Tap(p + int2(1,-1));
    const float3 d = Tap(p + int2(-1, 0));
    const float4 centre = Source.Load(int3(p, 0));
    const float3 e = centre.rgb;
    const float3 f = Tap(p + int2(1, 0));
    const float3 g = Tap(p + int2(-1, 1)), h = Tap(p + int2(0, 1)), i = Tap(p + int2(1, 1));
    float3 mn = min(min(min(d, e), min(f, b)), h);
    const float3 mn2 = min(min(mn, a), min(min(c, g), i));
    mn += mn2;
    float3 mx = max(max(max(d, e), max(f, b)), h);
    const float3 mx2 = max(max(mx, a), max(max(c, g), i));
    mx += mx2;
    float3 amp = saturate(min(mn, 2.0 - mx) / max(mx, 1e-5));
    amp = sqrt(amp);
    const float3 w = amp * Peak;
    const float3 weight = 1.0 / (1.0 + 4.0 * w);
    Target[id.xy] = float4(saturate((b * w + d * w + f * w + h * w + e) * weight), centre.a);
}
)";
struct alignas(16) SharpenConstants {
    float peak, padding[3];
    unsigned size[2], padding2[2];
};
static_assert(sizeof(SharpenConstants)==32);

struct alignas(16) MotionConstants {
    float prevFromCur[4][4];
    float size[2], invSize[2];
    float valid, padding[3];
};
static_assert(sizeof(MotionConstants)==96);

DXGI_FORMAT UnormOf(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS: case DXGI_FORMAT_R8G8B8A8_UNORM: case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        return DXGI_FORMAT_R8G8B8A8_UNORM;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS: case DXGI_FORMAT_B8G8R8A8_UNORM: case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        return DXGI_FORMAT_B8G8R8A8_UNORM;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: case DXGI_FORMAT_R10G10B10A2_UNORM:
        return DXGI_FORMAT_R10G10B10A2_UNORM;
    default: return DXGI_FORMAT_UNKNOWN;
    }
}
bool DepthFamily(DXGI_FORMAT format) {
    return format==DXGI_FORMAT_R24G8_TYPELESS || format==DXGI_FORMAT_D24_UNORM_S8_UINT;
}
std::string Hex(const char* what, long value) {
    char text[160];
    std::snprintf(text,sizeof(text),"%s failed (0x%08lx)",what,static_cast<unsigned long>(value));
    return text;
}

}
struct DlssUpscaler::Impl {
    std::wstring ngxDirectory, dataDirectory;
    ID3D11Device* device=nullptr;
    ComPtr<ID3D11DeviceContext1> context;
    ComPtr<ID3DDeviceContextState> privateState;
    ComPtr<ID3D11ComputeShader> motionShader, sharpenShader;
    ComPtr<ID3D11Buffer> constants, sharpenConstants;
    NVSDK_NGX_Parameter* params=nullptr;
    bool ngxReady=false, ngxInitialized=false, attempted=false;
    struct Eye {
        ComPtr<ID3D11Texture2D> colorIn, depthCopy, depthOut, motion;
        ComPtr<ID3D11Texture2D> upscaled; // DLSS output before sharpening.
        ComPtr<ID3D11ShaderResourceView> upscaledView;
        ComPtr<ID3D11ShaderResourceView> depthView;
        ComPtr<ID3D11UnorderedAccessView> motionUav, depthUav;
        NVSDK_NGX_Handle* feature=nullptr;
        unsigned renderWidth=0, renderHeight=0, outputWidth=0, outputHeight=0;
        unsigned depthWidth=0, depthHeight=0;
        DXGI_FORMAT colorFormat=DXGI_FORMAT_UNKNOWN;
        pinned::NativeMatrix4 previousView{}, previousProjection{};
        bool historyValid=false;
    };
    std::array<Eye,2> eyes;

    bool Initialise(ID3D11Device* suppliedDevice, ID3D11DeviceContext* supplied, DlssMode mode, std::string& error) {
        if (ngxReady) {
            if (suppliedDevice!=device) { error="DLSS device changed"; return false; }
            return true;
        }
        if (attempted) { error="DLSS initialisation already failed"; return false; }
        attempted=true;
        device=suppliedDevice;
        if (FAILED(supplied->QueryInterface(IID_PPV_ARGS(&context)))) { error="ID3D11DeviceContext1 unavailable"; return false; }
        ComPtr<ID3D11Device1> device1;
        if (FAILED(device->QueryInterface(IID_PPV_ARGS(&device1)))) { error="ID3D11Device1 unavailable"; return false; }
        const D3D_FEATURE_LEVEL level=std::min(device->GetFeatureLevel(),D3D_FEATURE_LEVEL_11_1);
        const UINT flags=(device->GetCreationFlags()&D3D11_CREATE_DEVICE_SINGLETHREADED)
            ? D3D11_1_CREATE_DEVICE_CONTEXT_STATE_SINGLETHREADED : 0u;
        HRESULT hr=device1->CreateDeviceContextState(flags,&level,1,D3D11_SDK_VERSION,__uuidof(ID3D11Device),nullptr,&privateState);
        if (FAILED(hr)) { error=Hex("CreateDeviceContextState",hr); return false; }
        ComPtr<ID3DBlob> code, messages;
        hr=D3DCompile(kMotionShader,sizeof(kMotionShader)-1,"KF2VR DLSS motion",nullptr,nullptr,"CS","cs_5_0",
            D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&messages);
        if (FAILED(hr)) {
            error="D3DCompile(DLSS motion): ";
            if (messages) error.append(static_cast<const char*>(messages->GetBufferPointer()),messages->GetBufferSize());
            return false;
        }
        hr=device->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&motionShader);
        if (FAILED(hr)) { error=Hex("CreateComputeShader(DLSS motion)",hr); return false; }
        code.Reset(); messages.Reset();
        hr=D3DCompile(kSharpenShader,sizeof(kSharpenShader)-1,"KF2VR DLSS sharpen",nullptr,nullptr,"CS","cs_5_0",
            D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&messages);
        if (FAILED(hr)) {
            error="D3DCompile(DLSS sharpen): ";
            if (messages) error.append(static_cast<const char*>(messages->GetBufferPointer()),messages->GetBufferSize());
            return false;
        }
        hr=device->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&sharpenShader);
        if (FAILED(hr)) { error=Hex("CreateComputeShader(DLSS sharpen)",hr); return false; }
        D3D11_BUFFER_DESC cb{};cb.ByteWidth=sizeof(MotionConstants);cb.Usage=D3D11_USAGE_DYNAMIC;
        cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;cb.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
        hr=device->CreateBuffer(&cb,nullptr,&constants);
        if (FAILED(hr)) { error=Hex("CreateBuffer(DLSS constants)",hr); return false; }
        cb.ByteWidth=sizeof(SharpenConstants);
        hr=device->CreateBuffer(&cb,nullptr,&sharpenConstants);
        if (FAILED(hr)) { error=Hex("CreateBuffer(DLSS sharpen constants)",hr); return false; }

        const wchar_t* paths[]{ngxDirectory.c_str()};
        NVSDK_NGX_FeatureCommonInfo info{};
        info.PathListInfo.Path=paths;
        info.PathListInfo.Length=ngxDirectory.empty() ? 0u : 1u;
        info.LoggingInfo.MinimumLoggingLevel=NVSDK_NGX_LOGGING_LEVEL_OFF;
        auto result=NVSDK_NGX_D3D11_Init_with_ProjectID(kProjectId,NVSDK_NGX_ENGINE_TYPE_CUSTOM,"1.0",
            dataDirectory.c_str(),device,&info);
        if (NVSDK_NGX_FAILED(result)) { error=Hex("NVSDK_NGX_D3D11_Init",result); return false; }
        ngxInitialized=true;
        result=NVSDK_NGX_D3D11_GetCapabilityParameters(&params);
        if (NVSDK_NGX_FAILED(result) || !params) { error=Hex("NVSDK_NGX_D3D11_GetCapabilityParameters",result); return false; }
        int available=0, driverUpdate=0;
        params->Get(NVSDK_NGX_Parameter_SuperSampling_Available,&available);
        params->Get(NVSDK_NGX_Parameter_SuperSampling_NeedsUpdatedDriver,&driverUpdate);
        if (driverUpdate) { error="DLSS needs a newer NVIDIA driver"; return false; }
        if (!available) { error="DLSS Super Resolution is not available on this GPU/driver"; return false; }
        (void)mode;
        ngxReady=true;
        return true;
    }

    bool Texture(unsigned width, unsigned height, DXGI_FORMAT format, UINT bind, ComPtr<ID3D11Texture2D>& out,
                 const char* what, std::string& error) {
        D3D11_TEXTURE2D_DESC d{};
        d.Width=width;d.Height=height;d.MipLevels=1;d.ArraySize=1;d.Format=format;d.SampleDesc={1,0};
        d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=bind;
        out.Reset();
        const HRESULT hr=device->CreateTexture2D(&d,nullptr,&out);
        if (FAILED(hr)) { error=Hex(what,hr); return false; }
        return true;
    }

    void ReleaseFeature(Eye& e) {
        if (e.feature) { NVSDK_NGX_D3D11_ReleaseFeature(e.feature); e.feature=nullptr; }
    }

    bool EnsureEye(Eye& e, DlssMode mode, DXGI_FORMAT colorFormat, unsigned rw, unsigned rh,
                   unsigned ow, unsigned oh, unsigned dw, unsigned dh, std::string& error) {
        if (e.colorFormat!=colorFormat || e.renderWidth!=rw || e.renderHeight!=rh) {
            if (!Texture(rw,rh,colorFormat,D3D11_BIND_SHADER_RESOURCE,e.colorIn,"CreateTexture2D(DLSS colour)",error)) return false;
            if (!Texture(rw,rh,DXGI_FORMAT_R32_FLOAT,D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS,e.depthOut,"CreateTexture2D(DLSS depth)",error)) return false;
            if (!Texture(rw,rh,DXGI_FORMAT_R16G16_FLOAT,D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS,e.motion,"CreateTexture2D(DLSS motion)",error)) return false;
            e.motionUav.Reset();e.depthUav.Reset();
            HRESULT hr=device->CreateUnorderedAccessView(e.motion.Get(),nullptr,&e.motionUav);
            if (FAILED(hr)) { error=Hex("CreateUnorderedAccessView(DLSS motion)",hr); return false; }
            hr=device->CreateUnorderedAccessView(e.depthOut.Get(),nullptr,&e.depthUav);
            if (FAILED(hr)) { error=Hex("CreateUnorderedAccessView(DLSS depth)",hr); return false; }
            ReleaseFeature(e);
            e.historyValid=false;
        }
        if (e.depthWidth!=dw || e.depthHeight!=dh || !e.depthCopy) {
            if (!Texture(dw,dh,DXGI_FORMAT_R24G8_TYPELESS,D3D11_BIND_SHADER_RESOURCE,e.depthCopy,"CreateTexture2D(DLSS depth copy)",error)) return false;
            D3D11_SHADER_RESOURCE_VIEW_DESC v{};
            v.Format=DXGI_FORMAT_R24_UNORM_X8_TYPELESS;v.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D;v.Texture2D.MipLevels=1;
            e.depthView.Reset();
            const HRESULT hr=device->CreateShaderResourceView(e.depthCopy.Get(),&v,&e.depthView);
            if (FAILED(hr)) { error=Hex("CreateShaderResourceView(DLSS depth copy)",hr); return false; }
            e.depthWidth=dw;e.depthHeight=dh;
        }
        if (!e.feature || e.outputWidth!=ow || e.outputHeight!=oh) {
            ReleaseFeature(e);
            NVSDK_NGX_PerfQuality_Value quality=NVSDK_NGX_PerfQuality_Value_MaxQuality;
            switch (mode) {
            case DlssMode::Dlaa: quality=NVSDK_NGX_PerfQuality_Value_DLAA; break;
            case DlssMode::Balanced: quality=NVSDK_NGX_PerfQuality_Value_Balanced; break;
            case DlssMode::Performance: quality=NVSDK_NGX_PerfQuality_Value_MaxPerf; break;
            case DlssMode::UltraPerformance: quality=NVSDK_NGX_PerfQuality_Value_UltraPerformance; break;
            default: break;
            }
            NVSDK_NGX_DLSS_Create_Params create{};
            create.Feature.InWidth=rw;create.Feature.InHeight=rh;
            create.Feature.InTargetWidth=ow;create.Feature.InTargetHeight=oh;
            create.Feature.InPerfQualityValue=quality;
            create.InFeatureCreateFlags=NVSDK_NGX_DLSS_Feature_Flags_MVLowRes;
            const auto result=NGX_D3D11_CREATE_DLSS_EXT(context.Get(),&e.feature,params,&create);
            if (NVSDK_NGX_FAILED(result) || !e.feature) {
                e.feature=nullptr;
                error=Hex("NGX_D3D11_CREATE_DLSS_EXT",result);
                return false;
            }
            e.historyValid=false;
        }
        e.colorFormat=colorFormat;
        e.renderWidth=rw;e.renderHeight=rh;e.outputWidth=ow;e.outputHeight=oh;
        return true;
    }

    void Shutdown() {
        for (auto& e:eyes) { ReleaseFeature(e); e=Eye{}; }
        if (params) { NVSDK_NGX_D3D11_DestroyParameters(params); params=nullptr; }
        if (ngxInitialized && device) NVSDK_NGX_D3D11_Shutdown1(device);
        ngxReady=false;ngxInitialized=false;attempted=false;
        constants.Reset();motionShader.Reset();sharpenConstants.Reset();sharpenShader.Reset();
        privateState.Reset();context.Reset();
        device=nullptr;
    }
};

DlssUpscaler::DlssUpscaler() : impl_(std::make_unique<Impl>()) {}
DlssUpscaler::~DlssUpscaler()=default;

void DlssUpscaler::Configure(DlssMode mode, std::wstring ngxDirectory, std::wstring dataDirectory) {
    mode_=mode;
    impl_->ngxDirectory=std::move(ngxDirectory);
    impl_->dataDirectory=std::move(dataDirectory);
}

void DlssUpscaler::Fail(const std::string& why) {
    if (!failed_.exchange(true,std::memory_order_acq_rel)) failure_=why;
}

void DlssUpscaler::Reset() noexcept {
    for (auto& e:impl_->eyes) e.historyValid=false;
}

void DlssUpscaler::Shutdown() noexcept {
    impl_->Shutdown();
    failure_.clear();failed_.store(false,std::memory_order_release);
}

bool DlssUpscaler::Evaluate(ID3D11Device* device, ID3D11DeviceContext* context, unsigned eye,
                            ID3D11Texture2D* color, ID3D11Texture2D* depth, ID3D11Texture2D* output,
                            const DlssEyeInput& input, std::string& error) {
    error.clear();
    if (!Active()) { error="DLSS inactive"; Fail(error); return false; }
    if (eye>1 || !device || !context || !color || !depth || !output || !input.valid) { error="DLSS input missing"; Fail(error); return false; }
    auto& p=*impl_;
    if (!p.Initialise(device,context,mode_,error)) { Fail(error); return false; }
    D3D11_TEXTURE2D_DESC cd{},dd{},od{};
    color->GetDesc(&cd);depth->GetDesc(&dd);output->GetDesc(&od);
    const unsigned rw=input.renderWidth, rh=input.renderHeight;
    const DXGI_FORMAT colorFormat=UnormOf(cd.Format);
    if (!rw || !rh || rw>cd.Width || rh>cd.Height || cd.SampleDesc.Count!=1 || colorFormat==DXGI_FORMAT_UNKNOWN) {
        error="DLSS colour does not match the eye render size/format"; Fail(error); return false;
    }
    if (!DepthFamily(dd.Format) || dd.SampleDesc.Count!=1 || dd.Width<rw || dd.Height<rh) {
        error="DLSS scene depth does not cover the eye render"; Fail(error); return false;
    }
    if (UnormOf(od.Format)!=colorFormat || !(od.BindFlags&D3D11_BIND_UNORDERED_ACCESS) || od.Width<rw || od.Height<rh) {
        error="DLSS output texture is unusable"; Fail(error); return false;
    }
    auto& e=p.eyes[eye];

    // Copies are independent of pipeline state; take them in the game's state.
    // A depth-stencil copy must be whole-subresource.
    // EnsureEye may create the NGX feature, which binds state: do it privately.
    ComPtr<ID3DDeviceContextState> gameState;
    p.context->SwapDeviceContextState(p.privateState.Get(),&gameState);
    struct Restore {
        ID3D11DeviceContext1* context; ID3DDeviceContextState* state;
        ~Restore() { context->SwapDeviceContextState(state,nullptr); }
    } restore{p.context.Get(),gameState.Get()};

    if (!p.EnsureEye(e,mode_,colorFormat,rw,rh,od.Width,od.Height,dd.Width,dd.Height,error)) { Fail(error); return false; }
    const D3D11_BOX box{0,0,0,rw,rh,1};
    p.context->CopySubresourceRegion(e.colorIn.Get(),0,0,0,0,color,0,&box);
    p.context->CopyResource(e.depthCopy.Get(),depth);

    // Camera-only reprojection. A cut (travel, teleport, respawn) resets history.
    bool reset=!e.historyValid;
    MotionConstants constants{};
    if (!reset) {
        double now[3],before[3];
        DlssViewOrigin(input.view,now);DlssViewOrigin(e.previousView,before);
        const double dx=now[0]-before[0],dy=now[1]-before[1],dz=now[2]-before[2];
        if (dx*dx+dy*dy+dz*dz>300.0*300.0 ||
            !DlssReprojection(input.view,input.projection,e.previousView,e.previousProjection,constants.prevFromCur))
            reset=true;
    }
    constants.valid=reset ? 0.0f : 1.0f;
    constants.size[0]=static_cast<float>(rw);constants.size[1]=static_cast<float>(rh);
    constants.invSize[0]=1.0f/static_cast<float>(rw);constants.invSize[1]=1.0f/static_cast<float>(rh);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr=p.context->Map(p.constants.Get(),0,D3D11_MAP_WRITE_DISCARD,0,&mapped);
    if (FAILED(hr)) { error=Hex("Map(DLSS constants)",hr); Fail(error); return false; }
    std::memcpy(mapped.pData,&constants,sizeof(constants));
    p.context->Unmap(p.constants.Get(),0);

    ID3D11ShaderResourceView* srv=e.depthView.Get();
    ID3D11UnorderedAccessView* uavs[]{e.motionUav.Get(),e.depthUav.Get()};
    ID3D11Buffer* cb=p.constants.Get();
    p.context->CSSetShader(p.motionShader.Get(),nullptr,0);
    p.context->CSSetConstantBuffers(0,1,&cb);
    p.context->CSSetShaderResources(0,1,&srv);
    p.context->CSSetUnorderedAccessViews(0,2,uavs,nullptr);
    p.context->Dispatch((rw+7)/8,(rh+7)/8,1);
    ID3D11ShaderResourceView* nullSrv=nullptr;
    ID3D11UnorderedAccessView* nullUavs[2]{};
    p.context->CSSetShaderResources(0,1,&nullSrv);
    p.context->CSSetUnorderedAccessViews(0,2,nullUavs,nullptr);
    p.context->CSSetShader(nullptr,nullptr,0);

    NVSDK_NGX_D3D11_DLSS_Eval_Params eval{};
    eval.Feature.pInColor=e.colorIn.Get();
    // With sharpening, DLSS writes an intermediate that CAS then filters into
    // the caller's output; without it, DLSS writes the output directly.
    const bool sharpen=sharpness_>0.0f;
    if (sharpen) {
        D3D11_TEXTURE2D_DESC ud{};
        if (e.upscaled) e.upscaled->GetDesc(&ud);
        if (!e.upscaled || ud.Width!=od.Width || ud.Height!=od.Height || ud.Format!=od.Format) {
            if (!p.Texture(od.Width,od.Height,od.Format,D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_UNORDERED_ACCESS,
                    e.upscaled,"CreateTexture2D(DLSS upscaled)",error)) { Fail(error); return false; }
            e.upscaledView.Reset();
            hr=device->CreateShaderResourceView(e.upscaled.Get(),nullptr,&e.upscaledView);
            if (FAILED(hr)) { error=Hex("CreateShaderResourceView(DLSS upscaled)",hr); Fail(error); return false; }
        }
    }
    eval.Feature.pInOutput=sharpen ? static_cast<ID3D11Resource*>(e.upscaled.Get()) : output;
    eval.pInDepth=e.depthOut.Get();
    eval.pInMotionVectors=e.motion.Get();
    // DLSS reads the offset as where the content moved: the negated sample offset.
    eval.InJitterOffsetX=-input.jitter.x;
    eval.InJitterOffsetY=-input.jitter.y;
    eval.InRenderSubrectDimensions={rw,rh};
    eval.InReset=reset ? 1 : 0;
    eval.InMVScaleX=static_cast<float>(rw);
    eval.InMVScaleY=static_cast<float>(rh);
    const auto result=NGX_D3D11_EVALUATE_DLSS_EXT(p.context.Get(),e.feature,p.params,&eval);
    if (NVSDK_NGX_FAILED(result)) { error=Hex("NGX_D3D11_EVALUATE_DLSS_EXT",result); Fail(error); return false; }

    if (sharpen) {
        ComPtr<ID3D11UnorderedAccessView> target;
        hr=device->CreateUnorderedAccessView(output,nullptr,&target);
        if (FAILED(hr)) { error=Hex("CreateUnorderedAccessView(DLSS sharpen output)",hr); Fail(error); return false; }
        SharpenConstants sc{};
        sc.peak=-1.0f/(8.0f+(5.0f-8.0f)*sharpness_);
        sc.size[0]=od.Width; sc.size[1]=od.Height;
        hr=p.context->Map(p.sharpenConstants.Get(),0,D3D11_MAP_WRITE_DISCARD,0,&mapped);
        if (FAILED(hr)) { error=Hex("Map(DLSS sharpen constants)",hr); Fail(error); return false; }
        std::memcpy(mapped.pData,&sc,sizeof(sc));
        p.context->Unmap(p.sharpenConstants.Get(),0);
        ID3D11ShaderResourceView* source=e.upscaledView.Get();
        ID3D11UnorderedAccessView* uav=target.Get();
        ID3D11Buffer* scb=p.sharpenConstants.Get();
        p.context->CSSetShader(p.sharpenShader.Get(),nullptr,0);
        p.context->CSSetConstantBuffers(0,1,&scb);
        p.context->CSSetShaderResources(0,1,&source);
        p.context->CSSetUnorderedAccessViews(0,1,&uav,nullptr);
        p.context->Dispatch((od.Width+7)/8,(od.Height+7)/8,1);
        p.context->CSSetShaderResources(0,1,&nullSrv);
        p.context->CSSetUnorderedAccessViews(0,1,nullUavs,nullptr);
        p.context->CSSetShader(nullptr,nullptr,0);
    }
    e.previousView=input.view;
    e.previousProjection=input.projection;
    e.historyValid=true;
    return true;
}
} // namespace kf2vr::adapter
