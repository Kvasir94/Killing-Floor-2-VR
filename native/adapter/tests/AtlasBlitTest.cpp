#include <windows.h>
#include <d3d11_1.h>
#include <d3d11sdklayers.h>
#include <wrl/client.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "AtlasBlit.h"
using Microsoft::WRL::ComPtr;
int checks=0,failures=0;
void Test(bool b,const char* s) { ++checks; if(!b) { ++failures; std::printf("FAIL %s\n",s); } }
void HR(HRESULT h) { if(FAILED(h)) { std::printf("FATAL HRESULT %08lx\n",(unsigned long)h); std::exit(2); } }
void MenuPixels(ID3D11Device* device,ID3D11DeviceContext* context,kf2vr::adapter::AtlasBlit& blit) {
    // A flat midtone menu must keep its colour while its position exhibits
    // binocular disparity and motion parallax on a dark, independent surround.
    D3D11_TEXTURE2D_DESC d{};
    d.Width=65; d.Height=33; d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;
    d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    std::vector<unsigned char> bytes(d.Width*d.Height*4);
    for (size_t i=0;i<bytes.size();i+=4) { bytes[i]=128; bytes[i+3]=255; }
    D3D11_SUBRESOURCE_DATA init{bytes.data(),d.Width*4,0};
    ComPtr<ID3D11Texture2D> source,target,stage;
    HR(device->CreateTexture2D(&d,&init,&source));
    d.Width=256; d.Height=128; d.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; d.BindFlags=D3D11_BIND_RENDER_TARGET;
    HR(device->CreateTexture2D(&d,nullptr,&target));
    ComPtr<ID3D11RenderTargetView> rtv; HR(device->CreateRenderTargetView(target.Get(),nullptr,&rtv));
    d.BindFlags=0; d.Usage=D3D11_USAGE_STAGING; d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&d,nullptr,&stage));
    kf2vr::xr::FrameState f; f.viewsValid=true;
    f.eyeLeft.poseValid=f.eyeRight.poseValid=true;
    f.eyeLeft.fov=f.eyeRight.fov={-.7853982f,.7853982f,.7853982f,-.7853982f};
    f.eyeLeft.pose.pos={-.032f,0,0}; f.eyeRight.pose.pos={.032f,0,0};
    kf2vr::adapter::SpatialMenuPanel p; p.valid=true; p.center={0,0,-1.5f}; p.height=p.width*33.f/65;
    kf2vr::adapter::SpatialMenuPointer pointer;
    kf2vr::xr::D3D11EyeTarget eye; eye.width=256; eye.height=128; eye.colorView=rtv.Get();
    const auto measure=[&](unsigned channel) {
        context->CopyResource(stage.Get(),target.Get());
        D3D11_MAPPED_SUBRESOURCE map{}; HR(context->Map(stage.Get(),0,D3D11_MAP_READ,0,&map));
        double sum=0; int count=0;
        for (unsigned y=0;y<128;++y) for (unsigned x=0;x<256;++x) {
            const auto* pixel=static_cast<unsigned char*>(map.pData)+y*map.RowPitch+x*4;
            // Channel 1 is pointer feedback: the off-white cursor ring, or the
            // KF2-red beam, far brighter than the 128 red test panel or the dim trim.
            const bool pointerPixel=(pixel[1]>100 && pixel[2]>100) || (pixel[0]>=190 && pixel[1]<80 && pixel[2]<80);
            const bool match=channel==0 ? std::abs(int(pixel[0])-128)<=1 && pixel[1]==0 && pixel[2]==0 : pointerPixel;
            if (match) { ++count; sum+=x; }
        }
        context->Unmap(stage.Get(),0); return std::pair<double,int>{count?sum/count:-1,count};
    };
    ID3D11RenderTargetView* bound=rtv.Get(); context->OMSetRenderTargets(1,&bound,nullptr);
    const D3D11_VIEWPORT sentinel{3,4,100,80,.2f,.8f}; context->RSSetViewports(1,&sentinel);
    Test(blit.BeginFrame(source.Get(),true,true),"spatial menu snapshots odd full-frame width");
    Test(blit.RenderMenuEye(eye,f,p,pointer),"left spatial menu renders");
    const auto left=measure(0);
    Test(left.second>1000 && left.second<20000,"finite menu extent and exact sRGB midtone, dark surround");
    eye.eye=kf2vr::xr::Eye::Right;
    Test(blit.RenderMenuEye(eye,f,p,pointer),"right spatial menu renders");
    const auto right=measure(0);
    Test(left.first-right.first>4 && left.first-right.first<7,"physical IPD produces expected binocular disparity");
    f.eyeRight.pose.pos.x+=.3f;
    Test(blit.RenderMenuEye(eye,f,p,pointer),"translated head menu renders");
    const auto moved=measure(0);
    Test(right.first-moved.first>24 && right.first-moved.first<28,"anchored menu exhibits translation parallax");
    pointer.rayVisible=pointer.hit=true; pointer.u=pointer.v=.5f; pointer.rayStart={.2f,-.15f,-.3f}; pointer.rayEnd=p.center;
    Test(blit.RenderMenuEye(eye,f,p,pointer),"ray and cursor render in panel space");
    Test(measure(1).second>5,"visible pointer ring and beam pixels");
    pointer.hit=false; pointer.rayEnd={1.2f,-.15f,-1.5f};
    Test(blit.RenderMenuEye(eye,f,p,pointer),"off-panel tracked aim renders without a target ring");
    Test(measure(1).second>5,"off-panel beam remains visible before acquiring a menu target");
    pointer.rayVisible=false;
    Test(blit.RenderMenuEye(eye,f,p,pointer),"lost tracked aim renders the panel alone");
    Test(measure(1).second==0,"tracking loss removes the controller beam");
    pointer={}; f.eyeRight.pose.pos={0,0,-2};
    Test(blit.RenderMenuEye(eye,f,p,pointer),"backside view renders safely");
    Test(measure(0).second==0,"backside cannot mirror menu text");
    blit.EndFrame();
    ComPtr<ID3D11RenderTargetView> restored; context->OMGetRenderTargets(1,&restored,nullptr);
    D3D11_VIEWPORT viewport{}; UINT n=1; context->RSGetViewports(&n,&viewport);
    Test(restored.Get()==rtv.Get() && n==1 && viewport.TopLeftX==3 && viewport.Width==100,"spatial menu restores game render state");
    blit.OnResize(); context->ClearState();
}
void MenuWorldPixels(ID3D11Device* device,ID3D11DeviceContext* context,kf2vr::adapter::AtlasBlit& blit) {
    // Deliberately different eye colours expose accidental mono backgrounds,
    // atlas seam bleed, stale frames and double sRGB conversion in the menu path.
    D3D11_TEXTURE2D_DESC d{};
    d.Width=65; d.Height=33; d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;
    d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    std::vector<unsigned char> menuBytes(d.Width*d.Height*4);
    for(size_t i=0;i<menuBytes.size();i+=4) { menuBytes[i]=128; menuBytes[i+3]=255; }
    D3D11_SUBRESOURCE_DATA initial{menuBytes.data(),d.Width*4,0};
    ComPtr<ID3D11Texture2D> menu,world,target,stage;
    HR(device->CreateTexture2D(&d,&initial,&menu));
    d.Width=16; d.Height=8; d.Format=DXGI_FORMAT_R8G8B8A8_TYPELESS;
    d.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    std::array<unsigned char,16*8*4> worldBytes{};
    const auto fillWorld=[&](unsigned char left,unsigned char right) {
        for(unsigned y=0;y<8;++y) for(unsigned x=0;x<16;++x) {
            auto* pixel=worldBytes.data()+(y*16+x)*4;
            pixel[0]=0; pixel[1]=x<8?left:0; pixel[2]=x<8?0:right; pixel[3]=255;
        }
    };
    fillWorld(96,160); initial={worldBytes.data(),16*4,0};
    HR(device->CreateTexture2D(&d,&initial,&world));
    D3D11_SHADER_RESOURCE_VIEW_DESC sv{};
    sv.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; sv.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D; sv.Texture2D.MipLevels=1;
    ComPtr<ID3D11ShaderResourceView> worldView; HR(device->CreateShaderResourceView(world.Get(),&sv,&worldView));
    d.Width=256; d.Height=128; d.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; d.BindFlags=D3D11_BIND_RENDER_TARGET;
    HR(device->CreateTexture2D(&d,nullptr,&target));
    ComPtr<ID3D11RenderTargetView> rtv; HR(device->CreateRenderTargetView(target.Get(),nullptr,&rtv));
    d.BindFlags=0; d.Usage=D3D11_USAGE_STAGING; d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&d,nullptr,&stage));
    kf2vr::xr::FrameState f; f.viewsValid=true; f.eyeLeft.poseValid=f.eyeRight.poseValid=true;
    f.eyeLeft.fov=f.eyeRight.fov={-.7853982f,.7853982f,.7853982f,-.7853982f};
    f.eyeLeft.pose.pos={-.032f,0,0}; f.eyeRight.pose.pos={.032f,0,0};
    kf2vr::adapter::SpatialMenuPanel panel; panel.valid=true; panel.center={0,0,-1.5f}; panel.height=panel.width*33.f/65;
    kf2vr::adapter::SpatialMenuPointer pointer;
    kf2vr::xr::D3D11EyeTarget eye; eye.width=256; eye.height=128; eye.colorView=rtv.Get();
    const auto exactPixels=[&](bool left,int value,bool expectMenu) {
        context->CopyResource(stage.Get(),target.Get());
        D3D11_MAPPED_SUBRESOURCE map{}; HR(context->Map(stage.Get(),0,D3D11_MAP_READ,0,&map));
        bool correct=true; unsigned menuCount=0,worldCount=0;
        for(unsigned y=0;y<128;++y) for(unsigned x=0;x<256;++x) {
            const auto* pixel=static_cast<unsigned char*>(map.pData)+y*map.RowPitch+x*4;
            const bool menuPixel=std::abs(int(pixel[0])-128)<=1 && pixel[1]==0 && pixel[2]==0 && pixel[3]==255;
            const bool worldPixel=pixel[0]==0 && std::abs(int(pixel[left?1:2])-value)<=1 && pixel[left?2:1]==0 && pixel[3]==255;
            correct=correct && (menuPixel||worldPixel);
            menuCount+=menuPixel; worldCount+=worldPixel;
        }
        context->Unmap(stage.Get(),0);
        return correct && worldCount>1000 && (expectMenu ? menuCount>1000 : menuCount==0);
    };
    ID3D11RenderTargetView* bound=rtv.Get(); context->OMSetRenderTargets(1,&bound,nullptr);
    ID3D11ShaderResourceView* sentinel=worldView.Get(); context->PSSetShaderResources(1,1,&sentinel);
    const D3D11_VIEWPORT viewport{3,4,100,80,.2f,.8f}; context->RSSetViewports(1,&viewport);
    const auto stateRestored=[&]() {
        ComPtr<ID3D11RenderTargetView> savedTarget; context->OMGetRenderTargets(1,&savedTarget,nullptr);
        ComPtr<ID3D11ShaderResourceView> savedView; context->PSGetShaderResources(1,1,&savedView);
        D3D11_VIEWPORT savedViewport{}; UINT count=1; context->RSGetViewports(&count,&savedViewport);
        return savedTarget.Get()==rtv.Get() && savedView.Get()==worldView.Get() && count==1 && savedViewport.Width==100;
    };
    Test(blit.BeginMenuFrame(menu.Get(),worldView.Get()),"menu snapshot accepts independent completed stereo background");
    Test(!blit.BeginMenuFrame(menu.Get(),worldView.Get()),"nested menu frame leaves active sources intact");
    Test(blit.RenderMenuEye(eye,f,panel,pointer) && exactPixels(true,96,true),
        "left eye keeps exact world pixels outside opaque stock menu");
    eye.eye=kf2vr::xr::Eye::Right;
    Test(blit.RenderMenuEye(eye,f,panel,pointer) && exactPixels(false,160,true),
        "right eye keeps distinct world pixels without cross-eye seam bleed");
    f.eyeRight.pose.pos={0,0,-2};
    Test(blit.RenderMenuEye(eye,f,panel,pointer) && exactPixels(false,160,false),
        "behind the menu the eye sees its entire stereo world without mirrored text");
    blit.EndFrame(); Test(stateRestored(),"menu composition restores game target, second SRV slot and viewport");
    Test(!blit.BeginMenuFrame(menu.Get(),nullptr) && stateRestored(),"missing world refuses menu composition and restores state");
    Test(!blit.BeginMenuFrame(menu.Get(),worldView.Get(),true,false) && stateRestored(),
        "wrong background colour policy refuses composition without state loss");
    Test(!blit.BeginMenuFrame(world.Get(),worldView.Get()) && stateRestored(),
        "same image cannot masquerade as menu and completed stereo world");
    D3D11_TEXTURE2D_DESC invalidDesc{}; world->GetDesc(&invalidDesc); invalidDesc.Width=15;
    ComPtr<ID3D11Texture2D> oddWorld; ComPtr<ID3D11ShaderResourceView> oddView;
    HR(device->CreateTexture2D(&invalidDesc,nullptr,&oddWorld));
    HR(device->CreateShaderResourceView(oddWorld.Get(),&sv,&oddView));
    Test(!blit.BeginMenuFrame(menu.Get(),oddView.Get()) && stateRestored(),
        "menu mode still rejects an odd-width stereo background");
    D3D11_RENDER_TARGET_VIEW_DESC worldRtvDesc{}; worldRtvDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    worldRtvDesc.ViewDimension=D3D11_RTV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11RenderTargetView> worldRtv; HR(device->CreateRenderTargetView(world.Get(),&worldRtvDesc,&worldRtv));
    Test(blit.BeginMenuFrame(menu.Get(),worldView.Get()),"menu frame opens for background alias guard");
    auto aliasEye=eye; aliasEye.colorView=worldRtv.Get(); aliasEye.width=16; aliasEye.height=8;
    Test(!blit.RenderMenuEye(aliasEye,f,panel,pointer),"eye target cannot overwrite its own stereo background");
    blit.EndFrame(); worldRtv.Reset();
    fillWorld(64,192); context->UpdateSubresource(world.Get(),0,nullptr,worldBytes.data(),16*4,0);
    f.eyeRight.pose.pos={.032f,0,0};
    Test(blit.BeginMenuFrame(menu.Get(),worldView.Get()),"new menu frame borrows the latest completed world");
    Test(blit.RenderMenuEye(eye,f,panel,pointer) && exactPixels(false,192,true),"new world frame replaces previous background pixels");
    blit.OnResize(); Test(stateRestored(),"resize restores state and releases an active menu composition");
    Test(!blit.RenderMenuEye(eye,f,panel,pointer),"resize invalidates the composed menu frame");
    context->ClearState();
    Test(blit.BeginMenuFrame(menu.Get(),worldView.Get()),"menu frame retains its borrowed world resource");
    worldView.Reset(); world.Reset();
    Test(blit.RenderMenuEye(eye,f,panel,pointer) && exactPixels(false,192,true),"borrowed world survives caller releasing both resource references");
    blit.EndFrame();
    Test(blit.BeginFrame(menu.Get(),true,true),"diagnostic menu can follow stereo composition");
    Test(blit.RenderMenuEye(eye,f,panel,pointer) && !exactPixels(false,192,true),"diagnostic menu never reuses a previous stereo background");
    blit.EndFrame(); blit.OnResize(); context->ClearState();
}
void ComfortPixels(ID3D11Device* device,ID3D11DeviceContext* context,kf2vr::adapter::AtlasBlit& blit) {
    D3D11_TEXTURE2D_DESC d{}; d.Width=256; d.Height=128;
    d.MipLevels=d.ArraySize=d.SampleDesc.Count=1; d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    std::vector<unsigned char> bytes(256*128*4,64);
    for(size_t i=3;i<bytes.size();i+=4) bytes[i]=255;
    D3D11_SUBRESOURCE_DATA initial{bytes.data(),256*4,0};
    ComPtr<ID3D11Texture2D> source,target,readback; ComPtr<ID3D11RenderTargetView> rtv;
    HR(device->CreateTexture2D(&d,&initial,&source));
    d.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; d.BindFlags=D3D11_BIND_RENDER_TARGET;
    HR(device->CreateTexture2D(&d,nullptr,&target)); HR(device->CreateRenderTargetView(target.Get(),nullptr,&rtv));
    d.BindFlags=0; d.Usage=D3D11_USAGE_STAGING; d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&d,nullptr,&readback));
    kf2vr::xr::FrameState frame; frame.viewsValid=frame.headPoseValid=frame.headPoseTracked=true;
    frame.eyeLeft.poseValid=frame.eyeRight.poseValid=true;
    frame.eyeLeft.fov=frame.eyeRight.fov={-.7853982f,.7853982f,.7853982f,-.7853982f};
    frame.eyeLeft.pose.pos={-.032f,0,0}; frame.eyeRight.pose.pos={.032f,0,0};
    frame.predictedDisplayTime=12;
    kf2vr::xr::D3D11EyeTarget eye; eye.width=256; eye.height=128; eye.colorView=rtv.Get();
    const auto render=[&](kf2vr::xr::Eye side,kf2vr::adapter::ComfortEffects effects) {
        eye.eye=side; blit.SetComfortEffects(frame,effects);
        Test(blit.BeginFrame(source.Get(),true,true) && blit.RenderEye(eye),"comfort effect renders on real D3D11 pipeline");
        blit.EndFrame(); context->CopyResource(readback.Get(),target.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{}; HR(context->Map(readback.Get(),0,D3D11_MAP_READ,0,&mapped));
        std::vector<unsigned char> result(bytes.size());
        for(unsigned y=0;y<128;++y) std::memcpy(result.data()+y*1024,static_cast<unsigned char*>(mapped.pData)+y*mapped.RowPitch,1024);
        context->Unmap(readback.Get(),0); return result;
    };
    const auto clear=render(kf2vr::xr::Eye::Left,{});
    const auto clearRight=render(kf2vr::xr::Eye::Right,{});
    // Exercise the production shader: every retired custom channel, including
    // healing and focus, must preserve the stock atlas pixels in both eyes.
    for(int effect=0;effect<11;++effect) {
        kf2vr::adapter::ComfortEffects fx;
        if(effect==0 || effect==10) fx.puke=1;
        if(effect==1 || effect==10) fx.fire=1;
        if(effect==2 || effect==10) fx.damage=1;
        if(effect==3 || effect==10) fx.heal=1;
        if(effect==4 || effect==10) fx.energy=1;
        if(effect==5 || effect==10) fx.rage=1;
        if(effect==6 || effect==10) fx.flash=1;
        if(effect==7 || effect==10) fx.nightVision=1;
        if(effect==8 || effect==10) fx.focus=1;
        if(effect==9 || effect==10) fx.blood=1;
        Test(render(kf2vr::xr::Eye::Left,fx)==clear && render(kf2vr::xr::Eye::Right,fx)==clearRight,
            "retired custom status/focus inputs preserve exact stock pixels in both eyes");
    }
    kf2vr::adapter::ComfortEffects fx; fx.blink=1;
    const auto blinkLeft=render(kf2vr::xr::Eye::Left,fx),blinkRight=render(kf2vr::xr::Eye::Right,fx);
    bool black=true;
    for(size_t i=0;i<blinkLeft.size();i+=4)
        black &= blinkLeft[i]==0 && blinkLeft[i+1]==0 && blinkLeft[i+2]==0;
    Test(black && blinkLeft==blinkRight,"existing teleport/spectator blink still fades both eyes to black");
    frame.headPoseTracked=false;
    Test(render(kf2vr::xr::Eye::Left,fx)==blinkLeft,"transition blink still works without head tracking");
    Test(render(kf2vr::xr::Eye::Left,{})==clear,"ending the transition restores original stock pixels");
    blit.SetComfortEffects({},{}); blit.OnResize(); context->ClearState();
}
int main() {
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
    UINT flags=D3D11_CREATE_DEVICE_DEBUG;
    HRESULT h=D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,flags,&level,1,D3D11_SDK_VERSION,&device,nullptr,&context);
    if(h==DXGI_ERROR_SDK_COMPONENT_MISSING) { flags=0; h=D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,flags,&level,1,D3D11_SDK_VERSION,&device,nullptr,&context); }
    HR(h);
    kf2vr::adapter::AtlasBlit blit;
    Test(blit.Initialise(device.Get(),context.Get()),"initialize AtlasBlit WARP");
    if(!blit.LastError().empty()) std::puts(blit.LastError().c_str());
    if(failures) return 1;
    D3D11_TEXTURE2D_DESC out{};
    out.Width=16; out.Height=8; out.MipLevels=out.ArraySize=1; out.SampleDesc.Count=1;
    out.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; out.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> target,stage;
    ComPtr<ID3D11RenderTargetView> targetView;
    HR(device->CreateTexture2D(&out,nullptr,&target)); HR(device->CreateRenderTargetView(target.Get(),nullptr,&targetView));
    out.Usage=D3D11_USAGE_STAGING; out.BindFlags=0; out.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&out,nullptr,&stage));
    auto pixels=[&](bool left,int value) {
        context->CopyResource(stage.Get(),target.Get());
        D3D11_MAPPED_SUBRESOURCE map{}; HR(context->Map(stage.Get(),0,D3D11_MAP_READ,0,&map));
        bool correct=true;
        for(UINT y=0;y<8;++y) for(UINT x=0;x<16;++x) {
            auto* p=(unsigned char*)map.pData+y*map.RowPitch+x*4;
            correct=correct && std::abs(int(p[left?0:1])-value)<=1 && p[left?1:0]==0 && p[2]==0 && p[3]==255;
        }
        context->Unmap(stage.Get(),0); return correct;
    };
    const DXGI_FORMAT formats[]{DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,DXGI_FORMAT_R8G8B8A8_TYPELESS,
        DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,DXGI_FORMAT_B8G8R8A8_TYPELESS,
        DXGI_FORMAT_B8G8R8X8_UNORM,DXGI_FORMAT_B8G8R8X8_UNORM_SRGB,DXGI_FORMAT_B8G8R8X8_TYPELESS};
    for(const auto format:formats) {
        const bool bgra=format==DXGI_FORMAT_B8G8R8A8_UNORM||format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB||format==DXGI_FORMAT_B8G8R8A8_TYPELESS||format==DXGI_FORMAT_B8G8R8X8_UNORM||format==DXGI_FORMAT_B8G8R8X8_UNORM_SRGB||format==DXGI_FORMAT_B8G8R8X8_TYPELESS;
        D3D11_TEXTURE2D_DESC desc{}; desc.Width=8; desc.Height=4; desc.MipLevels=desc.ArraySize=1; desc.SampleDesc.Count=1; desc.Format=format; desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
        std::array<unsigned char,8*4*4> bytes{};
        for(UINT y=0;y<4;++y) for(UINT x=0;x<8;++x) { auto* p=bytes.data()+(y*8+x)*4; p[x<4?(bgra?2:0):1]=128; p[3]=255; }
        D3D11_SUBRESOURCE_DATA init{bytes.data(),8*4,0};
        ComPtr<ID3D11Texture2D> source; HR(device->CreateTexture2D(&desc,&init,&source));
        D3D11_RENDER_TARGET_VIEW_DESC rv{}; rv.ViewDimension=D3D11_RTV_DIMENSION_TEXTURE2D;
        rv.Format=bgra?(format==DXGI_FORMAT_B8G8R8X8_TYPELESS||format==DXGI_FORMAT_B8G8R8X8_UNORM||format==DXGI_FORMAT_B8G8R8X8_UNORM_SRGB?DXGI_FORMAT_B8G8R8X8_UNORM:DXGI_FORMAT_B8G8R8A8_UNORM):DXGI_FORMAT_R8G8B8A8_UNORM;
        if(format==DXGI_FORMAT_R8G8B8A8_UNORM_SRGB||format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB||format==DXGI_FORMAT_B8G8R8X8_UNORM_SRGB) rv.Format=format;
        ComPtr<ID3D11RenderTargetView> sentinel; HR(device->CreateRenderTargetView(source.Get(),&rv,&sentinel));
        ID3D11RenderTargetView* bound=sentinel.Get(); context->OMSetRenderTargets(1,&bound,nullptr);
        D3D11_VIEWPORT viewport{3,4,5,6,.2f,.8f}; context->RSSetViewports(1,&viewport);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);
        Test(blit.BeginFrame(source.Get()),"begin/snapshot with source bound as game render target");
        for(int eye=0;eye<2;++eye) {
            kf2vr::xr::D3D11EyeTarget view; view.eye=eye? kf2vr::xr::Eye::Right:kf2vr::xr::Eye::Left;
            view.width=16; view.height=8; view.colorView=targetView.Get(); view.colorTexture=target.Get(); view.colorFormat=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
            Test(blit.RenderEye(view),"render scaled atlas eye");
            Test(pixels(eye==0,128),"all pixels: correct eye and exact sRGB midtone; no boundary bleed");
        }
        blit.EndFrame();
        ComPtr<ID3D11RenderTargetView> restored; context->OMGetRenderTargets(1,&restored,nullptr);
        Test(restored.Get()==sentinel.Get(),"game render target restored");
        D3D11_VIEWPORT got{}; UINT n=1; context->RSGetViewports(&n,&got);
        Test(n==1 && got.TopLeftX==3 && got.TopLeftY==4 && got.Width==5 && got.Height==6 && got.MinDepth==.2f && got.MaxDepth==.8f,"game viewport restored");
        D3D11_PRIMITIVE_TOPOLOGY topology{}; context->IAGetPrimitiveTopology(&topology);
        Test(topology==D3D11_PRIMITIVE_TOPOLOGY_LINELIST,"game topology restored");
        // Returning false from BeginFrame must restore the saved game pipeline.
        Test(!blit.BeginFrame(nullptr),"null source fails safely");
        restored.Reset(); context->OMGetRenderTargets(1,&restored,nullptr);
        Test(restored.Get()==sentinel.Get(),"game render target restored after failed snapshot");
        // The direct view must supply the declared colour decoding. Typed
        // UNORM uses the explicit linear policy; typeless and sRGB use sRGB.
        const bool encoded=format!=DXGI_FORMAT_R8G8B8A8_UNORM && format!=DXGI_FORMAT_B8G8R8A8_UNORM && format!=DXGI_FORMAT_B8G8R8X8_UNORM;
        D3D11_SHADER_RESOURCE_VIEW_DESC sv{}; sv.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D; sv.Texture2D.MipLevels=1;
        sv.Format=encoded ? (rv.Format==DXGI_FORMAT_R8G8B8A8_UNORM ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB :
            rv.Format==DXGI_FORMAT_B8G8R8A8_UNORM ? DXGI_FORMAT_B8G8R8A8_UNORM_SRGB :
            rv.Format==DXGI_FORMAT_B8G8R8X8_UNORM ? DXGI_FORMAT_B8G8R8X8_UNORM_SRGB : rv.Format) : rv.Format;
        ComPtr<ID3D11ShaderResourceView> sourceView; HR(device->CreateShaderResourceView(source.Get(),&sv,&sourceView));
        Test(blit.BeginFrameView(sourceView.Get(),encoded),"begin direct atlas with source bound as game target");
        Test(!blit.BeginFrame(source.Get(),true,true),"nested snapshot rejected without changing direct stereo mode");
        for(int eye=0;eye<2;++eye) {
            kf2vr::xr::D3D11EyeTarget view; view.eye=eye?kf2vr::xr::Eye::Right:kf2vr::xr::Eye::Left;
            view.width=16; view.height=8; view.colorView=targetView.Get();
            Test(blit.RenderEye(view),"direct atlas eye renders");
            Test(pixels(eye==0,encoded?128:188),"direct atlas keeps eye separation, format channels and exact colour policy");
        }
        blit.EndFrame();
        restored.Reset(); context->OMGetRenderTargets(1,&restored,nullptr);
        context->RSGetViewports(&n,&got); context->IAGetPrimitiveTopology(&topology);
        Test(restored.Get()==sentinel.Get() && got.Width==5 && topology==D3D11_PRIMITIVE_TOPOLOGY_LINELIST,"direct atlas restores game pipeline");
        Test(!blit.BeginFrameView(sourceView.Get(),!encoded),"direct view rejects opposite colour policy");
        restored.Reset(); context->OMGetRenderTargets(1,&restored,nullptr);
        Test(restored.Get()==sentinel.Get(),"failed direct view restores game render target");
        Test(!blit.BeginFrameView(nullptr),"null direct view fails safely");
        blit.OnResize(); context->ClearState();
    }
    // Explicit linear source policy: .502 linear should encode to about 188 sRGB.
    D3D11_TEXTURE2D_DESC desc{}; desc.Width=8; desc.Height=4; desc.MipLevels=desc.ArraySize=1; desc.SampleDesc.Count=1; desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    std::array<unsigned char,8*4*4> bytes{}; for(size_t i=0;i<bytes.size();i+=4) { bytes[i]=128; bytes[i+3]=255; }
    D3D11_SUBRESOURCE_DATA init{bytes.data(),32,0}; ComPtr<ID3D11Texture2D> linear; HR(device->CreateTexture2D(&desc,&init,&linear));
    Test(blit.BeginFrame(linear.Get(),false),"explicit linear source begins");
    kf2vr::xr::D3D11EyeTarget eye; eye.width=16; eye.height=8; eye.colorView=targetView.Get();
    Test(blit.RenderEye(eye),"linear source renders"); Test(pixels(true,188),"linear source sRGB-encodes exactly once"); blit.EndFrame();
    // Switching to a larger borrowed atlas must not overwrite the dimensions
    // of the cached 8x4 snapshot, or the next snapshot could reuse the wrong size.
    Test(blit.BeginFrame(linear.Get()),"prime small sRGB snapshot cache before direct atlas"); blit.EndFrame();
    D3D11_TEXTURE2D_DESC directDesc=desc; directDesc.Width=16; directDesc.Height=8;
    directDesc.Format=DXGI_FORMAT_R8G8B8A8_TYPELESS;
    directDesc.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> direct; HR(device->CreateTexture2D(&directDesc,nullptr,&direct));
    // Match SnapshotEye: copy each typed UNORM eye into one half of a
    // typeless shader-readable atlas, then decode its sRGB view exactly once.
    D3D11_TEXTURE2D_DESC eyeDesc=directDesc; eyeDesc.Width=8;
    eyeDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM; eyeDesc.BindFlags=D3D11_BIND_RENDER_TARGET;
    std::array<ComPtr<ID3D11Texture2D>,2> sourceEyes;
    for(UINT i=0;i<2;++i) {
        std::array<unsigned char,8*8*4> eyeBytes{};
        for(size_t p=0;p<eyeBytes.size();p+=4) { eyeBytes[p+i]=128; eyeBytes[p+3]=255; }
        D3D11_SUBRESOURCE_DATA eyeInit{eyeBytes.data(),8*4,0};
        HR(device->CreateTexture2D(&eyeDesc,&eyeInit,&sourceEyes[i]));
        context->CopySubresourceRegion(direct.Get(),0,i*eyeDesc.Width,0,0,sourceEyes[i].Get(),0,nullptr);
    }
    D3D11_SHADER_RESOURCE_VIEW_DESC directSv{}; directSv.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    directSv.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D; directSv.Texture2D.MipLevels=1;
    ComPtr<ID3D11ShaderResourceView> directView; HR(device->CreateShaderResourceView(direct.Get(),&directSv,&directView));
    D3D11_RENDER_TARGET_VIEW_DESC directRv{}; directRv.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    directRv.ViewDimension=D3D11_RTV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11RenderTargetView> directTarget; HR(device->CreateRenderTargetView(direct.Get(),&directRv,&directTarget));
    Test(blit.BeginFrameView(directView.Get()),"borrow larger atlas after small cached snapshot");
    eye.colorView=directTarget.Get();
    Test(!blit.RenderEye(eye),"direct source cannot also be the eye output");
    eye.colorView=targetView.Get();
    Test(blit.RenderEye(eye) && pixels(true,128),"copied typed UNORM left eye keeps its sRGB midtone after alias rejection");
    eye.eye=kf2vr::xr::Eye::Right;
    Test(blit.RenderEye(eye) && pixels(false,128),"copied typed UNORM right eye keeps its sRGB midtone");
    blit.EndFrame();
    Test(blit.BeginFrame(direct.Get()),"snapshot after borrowed atlas uses its own allocation dimensions");
    for(int i=0;i<2;++i) {
        eye.eye=i?kf2vr::xr::Eye::Right:kf2vr::xr::Eye::Left;
        Test(blit.RenderEye(eye) && pixels(i==0,128),"borrowed-to-snapshot transition preserves both eye pixels");
    }
    blit.EndFrame();
    Test(blit.BeginFrame(linear.Get(),false,true),"full-frame snapshot after direct stereo path");
    Test(blit.RenderEye(eye) && pixels(true,188),"full-frame right eye still uses the whole source");
    blit.EndFrame();
    Test(blit.BeginFrameView(directView.Get()),"direct stereo after full-frame snapshot");
    Test(blit.RenderEye(eye) && pixels(false,128),"direct path resets full-frame mode");
    blit.EndFrame();
    ID3D11RenderTargetView* resizeSentinel=targetView.Get(); context->OMSetRenderTargets(1,&resizeSentinel,nullptr);
    Test(blit.BeginFrameView(directView.Get()),"direct atlas active before resize");
    blit.OnResize();
    ComPtr<ID3D11RenderTargetView> resizeRestored; context->OMGetRenderTargets(1,&resizeRestored,nullptr);
    Test(resizeRestored.Get()==targetView.Get(),"resize restores pipeline during borrowed frame");
    Test(!blit.RenderEye(eye),"resize ends borrowed frame");
    Test(blit.BeginFrameView(directView.Get()),"borrowed frame retains its own view and resource references");
    directTarget.Reset(); directView.Reset(); direct.Reset();
    Test(blit.RenderEye(eye) && pixels(false,128),"direct rendering survives caller releasing source references");
    blit.EndFrame();
    // Invalid geometry and a valid view on another device must fail cleanly.
    directDesc.Width=7;
    HR(device->CreateTexture2D(&directDesc,nullptr,&direct));
    HR(device->CreateShaderResourceView(direct.Get(),&directSv,&directView));
    Test(!blit.BeginFrameView(directView.Get()),"odd-width direct stereo atlas rejected");
    directDesc.Width=8; directDesc.MipLevels=2; directView.Reset(); direct.Reset();
    HR(device->CreateTexture2D(&directDesc,nullptr,&direct));
    directSv.Texture2D.MostDetailedMip=1;
    HR(device->CreateShaderResourceView(direct.Get(),&directSv,&directView));
    Test(!blit.BeginFrameView(directView.Get()),"nonzero direct mip rejected");
    directView.Reset(); directSv.Texture2D.MostDetailedMip=0;
    HR(device->CreateShaderResourceView(direct.Get(),&directSv,&directView));
    Test(!blit.BeginFrameView(directView.Get()),"multi-mip source rejected even through a single-mip view");
    directDesc.MipLevels=1;
    ComPtr<ID3D11Device> otherDevice; ComPtr<ID3D11DeviceContext> otherContext;
    HR(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,&level,1,D3D11_SDK_VERSION,&otherDevice,nullptr,&otherContext));
    directDesc.Width=8; direct.Reset(); directView.Reset();
    HR(otherDevice->CreateTexture2D(&directDesc,nullptr,&direct));
    HR(otherDevice->CreateShaderResourceView(direct.Get(),&directSv,&directView));
    Test(!blit.BeginFrameView(directView.Get()),"direct source from another device rejected");
    resizeRestored.Reset(); context->OMGetRenderTargets(1,&resizeRestored,nullptr);
    Test(resizeRestored.Get()==targetView.Get(),"direct validation failures restore game render target");
    eye.eye=kf2vr::xr::Eye::Left;
    // Real 4x MSAA source resolve, all samples initialized with an sRGB red clear.
    desc.SampleDesc.Count=4; desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE; desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    ComPtr<ID3D11Texture2D> msaa; ComPtr<ID3D11RenderTargetView> msaaView;
    HR(device->CreateTexture2D(&desc,nullptr,&msaa)); HR(device->CreateRenderTargetView(msaa.Get(),nullptr,&msaaView));
    const float clear[]{.2158605f,0,0,1}; context->ClearRenderTargetView(msaaView.Get(),clear);
    Test(blit.BeginFrame(msaa.Get()),"4x MSAA source resolves"); Test(blit.RenderEye(eye),"resolved source renders"); Test(pixels(true,128),"MSAA midtone correct"); blit.EndFrame();
    ComPtr<ID3D11ShaderResourceView> msaaSourceView; HR(device->CreateShaderResourceView(msaa.Get(),nullptr,&msaaSourceView));
    Test(!blit.BeginFrameView(msaaSourceView.Get()),"multisampled view requires the snapshot/resolve path");
    blit.OnResize(); context->ClearState();
    MenuPixels(device.Get(),context.Get(),blit);
    MenuWorldPixels(device.Get(),context.Get(),blit);
    ComfortPixels(device.Get(),context.Get(),blit);
    blit.Shutdown(); context->ClearState();
    ComPtr<ID3D11InfoQueue> queue;
    if(SUCCEEDED(device.As(&queue))) {
        unsigned errors=0;
        for(UINT64 i=0;i<queue->GetNumStoredMessages();++i) {
            SIZE_T size=0; queue->GetMessage(i,nullptr,&size); std::vector<unsigned char> data(size); auto* message=(D3D11_MESSAGE*)data.data(); queue->GetMessage(i,message,&size);
            if(message->Severity<=D3D11_MESSAGE_SEVERITY_WARNING) { ++errors; std::printf("D3D debug: %s\n",message->pDescription); }
        }
        Test(errors==0,"no D3D11 debug errors or warnings");
    }
    std::printf("Atlas checks=%d failures=%d debug_layer=%u\n",checks,failures,flags!=0); return failures?1:0;
}
