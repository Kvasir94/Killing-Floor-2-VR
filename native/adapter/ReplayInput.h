#pragma once
#include "kf2vr/xr/XrBackend.h"
#include <cmath>
#include <cstdint>
#include <istream>
#include <locale>
#include <sstream>
#include <string>
#include <vector>

namespace kf2vr::adapter {
// A process-local, offline input source. It owns samples, never gameplay state.
// Each Next is one production bridge update, not a render pass or wall clock poll.
class ReplayInput {
public:
    struct Record { unsigned ticks=0, ageMs=0; xr::FrameState frame{}; };
    bool Load(std::istream& input, std::string& error) {
        records_.clear(); cursor_=0; remaining_=0; tick_=0; owner_=pawn_=0; epoch_=0; haveEpoch_=false; stopped_=false;
        std::string line, magic; unsigned version=0;
        if (!std::getline(input,line)) return Fail(error,"missing header");
        std::istringstream header(line); header.imbue(std::locale::classic());
        if (!(header>>magic>>version>>stepUs_>>seed_) || magic!="KF2VR_INPUT" || version!=1 ||
            stepUs_<1000 || stepUs_>100000 || !End(header)) return Fail(error,"invalid v1 header");
        std::uint64_t total=0; unsigned lineNumber=1;
        while (std::getline(input,line)) {
            ++lineNumber;
            if (line.empty() || line[0]=='#') continue;
            Record r; unsigned focused=0, synced=0, headValid=0;
            std::istringstream row(line); row.imbue(std::locale::classic());
            if (!(row>>r.ticks>>r.ageMs>>r.frame.referenceSpaceEpoch>>focused>>synced>>headValid) ||
                !r.ticks || focused>1 || synced>1 || headValid>1 ||
                !Pose(row,r.frame.head) || !Hand(row,r.frame.handLeft) || !Hand(row,r.frame.handRight) || !End(row))
                return Fail(error,"invalid record at line "+std::to_string(lineNumber));
            total+=r.ticks;
            if (total>360000 || records_.size()>=360000) return Fail(error,"replay exceeds 360000 ticks");
            r.frame.state=focused?xr::SessionState::Focused:xr::SessionState::Visible;
            r.frame.actionsSynced=synced!=0;
            r.frame.headPoseValid=r.frame.headPoseTracked=headValid!=0;
            records_.push_back(r);
        }
        if (input.bad() || records_.empty()) return Fail(error,"empty or unreadable replay");
        error.clear(); return true;
    }
    xr::FrameState Next(std::uintptr_t owner, std::uintptr_t pawn) {
        // Travel/replacement never silently restarts a scenario against a new pawn.
        if (!owner || !pawn || (owner_ && (owner_!=owner || pawn_!=pawn))) stopped_=true;
        if (!owner_) { owner_=owner; pawn_=pawn; }
        xr::FrameState out{};
        if (!stopped_ && cursor_<records_.size()) {
            const auto& r=records_[cursor_]; out=r.frame;
            if (!remaining_) remaining_=r.ticks;
            if (--remaining_==0) ++cursor_;
            // An old sample is unavailable, not an observed physical release.
            if (r.ageMs>250 || (haveEpoch_ && epoch_!=out.referenceSpaceEpoch)) {
                out.actionsSynced=false; out.headPoseValid=false;
            }
            epoch_=out.referenceSpaceEpoch; haveEpoch_=true;
        }
        out.poseSampleId=++tick_;
        out.predictedDisplayPeriod=double(stepUs_)/1000000.0;
        out.predictedDisplayTime=double(tick_)*out.predictedDisplayPeriod;
        return out;
    }
    bool Finished() const { return stopped_ || cursor_==records_.size(); }
    std::uint64_t Seed() const { return seed_; } // provenance, never an implicit RNG reseed
private:
    bool Fail(std::string& error,const std::string& message) { records_.clear(); stopped_=true; error=message; return false; }
    static bool End(std::istream& s) { s>>std::ws; return s.eof(); }
    template<class T> static bool Pose(std::istream& s,T& p) {
        if (!(s>>p.pos.x>>p.pos.y>>p.pos.z>>p.rot.x>>p.rot.y>>p.rot.z>>p.rot.w)) return false;
        return std::isfinite(p.pos.x)&&std::isfinite(p.pos.y)&&std::isfinite(p.pos.z)&&
            std::isfinite(p.rot.x)&&std::isfinite(p.rot.y)&&std::isfinite(p.rot.z)&&std::isfinite(p.rot.w)&&
            std::abs(p.rot.LengthSq()-1.f)<.02f;
    }
    template<class T> static bool Hand(std::istream& s,T& h) {
        unsigned flags=0, buttons=0;
        if (!(s>>flags>>buttons>>h.triggerAxis>>h.gripAxis>>h.stickX>>h.stickY) || flags>2047 || buttons>15 ||
            !Pose(s,h.grip) || !Pose(s,h.aim)) return false;
        if (!std::isfinite(h.triggerAxis)||!std::isfinite(h.gripAxis)||!std::isfinite(h.stickX)||!std::isfinite(h.stickY)||
            h.triggerAxis<0||h.triggerAxis>1||h.gripAxis<0||h.gripAxis>1||std::abs(h.stickX)>1||std::abs(h.stickY)>1) return false;
        h.poseValid=(flags&1)!=0; h.poseTracked=(flags&2)!=0;
        h.aimPoseValid=(flags&4)!=0; h.aimPoseTracked=(flags&8)!=0;
        h.triggerActive=(flags&16)!=0; h.gripActive=(flags&32)!=0; h.stickActive=(flags&64)!=0;
        h.primaryActive=(flags&128)!=0; h.secondaryActive=(flags&256)!=0;
        h.stickClickActive=(flags&512)!=0; h.menuActive=(flags&1024)!=0;
        h.primaryPressed=(buttons&1)!=0; h.secondaryPressed=(buttons&2)!=0;
        h.stickPressed=(buttons&4)!=0; h.menuPressed=(buttons&8)!=0;
        return true;
    }
    std::vector<Record> records_;
    std::size_t cursor_=0;
    unsigned remaining_=0, stepUs_=16667;
    std::uint64_t tick_=0, seed_=0;
    std::uintptr_t owner_=0, pawn_=0;
    std::uint64_t epoch_=0;
    bool haveEpoch_=false, stopped_=false;
};
}
