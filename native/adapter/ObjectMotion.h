#pragma once
#include <d3d11_1.h>
#include <wrl/client.h>
#include <cstdint>

namespace kf2vr::adapter {
// Per-object motion for DLSS from KF2's own velocity pass (docs/re/09-velocity-pass.md).
// RenderVelocities (0x94d240) draws every moving primitive, skinned meshes with
// their previous bones, into a G16R16F buffer packed as clamp(object*Scale.xy +
// camera*Scale.zw)*0.5+0.5. The adapter sets Scale to (1,1,0,0) so only object
// motion (NDC displacement over clip z) remains, redirects the draws into its
// own R32G32F target for precision, and gives each eye its own viewport. The
// camera part DLSS needs comes from depth and the eye's own matrices.
class ObjectMotion {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture_;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> target_;
    D3D11_VIEWPORT eye_{};
    bool eyeActive_=false, written_=false;
public:
    // The rectangle the next velocity draws belong to (one view of the scene).
    void BeginEye(const std::int32_t rect[4]) {
        eye_={float(rect[0]),float(rect[1]),float(rect[2]),float(rect[3]),0.0f,1.0f};
        eyeActive_=rect[2]>0 && rect[3]>0;
    }
    void EndEye() { eyeActive_=false; }
    // Called right after the engine binds its velocity surface: rebind ours
    // with the engine's depth, cleared to zero motion over this eye.
    bool Redirect(ID3D11DeviceContext* context) {
        if (!context) return false;
        Microsoft::WRL::ComPtr<ID3D11RenderTargetView> engine; Microsoft::WRL::ComPtr<ID3D11DepthStencilView> depth;
        context->OMGetRenderTargets(1,&engine,&depth);
        if (!engine) return false;
        Microsoft::WRL::ComPtr<ID3D11Resource> resource; engine->GetResource(&resource);
        Microsoft::WRL::ComPtr<ID3D11Texture2D> source;
        if (FAILED(resource.As(&source))) return false;
        D3D11_TEXTURE2D_DESC d{}; source->GetDesc(&d);
        if (!Ensure(context,d.Width,d.Height)) return false;
        ID3D11RenderTargetView* rtv=target_.Get();
        context->OMSetRenderTargets(1,&rtv,depth.Get());
        const float zero[4]{0.5f,0.5f,0.0f,0.0f};
        Microsoft::WRL::ComPtr<ID3D11DeviceContext1> context1;
        if (eyeActive_ && SUCCEEDED(context->QueryInterface(IID_PPV_ARGS(&context1)))) {
            const D3D11_RECT rect{LONG(eye_.TopLeftX),LONG(eye_.TopLeftY),
                LONG(eye_.TopLeftX+eye_.Width),LONG(eye_.TopLeftY+eye_.Height)};
            context1->ClearView(rtv,zero,&rect,1);
        } else context->ClearRenderTargetView(rtv,zero);
        written_=true;
        return true;
    }
    // RHI SetViewport during a velocity pass covers the whole buffer; each
    // view's draws belong to its own eye rectangle.
    bool OverrideViewport(UINT count, const D3D11_VIEWPORT*& viewports) const {
        if (!eyeActive_ || count!=1) return false;
        viewports=&eye_;
        return true;
    }
    bool EyeActive() const { return eyeActive_; }
    // This frame's object motion, or null when no velocity pass ran.
    ID3D11Texture2D* Frame() const { return written_ ? texture_.Get() : nullptr; }
    void EndFrame() { written_=false; }
    void Reset() { texture_.Reset(); target_.Reset(); eyeActive_=false; written_=false; }
private:
    bool Ensure(ID3D11DeviceContext* context, UINT width, UINT height) {
        D3D11_TEXTURE2D_DESC d{};
        if (texture_) texture_->GetDesc(&d);
        if (texture_ && d.Width==width && d.Height==height) return true;
        texture_.Reset(); target_.Reset();
        Microsoft::WRL::ComPtr<ID3D11Device> device; context->GetDevice(&device);
        d={}; d.Width=width; d.Height=height; d.MipLevels=1; d.ArraySize=1; d.Format=DXGI_FORMAT_R32G32_FLOAT;
        d.SampleDesc={1,0}; d.Usage=D3D11_USAGE_DEFAULT; d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
        if (!device || FAILED(device->CreateTexture2D(&d,nullptr,&texture_)) ||
            FAILED(device->CreateRenderTargetView(texture_.Get(),nullptr,&target_))) { texture_.Reset(); target_.Reset(); return false; }
        const float zero[4]{0.5f,0.5f,0.0f,0.0f};
        context->ClearRenderTargetView(target_.Get(),zero);
        return true;
    }
};
} // namespace kf2vr::adapter
