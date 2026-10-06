#ifdef NDEBUG
#undef NDEBUG
#endif
#include "MotionSession.h"
#include "MotionRuntime.h"
#include <cassert>
#include <fstream>
#include <iostream>
using namespace kf2vr::adapter::motion;
static std::string Read(const std::filesystem::path& path) {
    std::ifstream f(path,std::ios::binary);return {std::istreambuf_iterator<char>(f),{}};
}
static std::vector<Sample> Clip(const std::filesystem::path& path) {
    const auto bytes=Read(path);std::vector<Sample> samples;
    assert(decode({bytes.begin(),bytes.end()},samples));return samples;
}
int main() {
    const std::string uuid="12345678-1234-4234-8234-123456789abc";
    assert(SessionRecorder::Identity(uuid));assert(!SessionRecorder::Identity("../capture"));
    assert(!SessionRecorder::Identity("12345678-1234-4234-8234-123456789ab\""));
    assert(SessionRecorder::Utc("2026-10-05T12:30:00Z"));
    assert(SessionRecorder::Utc("2026-10-05T12:30:00.123456Z"));
    assert(!SessionRecorder::Utc("2026-10-05T12:30:00.Z"));
    assert(!SessionRecorder::Utc("2026-10-05T12:30:00+00:00"));
    assert(SessionRecorder::CanQueue(0)&&SessionRecorder::CanQueue(1)&&!SessionRecorder::CanQueue(2));
    assert(SessionRecorder::CanWrite(0,0,1024));
    assert(!SessionRecorder::CanWrite(SessionRecorder::SegmentCount,0,1));
    assert(SessionRecorder::CanWrite(0,SessionRecorder::DiskBytes-4097,1));
    assert(!SessionRecorder::CanWrite(0,SessionRecorder::DiskBytes-4096,1));
    assert(!SessionRecorder::CanWrite(0,UINT64_MAX,1));
    const auto root=std::filesystem::temp_directory_path()/
        (L"kf2vr-motion-unit-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(SessionRecorder::Clock()));
    SessionRecorder::Config config{root/L"normal",uuid,"2026-10-05T12:30:00.123456Z"};
    SessionRecorder disabled;Sample sample;disabled.Append(sample,0);disabled.Close();
    assert(!std::filesystem::exists(root));
    SetEnvironmentVariableW(L"KF2VR_RECORD_MOTION",nullptr);
    SessionRecorder::Config env;assert(!SessionRecorder::FromEnvironment(env));
    Runtime offRuntime;offRuntime.Configure(false,false);offRuntime.Shutdown();
    assert(!offRuntime.CaptureConfigured());
    assert(!std::filesystem::exists(root));
    // The adapter uses this cleanup both before orderly process exit and when
    // hook initialization refuses after configuration. No game hooks run here.
    const auto runtimeDirectory=root/L"runtime-cleanup";
    SetEnvironmentVariableW(L"KF2VR_RECORD_MOTION",L"1");
    SetEnvironmentVariableW(L"KF2VR_MOTION_SESSION_DIR",runtimeDirectory.c_str());
    SetEnvironmentVariableW(L"KF2VR_CAPTURE_SESSION_ID",L"12345678-1234-4234-8234-123456789abc");
    SetEnvironmentVariableW(L"KF2VR_CAPTURE_SESSION_STARTED_UTC",L"2026-10-05T12:30:00.123Z");
    SetEnvironmentVariableW(L"KF2VR_PROMO_SESSION",L"12345678-1234-4234-8234-123456789abc");
    Runtime configured;configured.Configure(true,false);assert(configured.CaptureConfigured());
    configured.Shutdown();configured.Shutdown();
    assert(Read(runtimeDirectory/L"session.jsonl").find("\"event\":\"session_end\"")!=std::string::npos);
    SetEnvironmentVariableW(L"KF2VR_RECORD_MOTION",nullptr);
    SetEnvironmentVariableW(L"KF2VR_MOTION_SESSION_DIR",nullptr);
    SetEnvironmentVariableW(L"KF2VR_CAPTURE_SESSION_ID",nullptr);
    SetEnvironmentVariableW(L"KF2VR_CAPTURE_SESSION_STARTED_UTC",nullptr);
    SetEnvironmentVariableW(L"KF2VR_PROMO_SESSION",nullptr);
    SessionRecorder session;assert(session.Start(config));
    const auto clock=SessionRecorder::ReadAnchor();
    sample.input.state=kf2vr::xr::SessionState::Focused;sample.input.actionsSynced=true;
    sample.input.handLeft.triggerActive=true;
    session.Append(sample,clock.ticks);
    session.Append(sample,clock.ticks+clock.frequency*5);
    // Segment overlap seeds held state; the next real edge is retained.
    sample.input.handLeft.triggerAxis=1;
    session.Append(sample,clock.ticks+clock.frequency*5+clock.frequency/100);
    session.Close();session.Close();assert(!session.Active()&&!session.Failed());
    auto first=Clip(config.directory/L"segment-1.kfm"),second=Clip(config.directory/L"segment-2.kfm");
    assert(first.size()==2&&second.size()==2);
    assert(second[0].seconds==0&&second[0].boundary==Start&&second[1].pressed==1);
    const auto manifest=Read(config.directory/L"session.jsonl");
    assert(manifest.find(uuid)!=std::string::npos&&manifest.find("\"qpc_frequency\"")!=std::string::npos);
    assert(manifest.find("\"overlap_frames\":1")!=std::string::npos);
    assert(manifest.find("\"event\":\"session_end\"")!=std::string::npos);
    assert(manifest.find("\"reason\":\"shutdown\"")!=std::string::npos);
    const auto before=Read(config.directory/L"segment-1.kfm");
    SessionRecorder duplicate;assert(!duplicate.Start(config));duplicate.Close();
    assert(Read(config.directory/L"segment-1.kfm")==before);
    config.directory=root/L"invalid";SessionRecorder invalid;assert(invalid.Start(config));
    sample.input.handLeft.triggerAxis=std::numeric_limits<float>::quiet_NaN();
    invalid.Append(sample,clock.ticks);invalid.Close();assert(invalid.Failed()&&!invalid.Active());
    assert(std::string(invalid.Failure())=="invalid_sample");
    config.directory=root/L"write-failure";SessionRecorder failure;assert(failure.Start(config));
    // Occupy the first exclusive temp path for a deterministic disk failure.
    std::filesystem::create_directory(config.directory/L"segment-1.kfm.tmp");
    sample={};failure.Append(sample,clock.ticks);failure.Close();
    assert(failure.Failed()&&!failure.Active()&&std::string(failure.Failure())=="segment_open");
    assert(!std::filesystem::exists(config.directory/L"segment-1.kfm"));
    // Test owns this fresh temporary tree only.
    std::filesystem::remove_all(root);
    std::cout<<"Motion session identity, off state, bounds, rotation, final save, no overwrite and failure state passed\n";
}
