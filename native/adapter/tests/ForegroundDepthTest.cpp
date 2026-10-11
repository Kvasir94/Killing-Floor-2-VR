#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "ForegroundDepth.h"
using Microsoft::WRL::ComPtr;
namespace {
int checks=0, failures=0;
void Test(bool value,const char* label) { ++checks;if(!value) { ++failures;std::printf("FAIL %s\n",label); } }
void HR(HRESULT h) { if(FAILED(h)) { std::printf("HRESULT %08lx\n",(unsigned long)h);std::exit(2); } }
struct Vertex { float x,y,z,r,g,b; };
}
int main() {
    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    HR(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
    const char* shader=R"(
struct V { float3 p:POSITION; float3 c:COLOR; };
struct P { float4 p:SV_POSITION; float3 c:COLOR; };
P VS(V v) { P p;p.p=float4(v.p,1);p.c=v.c;return p; }
float4 PS(P p):SV_TARGET { return float4(p.c,1); }
)";
    ComPtr<ID3DBlob> vs,ps;
    HR(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"VS","vs_5_0",0,0,&vs,nullptr));
    HR(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"PS","ps_5_0",0,0,&ps,nullptr));
    ComPtr<ID3D11VertexShader> vertexShader;ComPtr<ID3D11PixelShader> pixelShader;
    HR(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertexShader));
    HR(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixelShader));
    const D3D11_INPUT_ELEMENT_DESC elements[]{
        {"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0},
        {"COLOR",0,DXGI_FORMAT_R32G32B32_FLOAT,0,12,D3D11_INPUT_PER_VERTEX_DATA,0}};
    ComPtr<ID3D11InputLayout> layout;
    HR(device->CreateInputLayout(elements,2,vs->GetBufferPointer(),vs->GetBufferSize(),&layout));
    D3D11_BUFFER_DESC vb{};vb.ByteWidth=sizeof(Vertex)*6;vb.Usage=D3D11_USAGE_DYNAMIC;
    vb.BindFlags=D3D11_BIND_VERTEX_BUFFER;vb.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
    ComPtr<ID3D11Buffer> vertices;HR(device->CreateBuffer(&vb,nullptr,&vertices));
    ID3D11Buffer* buffer=vertices.Get();UINT stride=sizeof(Vertex),offset=0;
    context->IASetVertexBuffers(0,1,&buffer,&stride,&offset);context->IASetInputLayout(layout.Get());
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vertexShader.Get(),nullptr,0);context->PSSetShader(pixelShader.Get(),nullptr,0);
    D3D11_RASTERIZER_DESC raster{};raster.FillMode=D3D11_FILL_SOLID;raster.CullMode=D3D11_CULL_NONE;raster.DepthClipEnable=TRUE;
    ComPtr<ID3D11RasterizerState> rasterState;HR(device->CreateRasterizerState(&raster,&rasterState));context->RSSetState(rasterState.Get());
    D3D11_TEXTURE2D_DESC td{};td.Width=8;td.Height=4;td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;
    td.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;td.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> color,depth,colorRead,depthRead,ui;
    ComPtr<ID3D11RenderTargetView> rtv,uiRtv;
    HR(device->CreateTexture2D(&td,nullptr,&color));HR(device->CreateRenderTargetView(color.Get(),nullptr,&rtv));
    td.Usage=D3D11_USAGE_STAGING;td.BindFlags=0;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&td,nullptr,&colorRead));
    td.Usage=D3D11_USAGE_DEFAULT;td.CPUAccessFlags=0;td.BindFlags=D3D11_BIND_RENDER_TARGET;td.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    HR(device->CreateTexture2D(&td,nullptr,&ui));HR(device->CreateRenderTargetView(ui.Get(),nullptr,&uiRtv));
    td.Format=DXGI_FORMAT_R24G8_TYPELESS;td.BindFlags=D3D11_BIND_DEPTH_STENCIL;
    HR(device->CreateTexture2D(&td,nullptr,&depth));
    td.Usage=D3D11_USAGE_STAGING;td.BindFlags=0;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&td,nullptr,&depthRead));
    D3D11_DEPTH_STENCIL_VIEW_DESC dd{};dd.Format=DXGI_FORMAT_D24_UNORM_S8_UINT;dd.ViewDimension=D3D11_DSV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11DepthStencilView> dsv;HR(device->CreateDepthStencilView(depth.Get(),&dd,&dsv));
    D3D11_DEPTH_STENCIL_DESC ds{};ds.DepthEnable=TRUE;ds.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ALL;ds.DepthFunc=D3D11_COMPARISON_LESS_EQUAL;
    ds.StencilEnable=TRUE;ds.StencilReadMask=ds.StencilWriteMask=255;
    ds.FrontFace={D3D11_STENCIL_OP_KEEP,D3D11_STENCIL_OP_KEEP,D3D11_STENCIL_OP_REPLACE,D3D11_COMPARISON_ALWAYS};ds.BackFace=ds.FrontFace;
    ComPtr<ID3D11DepthStencilState> depthState;HR(device->CreateDepthStencilState(&ds,&depthState));
    D3D11_VIEWPORT viewport{0,0,8,4,0,1};context->RSSetViewports(1,&viewport);
    const auto bind=[&](ID3D11RenderTargetView* view) { context->OMSetRenderTargets(1,&view,dsv.Get()); };
    const auto draw=[&](float left,float right,float z,float red,float green,UINT stencil) {
        const Vertex v[]{{left,-1,z,red,green,0},{left,1,z,red,green,0},{right,1,z,red,green,0},
                         {left,-1,z,red,green,0},{right,1,z,red,green,0},{right,-1,z,red,green,0}};
        D3D11_MAPPED_SUBRESOURCE map{};HR(context->Map(vertices.Get(),0,D3D11_MAP_WRITE_DISCARD,0,&map));
        std::memcpy(map.pData,v,sizeof(v));context->Unmap(vertices.Get(),0);
        context->OMSetDepthStencilState(depthState.Get(),stencil);context->Draw(6,0);
    };
    kf2vr::adapter::ForegroundDepth policy;
    const auto clear=[&](bool expected) {
        UINT flags=D3D11_CLEAR_DEPTH|D3D11_CLEAR_STENCIL;
        Test(policy.Filter(context.Get(),dsv.Get(),flags,1,0)==expected,"clear selection");
        Test(flags==UINT(expected?D3D11_CLEAR_STENCIL:(D3D11_CLEAR_DEPTH|D3D11_CLEAR_STENCIL)),"clear flags");
        context->ClearDepthStencilView(dsv.Get(),flags,1,0);
    };
    bind(rtv.Get());policy.Begin(true);clear(false);
    draw(-1,0,.25f,1,0,7); // nearer opaque world geometry in the left half
    bind(uiRtv.Get());UINT flags=3;
    Test(!policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==3,"UI target clear unchanged");
    bind(rtv.Get());clear(true);
    draw(0,.5f,.4f,1,0,7); // nearer hand geometry at pixels 4 and 5
    UINT stencilFlags=D3D11_CLEAR_STENCIL;
    Test(!policy.Filter(context.Get(),dsv.Get(),stencilFlags,1,0) && stencilFlags==D3D11_CLEAR_STENCIL,"intermediate stencil clear does not abort preservation");
    clear(true);
    draw(-1,1,.6f,0,1,1); // forward-lit gun across both halves
    context->CopyResource(colorRead.Get(),color.Get());context->CopyResource(depthRead.Get(),depth.Get());
    D3D11_MAPPED_SUBRESOURCE cp{},dp{};HR(context->Map(colorRead.Get(),0,D3D11_MAP_READ,0,&cp));HR(context->Map(depthRead.Get(),0,D3D11_MAP_READ,0,&dp));
    bool colors=true,depths=true,stencils=true;
    for(unsigned y=0;y<4;++y) for(unsigned x=0;x<8;++x) {
        const auto* c=reinterpret_cast<const unsigned short*>(static_cast<const char*>(cp.pData)+y*cp.RowPitch+x*8);
        const auto d=*reinterpret_cast<const unsigned*>(static_cast<const char*>(dp.pData)+y*dp.RowPitch+x*4);
        colors &= c[0]==(x<6?0x3c00:0) && c[1]==(x<6?0:0x3c00);
        depths &= std::abs(float(d&0xffffff)/16777215.f-(x<4?.25f:(x<6?.4f:.6f)))<.00001f;
        stencils &= (d>>24)==(x<6?0u:1u);
    }
    context->Unmap(colorRead.Get(),0);context->Unmap(depthRead.Get(),0);
    Test(colors,"wall and nearer hand hide the gun; exposed gun retains its forward color");
    Test(depths,"world, hand and weapon retain real geometric depth");
    Test(stencils,"world and hand stencil reset; only visible gun receives stencil 1");
    flags=D3D11_CLEAR_DEPTH;
    Test(!policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==D3D11_CLEAR_DEPTH,"depth-only operation unchanged");
    clear(false);clear(false); // a mismatch ends preservation until the next scope
    policy.Begin(true);clear(false); // each eye/fresh frame starts with clean world depth
    clear(true);
    viewport.Width=4;context->RSSetViewports(1,&viewport);flags=3;
    Test(!policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==3,"subview/shadow viewport rejected");
    viewport.Width=8;context->RSSetViewports(1,&viewport);clear(false);clear(false);
    policy.Begin(true);clear(false);
    clear(true);policy.End();clear(false);
    policy.Begin(false);clear(false);clear(false);
    // Sub-viewports and stereo offsets preserve depth when matching across passes
    policy.Begin(true);
    viewport.TopLeftX=2;viewport.Width=4;
    context->RSSetViewports(1,&viewport);
    clear(false);
    clear(true);
    // Single-pass stereo: two eye rectangles side by side in one target.
    const D3D11_VIEWPORT left{0,0,4,4,0,1}, right{4,0,4,4,0,1}, both{0,0,8,4,0,1};
    policy.SetEyes(left,right);
    const auto at=[&](const D3D11_VIEWPORT& v) { context->RSSetViewports(1,&v); };
    policy.Begin(true);
    at(left);clear(false);at(right);clear(false);   // each eye's world clear
    at(left);clear(true);at(right);clear(true);     // each eye's foreground clear
    at(left);clear(true);                           // repeated foreground clear
    policy.Begin(true);
    at(both);clear(false);                          // one world clear of both eyes
    at(left);clear(true);at(right);clear(true);     // foreground clears per eye
    // A second view of the same depth buffer is the same target.
    ComPtr<ID3D11DepthStencilView> dsv2;HR(device->CreateDepthStencilView(depth.Get(),&dd,&dsv2));
    policy.Begin(true);
    at(left);clear(false);at(right);flags=3;
    Test(!policy.Filter(context.Get(),dsv2.Get(),flags,1,0) && flags==3,"other view: right eye world clear");
    at(right);flags=3;
    Test(policy.Filter(context.Get(),dsv2.Get(),flags,1,0) && flags==D3D11_CLEAR_STENCIL,"other view: right eye foreground clear");
    // RHIClear's quad path may clear an eye's depth alone.
    policy.Begin(true);
    at(left);flags=D3D11_CLEAR_DEPTH;
    Test(!policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==D3D11_CLEAR_DEPTH,"depth-only eye world clear");
    at(left);flags=D3D11_CLEAR_DEPTH;
    Test(policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==0,"depth-only eye foreground clear skipped");
    at(both);flags=D3D11_CLEAR_DEPTH;
    Test(!policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==D3D11_CLEAR_DEPTH,"depth-only clear of both eyes unchanged");
    policy.Begin(false);
    at(left);clear(false);at(right);clear(false);   // inactive: never preserved
    policy.ClearEyes();
    policy.Begin(true);
    at(left);clear(false);at(right);flags=3;
    Test(!policy.Filter(context.Get(),dsv.Get(),flags,1,0) && flags==3,"mono: other viewport still rejected");
    context->ClearState();
    std::printf("Foreground depth checks=%d failures=%d\n",checks,failures);
    return failures?1:0;
}
