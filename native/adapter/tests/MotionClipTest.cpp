#ifdef NDEBUG
#undef NDEBUG
#endif
#include "MotionClip.h"
#include <cassert>
#include <iostream>
#include <limits>
using namespace kf2vr::adapter::motion;
int main(){
    Recorder r;Sample s;s.input.state=kf2vr::xr::SessionState::Focused;s.input.actionsSynced=true;
    s.input.handLeft.triggerActive=true;
    assert(!r.Append(s,0)&&r.samples.capacity()==0);
    r.StartRecording(10);assert(r.Append(s,10));
    s.input.handLeft.triggerAxis=1;assert(r.Append(s,10.01));assert(r.samples.back().pressed==1);
    s.input.handLeft.triggerActive=false;assert(r.Append(s,10.02));assert(!r.samples.back().released);
    s.input.handLeft.triggerActive=true;assert(r.Append(s,10.03));assert(!r.samples.back().pressed);
    s.input.handLeft.triggerAxis=0;assert(r.Append(s,10.04));assert(r.samples.back().released==1);
    assert(!r.Append(s,10.04));
    s.input.referenceSpaceEpoch=1;s.visual.state[7]=1;s.visual.state[6]=1;s.visual.map[0]='M';
    assert(r.Append(s,10.05));assert((r.samples.back().boundary&30)==30);
    auto data=encode(r.samples);assert(!data.empty());std::vector<Sample> loaded;
    assert(decode(data,loaded));assert(loaded.size()==r.samples.size());assert(loaded[1].pressed==1);
    assert(loaded.back().input.referenceSpaceEpoch==1);assert(encode(loaded)==data);
    for(auto n:{std::size_t(0),std::size_t(11),data.size()-1}){auto cut=data;cut.resize(n);assert(!decode(cut,loaded));}
    auto corrupt=data;corrupt[30]^=1;assert(!decode(corrupt,loaded));
    auto version=data;version[4]=2;assert(!decode(version,loaded));
    auto extra=data;extra.push_back(0);assert(!decode(extra,loaded));
    auto bad=r.samples;bad[1].seconds=bad[0].seconds;assert(encode(bad).empty());
    bad=r.samples;bad[1].input.handLeft.stickX=std::numeric_limits<float>::quiet_NaN();assert(encode(bad).empty());
    bad=r.samples;bad.back().boundary=0;auto missing=encode(bad);assert(!decode(missing,loaded));
    for(auto flag:{Recenter,Respawn,Map}){bad=r.samples;bad.back().boundary&=~flag;assert(!decode(encode(bad),loaded));}
    auto preserved=loaded;assert(!decode(corrupt,loaded));assert(loaded.size()==preserved.size());
    r.Stop();auto n=r.samples.size();assert(!r.Append(s,11)&&r.samples.size()==n);
    Player p;p.samples=r.samples;p.Play(0);assert(p.Tick(.02)->seconds>=.019);
    p.paused=true;auto before=p.Tick(.02);assert(p.Tick(2)==before);
    p.paused=false;p.loop=true;assert(p.Tick(3));
    Player network;network.samples=r.samples;network.holdEnd=false;network.Play(0);
    assert(network.Tick(.01));network.paused=true;auto frozen=network.Index();
    assert(network.Tick(2)&&network.Index()==frozen);network.paused=false;network.speed=2;
    assert(network.Tick(2.1)==&network.samples.back());assert(!network.Tick(2.2)&&!network.playing);
    Recorder focus;focus.StartRecording(0);s={};s.input.state=kf2vr::xr::SessionState::Focused;s.input.actionsSynced=true;
    s.input.handRight.primaryActive=true;s.input.handRight.primaryPressed=true;assert(focus.Append(s,0));assert(!focus.samples.back().pressed);
    s.input.state=kf2vr::xr::SessionState::Visible;assert(focus.Append(s,.01));assert(!focus.samples.back().released);
    s.input.state=kf2vr::xr::SessionState::Focused;assert(focus.Append(s,.02));assert(!focus.samples.back().pressed);
    s.input.handRight.primaryPressed=false;assert(focus.Append(s,.03));assert(focus.samples.back().released==(1u<<8));
    s.input.handRight.primaryPressed=true;s.input.referenceSpaceEpoch=2;assert(focus.Append(s,.04));assert(!focus.samples.back().pressed);
    for(std::size_t i=focus.samples.size();i<MaxFrames;++i)assert(focus.Append(s,static_cast<double>(i)));
    assert(!focus.Append(s,static_cast<double>(MaxFrames))&&!focus.Recording()&&focus.samples.size()==MaxFrames);
    // A saved world-space clip may start beyond the old spawn-relative 10k gate.
    const kf2vr::Vec3 coldSpawn{-9669,0,0}, recordedRoot{1000,0,0};
    assert(recordedRoot.x-coldSpawn.x>10000);
    auto roots=r.samples;for(auto& sample:roots){sample.boundary=0;sample.visual.positions[0]=recordedRoot;}
    roots[0].boundary=Start;assert(networkRootsValid(roots));
    for(float value:{std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::infinity(),10000001.f,-10000001.f}){
        auto invalid=roots;invalid[0].visual.positions[0].x=value;assert(!networkRootsValid(invalid));
    }
    roots[1].visual.positions[0].x=11000;assert(networkRootsValid(roots));
    roots[1].visual.positions[0].x=11001;assert(!networkRootsValid(roots));
    ReplayRootAnchor anchor;assert(anchor.Accept(recordedRoot));assert(!anchor.Accept({11001,0,0}));
    assert(anchor.Accept({11000,0,0})); // rejection must not move the anchor
    roots[1].boundary=Map;assert(networkRootsValid(roots)); // preserve stop-at-map semantics
    std::cout<<"Motion clip roundtrip, edges, corruption, boundaries, playback, network roots and disabled state passed\n";
}
