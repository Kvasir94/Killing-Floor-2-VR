#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "ReflectionCoverage.h"
using Microsoft::WRL::ComPtr;
namespace {
int checks=0,failures=0;
void Test(bool value,const char* label) { ++checks; if(!value) { ++failures; std::printf("FAIL %s\n",label); } }
void HR(HRESULT result) { if(FAILED(result)) { std::printf("HRESULT %08lx\n",(unsigned long)result); std::exit(2); } }
}
int main() {
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
    HR(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
    constexpr UINT width=9,height=4;
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width=width; desc.Height=height; desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_R24G8_TYPELESS; desc.BindFlags=D3D11_BIND_DEPTH_STENCIL;
    ComPtr<ID3D11Texture2D> depth;
    HR(device->CreateTexture2D(&desc,nullptr,&depth));
    D3D11_DEPTH_STENCIL_VIEW_DESC depthDesc{};
    depthDesc.Format=DXGI_FORMAT_D24_UNORM_S8_UINT; depthDesc.ViewDimension=D3D11_DSV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11DepthStencilView> depthView;
    HR(device->CreateDepthStencilView(depth.Get(),&depthDesc,&depthView));
    context->ClearDepthStencilView(depthView.Get(),D3D11_CLEAR_DEPTH|D3D11_CLEAR_STENCIL,.5f,37);

    // A one-D24-unit discrepancy must survive; four units must be masked.
    constexpr float unit=1.f/16777215.f,visible=8388608.f/16777215.f;
    std::array<float,width*height> receivers{};
    receivers.fill(.9f);
    for(UINT y=1;y<3;++y) {
        receivers[y*width+1]=visible;
        receivers[y*width+2]=visible+unit;
        receivers[y*width+3]=visible+4*unit;
        receivers[y*width+5]=.9f;
        receivers[y*width+6]=.4f;
        receivers[y*width+7]=visible;
    }
    desc.Format=DXGI_FORMAT_R32_FLOAT; desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA initial{receivers.data(),width*sizeof(float),0};
    ComPtr<ID3D11Texture2D> hierarchy;
    ComPtr<ID3D11ShaderResourceView> hierarchyView;
    HR(device->CreateTexture2D(&desc,&initial,&hierarchy));
    HR(device->CreateShaderResourceView(hierarchy.Get(),nullptr,&hierarchyView));

    desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    desc.BindFlags=D3D11_BIND_UNORDERED_ACCESS|D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> result,sentinelOutput,readback;
    ComPtr<ID3D11UnorderedAccessView> resultView,sentinelOutputView;
    ComPtr<ID3D11ShaderResourceView> resultInput;
    HR(device->CreateTexture2D(&desc,nullptr,&result));
    HR(device->CreateTexture2D(&desc,nullptr,&sentinelOutput));
    HR(device->CreateUnorderedAccessView(result.Get(),nullptr,&resultView));
    HR(device->CreateUnorderedAccessView(sentinelOutput.Get(),nullptr,&sentinelOutputView));
    HR(device->CreateShaderResourceView(result.Get(),nullptr,&resultInput));
    const float sentinel[]{.125f,.25f,.5f,2.f};
    context->ClearUnorderedAccessViewFloat(resultView.Get(),sentinel);
    desc.BindFlags=0; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&desc,nullptr,&readback));

    desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM; desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    desc.Usage=D3D11_USAGE_DEFAULT; desc.CPUAccessFlags=0;
    ComPtr<ID3D11Texture2D> color0,color7;
    ComPtr<ID3D11RenderTargetView> colorView0,colorView7;
    HR(device->CreateTexture2D(&desc,nullptr,&color0));
    HR(device->CreateTexture2D(&desc,nullptr,&color7));
    HR(device->CreateRenderTargetView(color0.Get(),nullptr,&colorView0));
    HR(device->CreateRenderTargetView(color7.Get(),nullptr,&colorView7));
    ID3D11RenderTargetView* targets[8]{}; targets[0]=colorView0.Get(); targets[7]=colorView7.Get();
    context->OMSetRenderTargets(8,targets,depthView.Get());
    const D3D11_VIEWPORT viewport{2,1,5,2,.1f,.9f}; context->RSSetViewports(1,&viewport);

    const char* shader="[numthreads(1,1,1)] void CS(uint3 id:SV_DispatchThreadID) {}";
    ComPtr<ID3DBlob> bytecode;
    HR(D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"CS","cs_5_0",0,0,&bytecode,nullptr));
    ComPtr<ID3D11ComputeShader> gameShader;
    HR(device->CreateComputeShader(bytecode->GetBufferPointer(),bytecode->GetBufferSize(),nullptr,&gameShader));
    context->CSSetShader(gameShader.Get(),nullptr,0);
    D3D11_BUFFER_DESC bufferDesc{}; bufferDesc.ByteWidth=16;
    bufferDesc.Usage=D3D11_USAGE_DEFAULT; bufferDesc.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    ComPtr<ID3D11Buffer> gameConstants; HR(device->CreateBuffer(&bufferDesc,nullptr,&gameConstants));
    ID3D11Buffer* constants=gameConstants.Get(); context->CSSetConstantBuffers(0,1,&constants);
    ID3D11ShaderResourceView* input=hierarchyView.Get();
    context->CSSetShaderResources(0,1,&input); context->CSSetShaderResources(2,1,&input);
    ID3D11UnorderedAccessView* output=resultView.Get(); context->CSSetUnorderedAccessViews(0,1,&output,nullptr);
    constexpr std::int32_t eyes[2][4]{{1,1,3,2},{5,1,3,2}};
    kf2vr::adapter::ReflectionCoverage coverage;
    Test(coverage.Capture(context.Get(),depth.Get(),eyes),"capture compatible depth and SSR resources");
    Test(coverage.Capture(context.Get(),depth.Get(),eyes),"second eye uses the same capture");

    // Simulate a later graphics pass sampling the result while an unrelated
    // compute output remains bound. Neither binding may be lost to aliasing.
    output=nullptr; context->CSSetUnorderedAccessViews(0,1,&output,nullptr);
    output=sentinelOutputView.Get(); context->CSSetUnorderedAccessViews(3,1,&output,nullptr);
    input=resultInput.Get();
    context->PSSetShaderResources(7,1,&input); context->VSSetShaderResources(11,1,&input);
    context->CSSetShaderResources(9,1,&input);
    Test(coverage.Mask(context.Get()),"mask current visible depth in both eye rectangles");

    ComPtr<ID3D11ComputeShader> restoredShader; context->CSGetShader(&restoredShader,nullptr,nullptr);
    ComPtr<ID3D11Buffer> restoredConstants; context->CSGetConstantBuffers(0,1,&restoredConstants);
    ComPtr<ID3D11ShaderResourceView> restoredInput,restoredPixel,restoredVertex,restoredComputeAlias;
    context->CSGetShaderResources(0,1,&restoredInput); context->PSGetShaderResources(7,1,&restoredPixel);
    context->VSGetShaderResources(11,1,&restoredVertex); context->CSGetShaderResources(9,1,&restoredComputeAlias);
    ComPtr<ID3D11UnorderedAccessView> restoredOutput,restoredSlot0;
    context->CSGetUnorderedAccessViews(3,1,&restoredOutput); context->CSGetUnorderedAccessViews(0,1,&restoredSlot0);
    Test(restoredShader.Get()==gameShader.Get() && restoredConstants.Get()==gameConstants.Get(),"compute shader and constant buffer restored");
    Test(restoredInput.Get()==hierarchyView.Get() && restoredPixel.Get()==resultInput.Get()
        && restoredVertex.Get()==resultInput.Get() && restoredComputeAlias.Get()==resultInput.Get(),"graphics and compute resource aliases restored");
    Test(restoredOutput.Get()==sentinelOutputView.Get() && !restoredSlot0,"all touched compute outputs restored");
    ID3D11RenderTargetView* restoredTargets[8]{};
    ComPtr<ID3D11DepthStencilView> restoredDepth;
    context->OMGetRenderTargets(8,restoredTargets,&restoredDepth);
    bool matchingTargets=restoredDepth.Get()==depthView.Get();
    for(unsigned n=0;n<8;++n) {
        matchingTargets &= restoredTargets[n]==targets[n];
        if(restoredTargets[n]) restoredTargets[n]->Release();
    }
    Test(matchingTargets,"all eight render targets and original bound depth restored");
    D3D11_VIEWPORT restoredViewport{}; UINT count=1; context->RSGetViewports(&count,&restoredViewport);
    Test(count==1 && std::memcmp(&restoredViewport,&viewport,sizeof(viewport))==0,"viewport untouched");

    const auto checkPixels=[&](bool later) {
        context->CopyResource(readback.Get(),result.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{}; HR(context->Map(readback.Get(),0,D3D11_MAP_READ,0,&mapped));
        bool good=true;
        for(UINT y=0;y<height;++y) for(UINT x=0;x<width;++x) {
            const bool inEye=y>=1 && y<3 && ((x>=1 && x<4) || (x>=5 && x<8));
            const bool masked=inEye && (later || x==3 || x==5);
            const auto* pixel=reinterpret_cast<const float*>(static_cast<const char*>(mapped.pData)+y*mapped.RowPitch)+x*4;
            for(unsigned channel=0;channel<4;++channel) good &= pixel[channel]==(masked ? 0.f : sentinel[channel]);
        }
        context->Unmap(readback.Get(),0);
        return good;
    };
    Test(checkPixels(false),"equal and farther receivers plus one-unit tolerance preserved; nearer pixels cleared; outside eyes untouched");
    context->ClearDepthStencilView(depthView.Get(),D3D11_CLEAR_DEPTH,.25f,0);
    Test(coverage.Mask(context.Get()) && checkPixels(true),"late visible depth is resampled and additional covered pixels cleared");

    // A mismatching output dimension must drop the old valid capture.
    context->ClearState();
    desc.Width=width-1; desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT; desc.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
    ComPtr<ID3D11Texture2D> wrongOutput; ComPtr<ID3D11UnorderedAccessView> wrongView;
    HR(device->CreateTexture2D(&desc,nullptr,&wrongOutput));
    HR(device->CreateUnorderedAccessView(wrongOutput.Get(),nullptr,&wrongView));
    input=hierarchyView.Get(); context->CSSetShaderResources(2,1,&input);
    output=wrongView.Get(); context->CSSetUnorderedAccessViews(0,1,&output,nullptr);
    Test(!coverage.Capture(context.Get(),depth.Get(),eyes) && !coverage.HasCapture(),"incompatible resource drops prior scene capture");
    Test(!coverage.Capture(context.Get(),depth.Get(),eyes) && !coverage.Mask(context.Get()),"dimension mismatch rejected without previous capture too");
    output=resultView.Get(); context->CSSetUnorderedAccessViews(0,1,&output,nullptr);
    const std::int32_t overlapping[2][4]{{1,1,3,2},{2,1,3,2}};
    Test(!coverage.Capture(context.Get(),depth.Get(),overlapping) && !coverage.HasCapture(),"overlapping eye rectangles rejected");
    Test(coverage.Capture(context.Get(),depth.Get(),eyes),"valid scene can capture after rejection");
    coverage.Clear();
    Test(!coverage.HasCapture() && !coverage.Mask(context.Get()),"cleared scene cannot reuse prior reflection targets");

    // KF2's actual SSR target is PF_A2B10G10R10. Preserve unmasked packed
    // words exactly; the coverage shader must not read/re-encode the result.
    context->ClearState();
    context->ClearDepthStencilView(depthView.Get(),D3D11_CLEAR_DEPTH,.5f,0);
    constexpr std::uint32_t packedValue=17u|(333u<<10)|(777u<<20)|(3u<<30);
    std::array<std::uint32_t,width*height> packedPixels{}; packedPixels.fill(packedValue);
    desc.Width=width; desc.Format=DXGI_FORMAT_R10G10B10A2_UNORM;
    desc.BindFlags=D3D11_BIND_UNORDERED_ACCESS; desc.Usage=D3D11_USAGE_DEFAULT; desc.CPUAccessFlags=0;
    D3D11_SUBRESOURCE_DATA packedInitial{packedPixels.data(),width*sizeof(std::uint32_t),0};
    ComPtr<ID3D11Texture2D> packedResult,packedReadback;
    ComPtr<ID3D11UnorderedAccessView> packedView;
    HR(device->CreateTexture2D(&desc,&packedInitial,&packedResult));
    HR(device->CreateUnorderedAccessView(packedResult.Get(),nullptr,&packedView));
    desc.BindFlags=0; desc.Usage=D3D11_USAGE_STAGING; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    HR(device->CreateTexture2D(&desc,nullptr,&packedReadback));
    input=hierarchyView.Get(); context->CSSetShaderResources(2,1,&input);
    output=packedView.Get(); context->CSSetUnorderedAccessViews(0,1,&output,nullptr);
    context->OMSetRenderTargets(8,targets,depthView.Get());
    Test(coverage.Capture(context.Get(),depth.Get(),eyes),"actual packed SSR UAV format accepted");
    Test(coverage.Mask(context.Get()),"actual packed SSR UAV format masked");
    context->CopyResource(packedReadback.Get(),packedResult.Get());
    D3D11_MAPPED_SUBRESOURCE packedMap{};
    HR(context->Map(packedReadback.Get(),0,D3D11_MAP_READ,0,&packedMap));
    bool packedCorrect=true;
    for(UINT y=0;y<height;++y) for(UINT x=0;x<width;++x) {
        const bool masked=y>=1 && y<3 && (x==3 || x==5);
        const auto* row=reinterpret_cast<const std::uint32_t*>(static_cast<const char*>(packedMap.pData)+y*packedMap.RowPitch);
        packedCorrect &= row[x]==(masked ? 0u : packedValue);
    }
    context->Unmap(packedReadback.Get(),0);
    Test(packedCorrect,"packed covered pixels are zero and every unmasked word is unchanged");
    std::printf("ReflectionCoverage: %d checks, %d failures\n",checks,failures);
    return failures ? 1 : 0;
}
