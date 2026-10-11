#pragma once
#include <d3d11_1.h>
#include <wrl/client.h>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace kf2vr::adapter {
// Adapted from optimumbox 8c571ce: HBAO+ writes beyond its input viewport.
// Render both eyes as isolated frames before KF2 reads the shared AO target.
// A failed pair is neutral AO, never a whole-atlas call with one eye's camera.
class StereoAmbientOcclusion {
    template<class T> using Ptr=Microsoft::WRL::ComPtr<T>;
    Ptr<ID3D11Device> device_;
    Ptr<ID3DDeviceContextState> state_;
    bool failed_=false;
    bool Fail() { failed_=true; return false; }
    Ptr<ID3D11Texture2D> fullDepth_;
    struct Eye { Ptr<ID3D11Texture2D> depth,output; Ptr<ID3D11ShaderResourceView> depthView; Ptr<ID3D11RenderTargetView> outputView; } eyes_[2];
    static D3D11_TEXTURE2D_DESC Plain(D3D11_TEXTURE2D_DESC d,UINT w,UINT h,UINT bind) {
        d.Width=w; d.Height=h; d.MipLevels=d.ArraySize=1; d.SampleDesc={1,0};
        d.Usage=D3D11_USAGE_DEFAULT; d.BindFlags=bind; d.CPUAccessFlags=d.MiscFlags=0; return d;
    }
    static bool Matches(ID3D11Texture2D* texture,const D3D11_TEXTURE2D_DESC& wanted) {
        D3D11_TEXTURE2D_DESC d{}; if(texture) texture->GetDesc(&d);
        return texture && d.Width==wanted.Width && d.Height==wanted.Height && d.Format==wanted.Format;
    }
    static bool Rect(const std::int32_t r[4],UINT w,UINT h) {
        return r[0]>=0 && r[1]>=0 && r[2]>0 && r[3]>0 && w<=8192 && h<=8192
            && UINT(r[0])<=w && UINT(r[1])<=h && UINT(r[2])<=w-UINT(r[0]) && UINT(r[3])<=h-UINT(r[1]);
    }
public:
    using Render=std::int32_t(*)(void*,void*,void*,const void*,const void*,std::uint32_t);
    void Reset() { for(auto& eye:eyes_) eye={}; fullDepth_.Reset(); state_.Reset(); device_.Reset(); failed_=false; }
    bool RenderPair(Render render,void* self,ID3D11DeviceContext* context,void* input,const void* params,
                    ID3D11RenderTargetView* output,std::uint32_t mask,const std::int32_t rects[2][4],
                    const void* projections[2],std::int32_t& result) {
        if(!render || !context || !input || !output) return false;
        Ptr<ID3D11Device> device; context->GetDevice(&device);
        if(device.Get()!=device_.Get()) { Reset(); device_=device; }
        if(failed_) return false;
        Ptr<ID3D11Resource> resource; output->GetResource(&resource);
        Ptr<ID3D11Texture2D> target; if(!resource || FAILED(resource.As(&target))) return false;
        ID3D11ShaderResourceView* sourceView=nullptr;
        auto* in=static_cast<std::byte*>(input); std::memcpy(&sourceView,in+0x68,sizeof(sourceView));
        Ptr<ID3D11Resource> sourceResource; if(sourceView) sourceView->GetResource(&sourceResource);
        Ptr<ID3D11Texture2D> source; if(!sourceResource || FAILED(sourceResource.As(&source))) return false;
        D3D11_TEXTURE2D_DESC td{},dd{}; target->GetDesc(&td); source->GetDesc(&dd);
        Ptr<ID3D11Device> targetDevice,sourceDevice; target->GetDevice(&targetDevice); source->GetDevice(&sourceDevice);
        D3D11_SHADER_RESOURCE_VIEW_DESC sv{}; sourceView->GetDesc(&sv);
        D3D11_RENDER_TARGET_VIEW_DESC rv{}; output->GetDesc(&rv);
        if(!device || targetDevice.Get()!=device.Get() || sourceDevice.Get()!=device.Get()
            || context->GetType()!=D3D11_DEVICE_CONTEXT_IMMEDIATE || td.SampleDesc.Count!=1 || dd.SampleDesc.Count!=1
            || td.ArraySize!=1 || dd.ArraySize!=1 || td.MipLevels!=1 || dd.MipLevels!=1
            || rv.ViewDimension!=D3D11_RTV_DIMENSION_TEXTURE2D || rv.Texture2D.MipSlice!=0
            || sv.ViewDimension!=D3D11_SRV_DIMENSION_TEXTURE2D || sv.Texture2D.MostDetailedMip!=0
            || (dd.Format!=DXGI_FORMAT_R24G8_TYPELESS && dd.Format!=DXGI_FORMAT_R32_TYPELESS)
            || !Rect(rects[0],td.Width,td.Height) || !Rect(rects[1],td.Width,td.Height)
            || !Rect(rects[0],dd.Width,dd.Height) || !Rect(rects[1],dd.Width,dd.Height)) return false;
        const auto* a=rects[0]; const auto* b=rects[1];
        if(a[0]<b[0]+b[2] && b[0]<a[0]+a[2] && a[1]<b[1]+b[3] && b[1]<a[1]+a[3]) return false;
        Ptr<ID3D11DeviceContext1> context1; Ptr<ID3D11Device1> device1;
        if(FAILED(context->QueryInterface(IID_PPV_ARGS(&context1))) || FAILED(device.As(&device1))) return Fail();
        if(!state_) {
            const auto actual=device->GetFeatureLevel();
            const auto level=actual>D3D_FEATURE_LEVEL_11_1 ? D3D_FEATURE_LEVEL_11_1 : actual;
            const UINT flags=(device->GetCreationFlags()&D3D11_CREATE_DEVICE_SINGLETHREADED)
                ? D3D11_1_CREATE_DEVICE_CONTEXT_STATE_SINGLETHREADED : 0u;
            if(FAILED(device1->CreateDeviceContextState(flags,&level,1,D3D11_SDK_VERSION,__uuidof(ID3D11Device),nullptr,&state_))) return Fail();
        }
        const auto full=Plain(dd,dd.Width,dd.Height,D3D11_BIND_SHADER_RESOURCE);
        if(!Matches(fullDepth_.Get(),full)) {
            fullDepth_.Reset(); if(FAILED(device->CreateTexture2D(&full,nullptr,&fullDepth_))) return Fail();
        }
        // Allocate both eyes before rendering either, so failures cannot leave
        // one new AO image beside one stale image.
        for(unsigned i=0;i<2;++i) {
            auto& eye=eyes_[i]; const UINT w=UINT(rects[i][2]),h=UINT(rects[i][3]);
            const auto depth=Plain(dd,w,h,D3D11_BIND_SHADER_RESOURCE);
            const auto color=Plain(td,w,h,D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE);
            if(!Matches(eye.depth.Get(),depth) || !Matches(eye.output.Get(),color)) {
                eye={}; sv.Texture2D.MipLevels=1;
                if(FAILED(device->CreateTexture2D(&depth,nullptr,&eye.depth))
                    || FAILED(device->CreateShaderResourceView(eye.depth.Get(),&sv,&eye.depthView))
                    || FAILED(device->CreateTexture2D(&color,nullptr,&eye.output))
                    || FAILED(device->CreateRenderTargetView(eye.output.Get(),&rv,&eye.outputView))) { eye={}; return Fail(); }
            }
        }
        struct Restore {
            std::byte* input; std::byte projection[64],viewport[0x24];
            Restore(std::byte* p):input(p) { std::memcpy(projection,p+4,sizeof(projection)); std::memcpy(viewport,p+0x4c,sizeof(viewport)); }
            ~Restore() { std::memcpy(input+4,projection,sizeof(projection)); std::memcpy(input+0x4c,viewport,sizeof(viewport)); }
        } restore(in);
        context->CopyResource(fullDepth_.Get(),source.Get());
        result=0;
        for(unsigned i=0;i<2;++i) {
            auto& eye=eyes_[i]; const UINT x=UINT(rects[i][0]),y=UINT(rects[i][1]),w=UINT(rects[i][2]),h=UINT(rects[i][3]);
            const D3D11_BOX box{x,y,0,x+w,y+h,1};
            context->CopySubresourceRegion(eye.depth.Get(),0,0,0,0,fullDepth_.Get(),0,&box);
            context->CopySubresourceRegion(eye.output.Get(),0,0,0,0,target.Get(),0,&box);
            std::memcpy(in+4,projections[i],64);
            const std::uint32_t viewport[5]{1,0,0,w,h}; const float range[2]{0,1};
            std::memcpy(in+0x4c,viewport,sizeof(viewport)); std::memcpy(in+0x60,range,sizeof(range));
            auto* view=eye.depthView.Get(); std::memcpy(in+0x68,&view,sizeof(view));
            Ptr<ID3DDeviceContextState> gameState; context1->SwapDeviceContextState(state_.Get(),&gameState);
            struct RestoreState { ID3D11DeviceContext1* context; ID3DDeviceContextState* state; ~RestoreState(){context->SwapDeviceContextState(state,nullptr);} } restoreState{context1.Get(),gameState.Get()};
            const auto status=render(self,context,in,params,eye.outputView.Get(),mask);
            if(status!=0) { result=status; return Fail(); }
        }
        // Both calls succeeded in private states. Publish the complete pair.
        for(unsigned i=0;i<2;++i) {
            const UINT x=UINT(rects[i][0]),y=UINT(rects[i][1]),w=UINT(rects[i][2]),h=UINT(rects[i][3]);
            const D3D11_BOX box{0,0,0,w,h,1}; context->CopySubresourceRegion(target.Get(),0,x,y,0,eyes_[i].output.Get(),0,&box);
        }
        return true;
    }
};
}
