#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <cstdint>

namespace kf2vr::adapter::timing {
// One outstanding sample. Never flush, spin or reuse queries awaiting results.
// Elapsed GPU timeline includes bubbles between CPU submissions; it is not GPU
// busy time. The adapter samples every 30 eligible stereo pairs after XR wait.
class GpuFrameTiming {
    Microsoft::WRL::ComPtr<ID3D11Query> disjoint_,start_,end_;
    bool active_=false,pending_=false,valid_=false;
public:
    enum class Result { Empty, Pending, Ready, Discarded, Error };
    bool Initialise(ID3D11Device* device) {
        if(!device) return false;
        D3D11_QUERY_DESC desc{D3D11_QUERY_TIMESTAMP_DISJOINT,0};
        if(FAILED(device->CreateQuery(&desc,&disjoint_))) return false;
        desc.Query=D3D11_QUERY_TIMESTAMP;
        return SUCCEEDED(device->CreateQuery(&desc,&start_)) &&
            SUCCEEDED(device->CreateQuery(&desc,&end_));
    }
    bool Begin(ID3D11DeviceContext* context) {
        if(!context || !disjoint_ || !start_ || !end_ || active_ || pending_) return false;
        context->Begin(disjoint_.Get());context->End(start_.Get());
        active_=true;return true;
    }
    void End(ID3D11DeviceContext* context,bool valid) {
        if(!active_ || !context) return;
        context->End(end_.Get());context->End(disjoint_.Get());
        active_=false;pending_=true;valid_=valid;
    }
    Result Poll(ID3D11DeviceContext* context,double& milliseconds) {
        if(!pending_ || !context) return Result::Empty;
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT frequency{};
        UINT64 start=0,end=0;
        constexpr UINT flags=D3D11_ASYNC_GETDATA_DONOTFLUSH;
        const HRESULT a=context->GetData(disjoint_.Get(),&frequency,sizeof(frequency),flags);
        if(a==S_FALSE) return Result::Pending;
        if(FAILED(a)) { pending_=false;return Result::Error; }
        const HRESULT b=context->GetData(start_.Get(),&start,sizeof(start),flags);
        const HRESULT c=context->GetData(end_.Get(),&end,sizeof(end),flags);
        if(FAILED(b) || FAILED(c)) { pending_=false;return Result::Error; }
        if(b==S_FALSE || c==S_FALSE) return Result::Pending;
        pending_=false;
        if(!valid_ || frequency.Disjoint || !frequency.Frequency || end<start) return Result::Discarded;
        milliseconds=static_cast<double>(end-start)*1000.0/static_cast<double>(frequency.Frequency);
        return Result::Ready;
    }
};
}
