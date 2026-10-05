#pragma once
#include <d3d11.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <vector>
#include <cstring>
#include <algorithm>

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
} // namespace kf2vr::diagnostics
