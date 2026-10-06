#pragma once
#include "MotionClip.h"
#include "MotionSession.h"
#include "GameScript.h"
#include <chrono>
#include <filesystem>
#include <fstream>

namespace kf2vr::adapter::motion {
class Runtime {
    // Adapter globals live until process termination. Keep the worker resident
    // unless Shutdown is called explicitly; never join/write under loader lock.
    SessionRecorder* session_=nullptr;
    bool configured_=false;
    Recorder recorder_; Player player_;int request_=0,status_=0;std::size_t namesIndex_=~std::size_t{};
    bool network_=false;double playStarted_=0;std::size_t edgeIndex_=0;
    static double Now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
    static bool Fixture(){return wcsstr(GetCommandLineW(),L"-kf2vr-motion-fixture")!=nullptr;}
    static std::filesystem::path Path(int id){
        std::filesystem::path root=L"D:\\KF2VR-motion-clips";
        if(Fixture()){wchar_t path[32768]{};auto n=GetEnvironmentVariableW(L"KF2VR_MOTION_FIXTURE_ROOT",path,32768);
            if(!n||n>=32768)throw std::runtime_error("Missing isolated fixture clip root");root=path;}
        return root/(L"clip-"+std::to_wstring(id)+L".kfm");
    }
    struct ScriptString {const wchar_t* data=nullptr;int count=0,capacity=0;};
    static std::array<char,128> Text(GameScript& script,void* o,const wchar_t* name){
        std::array<char,128> out{};const auto s=script.Read<ScriptString>(o,name);
        if(s.count<0||s.count>128||s.count>s.capacity||(!s.data&&s.count))return out;
        for(int i=0;i<s.count;++i){auto c=GameScript::At<wchar_t>(s.data,i*sizeof(wchar_t));if(!c)break;if(c>127)return {};out[i]=static_cast<char>(c);}return out;
    }
    static const auto& PositionNames(){static constexpr std::array<const wchar_t*,10> n{L"MotionP0",L"MotionP1",L"MotionP2",L"MotionP3",L"MotionP4",L"MotionP5",L"MotionP6",L"MotionP7",L"MotionP8",L"MotionP9"};return n;}
    static const auto& RotationNames(){static constexpr std::array<const wchar_t*,10> n{L"MotionR0",L"MotionR1",L"MotionR2",L"MotionR3",L"MotionR4",L"MotionR5",L"MotionR6",L"MotionR7",L"MotionR8",L"MotionR9"};return n;}
    static const auto& StateNames(){static constexpr std::array<const wchar_t*,12> n{L"MotionS0",L"MotionS1",L"MotionS2",L"MotionS3",L"MotionS4",L"MotionS5",L"MotionS6",L"MotionS7",L"MotionS8",L"MotionS9",L"MotionS10",L"MotionS11"};return n;}
    static const auto& WeaponNames(){static constexpr std::array<std::array<const wchar_t*,6>,2> n{{{L"MotionW00",L"MotionW01",L"MotionW02",L"MotionW03",L"MotionW04",L"MotionW05"},{L"MotionW10",L"MotionW11",L"MotionW12",L"MotionW13",L"MotionW14",L"MotionW15"}}};return n;}
    static Presentation Read(GameScript& script,void* bridge){Presentation v;
        for(int i=0;i<10;++i){v.positions[i]=script.Read<Vec3>(bridge,PositionNames()[i]);v.rotations[i]=script.Read<std::array<std::int32_t,3>>(bridge,RotationNames()[i]);}
        for(int i=0;i<12;++i)v.state[i]=script.Read<int>(bridge,StateNames()[i]);
        for(int h=0;h<2;++h)for(int i=0;i<6;++i)v.weapon[h][i]=script.Read<int>(bridge,WeaponNames()[h][i]);
        v.bodyYaw=script.Read<float>(bridge,L"MotionBodyYaw");v.eyeHeight=script.Read<float>(bridge,L"MotionEyeHeight");v.gameSeconds=script.Read<float>(bridge,L"MotionGameSeconds");v.velocity=script.Read<Vec3>(bridge,L"MotionVelocity");
        v.weaponClass[0]=Text(script,bridge,L"MotionWeapon0");v.weaponClass[1]=Text(script,bridge,L"MotionWeapon1");v.map=Text(script,bridge,L"MotionMap");
        v.animRate[0]=script.Read<float>(bridge,L"MotionRate0");v.animRate[1]=script.Read<float>(bridge,L"MotionRate1");return v;}
    static void Names(GameScript& script,void* bridge,const Presentation& v){
        std::array<std::wstring,3> text;std::array<ScriptString,3> params;
        for(int i=0;i<3;++i){const auto& a=i<2?v.weaponClass[i]:v.map;for(auto ch:a){if(!ch)break;text[i].push_back(ch);}params[i]={text[i].c_str(),static_cast<int>(text[i].size()+1),static_cast<int>(text[i].size()+1)};}
        script.Invoke(bridge,script.FindFunction(bridge,L"MotionLoadNames"),params.data());
    }
    static void Write(GameScript& script,void* bridge,const Presentation& v){
        for(int i=0;i<10;++i){script.Write(bridge,PositionNames()[i],v.positions[i]);script.Write(bridge,RotationNames()[i],v.rotations[i]);}
        for(int i=0;i<12;++i)script.Write(bridge,StateNames()[i],v.state[i]);
        for(int h=0;h<2;++h)for(int i=0;i<6;++i)script.Write(bridge,WeaponNames()[h][i],v.weapon[h][i]);
        script.Write(bridge,L"MotionBodyYaw",v.bodyYaw);script.Write(bridge,L"MotionEyeHeight",v.eyeHeight);script.Write(bridge,L"MotionGameSeconds",v.gameSeconds);script.Write(bridge,L"MotionVelocity",v.velocity);
        script.Write(bridge,L"MotionRate0",v.animRate[0]);script.Write(bridge,L"MotionRate1",v.animRate[1]);script.Write(bridge,L"MotionHasPose",1);
    }
    bool Save(int id){
        try{auto bytes=encode(recorder_.samples);if(bytes.empty())return false;
            auto path=Path(id);std::filesystem::create_directories(path.parent_path());
            std::uintmax_t total=0;for(auto& e:std::filesystem::directory_iterator(path.parent_path()))if(e.is_regular_file())total+=e.file_size();
            auto temp=path;temp+=L".tmp";
            if(total+bytes.size()>256*1024*1024 || std::filesystem::exists(path)||std::filesystem::exists(temp))return false;
            std::ofstream stream(temp,std::ios::binary);stream.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());stream.close();
            if(!stream){std::filesystem::remove(temp);return false;}std::filesystem::rename(temp,path);return true;
        }catch(...){return false;}
    }
    bool Load(int id){try{auto path=Path(id);auto size=std::filesystem::file_size(path);if(size>MaxBytes)return false;
        std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));std::ifstream f(path,std::ios::binary);f.read(reinterpret_cast<char*>(bytes.data()),bytes.size());
        return bool(f)&&decode(bytes,player_.samples);}catch(...){return false;}}
public:
    void Configure(bool stereo,bool desktop,SessionRecorder::Logger logger=nullptr) noexcept {
        if(configured_)return;configured_=true;
        try {
            if(SessionRecorder::Environment(L"KF2VR_RECORD_MOTION")!=L"1")return;
            SessionRecorder::Config config;
            if(!stereo||desktop||Fixture()||!SessionRecorder::FromEnvironment(config)) {
                if(logger)logger("MotionSession disabled=1 reason=launch_config");return;
            }
            session_=new SessionRecorder();
            if(!session_->Start(std::move(config),logger)) {
                if(logger)logger("MotionSession disabled=1 reason=session_start");
                delete session_;session_=nullptr;
            }
        }catch(...) {if(logger)logger("MotionSession disabled=1 reason=launch_config");}
    }
    void Shutdown() noexcept {if(session_)session_->Close();}
    bool CaptureConfigured() const noexcept {return session_!=nullptr;}
    void Update(GameScript& script,void* bridge,void* pc,const xr::FrameState& raw,
                const HeadInTracking& reference,const Quat& body,bool referenceValid,bool stereo,bool desktop,std::uint64_t age){
        const auto now=Now();const int request=script.Read<int>(pc,L"MotionRequest");
        if(request!=request_){request_=request;const auto command=script.Read<int>(pc,L"MotionCommand");const int id=script.Read<int>(pc,L"MotionClipId");
            if(id<0||id>999999){status_=-1;}
            else switch(command){
            case 1: if((stereo&&!Fixture())||(desktop&&Fixture())){player_.playing=false;recorder_.StartRecording(now);status_=1;}else status_=-4;break;
            case 2:recorder_.Stop();player_.playing=false;status_=3;break;
            case 3:recorder_.Stop();status_=Save(id)?3:-2;break;
            case 9:
            case 4:if(!desktop||stereo){status_=-4;break;}recorder_.Stop();player_.playing=false;
                if(Load(id) && (command!=9 || networkRootsValid(player_.samples))){network_=command==9;player_.holdEnd=!network_;player_.loop=false;player_.speed=1;
                    edgeIndex_=0;playStarted_=now;player_.Play(now);namesIndex_=~std::size_t{};status_=2;}else status_=-3;break;
            case 5:player_.paused=!player_.paused;break;
            case 6:player_.speed=script.Read<float>(pc,L"MotionSpeed");break;
            case 7:if(!network_)player_.loop=!player_.loop;break;
            default:break;}
        }
        script.Write(bridge,L"MotionNetwork",network_?1:0);
        script.Write(bridge,L"MotionHasPose",0);
        script.Write(bridge,L"MotionFixtureEnabled",Fixture()&&desktop&&!stereo?1:0);
        const bool sessionRecording=session_&&session_->Active();
        script.Write(bridge,L"MotionEnabled",recorder_.Recording()||sessionRecording?1:0);
        script.Write(bridge,L"MotionPlayback",player_.playing?1:0);
        if((recorder_.Recording()||sessionRecording)&&script.Read<int>(bridge,L"MotionPumpPhase")==1){
            Sample s;s.synthetic=Fixture();s.input=raw;s.reference=reference;s.body=body;s.referenceValid=referenceValid;s.visual=Read(script,bridge);
            // Preserve raw runtime validity and action state; mark its age separately.
            s.visual.state[11]=static_cast<int>(std::min<std::uint64_t>(age,INT32_MAX));
            if(sessionRecording)session_->Append(s,SessionRecorder::Clock());
            if(recorder_.Recording()&&!recorder_.Append(s,now)&&!recorder_.Recording())status_=3;
        }
        if(player_.playing){const auto* s=player_.Tick(now);if(s){
            // A map transition needs an explicit load in that map; never project into another world.
            const auto current=Text(script,bridge,L"MotionCurrentMap");
            if(current!=s->visual.map){player_.playing=false;script.Write(bridge,L"MotionPlayback",0);status_=-5;}
            else {const auto index=static_cast<std::size_t>(s-player_.samples.data());
                if(namesIndex_>=player_.samples.size() || s->visual.weaponClass!=player_.samples[namesIndex_].visual.weaponClass ||
                    s->visual.map!=player_.samples[namesIndex_].visual.map)Names(script,bridge,s->visual);
                namesIndex_=index;Write(script,bridge,s->visual);
                script.Write(bridge,L"MotionSampleIndex",static_cast<int>(index));
                script.Write(bridge,L"MotionClipSeconds",static_cast<float>(s->seconds));
                script.Write(bridge,L"MotionClockSeconds",static_cast<float>(now-playStarted_));
                script.Write(bridge,L"MotionPaused",player_.paused?1:0);
                script.Write(bridge,L"MotionBoundary",static_cast<int>(s->boundary));
                script.Write(bridge,L"MotionOriginEpoch",static_cast<int>(s->input.referenceSpaceEpoch));
                script.Write(bridge,L"MotionInputDown",static_cast<int>(buttons(s->input,false)));
                script.Write(bridge,L"MotionInputActive",static_cast<int>(buttons(s->input,true)));
                script.Write(bridge,L"MotionLeftAxes",Vec3{s->input.handLeft.stickX,s->input.handLeft.stickY,s->input.handLeft.triggerAxis});
                script.Write(bridge,L"MotionRightAxes",Vec3{s->input.handRight.stickX,s->input.handRight.stickY,s->input.handRight.triggerAxis});
                script.Write(bridge,L"MotionLeftGrip",s->input.handLeft.gripAxis);
                script.Write(bridge,L"MotionRightGrip",s->input.handRight.gripAxis);
                // The reliable script edge path receives every crossed sample, even at 4x speed.
                // Boundary changes seed state; no invented restart/focus/recenter actions.
                if(network_)for(;edgeIndex_<=index;++edgeIndex_){const auto& e=player_.samples[edgeIndex_];
                    if(edgeIndex_ && (e.boundary&(Respawn|Map))){player_.playing=false;status_=-6;break;}
                    if(e.pressed||e.released||e.boundary){
                        struct EdgeParams {int index;float seconds;int pressed,released,boundary;};
                        EdgeParams args{static_cast<int>(edgeIndex_),static_cast<float>(e.seconds),static_cast<int>(e.pressed),static_cast<int>(e.released),static_cast<int>(e.boundary)};
                        script.Invoke(bridge,script.FindFunction(bridge,L"MotionInputEdge"),&args);
                    }
                }}
        }}
        if(network_&&!player_.playing){if(status_==2)status_=3;script.Write(bridge,L"MotionHasPose",0);}
        script.Write(bridge,L"MotionPlayback",player_.playing?1:0);
        script.Write(pc,L"MotionStatus",status_);
    }
};
}
