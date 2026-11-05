#pragma once
#include <d3d11.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <vector>
#include <cstring>
#include <algorithm>
#include <cmath>

namespace kf2vr::diagnostics {
using Microsoft::WRL::ComPtr;
inline bool CaptureCheck(HRESULT hr,const char* operation,std::string& error) {
    if (SUCCEEDED(hr)) return true;
    error=std::string(operation)+" HRESULT="+std::to_string(static_cast<long>(hr));
    return false;
}
// Explicit diagnostic capture on the context's owner thread. Copy and Map
// preserve pipeline bindings. This stalls the GPU; never use for routine frames.
inline bool CaptureTexture(ID3D11DeviceContext* context,ID3D11Texture2D* texture,
    const std::filesystem::path& path,std::string& error,std::vector<unsigned char>* pixels) {
    if (!context || !texture) { error="Missing capture context or texture"; return false; }
    const HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment!=RPC_E_CHANGED_MODE) {
        error="Capture COM initialization failed"; return false;
    }
    struct ApartmentRelease { bool balance; ~ApartmentRelease() { if (balance) CoUninitialize(); } } release{SUCCEEDED(apartment)};
    D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
    if (desc.SampleDesc.Count!=1 || desc.ArraySize!=1 ||
        (desc.Format!=DXGI_FORMAT_R8G8B8A8_UNORM && desc.Format!=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB && desc.Format!=DXGI_FORMAT_R8G8B8A8_TYPELESS &&
         desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM && desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM_SRGB && desc.Format!=DXGI_FORMAT_B8G8R8A8_TYPELESS)) {
        error="Unsupported capture texture: format="+std::to_string(desc.Format)+" samples="+std::to_string(desc.SampleDesc.Count)+" array="+std::to_string(desc.ArraySize); return false;
    }
    ComPtr<ID3D11Device> device; context->GetDevice(&device);
    desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ; desc.MiscFlags=0;
    ComPtr<ID3D11Texture2D> staging;
    if (!CaptureCheck(device->CreateTexture2D(&desc,nullptr,&staging),"Create staging texture",error)) return false;
    context->CopyResource(staging.Get(),texture);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (!CaptureCheck(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped),"Map capture",error)) return false;
    std::vector<unsigned char> data(static_cast<size_t>(desc.Width)*desc.Height*4);
    for (UINT y=0;y<desc.Height;++y) std::memcpy(data.data()+static_cast<size_t>(y)*desc.Width*4,
        static_cast<const unsigned char*>(mapped.pData)+static_cast<size_t>(y)*mapped.RowPitch,static_cast<size_t>(desc.Width)*4);
    context->Unmap(staging.Get(),0);
    if (desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB || desc.Format==DXGI_FORMAT_B8G8R8A8_TYPELESS)
        for (size_t i=0;i<data.size();i+=4) std::swap(data[i],data[i+2]);
    if (pixels) *pixels=data;
    if (path.empty()) return true;
    ComPtr<IWICImagingFactory> factory;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    if (!CaptureCheck(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&factory)),"WIC factory",error) ||
        !CaptureCheck(factory->CreateStream(&stream),"WIC stream",error) ||
        !CaptureCheck(stream->InitializeFromFilename(path.c_str(),GENERIC_WRITE),"Open PNG",error) ||
        !CaptureCheck(factory->CreateEncoder(GUID_ContainerFormatPng,nullptr,&encoder),"PNG encoder",error) ||
        !CaptureCheck(encoder->Initialize(stream.Get(),WICBitmapEncoderNoCache),"PNG initialise",error) ||
        !CaptureCheck(encoder->CreateNewFrame(&frame,nullptr),"PNG frame",error) ||
        !CaptureCheck(frame->Initialize(nullptr),"PNG frame initialise",error) ||
        !CaptureCheck(frame->SetSize(desc.Width,desc.Height),"PNG dimensions",error)) return false;
    WICPixelFormatGUID format=GUID_WICPixelFormat24bppBGR;
    if (!CaptureCheck(frame->SetPixelFormat(&format),"PNG format",error)) return false;
    if (!IsEqualGUID(format,GUID_WICPixelFormat24bppBGR)) { error="WIC changed requested pixel format"; return false; }
    std::vector<unsigned char> bgr(static_cast<size_t>(desc.Width)*desc.Height*3);
    for (size_t pixel=0;pixel<data.size()/4;++pixel) {
        bgr[pixel*3]=data[pixel*4+2]; bgr[pixel*3+1]=data[pixel*4+1]; bgr[pixel*3+2]=data[pixel*4];
    }
    return CaptureCheck(frame->WritePixels(desc.Height,desc.Width*3,static_cast<UINT>(bgr.size()),bgr.data()),"PNG pixels",error) &&
        CaptureCheck(frame->Commit(),"PNG frame commit",error) && CaptureCheck(encoder->Commit(),"PNG commit",error);
}
inline float CaptureHalf(unsigned short h) {
    const unsigned sign=(h>>15)&1, exponent=(h>>10)&31, mantissa=h&1023;
    float value=exponent==0 ? mantissa/1024.f*0.00006103515625f :
        exponent==31 ? 0.f : (1.f+mantissa/1024.f)*static_cast<float>(1u<<exponent)/32768.f;
    return sign ? -value : value;
}

// Depth and motion inputs as viewable PNGs, for diagnostics. Depth formats
// (D24S8/R24G8, D32/R32, D32S8) become grey, stretched between the frame's own
// nearest and farthest values. Two-channel float motion (R16G16, R32G32, or the
// first two of RGBA16F) becomes red = x and green = y around a mid grey, scaled
// by the largest motion in the frame.
inline bool CaptureScalarTexture(ID3D11DeviceContext* context,ID3D11Texture2D* texture,
    const std::filesystem::path& path,std::string& error) {
    if (!context || !texture) { error="Missing capture context or texture"; return false; }
    D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
    if (desc.SampleDesc.Count!=1 || desc.ArraySize!=1) { error="Multisampled or array texture"; return false; }
    enum class Kind { Depth24, Depth32, Depth32S8, Half2, Half4, Float2 } kind;
    switch (desc.Format) {
    case DXGI_FORMAT_R24G8_TYPELESS: case DXGI_FORMAT_D24_UNORM_S8_UINT: case DXGI_FORMAT_R24_UNORM_X8_TYPELESS: kind=Kind::Depth24; break;
    case DXGI_FORMAT_R32_TYPELESS: case DXGI_FORMAT_D32_FLOAT: case DXGI_FORMAT_R32_FLOAT: kind=Kind::Depth32; break;
    case DXGI_FORMAT_R32G8X24_TYPELESS: case DXGI_FORMAT_D32_FLOAT_S8X24_UINT: kind=Kind::Depth32S8; break;
    case DXGI_FORMAT_R16G16_FLOAT: case DXGI_FORMAT_R16G16_TYPELESS: kind=Kind::Half2; break;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: case DXGI_FORMAT_R16G16B16A16_TYPELESS: kind=Kind::Half4; break;
    case DXGI_FORMAT_R32G32_FLOAT: case DXGI_FORMAT_R32G32_TYPELESS: kind=Kind::Float2; break;
    default: error="Unsupported scalar capture format="+std::to_string(desc.Format); return false;
    }
    ComPtr<ID3D11Device> device; context->GetDevice(&device);
    desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ; desc.MiscFlags=0;
    ComPtr<ID3D11Texture2D> staging;
    if (!CaptureCheck(device->CreateTexture2D(&desc,nullptr,&staging),"Create scalar staging texture",error)) return false;
    context->CopyResource(staging.Get(),texture);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (!CaptureCheck(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped),"Map scalar capture",error)) return false;
    const size_t count=static_cast<size_t>(desc.Width)*desc.Height;
    std::vector<float> a(count), b(count);
    const bool motion=kind==Kind::Half2 || kind==Kind::Half4 || kind==Kind::Float2;
    for (UINT y=0;y<desc.Height;++y) {
        const auto* row=static_cast<const unsigned char*>(mapped.pData)+static_cast<size_t>(y)*mapped.RowPitch;
        for (UINT x=0;x<desc.Width;++x) {
            const size_t i=static_cast<size_t>(y)*desc.Width+x;
            unsigned v32=0; float f=0; unsigned short h[2]{};
            switch (kind) {
            case Kind::Depth24: std::memcpy(&v32,row+x*4,4); a[i]=(v32&0xFFFFFF)/16777215.f; break;
            case Kind::Depth32: std::memcpy(&f,row+x*4,4); a[i]=f; break;
            case Kind::Depth32S8: std::memcpy(&f,row+x*8,4); a[i]=f; break;
            case Kind::Half2: std::memcpy(h,row+x*4,4); a[i]=CaptureHalf(h[0]); b[i]=CaptureHalf(h[1]); break;
            case Kind::Half4: std::memcpy(h,row+x*8,4); a[i]=CaptureHalf(h[0]); b[i]=CaptureHalf(h[1]); break;
            case Kind::Float2: std::memcpy(&a[i],row+x*8,4); std::memcpy(&b[i],row+x*8+4,4); break;
            }
        }
    }
    context->Unmap(staging.Get(),0);
    ComPtr<IWICImagingFactory> factory;
    const HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment!=RPC_E_CHANGED_MODE) { error="Capture COM initialization failed"; return false; }
    struct ApartmentRelease { bool balance; ~ApartmentRelease() { if (balance) CoUninitialize(); } } release{SUCCEEDED(apartment)};
    std::vector<unsigned char> bgr(count*3);
    if (motion) {
        float peak=1e-6f;
        for (size_t i=0;i<count;++i) if (std::isfinite(a[i]) && std::isfinite(b[i])) peak=std::max(peak,std::max(std::abs(a[i]),std::abs(b[i])));
        for (size_t i=0;i<count;++i) {
            const auto channel=[&](float v) { return static_cast<unsigned char>(std::clamp(128.f+127.f*(std::isfinite(v)?v:0.f)/peak,0.f,255.f)); };
            bgr[i*3]=128; bgr[i*3+1]=channel(b[i]); bgr[i*3+2]=channel(a[i]);
        }
    } else {
        float low=1e30f, high=-1e30f;
        for (float v : a) if (std::isfinite(v)) { low=std::min(low,v); high=std::max(high,v); }
        const float span=high>low ? high-low : 1.f;
        for (size_t i=0;i<count;++i) bgr[i*3]=bgr[i*3+1]=bgr[i*3+2]=
            static_cast<unsigned char>(std::clamp(255.f*((std::isfinite(a[i])?a[i]:low)-low)/span,0.f,255.f));
    }
    ComPtr<IWICStream> stream; ComPtr<IWICBitmapEncoder> encoder; ComPtr<IWICBitmapFrameEncode> frame;
    if (!CaptureCheck(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&factory)),"WIC factory",error) ||
        !CaptureCheck(factory->CreateStream(&stream),"WIC stream",error) ||
        !CaptureCheck(stream->InitializeFromFilename(path.c_str(),GENERIC_WRITE),"Open PNG",error) ||
        !CaptureCheck(factory->CreateEncoder(GUID_ContainerFormatPng,nullptr,&encoder),"PNG encoder",error) ||
        !CaptureCheck(encoder->Initialize(stream.Get(),WICBitmapEncoderNoCache),"PNG initialise",error) ||
        !CaptureCheck(encoder->CreateNewFrame(&frame,nullptr),"PNG frame",error) ||
        !CaptureCheck(frame->Initialize(nullptr),"PNG frame initialise",error) ||
        !CaptureCheck(frame->SetSize(desc.Width,desc.Height),"PNG dimensions",error)) return false;
    WICPixelFormatGUID format=GUID_WICPixelFormat24bppBGR;
    if (!CaptureCheck(frame->SetPixelFormat(&format),"PNG format",error)) return false;
    if (!IsEqualGUID(format,GUID_WICPixelFormat24bppBGR)) { error="WIC changed requested pixel format"; return false; }
    return CaptureCheck(frame->WritePixels(desc.Height,desc.Width*3,static_cast<UINT>(bgr.size()),bgr.data()),"PNG pixels",error) &&
        CaptureCheck(frame->Commit(),"PNG frame commit",error) && CaptureCheck(encoder->Commit(),"PNG commit",error);
}
} // namespace kf2vr::diagnostics
