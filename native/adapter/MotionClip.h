// Local presentation clips. No engine pointers, voice, video or remote actors.
#pragma once
#include "kf2vr/xr/XrBackend.h"
#include <array>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <type_traits>

namespace kf2vr::adapter::motion {
constexpr std::size_t MaxFrames=32768, MaxBytes=64*1024*1024;
enum Boundary : std::uint32_t { Start=1, Origin=2, Recenter=4, Respawn=8, Map=16 };
// Unreal units/world axes. Indices: root, head, L/R aim, L/R grip rotation,
// R/L muzzle, L/R anatomical wrist. Rotations are UE integer rotators.
struct Presentation {
    std::array<Vec3,10> positions{};
    std::array<std::array<std::int32_t,3>,10> rotations{};
    std::array<std::int32_t,12> state{}; // tracking, flags, hand poses, epochs, crouch, menu/support/braced mask, health
    float bodyYaw=0, eyeHeight=0, gameSeconds=0;
    Vec3 velocity{};
    // class path + item id, shot sequence, ammo, weapon/reload/fire state, rate
    std::array<std::array<char,128>,2> weaponClass{};
    std::array<std::array<std::int32_t,6>,2> weapon{};
    std::array<float,2> animRate{1,1};
    std::array<char,128> map{};
};
struct Sample {
    double seconds=0;
    xr::FrameState input{};
    HeadInTracking reference{};
    Quat body{};
    bool referenceValid=false, synthetic=false;
    Presentation visual{};
    std::uint32_t boundary=0, pressed=0, released=0;
};
// Stable little-endian scalar wire format; never dump C++/UE structures.
struct Writer {
    std::vector<std::uint8_t> bytes;
    template<class T> void value(T& v) {
        static_assert(std::is_arithmetic_v<T>);
        if constexpr(std::is_same_v<T,bool>) { bytes.push_back(v?1:0); }
        else { std::array<std::uint8_t,sizeof(T)> b{}; std::memcpy(b.data(),&v,sizeof(T)); for(auto c:b) bytes.push_back(c); }
    }
};
struct Reader {
    const std::vector<std::uint8_t>& bytes; std::size_t at=0; bool ok=true;
    template<class T> void value(T& v) {
        const auto n=std::is_same_v<T,bool>?1:sizeof(T);
        if(at+n>bytes.size()) {ok=false;return;}
        if constexpr(std::is_same_v<T,bool>) { if(bytes[at]>1) ok=false; v=bytes[at++]!=0; }
        else {std::memcpy(&v,bytes.data()+at,n);at+=n; if constexpr(std::is_floating_point_v<T>) if(!std::isfinite(v)) ok=false;}
    }
};
template<class C> void vec(C& c,Vec3& v) {c.value(v.x);c.value(v.y);c.value(v.z);}
template<class C> void quat(C& c,Quat& q) {c.value(q.x);c.value(q.y);c.value(q.z);c.value(q.w);}
template<class C,class T> void pose(C& c,T& p) {quat(c,p.rot);vec(c,p.pos);c.value(p.scale);}
template<class C,class T> void hand(C& c,T& h) {
    pose(c,h.grip);pose(c,h.aim);
    c.value(h.poseValid);c.value(h.poseTracked);c.value(h.aimPoseValid);c.value(h.aimPoseTracked);
    c.value(h.triggerAxis);c.value(h.gripAxis);c.value(h.stickX);c.value(h.stickY);
    c.value(h.primaryPressed);c.value(h.secondaryPressed);c.value(h.stickPressed);c.value(h.menuPressed);
    c.value(h.triggerActive);c.value(h.gripActive);c.value(h.stickActive);
    c.value(h.primaryActive);c.value(h.secondaryActive);c.value(h.stickClickActive);c.value(h.menuActive);
}
template<class C> void visit(C& c,Sample& s) {
    c.value(s.seconds);auto& f=s.input;
    auto state=static_cast<std::uint8_t>(f.state);c.value(state);f.state=static_cast<xr::SessionState>(state);
    c.value(f.shouldRender);c.value(f.viewsValid);c.value(f.actionsSynced);
    c.value(f.predictedDisplayTime);c.value(f.predictedDisplayPeriod);c.value(f.poseSampleId);c.value(f.referenceSpaceEpoch);
    pose(c,f.head);c.value(f.headPoseValid);c.value(f.headPoseTracked);
    hand(c,f.handLeft);hand(c,f.handRight);pose(c,s.reference);quat(c,s.body);c.value(s.referenceValid);c.value(s.synthetic);
    auto& v=s.visual;
    for(auto& p:v.positions) vec(c,p);
    for(auto& r:v.rotations) for(auto& n:r) c.value(n);
    for(auto& n:v.state) c.value(n);
    c.value(v.bodyYaw);c.value(v.eyeHeight);c.value(v.gameSeconds);vec(c,v.velocity);
    for(auto& path:v.weaponClass) for(auto& ch:path) c.value(ch);
    for(auto& w:v.weapon) for(auto& n:w) c.value(n);
    for(auto& n:v.animRate) c.value(n);
    for(auto& ch:v.map)c.value(ch);
    c.value(s.boundary);c.value(s.pressed);c.value(s.released);
}
inline std::uint32_t hash(const std::uint8_t* p,std::size_t n) {
    std::uint32_t h=2166136261u;for(std::size_t i=0;i<n;++i)h=(h^p[i])*16777619u;return h;
}
struct FiniteCheck {
    bool ok=true;
    template<class T> void value(T& v) {if constexpr(std::is_floating_point_v<T>)if(!std::isfinite(v))ok=false;}
};
inline bool valid(const Sample& s) {
    if(!(s.seconds>=0) || !std::isfinite(s.seconds) || static_cast<unsigned>(s.input.state)>7 || s.boundary>31) return false;
    auto copy=s;FiniteCheck check;visit(check,copy);if(!check.ok)return false;
    for(auto& p:s.visual.positions)if(std::abs(p.x)>10000000 ||std::abs(p.y)>10000000 ||std::abs(p.z)>10000000)return false;
    if(s.visual.state[0]<0||s.visual.state[0]>7||s.visual.state[1]<0||s.visual.state[1]>63)return false;
    const auto path=[](const auto& a) {bool end=false;for(auto ch:a){if(!ch)end=true;else if(end || !((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='.'||ch=='-'))return false;}return end;};
    if(!path(s.visual.map))return false;
    for(auto& w:s.visual.weaponClass)if(!path(w))return false;
    return true;
}
inline std::vector<std::uint8_t> encode(const std::vector<Sample>& samples) {
    if(samples.empty() || samples.size()>MaxFrames)return {};
    Writer w;std::uint32_t magic=0x314d464b,version=1,count=static_cast<std::uint32_t>(samples.size());
    w.value(magic);w.value(version);w.value(count);
    double previous=-1;
    for(auto s:samples) {if(!valid(s)||s.seconds<=previous)return {};previous=s.seconds;const auto start=w.bytes.size();visit(w,s);auto crc=hash(w.bytes.data()+start,w.bytes.size()-start);w.value(crc);}
    if(w.bytes.size()>MaxBytes)return {};return std::move(w.bytes);
}
inline bool decode(const std::vector<std::uint8_t>& bytes,std::vector<Sample>& out) {
    if(bytes.size()>MaxBytes)return false;
    Reader r{bytes};std::uint32_t magic=0,version=0,count=0;r.value(magic);r.value(version);r.value(count);
    if(!r.ok||magic!=0x314d464b||version!=1||!count||count>MaxFrames)return false;
    std::vector<Sample> pending;pending.reserve(count);double previous=-1;
    for(std::uint32_t i=0;i<count;++i){Sample s;auto start=r.at;visit(r,s);auto finish=r.at;std::uint32_t crc=0;r.value(crc);
        if(!r.ok||crc!=hash(bytes.data()+start,finish-start)||!valid(s)||s.seconds<=previous || (i==0 && !(s.boundary&Start)))return false;
        if(i && (s.input.referenceSpaceEpoch!=pending.back().input.referenceSpaceEpoch) && !(s.boundary&Origin))return false;
        if(i){const auto& p=pending.back();
            if(s.visual.state[7]!=p.visual.state[7]&&!(s.boundary&Recenter))return false;
            if(s.visual.state[6]!=p.visual.state[6]&&!(s.boundary&Respawn))return false;
            if((s.visual.state[4]!=p.visual.state[4]||s.visual.map!=p.visual.map)&&!(s.boundary&Map))return false;}
        previous=s.seconds;pending.push_back(s);}
    if(r.at!=bytes.size())return false;out=std::move(pending);return true;
}
inline std::uint32_t buttons(const xr::FrameState& f,bool activeOnly) {
    if(f.state!=xr::SessionState::Focused || !f.actionsSynced)return 0;
    std::uint32_t bits=0;
    const auto h=[&](const auto& x,int shift){
        const bool active[]{x.triggerActive,x.gripActive,x.primaryActive,x.secondaryActive,x.stickClickActive,x.menuActive};
        const bool down[]{x.triggerAxis>=.55f,x.gripAxis>=.65f,x.primaryPressed,x.secondaryPressed,x.stickPressed,x.menuPressed};
        for(int i=0;i<6;++i)if(active[i]&&(activeOnly||down[i]))bits|=1u<<(i+shift);};
    h(f.handLeft,0);h(f.handRight,6);return bits;
}
// Network-file preflight uses the first recorded root, never a new session's spawn.
// The server repeats these checks and admits the anchor only after collision placement.
class ReplayRootAnchor {
    Vec3 root_{}; bool have_=false;
public:
    bool Accept(const Vec3& root) {
        const auto bounded=[](float x,float bound){return x>=-bound && x<=bound;};
        if(!bounded(root.x,10000000)||!bounded(root.y,10000000)||!bounded(root.z,10000000))return false;
        if(have_ && (!bounded(root.x-root_.x,10000)||!bounded(root.y-root_.y,10000)||!bounded(root.z-root_.z,10000)))return false;
        if(!have_){root_=root;have_=true;}return true;
    }
};
inline bool networkRootsValid(const std::vector<Sample>& samples) {
    if(samples.empty())return false;
    ReplayRootAnchor anchor;
    for(std::size_t i=0;i<samples.size();++i){
        if(i && (samples[i].boundary&(Respawn|Map)))break; // scheduler stops at this boundary
        if(!anchor.Accept(samples[i].visual.positions[0]))return false;
    }
    return true;
}
class Recorder {
    bool recording_=false; std::uint32_t down_=0,active_=0;double started_=0;
public:
    std::vector<Sample> samples;
    bool Recording()const{return recording_;}
    void StartRecording(double now){samples.clear();samples.reserve(MaxFrames);down_=active_=0;started_=now;recording_=true;}
    void Stop(){recording_=false;}
    bool Append(Sample s,double now){
        if(!recording_)return false; // disabled: no allocation/serialization
        if(samples.size()>=MaxFrames){Stop();return false;}
        s.seconds=now-started_;if(!samples.empty()&&s.seconds<=samples.back().seconds)return false;
        s.boundary=samples.empty()?Start:0;
        if(!samples.empty()){const auto& p=samples.back();
            if(s.input.referenceSpaceEpoch!=p.input.referenceSpaceEpoch)s.boundary|=Origin;
            if(s.visual.state[7]!=p.visual.state[7])s.boundary|=Recenter;
            if(s.visual.state[6]!=p.visual.state[6])s.boundary|=Respawn;
            if(s.visual.state[4]!=p.visual.state[4]||s.visual.map!=p.visual.map)s.boundary|=Map;}
        const auto d=buttons(s.input,false),a=buttons(s.input,true);
        const auto eligible=a&active_;
        // Activation/focus/origin changes seed held state; never invent edges.
        s.pressed=s.boundary?0:(d&~down_&eligible);
        s.released=s.boundary?0:(down_&~d&eligible);
        down_=d;active_=a;samples.push_back(s);return true;
    }
};
class Player {
    double last_=0,at_=0;std::size_t index_=0;
public:
    std::vector<Sample> samples;bool playing=false,paused=false,loop=false,holdEnd=true;double speed=1;
    double Seconds()const{return at_;}
    std::size_t Index()const{return index_;}
    void Play(double now){last_=now;at_=0;index_=0;playing=!samples.empty();paused=false;}
    const Sample* Tick(double now){if(!playing||samples.empty())return nullptr;
        if(!paused)at_+=std::max(0.0,now-last_)*std::clamp(speed,.1,4.0);last_=now;
        if(at_>samples.back().seconds){if(!holdEnd&&index_==samples.size()-1){playing=false;return nullptr;}if(loop&&samples.back().seconds>0){at_=std::fmod(at_,samples.back().seconds);index_=0;}else{at_=samples.back().seconds;paused=holdEnd;}}
        while(index_+1<samples.size()&&samples[index_+1].seconds<=at_)++index_;
        return &samples[index_]; // sample-and-hold; never blend across boundaries
    }
};
}
