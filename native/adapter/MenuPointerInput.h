#pragma once
#include "SpatialMenu.h"
#include <algorithm>
#include <cmath>

namespace kf2vr::adapter {
// Explicit receipts keep a lost move/release from becoming a click at an old
// coordinate. Sink cancellation must release OUTSIDE without dragging there.
struct MenuInputSink {
    virtual ~MenuInputSink()=default;
    virtual bool Move(int x,int y)=0;
    virtual bool Button(bool down)=0;
    virtual bool Wheel(int steps)=0;
    virtual bool Cancel()=0;
};
class MenuPointerInput {
public:
    bool Held() const { return held_; }
    // Only discard ownership when its movie/context has been destroyed.
    void Reset() { held_=cancelPending_=false; }
    bool Cancel(MenuInputSink& sink) {
        if (!held_ && !cancelPending_) return true;
        cancelPending_=true;
        if (!sink.Cancel()) return false;
        Reset(); return true;
    }
    bool Update(const SpatialMenuPointer& p,int width,int height,bool allowed,MenuInputSink& sink) {
        if (cancelPending_) { Cancel(sink); return false; }
        if (!allowed || !p.hit || p.cancelled || width<=0 || height<=0 || width>16384 || height>16384 ||
            !std::isfinite(p.u) || !std::isfinite(p.v) || p.u<0 || p.u>1 || p.v<0 || p.v>1) {
            Cancel(sink); return false;
        }
        const int x=std::min(static_cast<int>(p.u*width),width-1);
        const int y=std::min(static_cast<int>(p.v*height),height-1);
        if (!sink.Move(x,y)) { Cancel(sink); return false; }
        if (p.pressed && !held_) {
            // Even a rejected callback might have consumed part of the event.
            held_=true;
            if (!sink.Button(true)) { Cancel(sink); return false; }
        }
        if (held_ && !p.down) {
            if (!sink.Button(false)) { Cancel(sink); return false; }
            held_=false;
        }
        if (p.scrollSteps && !held_ && !sink.Wheel(p.scrollSteps)) return false;
        return true;
    }
private:
    bool held_=false,cancelPending_=false;
};
}
