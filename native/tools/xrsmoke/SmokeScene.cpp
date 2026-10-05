#include "SmokeScene.h"
#include "../../diagnostics/D3D11Capture.h"
#include <d3dcompiler.h>
#include <wincodec.h>
#include <array>
#include <cmath>
#include <cstring>

using namespace DirectX;
using Microsoft::WRL::ComPtr;

namespace {
const char* kShader = R"(
cbuffer Scene : register(b0) { float4x4 mvp; float4 tint; };
struct VSIn { float3 position : POSITION; };
struct VSOut { float4 position : SV_POSITION; float4 color : COLOR; };
VSOut vs(VSIn v) {
    VSOut o; o.position = mul(float4(v.position, 1), mvp);
    o.color = float4(tint.rgb * (0.72 + 0.28 * (v.position.y + 0.5)), 1); return o;
}
float4 ps(VSOut p) : SV_TARGET { return p.color; }
)";
struct Constants { XMFLOAT4X4 mvp; XMFLOAT4 tint; };
bool Check(HRESULT hr, const char* operation, std::string& error) {
    if (SUCCEEDED(hr)) return true;
    error = std::string(operation) + " HRESULT=" + std::to_string(static_cast<long>(hr));
    return false;
}
}

bool SmokeScene::Initialise(ID3D11Device* device, std::string& error) {
    ComPtr<ID3DBlob> vs, ps, messages;
    auto compile = [&](const char* entry, const char* target, ComPtr<ID3DBlob>& blob) {
        const HRESULT hr = D3DCompile(kShader, std::strlen(kShader), "kf2vr-smoke", nullptr, nullptr,
            entry, target, D3DCOMPILE_ENABLE_STRICTNESS, 0, &blob, &messages);
        if (FAILED(hr)) {
            error = messages ? static_cast<const char*>(messages->GetBufferPointer()) : "Shader compilation failed";
            return false;
        }
        return true;
    };
    if (!compile("vs", "vs_5_0", vs) || !compile("ps", "ps_5_0", ps)) return false;
    if (!Check(device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &vertexShader_), "CreateVertexShader", error) ||
        !Check(device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &pixelShader_), "CreatePixelShader", error)) return false;
    const D3D11_INPUT_ELEMENT_DESC element{"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0};
    if (!Check(device->CreateInputLayout(&element,1,vs->GetBufferPointer(),vs->GetBufferSize(),&layout_),"CreateInputLayout",error)) return false;
    const std::array<XMFLOAT3,8> corners{{{-.5f,-.5f,-.5f},{.5f,-.5f,-.5f},{.5f,.5f,-.5f},{-.5f,.5f,-.5f},
                                        {-.5f,-.5f,.5f},{.5f,-.5f,.5f},{.5f,.5f,.5f},{-.5f,.5f,.5f}}};
    const unsigned indices[]{0,1,2,0,2,3, 5,4,7,5,7,6, 4,0,3,4,3,7, 1,5,6,1,6,2, 3,2,6,3,6,7, 4,5,1,4,1,0};
    std::array<XMFLOAT3,36> points{};
    for (unsigned i=0;i<36;++i) points[i]=corners[indices[i]];
    D3D11_BUFFER_DESC buffer{};
    buffer.ByteWidth=sizeof(points); buffer.Usage=D3D11_USAGE_IMMUTABLE; buffer.BindFlags=D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA data{points.data(),0,0};
    if (!Check(device->CreateBuffer(&buffer,&data,&vertices_),"Create vertex buffer",error)) return false;
    buffer.ByteWidth=sizeof(Constants); buffer.Usage=D3D11_USAGE_DEFAULT; buffer.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    if (!Check(device->CreateBuffer(&buffer,nullptr,&constants_),"Create constants",error)) return false;
    D3D11_RASTERIZER_DESC raster{};
    raster.FillMode=D3D11_FILL_SOLID; raster.CullMode=D3D11_CULL_NONE; raster.DepthClipEnable=TRUE;
    if (!Check(device->CreateRasterizerState(&raster,&rasterizer_),"Create rasterizer",error)) return false;
    D3D11_DEPTH_STENCIL_DESC depth{};
    depth.DepthEnable=TRUE; depth.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ALL; depth.DepthFunc=D3D11_COMPARISON_LESS;
    return Check(device->CreateDepthStencilState(&depth,&depthState_),"Create depth state",error);
}

XMMATRIX SmokeScene::Projection(float left,float right,float down,float up) {
    constexpr float nearPlane=.05f, farPlane=100.f;
    return XMMatrixPerspectiveOffCenterRH(std::tan(left)*nearPlane,std::tan(right)*nearPlane,
        std::tan(down)*nearPlane,std::tan(up)*nearPlane,nearPlane,farPlane);
}

void SmokeScene::Cube(ID3D11DeviceContext* context, FXMMATRIX vp,
    float x,float y,float z,float sx,float sy,float sz,float red,float green,float blue) {
    Constants constants{};
    XMStoreFloat4x4(&constants.mvp,XMMatrixTranspose(XMMatrixScaling(sx,sy,sz)*XMMatrixTranslation(x,y,z)*vp));
    constants.tint={red,green,blue,1.f};
    context->UpdateSubresource(constants_.Get(),0,nullptr,&constants,0,0);
    context->Draw(36,0);
}

bool SmokeScene::Render(ID3D11DeviceContext* context,ID3D11RenderTargetView* color,
    ID3D11DepthStencilView* depth,unsigned width,unsigned height,const kf2vr::Quat& rotation,
    const kf2vr::Vec3& position,float left,float right,float down,float up,
    const kf2vr::Vec3* leftHand,const kf2vr::Vec3* rightHand) {
    if (!color || !depth || !width || !height || !(left<right && down<up) ||
        !std::isfinite(left+right+down+up)) return false;
    const float background[]{.014f,.018f,.025f,1.f};
    context->ClearRenderTargetView(color,background);
    context->ClearDepthStencilView(depth,D3D11_CLEAR_DEPTH,1.f,0);
    context->OMSetRenderTargets(1,&color,depth);
    context->OMSetDepthStencilState(depthState_.Get(),0);
    context->OMSetBlendState(nullptr,nullptr,0xffffffff);
    context->RSSetState(rasterizer_.Get());
    const D3D11_VIEWPORT viewport{0,0,static_cast<float>(width),static_cast<float>(height),0,1};
    context->RSSetViewports(1,&viewport);
    context->IASetInputLayout(layout_.Get());
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    auto* vertexBuffer=vertices_.Get(); const UINT stride=sizeof(XMFLOAT3),offset=0;
    context->IASetVertexBuffers(0,1,&vertexBuffer,&stride,&offset);
    context->VSSetShader(vertexShader_.Get(),nullptr,0);
    context->PSSetShader(pixelShader_.Get(),nullptr,0);
    auto* constants=constants_.Get(); context->VSSetConstantBuffers(0,1,&constants);
    const XMFLOAT4 q{rotation.x,rotation.y,rotation.z,rotation.w};
    const XMMATRIX pose=XMMatrixRotationQuaternion(XMLoadFloat4(&q))*XMMatrixTranslation(position.x,position.y,position.z);
    const XMMATRIX vp=XMMatrixInverse(nullptr,pose)*Projection(left,right,down,up);
    // Half-metre floor grid, metre markers and three depth-separated cubes.
    for (int i=-8;i<=8;++i) {
        const float n=static_cast<float>(i)*.5f;
        Cube(context,vp,n,-1.5f,-2, .008f,.008f,8, .11f,.15f,.18f);
        Cube(context,vp,0,-1.5f,n-2, 8,.008f,.008f, .11f,.15f,.18f);
    }
    Cube(context,vp,-.5f,0,-1.5f,.25f,.25f,.25f,.85f,.08f,.04f);
    Cube(context,vp,0,0,-3,.4f,.4f,.4f,.05f,.8f,.2f);
    Cube(context,vp,1,0,-6,.7f,.7f,.7f,.05f,.25f,.95f);
    Cube(context,vp,0,-.6f,-2,1,.012f,.012f,.85f,.65f,.1f);
    Cube(context,vp,-.5f,-.6f,-2,.012f,.12f,.012f,.85f,.65f,.1f);
    Cube(context,vp,.5f,-.6f,-2,.012f,.12f,.012f,.85f,.65f,.1f);
    if (leftHand) Cube(context,vp,leftHand->x,leftHand->y,leftHand->z,.065f,.065f,.065f,.95f,.16f,.07f);
    if (rightHand) Cube(context,vp,rightHand->x,rightHand->y,rightHand->z,.065f,.065f,.065f,.05f,.5f,.95f);
    context->OMSetRenderTargets(0,nullptr,nullptr);
    return true;
}

bool SmokeScene::Capture(ID3D11DeviceContext* context,ID3D11Texture2D* texture,
    const std::filesystem::path& path,std::string& error,std::vector<unsigned char>* pixels) {
    return kf2vr::diagnostics::CaptureTexture(context,texture,path,error,pixels);
}
