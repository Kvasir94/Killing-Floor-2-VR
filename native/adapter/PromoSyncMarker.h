#pragma once
#include <d3d11_1.h>
#include <wrl/client.h>
#include "PromoEventLog.h"

namespace kf2vr::adapter::promo {
// Desktop-only marks are drawn AFTER the XR eye images were submitted. They
// never enter the headset's eye atlas. F9 is observed, never synthesized.
class SyncMarker {
public:
    void Present(Log& log,IDXGISwapChain* swapchain,std::uint64_t frame) {
        if (!log.Enabled()) return;
        DXGI_SWAP_CHAIN_DESC desc{};
        if (FAILED(swapchain->GetDesc(&desc))) return;
        const bool down=(GetAsyncKeyState(VK_F9)&0x8000)!=0;
        if (down && !wasDown_ && GetForegroundWindow()==desc.OutputWindow) requested_=true;
        wasDown_=down;
        const auto now=Log::Clock();
        if (!requested_ && now>=until_) return;
        using Microsoft::WRL::ComPtr;
        ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context; ComPtr<ID3D11DeviceContext1> context1;
        ComPtr<ID3D11Texture2D> buffer; ComPtr<ID3D11RenderTargetView> target;
        if (FAILED(swapchain->GetDevice(IID_PPV_ARGS(&device)))) return;
        device->GetImmediateContext(&context);
        if (FAILED(context.As(&context1)) || FAILED(swapchain->GetBuffer(0,IID_PPV_ARGS(&buffer))) ||
            FAILED(device->CreateRenderTargetView(buffer.Get(),nullptr,&target))) return;
        D3D11_TEXTURE2D_DESC image{}; buffer->GetDesc(&image);
        if (image.Width<320 || image.Height<80) return;
        if (requested_) { ++id_; until_=now+log.Frequency()*3/4; requested_=false;
            log.Marker(id_,image.Width,image.Height,frame); }
        // Cyan/magenta bookends plus 16 black/white little-endian ID blocks.
        // The bar lasts 750 ms, long enough for ordinary 30/60 fps recording.
        for (unsigned i=0;i<18;++i) {
            const float bright=i>0 && i<17 && ((id_>>(i-1))&1) ? 1.f : 0.f;
            const FLOAT color[4]{i==17?1.f:bright,i==0?1.f:bright,i==0 || i==17?1.f:bright,1.f};
            const D3D11_RECT rect{static_cast<LONG>(8+i*16),8,static_cast<LONG>(24+i*16),56};
            context1->ClearView(target.Get(),color,&rect,1);
        }
    }
private:
    std::uint32_t id_{};
    std::uint64_t until_{};
    bool wasDown_{},requested_{};
};
} // namespace kf2vr::adapter::promo
