#include "ReplayInput.h"
#include <cstdlib>
#include <iostream>
#include <sstream>
using kf2vr::adapter::ReplayInput;
static void Check(bool ok,const char* message) { if (!ok) { std::cerr<<message<<'\n'; std::exit(1); } }
static std::string Hand(float trigger,unsigned flags=2047,unsigned buttons=0) {
    std::ostringstream s;
    s<<flags<<' '<<buttons<<' '<<trigger<<" 0 0 0  0.2 -0.25 -0.4 0 0 0 1  0.2 -0.25 -0.4 0 0 0 1 ";
    return s.str();
}
static std::string Row(unsigned ticks,float left,float right,unsigned age=0,unsigned flags=2047) {
    return std::to_string(ticks)+" "+std::to_string(age)+" 0 1 1 1  0 1.7 0 0 0 0 1  "+Hand(left,flags)+Hand(right)+"\n";
}
static bool Load(ReplayInput& r,const std::string& rows) {
    std::istringstream s("KF2VR_INPUT 1 10000 42\n"+rows); std::string error;
    return r.Load(s,error);
}
int main() {
    ReplayInput r;
    Check(Load(r,Row(1,0,0)+Row(3,1,0)+Row(1,0,1)+Row(1,1,0)+Row(1,0,1)),"load sequence");
    const float left[]{0,1,1,1,0,1,0}, right[]{0,0,0,0,1,0,1};
    for (unsigned i=0;i<7;++i) {
        const auto f=r.Next(1,2);
        Check(f.poseSampleId==i+1 && std::abs(f.predictedDisplayTime-(i+1)*.01)<1e-9,"clock/sample identity");
        Check(f.handLeft.triggerAxis==left[i] && f.handRight.triggerAxis==right[i],"press hold release double tap and independent hands");
        Check(f.handLeft.triggerActive && f.handRight.triggerActive,"active release remains available");
    }
    Check(r.Seed()==42 && r.Finished(),"seed and completion");
    auto f=r.Next(1,2);
    Check(!f.actionsSynced && !f.handLeft.triggerActive && !f.handRight.poseValid,"EOF unavailable, never release");
    Check(Load(r,Row(1,1,1,251)+Row(1,1,1,0,0)+Row(2,0,0)),"load stale reconnect");
    f=r.Next(1,2); Check(!f.actionsSynced && !f.headPoseValid,"stale invalidates sample");
    f=r.Next(1,2); Check(!f.handLeft.poseValid && !f.handLeft.triggerActive && f.handRight.poseValid,"per-hand availability");
    f=r.Next(1,2); Check(f.handLeft.triggerActive && f.handLeft.triggerAxis==0,"explicit physical release after reconnect");
    f=r.Next(1,3); Check(!f.actionsSynced && r.Finished(),"pawn replacement stops");
    f=r.Next(1,2); Check(!f.actionsSynced,"cannot restart old pawn");
    Check(Load(r,Row(3,0,0)),"reload resets state");
    r.Next(1,2); f=r.Next(3,2); Check(!f.actionsSynced,"bridge replacement stops");
    auto epochRow=Row(2,1,1); epochRow.replace(4,1,"1");
    Check(Load(r,Row(1,0,0)+epochRow),"epoch transition load");
    r.Next(1,2); f=r.Next(1,2); Check(!f.actionsSynced,"epoch transition cancels input");
    f=r.Next(1,2); Check(f.actionsSynced && f.referenceSpaceEpoch==1,"new epoch resumes without a fabricated release");
    Check(!Load(r,Row(0,0,0)),"reject empty duration");
    Check(!Load(r,Row(1,2,0)),"reject invalid axis");
    Check(!Load(r,Row(1,0,0)+"garbage"),"reject truncated trailing data");
    f=r.Next(1,2); Check(!f.actionsSynced,"failed parse cannot play a partial sequence");
    Check(!Load(r,Row(1,0,0,0,2048)),"reject unknown availability bits");
    auto badPose=Row(1,0,0); badPose.replace(badPose.find("0 1.7 0 0 0 0 1"),15,"0 1.7 0 0 0 0 0");
    Check(!Load(r,badPose),"reject non-unit rotation");
    Check(!Load(r,Row(360001,0,0)),"bounded allocation and duration");
    std::istringstream unknown("KF2VR_INPUT 2 10000 0\n"); std::string error;
    Check(!r.Load(unknown,error),"reject unknown version");
    std::cout<<"ReplayInput sequence, availability, ownership, EOF and parser checks passed\n";
}
