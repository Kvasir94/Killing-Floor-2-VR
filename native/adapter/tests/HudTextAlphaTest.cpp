#include <windows.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "HudTextAlpha.h"
using Microsoft::WRL::ComPtr;
int checks=0,failures=0;
void Test(bool value,const char* label) { ++checks;if(!value) { ++failures;std::printf("FAIL %s\n",label); } }
void HR(HRESULT h) { if(FAILED(h)) { std::printf("HRESULT %08lx\n",(unsigned long)h);std::exit(2); } }
int main() {
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    HR(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
    const char* shader=R"(
float4 VS(uint id:SV_VertexID):SV_POSITION { return float4(id==2?3:-1,id==1?3:-1,0,1); }
float4 PS():SV_TARGET { return float4(1,0,0,0.5); }
)";
    ComPtr<ID3DBlob> vs,ps;
    HR(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"VS","vs_5_0",0,0,&vs,nullptr));
    HR(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"PS","ps_5_0",0,0,&ps,nullptr));
    ComPtr<ID3D11VertexShader> vertexShader;ComPtr<ID3D11PixelShader> pixelShader;
    HR(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertexShader));
    HR(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixelShader));
    context->VSSetShader(vertexShader.Get(),nullptr,0);context->PSSetShader(pixelShader.Get(),nullptr,0);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    D3D11_RASTERIZER_DESC raster{};raster.FillMode=D3D11_FILL_SOLID;raster.CullMode=D3D11_CULL_NONE;raster.DepthClipEnable=TRUE;
    ComPtr<ID3D11RasterizerState> rasterState;HR(device->CreateRasterizerState(&raster,&rasterState));context->RSSetState(rasterState.Get());
    struct Target { ComPtr<ID3D11Texture2D> texture;ComPtr<ID3D11RenderTargetView> view; };
    const auto makeTarget=[&](unsigned width,unsigned height) {
        D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;
        d.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;d.BindFlags=D3D11_BIND_RENDER_TARGET;
        Target target;HR(device->CreateTexture2D(&d,nullptr,&target.texture));
        HR(device->CreateRenderTargetView(target.texture.Get(),nullptr,&target.view));return target;
    };
    auto panel=makeTarget(1024,512),other=makeTarget(1024,512);
    D3D11_BLEND_DESC bd{};bd.IndependentBlendEnable=TRUE;auto& rt=bd.RenderTarget[0];rt.BlendEnable=TRUE;
    rt.SrcBlend=D3D11_BLEND_SRC_ALPHA;rt.DestBlend=D3D11_BLEND_INV_SRC_ALPHA;rt.BlendOp=D3D11_BLEND_OP_ADD;
    rt.SrcBlendAlpha=D3D11_BLEND_ZERO;rt.DestBlendAlpha=D3D11_BLEND_ONE;rt.BlendOpAlpha=D3D11_BLEND_OP_ADD;
    rt.RenderTargetWriteMask=7;
    ComPtr<ID3D11BlendState> stock;HR(device->CreateBlendState(&bd,&stock));
    const FLOAT factors[]{.2f,.3f,.4f,.5f};context->OMSetBlendState(stock.Get(),factors,0xffffffff);
    kf2vr::adapter::HudTextAlpha alpha;
    const FLOAT transparent[]{0,0,0,0},backing[]{0,0,0,70.f/255};
    const auto draw=[&](const Target& target) {
        D3D11_TEXTURE2D_DESC d{};target.texture->GetDesc(&d);
        D3D11_VIEWPORT viewport{0,0,static_cast<float>(d.Width),static_cast<float>(d.Height),0,1};
        context->RSSetViewports(1,&viewport);
        auto* view=target.view.Get();
        context->OMSetRenderTargets(1,&view,nullptr);alpha.Targets(context.Get(),1,&view);
        context->ClearRenderTargetView(view,backing);
        kf2vr::adapter::HudTextAlpha::DrawScope scope;alpha.BeforeDraw(context.Get(),scope);context->Draw(3,0);
    };
    const auto pixel=[&](const Target& source,unsigned expectedAlpha) {
        D3D11_TEXTURE2D_DESC d{};source.texture->GetDesc(&d);
        d.Usage=D3D11_USAGE_STAGING;d.BindFlags=0;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;d.MiscFlags=0;
        ComPtr<ID3D11Texture2D> read;HR(device->CreateTexture2D(&d,nullptr,&read));
        context->CopyResource(read.Get(),source.texture.Get());
        D3D11_MAPPED_SUBRESOURCE m{};HR(context->Map(read.Get(),0,D3D11_MAP_READ,0,&m));
        const auto* p=static_cast<const unsigned char*>(m.pData)+20*m.RowPitch+20*4;
        const bool correct=p[0]>=187 && p[0]<=189 && p[1]==0 && p[2]==0
            && std::abs(int(p[3])-int(expectedAlpha))<=1;
        if(!correct) std::printf("Pixel RGBA=%u,%u,%u,%u expected alpha=%u\n",p[0],p[1],p[2],p[3],expectedAlpha);
        context->Unmap(read.Get(),0);return correct;
    };
    const auto checkDraw=[&](const Target& target,unsigned expectedAlpha,const char* label) {
        draw(target);Test(pixel(target,expectedAlpha),label);
    };
    int panelOwner=0,inputOwner=0,foreignOwner=0,newInputOwner=0;
    alpha.Clear(context.Get(),panel.view.Get(),transparent);
    Test(!alpha.RegisterPanel(0,&panelOwner,&panelOwner,800,320),"wrong owned Canvas dimensions cannot register the last clear");
    checkDraw(panel,70,"rejected dimensions leave the target's stock alpha intact");
    alpha.Clear(context.Get(),panel.view.Get(),transparent);
    Test(!alpha.RegisterPanel(0,nullptr,nullptr,1024,512),"two missing owner pointers do not establish HUD ownership");
    alpha.Clear(context.Get(),panel.view.Get(),transparent);
    Test(!alpha.RegisterPanel(0,&panelOwner,&panelOwner,756,512),"obsolete narrow watch dimensions are rejected");
    alpha.Clear(context.Get(),panel.view.Get(),transparent);
    Test(alpha.RegisterPanel(0,&panelOwner,&panelOwner,1024,512),"owned Canvas callback registers its transparent HUD target");
    checkDraw(panel,163,"glyph coverage updates alpha over translucent backing without changing RGB");
    ComPtr<ID3D11BlendState> restored;FLOAT restoredFactors[4]{};UINT mask=0;
    context->OMGetBlendState(&restored,restoredFactors,&mask);
    Test(restored.Get()==stock.Get() && mask==0xffffffff && std::memcmp(factors,restoredFactors,sizeof(factors))==0,"draw restores exact stock blend state, factors and sample mask");
    checkDraw(other,70,"same-size unregistered HUD texture retains stock alpha behavior");
    alpha.Clear(context.Get(),other.view.Get(),backing);
    Test(!alpha.RegisterPanel(0,&panelOwner,&panelOwner,1024,512),"nontransparent clear cannot register a panel");

    auto ammoLeft=makeTarget(800,320),ammoRight=makeTarget(800,320),session=makeTarget(1024,512),alert=makeTarget(1024,256);
    const Target* extraPanels[]{&ammoLeft,&ammoRight,&session,&alert};
    for(int i=0;i<4;++i) {
        const auto& target=*extraPanels[i];
        alpha.Clear(context.Get(),target.view.Get(),transparent);
        Test(alpha.RegisterPanel(i+1,&panelOwner,&panelOwner,
            float(kf2vr::adapter::HudTextAlpha::PanelWidth[i+1]),float(kf2vr::adapter::HudTextAlpha::PanelHeight[i+1])),
            "each remaining HUD slot, including session and alert, registers independently");
    }
    alpha.Clear(context.Get(),session.view.Get(),transparent);
    Test(!alpha.RegisterPanel(4,&panelOwner,&panelOwner,1024,512),"alert slot rejects the session module's dimensions");
    auto left=makeTarget(768,768),right=makeTarget(768,768),foreign=makeTarget(768,768);
    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterSelector(0,nullptr,nullptr,768,768),"missing hand-input owner cannot register a selector");
    checkDraw(foreign,70,"an unowned selector-sized texture retains stock alpha");
    alpha.Clear(context.Get(),left.view.Get(),transparent);
    Test(alpha.RegisterSelector(0,&inputOwner,&inputOwner,768,768),"left hand registers its selector");
    alpha.Clear(context.Get(),right.view.Get(),transparent);
    Test(alpha.RegisterSelector(1,&inputOwner,&inputOwner,768,768),"right hand registers its selector");
    checkDraw(left,163,"left selector receives glyph coverage alpha");
    checkDraw(right,163,"right selector receives glyph coverage alpha independently");
    checkDraw(panel,163,"selector registration preserves the status HUD slot");
    for(const auto* target:extraPanels) checkDraw(*target,163,"selector slots do not replace other HUD targets");

    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterSelector(0,&foreignOwner,&inputOwner,768,768),"foreign input owner cannot claim a selector");
    checkDraw(foreign,70,"foreign owner's texture is not modified");
    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterSelector(-1,&inputOwner,&inputOwner,768,768),"negative hand is rejected");
    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterSelector(2,&inputOwner,&inputOwner,768,768),"out-of-range hand is rejected");
    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterPanel(12,&panelOwner,&panelOwner,768,768),"HUD indices cannot access selector slots");
    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterSelector(0,&inputOwner,&inputOwner,640,383),"selector Canvas dimensions must match exactly");
    checkDraw(foreign,70,"invalid slot and Canvas registrations leave unrelated textures alone");
    alpha.Clear(context.Get(),other.view.Get(),transparent);
    Test(!alpha.RegisterSelector(0,&inputOwner,&inputOwner,768,768),"selector cannot register a differently sized cleared resource");
    checkDraw(other,70,"resource-size mismatch preserves the unregistered HUD texture");

    auto newRight=makeTarget(768,768);
    alpha.Clear(context.Get(),newRight.view.Get(),transparent);
    Test(alpha.RegisterSelector(1,&inputOwner,&inputOwner,768,768),"right selector replacement registers");
    checkDraw(right,70,"replaced selector resource no longer receives alpha correction");
    checkDraw(newRight,163,"replacement right selector receives alpha correction");
    checkDraw(left,163,"right selector replacement leaves the left selector registered");
    checkDraw(panel,163,"selector replacement preserves HUD ownership");

    auto newLeft=makeTarget(768,768);
    alpha.Clear(context.Get(),newLeft.view.Get(),transparent);
    Test(alpha.RegisterSelector(0,&newInputOwner,&newInputOwner,768,768),"new input owner can register its selector");
    checkDraw(left,70,"input-owner change releases the old left selector");
    checkDraw(newRight,70,"input-owner change releases the old right selector");
    checkDraw(newLeft,163,"new owner's selector receives alpha correction");
    checkDraw(panel,163,"input-owner change leaves HUD targets registered");
    alpha.Clear(context.Get(),foreign.view.Get(),transparent);
    Test(!alpha.RegisterSelector(0,&newInputOwner,nullptr,768,768),"missing current input owner rejects stale callbacks");
    checkDraw(newLeft,70,"loss of input ownership removes the previous selector correction");
    context->ClearState();std::printf("HUD alpha checks=%d failures=%d\n",checks,failures);return failures?1:0;
}
