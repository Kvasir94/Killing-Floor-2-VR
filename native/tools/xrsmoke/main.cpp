#include "SmokeScene.h"
#include "kf2vr/xr/OpenXrD3D11Backend.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <thread>

using Microsoft::WRL::ComPtr;
using namespace kf2vr::xr;
namespace {
using Clock=std::chrono::steady_clock;
int Usage() {
    std::puts("xrsmoke --self-test [--output DIR]\n"
              "xrsmoke --run [--seconds 30] [--output DIR]\n"
              "--run starts the OpenXR runtime and displays a diagnostic scene.\n"
              "Red cube: left/1.5m; green: center/3m; blue: right/6m. Gold bar: 1m.\n"
              "No KF2 integration or performance acceptance is implied.\n"
              "Capture readback stalls the GPU once; do not benchmark that frame.");
    return 0;
}

int SelfTest(const std::filesystem::path& output) {
    using namespace DirectX;
    unsigned checks=0, failures=0;
    auto check=[&](bool condition,const char* label) { ++checks; if (!condition) { ++failures; std::printf("FAIL: %s\n",label); } };
    // Project independently specified boundary rays. Asymmetric fields expose
    // sign or angle/tangent mistakes hidden by a symmetric headset fixture.
    const float l=-.65f,r=.9f,d=-.7f,u=.8f;
    const XMMATRIX projection=SmokeScene::Projection(l,r,d,u);
    auto projected=[&](float x,float y,float z) { XMFLOAT3 p{}; XMStoreFloat3(&p,XMVector3TransformCoord(XMVectorSet(x,y,z,1),projection)); return p; };
    check(std::fabs(projected(std::tan(l),0,-1).x+1)<1e-5f,"left FOV boundary maps to -1");
    check(std::fabs(projected(std::tan(r),0,-1).x-1)<1e-5f,"right FOV boundary maps to +1");
    check(std::fabs(projected(0,std::tan(d),-1).y+1)<1e-5f,"down FOV boundary maps to -1");
    check(std::fabs(projected(0,std::tan(u),-1).y-1)<1e-5f,"up FOV boundary maps to +1");
    check(std::fabs(projected(0,0,-.05f).z)<1e-5f,"D3D near depth is zero");
    check(std::fabs(projected(0,0,-100).z-1)<1e-5f,"D3D far depth is one");
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context; D3D_FEATURE_LEVEL feature{};
    const D3D_FEATURE_LEVEL levels[]{D3D_FEATURE_LEVEL_11_0};
    if (FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,levels,1,D3D11_SDK_VERSION,&device,&feature,&context))) {
        std::puts("WARP D3D11 device failed"); return 1;
    }
    std::string error; SmokeScene scene;
    if (!scene.Initialise(device.Get(),error)) { std::puts(error.c_str()); return 1; }
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width=640; desc.Height=480; desc.MipLevels=1; desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; desc.SampleDesc.Count=1;
    desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> color,depth;
    ComPtr<ID3D11RenderTargetView> rtv; ComPtr<ID3D11DepthStencilView> dsv;
    if (FAILED(device->CreateTexture2D(&desc,nullptr,&color)) || FAILED(device->CreateRenderTargetView(color.Get(),nullptr,&rtv))) return 1;
    desc.Format=DXGI_FORMAT_D32_FLOAT; desc.BindFlags=D3D11_BIND_DEPTH_STENCIL;
    if (FAILED(device->CreateTexture2D(&desc,nullptr,&depth)) || FAILED(device->CreateDepthStencilView(depth.Get(),nullptr,&dsv))) return 1;
    std::vector<unsigned char> images[2];
    double centroids[2]{};
    for (int eye=0;eye<2;++eye) {
        check(scene.Render(context.Get(),rtv.Get(),dsv.Get(),640,480,{}, {eye==0?-.032f:.032f,0,0},-.785398f,.785398f,-.785398f,.785398f),"render scene");
        const auto path=output/(eye==0?"left.png":"right.png");
        if (!SmokeScene::Capture(context.Get(),color.Get(),path,error,&images[eye])) { std::puts(error.c_str()); return 1; }
        size_t green=0; double totalX=0;
        for (size_t p=0;p<images[eye].size();p+=4) {
            const auto* rgb=images[eye].data()+p;
            if (rgb[1]>150 && rgb[0]<100 && rgb[2]<150) { ++green; totalX+=static_cast<double>((p/4)%640); }
        }
        check(green>100,"green depth marker present in actual D3D pixels");
        centroids[eye]=green?totalX/static_cast<double>(green):0;
    }
    check(images[0]!=images[1],"actual stereo images are distinct");
    check(centroids[0]>centroids[1]+3,"positive binocular disparity at known 3m depth");
    std::ofstream report(output/"self-test.json");
    report<<"{\n  \"schema\": \"kf2vr/d3d11-smoke/1\",\n  \"device\": \"D3D11 WARP\",\n  \"evidence\": \"synthetic GPU-rendered stereo, no XR runtime or game\",\n  \"checks\": "<<checks
          <<",\n  \"failures\": "<<failures<<",\n  \"green_centroid_left\": "<<centroids[0]<<",\n  \"green_centroid_right\": "<<centroids[1]<<"\n}\n";
    std::printf("D3D11 scene checks: %u, failures: %u. Captures: %ls\n",checks,failures,output.c_str());
    return failures?1:0;
}

int Run(unsigned seconds,const std::filesystem::path& output) {
    OpenXrD3D11Backend backend;
    D3D11Options options; options.preferStageSpace=false; options.applicationName="KF2VR stereo diagnostic";
    const auto started=Clock::now();
    if (!backend.Initialise(options)) { std::fprintf(stderr,"XR unavailable: %s\n",backend.LastError().c_str()); return 3; }
    const auto info=backend.Info();
    std::printf("Runtime %s %s; LUID %08x:%08x; per-eye %ux%u\n",info.name.c_str(),info.version.c_str(),
        static_cast<unsigned>(info.adapterLuidHigh),info.adapterLuidLow,backend.RecommendedWidth(),backend.RecommendedHeight());
    std::fflush(stdout);
    SmokeScene scene; std::string error;
    if (!scene.Initialise(backend.Device(),error)) { std::fprintf(stderr,"%s\n",error.c_str()); return 1; }
    std::ofstream csv(output/"frames.csv");
    csv<<"sample,time_s,period_s,state,should_render,head_valid,views_valid,left_grip_valid,right_grip_valid,left_trigger,right_trigger,left_eye_x,left_eye_y,left_eye_z,right_eye_x,right_eye_y,right_eye_z,cpu_render_submit_ms,capture_frame\n";
    std::uint64_t capturedSample=0; bool requestedExit=false,failed=false;
    SessionState lastState=SessionState::Idle;
    const auto deadline=Clock::now()+std::chrono::seconds(seconds);
    while (!backend.ShouldQuit()) {
        if (Clock::now()>=deadline && !requestedExit) { backend.RequestExit(); requestedExit=true; }
        if (Clock::now()>deadline+std::chrono::seconds(5)) break;
        FrameState frame;
        if (!backend.BeginFrame(frame)) {
            if (!backend.LastError().empty()) { failed=true; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue;
        }
        if (frame.state!=lastState) { std::printf("Session state %u, sample %llu\n",static_cast<unsigned>(frame.state),static_cast<unsigned long long>(frame.poseSampleId)); std::fflush(stdout); lastState=frame.state; }
        const bool capture=!capturedSample && frame.state==SessionState::Focused && frame.viewsValid && backend.Counters().submitted>=30;
        const auto cpuStart=Clock::now();
        const bool rendered=backend.RenderEyes([&](const FrameState& sample,const D3D11EyeTarget& target) {
            auto render=[&](const auto& eye) {
                return scene.Render(backend.Context(),target.colorView,target.depthView,target.width,target.height,
                    eye.pose.rot,eye.pose.pos,eye.fov.angleLeft,eye.fov.angleRight,eye.fov.angleDown,eye.fov.angleUp,
                    sample.handLeft.poseValid?&sample.handLeft.grip.pos:nullptr,sample.handRight.poseValid?&sample.handRight.grip.pos:nullptr);
            };
            if (!(target.eye==Eye::Left?render(sample.eyeLeft):render(sample.eyeRight))) return false;
            if (capture && !SmokeScene::Capture(backend.Context(),target.colorTexture,output/(target.eye==Eye::Left?"left.png":"right.png"),error)) return false;
            return true;
        });
        const bool ended=backend.EndFrame();
        const double cpuMs=std::chrono::duration<double,std::milli>(Clock::now()-cpuStart).count();
        if (capture && rendered && ended) capturedSample=frame.poseSampleId;
        csv<<frame.poseSampleId<<','<<frame.predictedDisplayTime<<','<<frame.predictedDisplayPeriod<<','<<static_cast<unsigned>(frame.state)<<','
           <<frame.shouldRender<<','<<frame.headPoseValid<<','<<frame.viewsValid<<','<<frame.handLeft.poseValid<<','<<frame.handRight.poseValid<<','
           <<frame.handLeft.triggerAxis<<','<<frame.handRight.triggerAxis<<','<<frame.eyeLeft.pose.pos.x<<','<<frame.eyeLeft.pose.pos.y<<','<<frame.eyeLeft.pose.pos.z<<','
           <<frame.eyeRight.pose.pos.x<<','<<frame.eyeRight.pose.pos.y<<','<<frame.eyeRight.pose.pos.z<<','<<cpuMs<<','<<capture<<'\n';
        if (!rendered || !ended) { failed=true; break; }
    }
    const auto counters=backend.Counters();
    const auto lastError=backend.LastError();
    backend.Shutdown();
    std::ofstream report(output/"run.txt");
    report<<"evidence=standalone OpenXR diagnostic; no KF2 integration or headset acceptance\n"
          <<"runtime="<<info.name<<' '<<info.version<<"\nload_state=cold process; runtime warm state uncontrolled\ngpu_time=unmeasured\n"
          <<"frames_begun="<<counters.begun<<"\nframes_ended="<<counters.ended<<"\nstereo_layers_submitted="<<counters.submitted
          <<"\ninvalid_views="<<counters.invalidViews<<"\nfocus_losses="<<counters.focusLosses<<"\ncaptured_sample="<<capturedSample
          <<"\nelapsed_s="<<std::chrono::duration<double>(Clock::now()-started).count()<<"\nerror="<<lastError<<' '<<error<<"\nshutdown_returned=true\n";
    std::printf("Frames begun/ended/submitted: %llu/%llu/%llu; capture sample %llu; shutdown returned\n",
        static_cast<unsigned long long>(counters.begun),static_cast<unsigned long long>(counters.ended),
        static_cast<unsigned long long>(counters.submitted),static_cast<unsigned long long>(capturedSample));
    if (!lastError.empty()) std::fprintf(stderr,"%s\n",lastError.c_str());
    return failed || !counters.submitted || counters.begun!=counters.ended?1:0;
}
}

int main(int argc,char** argv) {
    bool run=false,selfTest=false; unsigned seconds=30;
    std::filesystem::path output="xrsmoke-output";
    for (int i=1;i<argc;++i) {
        const std::string arg=argv[i];
        if (arg=="--help") return Usage();
        if (arg=="--run") run=true;
        else if (arg=="--self-test") selfTest=true;
        else if (arg=="--output" && i+1<argc) output=argv[++i];
        else if (arg=="--seconds" && i+1<argc) {
            try { size_t consumed=0; const std::string value=argv[++i]; seconds=static_cast<unsigned>(std::stoul(value,&consumed));
                if (consumed!=value.size() || seconds<1 || seconds>600) return 2;
            } catch (...) { return 2; }
        } else { Usage(); return 2; }
    }
    if (run==selfTest) { Usage(); return argc==1?0:2; }
    const HRESULT com=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if (FAILED(com)) return 1;
    int result=1;
    try {
        std::filesystem::create_directories(output);
        result=selfTest?SelfTest(output):Run(seconds,output);
    } catch (const std::exception& error) { std::fprintf(stderr,"%s\n",error.what()); }
    CoUninitialize();
    return result;
}
