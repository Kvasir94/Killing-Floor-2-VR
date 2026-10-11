#pragma once
#include <d3d11.h>
#include <wrl/client.h>

namespace kf2vr::adapter {
// KF2 clears the main depth/stencil before world geometry and again before
// its forward-lit foreground. Both passes use the same view-projection with
// mesh FOV=0. Retain world and hand depth across consecutive foreground clears
// while keeping the foreground stencil reset. A same-target mismatch ends
// preservation; unrelated targets leave it unchanged.
// Single-pass stereo: SetEyes names the two eye rectangles of the current
// two-view scene. Each eye's first clear is its world clear and later clears
// of that rectangle are foreground clears, also after one clear of both eyes.
class ForegroundDepth {
    bool active_=false;
    // The preserved depth buffer: compared as a resource, since the engine
    // binds more than one view of it.
    Microsoft::WRL::ComPtr<ID3D11Resource> worldDepth_;
    D3D11_VIEWPORT savedViewport_{};
    D3D11_VIEWPORT eyes_[2]{};
    bool stereo_=false, eyeCleared_[2]{};
    static bool Same(const D3D11_VIEWPORT& a,const D3D11_VIEWPORT& b) {
        return a.TopLeftX==b.TopLeftX && a.TopLeftY==b.TopLeftY && a.Width==b.Width && a.Height==b.Height;
    }
public:
    void Begin(bool active) { active_=active; worldDepth_=nullptr; savedViewport_={}; eyeCleared_[0]=eyeCleared_[1]=false; }
    void End() { active_=false; worldDepth_=nullptr; savedViewport_={}; eyeCleared_[0]=eyeCleared_[1]=false; }
    void SetEyes(const D3D11_VIEWPORT& left,const D3D11_VIEWPORT& right) { eyes_[0]=left; eyes_[1]=right; stereo_=true; }
    void ClearEyes() { stereo_=false; }
    bool Filter(ID3D11DeviceContext* context, ID3D11DepthStencilView* view,
                UINT& flags, float depth, UINT8 stencil) {
        if (!active_ || !context || !view) return false;
        // Stencil-only operations (e.g. dynamic lighting, decals, shadow masks)
        // do not touch the depth buffer and must not abort depth preservation.
        if ((flags & D3D11_CLEAR_DEPTH) == 0) return false;
        Microsoft::WRL::ComPtr<ID3D11RenderTargetView> color;
        Microsoft::WRL::ComPtr<ID3D11DepthStencilView> boundDepth;
        context->OMGetRenderTargets(1,&color,&boundDepth);
        if (!color || !boundDepth) return false;
        Microsoft::WRL::ComPtr<ID3D11Resource> colorResource, depthResource, boundResource;
        color->GetResource(&colorResource); view->GetResource(&depthResource);
        boundDepth->GetResource(&boundResource);
        if (depthResource.Get()!=boundResource.Get()) return false;
        if (worldDepth_ && worldDepth_.Get()!=depthResource.Get()) return false;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> colorTexture,depthTexture;
        if (FAILED(colorResource.As(&colorTexture)) || FAILED(depthResource.As(&depthTexture))) return false;
        D3D11_TEXTURE2D_DESC c{},d{};colorTexture->GetDesc(&c);depthTexture->GetDesc(&d);
        if (c.Format!=DXGI_FORMAT_R16G16B16A16_FLOAT) return false;
        const auto reject=[&]() { if (worldDepth_) End();return false; };
        // Single-pass eye clears come through RHIClear's quad path, which may
        // clear depth alone; elsewhere depth-only clears are not foreground clears.
        const bool depthOnly=stereo_ && flags==D3D11_CLEAR_DEPTH;
        if ((flags!=(D3D11_CLEAR_DEPTH|D3D11_CLEAR_STENCIL) && !depthOnly)
            || depth!=1.f || (!depthOnly && stencil!=0)) return reject();
        D3D11_VIEWPORT viewport{};UINT count=1;context->RSGetViewports(&count,&viewport);
        D3D11_DEPTH_STENCIL_VIEW_DESC viewDesc{};view->GetDesc(&viewDesc);
        if (viewDesc.Format!=DXGI_FORMAT_D24_UNORM_S8_UINT
            || c.Width!=d.Width || c.Height!=d.Height
            || c.SampleDesc.Count!=1 || d.SampleDesc.Count!=1 || count!=1
            || viewport.TopLeftX < 0.f || viewport.TopLeftY < 0.f
            || viewport.Width < 1.f || viewport.Height < 1.f
            || (viewport.TopLeftX + viewport.Width) > float(c.Width)
            || (viewport.TopLeftY + viewport.Height) > float(c.Height)
            || viewport.MinDepth!=0.f || viewport.MaxDepth!=1.f) return reject();
        if (stereo_) {
            for (int eye=0;eye<2;++eye) {
                if (!Same(viewport,eyes_[eye])) continue;
                if (!worldDepth_) worldDepth_=depthResource;
                // Inside an earlier clear of both eyes, or this eye's own
                // world clear already happened: a foreground clear.
                const bool both=savedViewport_.Width>0.f
                    && savedViewport_.TopLeftX<=eyes_[0].TopLeftX && savedViewport_.TopLeftY<=eyes_[0].TopLeftY
                    && savedViewport_.TopLeftX+savedViewport_.Width>=eyes_[1].TopLeftX+eyes_[1].Width
                    && savedViewport_.TopLeftY+savedViewport_.Height>=eyes_[1].TopLeftY+eyes_[1].Height;
                if (!eyeCleared_[eye] && !both) { eyeCleared_[eye]=true; return false; }
                flags=depthOnly ? 0u : UINT(D3D11_CLEAR_STENCIL);
                return true;
            }
        }
        if (depthOnly) return reject();
        if (!worldDepth_) {
            worldDepth_=depthResource;
            savedViewport_=viewport;
            return false;
        }
        if (viewport.TopLeftX!=savedViewport_.TopLeftX
            || viewport.TopLeftY!=savedViewport_.TopLeftY
            || viewport.Width!=savedViewport_.Width
            || viewport.Height!=savedViewport_.Height) return reject();
        flags=D3D11_CLEAR_STENCIL;
        return true;
    }
};
}
