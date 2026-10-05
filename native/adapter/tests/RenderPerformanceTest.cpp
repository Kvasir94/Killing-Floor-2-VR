#include <windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <cstdio>
#include <limits>
#include "EyeResolution.h"
#include "FrameTiming.h"
#include "GpuFrameTiming.h"

using Microsoft::WRL::ComPtr;
using namespace kf2vr::adapter;
namespace {
int checks=0,failures=0;
void Test(bool okay,const char* message) {
    ++checks;if(!okay) { ++failures;std::printf("FAIL %s\n",message); }
}
}
int main() {
    unsigned percent=100;
    for(const auto* text:{L"",L"49",L"101",L"nan",L"75.0",L"-75",L"75junk",L"999999999"})
        Test(!ParseEyeRenderPercent(text,percent) && percent==100,"invalid resolution leaves default intact");
    Test(ParseEyeRenderPercent(L"75",percent) && percent==75,"linear percentage parsed");
    Test(ScaledEyeExtent(2244,percent)==1683 && ScaledEyeExtent(2352,percent)==1764,"75 percent scales both dimensions");
    Test(ScaledEyeExtent(2244,100)==2244 && ScaledEyeExtent(2352,50)==1176,"default and lower boundary");
    Test(ScaledEyeExtent(0,100)==0 && ScaledEyeExtent(2244,101)==0,"invalid extents rejected");

    using namespace timing;
    enabled=true;scriptEnabled=false;
    auto& state=Current();state.calls={};
    const auto before=state.last;
    { Scope dispatch(ScriptDispatch);Scope body(ScriptBody); }
    Test(state.last==before && state.calls[ScriptDispatch]==0 && state.calls[ScriptBody]==0,
        "coarse stage tracing leaves full VM scopes disabled");
    {
        Scope left(LeftView);
        { Scope world(WorldScene);Test(state.active==WorldScene,"nested coarse stage active"); }
        Test(state.active==LeftView,"outer coarse stage restored");
    }
    Test(state.active==Other && state.calls[LeftView]==1 && state.calls[WorldScene]==1,"coarse stages restore owner state");
    scriptEnabled=true;
    { Scope dispatch(ScriptDispatch);Scope body(ScriptBody); }
    Test(state.calls[ScriptDispatch]==1 && state.calls[ScriptBody]==1,"VM timing requires explicit opt-in");
    enabled=false;
    { Scope dispatch(ScriptDispatch); }
    Test(state.calls[ScriptDispatch]==1,"global disable overrides VM option");
    Intervals intervals;
    intervals.Add(-1);intervals.Add(std::numeric_limits<double>::quiet_NaN());
    Test(intervals.count==0 && intervals.Percentile(.99)==0,"empty and invalid intervals");
    for(int i=100;i>0;--i) intervals.Add(i);
    Test(intervals.Percentile(.50)==50 && intervals.Percentile(.95)==95 && intervals.Percentile(.99)==99,
        "nearest-rank percentiles sort actual intervals");
    Test(intervals.over90==89 && intervals.over120==92 && intervals.maximum==100 && intervals.total==5050,
        "deadline counts and arithmetic retain individual intervals");
    intervals={};
    for(int i=0;i<4100;++i) intervals.Add(10);
    Test(intervals.count==4096 && intervals.overflow==4 && intervals.total==41000 && intervals.over120==4100,
        "bounded percentile storage reports overflow without losing totals");

    ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
    if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,
        &device,nullptr,&context))) return 2;
    GpuFrameTiming gpu;
    double ms=-1;
    Test(!gpu.Begin(context.Get()) && gpu.Poll(context.Get(),ms)==GpuFrameTiming::Result::Empty,"uninitialised GPU sampler inert");
    Test(gpu.Initialise(device.Get()),"WARP timestamp queries created");
    const auto poll=[&] {
        // Test harness drives submission in place of the game's normal Present.
        // Production sampler contains no Flush or wait loop.
        context->Flush();
        auto result=GpuFrameTiming::Result::Pending;
        for(int i=0;i<1000 && result==GpuFrameTiming::Result::Pending;++i) {
            result=gpu.Poll(context.Get(),ms);
            if(result==GpuFrameTiming::Result::Pending) Sleep(1);
        }
        return result;
    };
    Test(gpu.Begin(context.Get()) && !gpu.Begin(context.Get()),"GPU sample cannot nest");
    gpu.End(context.Get(),true);
    Test(!gpu.Begin(context.Get()),"outstanding GPU query cannot be overwritten");
    Test(poll()==GpuFrameTiming::Result::Ready && ms>=0,"asynchronous timestamp result consumed");
    Test(gpu.Poll(context.Get(),ms)==GpuFrameTiming::Result::Empty,"sample cannot be counted twice");
    Test(gpu.Begin(context.Get()),"queries reusable after readback");
    gpu.End(context.Get(),false);
    Test(poll()==GpuFrameTiming::Result::Discarded,"resize/cancelled pair cannot become valid GPU evidence");
    Test(gpu.Begin(context.Get()),"cancelled query can be reused after draining");
    gpu.End(context.Get(),true);
    Test(poll()==GpuFrameTiming::Result::Ready,"new valid pair after cancellation");
    std::printf("%d checks, %d failures\n",checks,failures);
    return failures?1:0;
}
