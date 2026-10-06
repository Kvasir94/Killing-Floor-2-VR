#pragma once
#include "MotionClip.h"
#include <windows.h>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>

namespace kf2vr::adapter::motion {
// Local input/presentation capture only. No playback, network, video or engine
// pointers. The writer never calls game code and has a bounded work queue.
class SessionRecorder {
public:
    static constexpr std::size_t SegmentFrames=2048, QueueSegments=2;
    static constexpr std::uint64_t DiskBytes=256ULL*1024*1024, SegmentCount=4096;
    using Logger=void(*)(const char*,...);
    struct Config { std::filesystem::path directory; std::string id,startedUtc; };
    struct Anchor { std::uint64_t ticks{},frequency{},utcUs{},spanTicks{}; };
    static bool CanQueue(std::size_t pending) noexcept {return pending<QueueSegments;}
    static bool CanWrite(std::uint64_t segments,std::uint64_t bytes,std::size_t size) noexcept {
        return segments<SegmentCount&&bytes<=DiskBytes-4096&&size<=DiskBytes-4096-bytes;
    }
    static std::uint64_t Clock() noexcept { LARGE_INTEGER q{};QueryPerformanceCounter(&q);return q.QuadPart; }
    static Anchor ReadAnchor() noexcept {
        LARGE_INTEGER f{};QueryPerformanceFrequency(&f);
        const auto before=Clock();FILETIME ft{};GetSystemTimePreciseAsFileTime(&ft);const auto after=Clock();
        return {before+(after-before)/2,static_cast<std::uint64_t>(f.QuadPart),
            ((std::uint64_t(ft.dwHighDateTime)<<32)|ft.dwLowDateTime)/10-11644473600000000ULL,after-before};
    }
    static bool Identity(const std::string& id) noexcept {
        if(id.size()!=36)return false;
        for(std::size_t i=0;i<id.size();++i){const char c=id[i];const bool dash=i==8||i==13||i==18||i==23;
            if(dash?c!='-':!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;}
        return true;
    }
    static bool Utc(const std::string& utc) noexcept {
        if((utc.size()!=20&&(utc.size()<22||utc.size()>32))||utc.back()!='Z')return false;
        for(std::size_t i=0;i<utc.size()-1;++i){const char c=utc[i];
            if(i==4||i==7){if(c!='-')return false;}
            else if(i==10){if(c!='T')return false;}
            else if(i==13||i==16){if(c!=':')return false;}
            else if(i==19){if(c!='.')return false;}
            else if(c<'0'||c>'9')return false;}
        return true;
    }
    static std::wstring Environment(const wchar_t* name) {
        wchar_t value[32768]{};const auto n=GetEnvironmentVariableW(name,value,32768);
        return n&&n<32768?std::wstring(value,n):std::wstring{};
    }
    static bool FromEnvironment(Config& config) {
        if(Environment(L"KF2VR_RECORD_MOTION")!=L"1")return false;
        config.directory=Environment(L"KF2VR_MOTION_SESSION_DIR");
        const auto id=Environment(L"KF2VR_CAPTURE_SESSION_ID"),utc=Environment(L"KF2VR_CAPTURE_SESSION_STARTED_UTC");
        const auto promo=Environment(L"KF2VR_PROMO_SESSION");
        if(!promo.empty()&&promo!=id)return false;
        config.id.clear();config.startedUtc.clear();
        for(auto c:id){if(c>127)return false;config.id.push_back(static_cast<char>(c));}
        for(auto c:utc){if(c>127)return false;config.startedUtc.push_back(static_cast<char>(c));}
        return Identity(config.id)&&Utc(config.startedUtc)&&config.directory.is_absolute();
    }
    ~SessionRecorder(){Close();}
    bool Start(Config config,Logger logger=nullptr) noexcept try {
        std::lock_guard guard(mutex_);
        if(started_||!Identity(config.id)||!Utc(config.startedUtc)||!config.directory.is_absolute())return false;
        logger_=logger;config_=std::move(config);anchor_=ReadAnchor();
        if(!anchor_.frequency)return false;
        // The launcher owns an empty per-role directory; never overwrite a
        // previous capture, nor send raw motion to a network drive.
        if(config_.directory.native().starts_with(L"\\\\")||
            GetDriveTypeW(config_.directory.root_path().c_str())==DRIVE_REMOTE)return false;
        std::filesystem::create_directories(config_.directory);
        if(!std::filesystem::is_empty(config_.directory))return false;
        manifest_=CreateFileW((config_.directory/L"session.jsonl").c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(manifest_==INVALID_HANDLE_VALUE)return false;
        started_=true;
        if(!Line("\"event\":\"session_start\",\"capture_session_started_utc\":\""+config_.startedUtc+
            "\",\"segment_frames\":2048,\"segment_seconds\":5,\"queue_segments\":2,\"limit_bytes\":268435456,\"limit_segments\":4096,"+
            "\"content\":\"local_motion_input_presentation\",\"video\":false,\"deterministic_world_replay\":false,"+AnchorFields(anchor_))) {
            Fail("metadata_write");CloseHandle(manifest_);manifest_=INVALID_HANDLE_VALUE;return false;
        }
        accepting_=true;worker_=std::thread([this]{WriteLoop();});
        if(logger_)logger_("MotionSession enabled=1 localOnly=1 segmentSeconds=5 limitBytes=268435456");
        return true;
    } catch(...) { Fail("session_start");accepting_=false;return false; }
    bool Active()const noexcept {return accepting_.load()&&!failed_.load();}
    bool Failed()const noexcept {return failed_.load();}
    const char* Failure()const noexcept {return reason_.load();}
    // ticks share the promo logger's Windows QPC domain. Clip seconds are
    // relative to segment_qpc_ticks, not wall time, game time or XR time.
    void Append(Sample sample,std::uint64_t ticks) noexcept try {
        if(!Active())return;
        std::lock_guard guard(mutex_);if(!Active())return;
        if(!recording_){segmentTicks_=ticks;recorder_.StartRecording(double(ticks)/anchor_.frequency,SegmentFrames);recording_=true;}
        if(!valid(sample)){Fail("invalid_sample");return;}
        if(!recorder_.Append(sample,double(ticks)/anchor_.frequency))return;
        lastTicks_=ticks;
        if(recorder_.samples.size()>=SegmentFrames||ticks-segmentTicks_>=5*anchor_.frequency) {
            Rotate();
        }
    } catch(...) {Fail("capture_allocation");}
    // Called outside DLL loader lock after the game-thread producer stops.
    // A forced process termination can lose the pending/partial segment.
    void Close() noexcept {
        try {
            {std::unique_lock lock(mutex_);
                if(!started_||closing_)return;
                accepting_=false;
                // At quit the writer may finish outstanding segments before
                // the final partial one is queued. During play Append never waits.
                wake_.wait(lock,[this]{return failed_||CanQueue(queue_.size());});
                if(!failed_&&recording_&&recorder_.samples.size()>(overlap_?1u:0u))Queue();
                recorder_.Stop();recorder_.samples.clear();closing_=true;wake_.notify_one();}
            if(worker_.joinable())worker_.join();
            if(manifest_!=INVALID_HANDLE_VALUE){
                Line(std::string("\"event\":\"session_end\",\"reason\":\"")+(failed_?Failure():"shutdown")+
                    "\",\"segments\":"+std::to_string(written_)+",\"bytes\":"+std::to_string(bytes_)+","+AnchorFields(ReadAnchor()));
                CloseHandle(manifest_);manifest_=INVALID_HANDLE_VALUE;
            }
        }catch(...){Fail("session_close");}
    }
private:
    struct Segment {std::vector<Sample> samples;std::uint64_t ticks{},lastTicks{};bool overlap{};};
    void Fail(const char* reason) noexcept {
        const char* expected=NoFailure;
        if(reason_.compare_exchange_strong(expected,reason)){accepting_=false;failed_=true;
            wake_.notify_all();
            if(logger_)logger_("MotionSession disabled=1 reason=%s",reason);}
    }
    bool Queue() {
        if(!CanQueue(queue_.size())){Fail("writer_backpressure");return false;}
        queue_.push_back({std::move(recorder_.samples),segmentTicks_,lastTicks_,overlap_});wake_.notify_one();return true;
    }
    void Rotate() {
        const auto overlap=recorder_.samples.back();
        if(!Queue())return;
        segmentTicks_=lastTicks_;recorder_.StartRecording(double(lastTicks_)/anchor_.frequency,SegmentFrames);
        recorder_.Append(overlap,double(lastTicks_)/anchor_.frequency);overlap_=true;
    }
    static bool Write(HANDLE file,const void* data,std::size_t size) noexcept {
        DWORD n=0;return size<=MAXDWORD&&WriteFile(file,data,static_cast<DWORD>(size),&n,nullptr)&&n==size;
    }
    static std::string AnchorFields(const Anchor& a) {
        return "\"qpc_ticks\":"+std::to_string(a.ticks)+",\"qpc_frequency\":"+std::to_string(a.frequency)+
            ",\"utc_unix_us\":"+std::to_string(a.utcUs)+",\"anchor_read_span_ticks\":"+std::to_string(a.spanTicks);
    }
    bool Line(const std::string& fields) {
        const auto line="{\"schema\":\"kf2vr/motion-session/1\",\"session_id\":\""+config_.id+"\","+fields+"}\n";
        if(bytes_+line.size()>DiskBytes||!Write(manifest_,line.data(),line.size())||!FlushFileBuffers(manifest_))return false;
        bytes_+=line.size();return true;
    }
    void WriteLoop() noexcept try {
        for(;;){Segment segment;
            {std::unique_lock lock(mutex_);
                wake_.wait_for(lock,std::chrono::seconds(1),[this]{return closing_||failed_||!queue_.empty();});
                // Persist the last partial samples even when travel/loading
                // stops the bridge pump. Never emit overlap-only segments.
                const auto now=Clock();
                if(!closing_&&!failed_&&queue_.empty()&&recording_&&
                    recorder_.samples.size()>(overlap_?1u:0u)&&now>=segmentTicks_&&now-segmentTicks_>=5*anchor_.frequency)Rotate();
                if(queue_.empty()){if(closing_||failed_)break;continue;}
                segment=std::move(queue_.front());queue_.pop_front();wake_.notify_all();}
            if(failed_)continue;
            auto data=encode(segment.samples);
            if(data.empty()){Fail("segment_encode");continue;}
            // Reserve metadata/final status space inside the hard disk limit.
            if(!CanWrite(written_,bytes_,data.size())){Fail("session_limit");continue;}
            const auto name="segment-"+std::to_string(written_+1)+".kfm";
            const auto path=config_.directory/name;auto temp=path;temp+=L".tmp";
            HANDLE file=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
            if(file==INVALID_HANDLE_VALUE){Fail("segment_open");continue;}
            const bool ok=Write(file,data.data(),data.size())&&FlushFileBuffers(file);
            const bool closed=CloseHandle(file)!=0;
            if(!ok||!closed||!MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_WRITE_THROUGH)){
                DeleteFileW(temp.c_str());Fail("segment_write");continue;}
            bytes_+=data.size();++written_;
            if(!Line("\"event\":\"segment\",\"file\":\""+name+"\",\"frames\":"+std::to_string(segment.samples.size())+
                ",\"overlap_frames\":"+std::to_string(segment.overlap?1:0)+",\"segment_qpc_ticks\":"+std::to_string(segment.ticks)+
                ",\"last_sample_qpc_ticks\":"+std::to_string(segment.lastTicks)+",\"bytes\":"+std::to_string(data.size())+","+AnchorFields(ReadAnchor())))Fail("metadata_write");
        }
    }catch(...){Fail("writer_exception");}
    Config config_;Anchor anchor_;Logger logger_{};Recorder recorder_;
    std::mutex mutex_;std::condition_variable wake_;std::deque<Segment> queue_;std::thread worker_;
    HANDLE manifest_=INVALID_HANDLE_VALUE;
    static constexpr const char* NoFailure="none";
    std::atomic<bool> accepting_{false},failed_{false};std::atomic<const char*> reason_{NoFailure};
    bool started_{},closing_{},recording_{},overlap_{};
    std::uint64_t segmentTicks_{},lastTicks_{},bytes_{},written_{};
};
} // namespace kf2vr::adapter::motion
