#include "SpatialMenu.h"
#include <cmath>

namespace kf2vr::adapter {
namespace {
bool Finite(const Vec3& v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); }
bool Rotation(const Quat& q) { return std::isfinite(q.LengthSq()) && std::abs(q.LengthSq()-1.f)<.01f; }
}
bool IntersectSpatialMenu(const SpatialMenuPanel& p,const Vec3& origin,
                          const Vec3& direction,float& u,float& v,Vec3& point) {
    if (!p.valid || !Finite(origin) || !Finite(direction) || !Finite(p.center) || !Rotation(p.rotation) ||
        !std::isfinite(p.width) || !std::isfinite(p.height) || p.width<=0 || p.height<=0) return false;
    const auto local=p.rotation.Inverse().Rotate(origin-p.center);
    const auto ray=p.rotation.Inverse().Rotate(direction);
    if (local.z<=.01f || ray.z>=-1e-5f) return false;
    if (!std::isfinite(p.curveRadius) || p.curveRadius<=.01f) {
        const float t=-local.z/ray.z;
        const auto hit=local+ray*t;
        u=.5f+hit.x/p.width; v=.5f-hit.y/p.height;
        if (!std::isfinite(t) || t<0 || !std::isfinite(u) || !std::isfinite(v) || u<0 || u>1 || v<0 || v>1) return false;
        point=origin+direction*t;
        return Finite(point);
    }
    // Vertical cylinder x^2+(z-R)^2=R^2 in panel space. AtlasBlit's shader
    // solves the same equation, so the cursor lands where the beam ends.
    const float R=p.curveRadius;
    const float qx=local.x,qz=local.z-R;
    const float a=ray.x*ray.x+ray.z*ray.z,b=qx*ray.x+qz*ray.z,c=qx*qx+qz*qz-R*R;
    const float disc=b*b-a*c;
    if (a<=1e-8f || !(disc>0)) return false;
    const float root=std::sqrt(disc);
    // From inside the cylinder (the normal case) only the far root is ahead.
    // From outside, the near root is the front face.
    const float t=c>0 ? (-b-root)/a : (-b+root)/a;
    const auto hit=local+ray*t;
    if (!std::isfinite(t) || t<0 || R-hit.z<=0) return false;
    u=.5f+R*std::atan2(hit.x,R-hit.z)/p.width; v=.5f-hit.y/p.height;
    if (!std::isfinite(u) || !std::isfinite(v) || u<0 || u>1 || v<0 || v>1) return false;
    point=origin+direction*t;
    return Finite(point);
}
void SpatialMenu::Reset() { panel_={}; CancelInput(); epoch_=0; lastTime_=0; haveTime_=false; nextScrollTime_=0; }
void SpatialMenu::Configure(float distance,float height,float scale) {
    if (!std::isfinite(distance) || !std::isfinite(height) || !std::isfinite(scale) ||
        distance<.6f || distance>3.f || height<-.8f || height>.5f || scale<.5f || scale>1.5f) return;
    if (distance!=distance_ || height!=height_ || scale!=scale_) Reset();
    distance_=distance; height_=height; scale_=scale;
}
void SpatialMenu::DisarmInput() {
    pointer_.released=pointer_.released || pointer_.down;
    pointer_.cancelled=pointer_.cancelled || pointer_.down;
    pointer_.down=pointer_.pressed=false;
    pointer_.scrollSteps=0;
    armed_=false; scrollArmed_=false; scrollDirection_=0;
}
bool SpatialMenu::Update(const xr::FrameState& frame,bool visible,float aspect,int pointerHand) {
    const bool wasDown=pointer_.down;
    pointer_={};
    const bool handChanged=pointerHand_!=pointerHand;
    if (handChanged) { CancelInput(); pointerHand_=pointerHand; }
    if (!visible || !std::isfinite(aspect) || aspect<.25f || aspect>4.f) {
        Reset(); pointer_.released=pointer_.cancelled=wasDown; return false;
    }
    const bool discontinuity=!std::isfinite(frame.predictedDisplayTime) || (haveTime_ &&
        (frame.predictedDisplayTime<lastTime_ || frame.predictedDisplayTime-lastTime_>.25));
    lastTime_=frame.predictedDisplayTime; haveTime_=std::isfinite(lastTime_);
    const bool recenter=panel_.valid && epoch_!=frame.referenceSpaceEpoch;
    if (recenter) { panel_={}; CancelInput(); }
    const bool valid=frame.shouldRender && frame.viewsValid && frame.headPoseValid &&
        Finite(frame.head.pos) && Rotation(frame.head.rot);
    if (!valid) { CancelInput(); pointer_.released=pointer_.cancelled=wasDown; return false; }
    if (!panel_.valid) {
        auto forward=frame.head.rot.Rotate({0,0,-1}); forward.y=0;
        // Looking vertically cannot define a stable opening yaw; wait for it.
        if (forward.LengthSq()<.001f) { pointer_.released=pointer_.cancelled=wasDown; return false; }
        forward=forward.Normalized();
        panel_.rotation=Quat::FromAxisAngle({0,1,0},std::atan2(-forward.x,-forward.z));
        panel_.center=frame.head.pos+forward*distance_+Vec3{0,height_,0};
        panel_.valid=true; epoch_=frame.referenceSpaceEpoch; CancelInput();
    }
    panel_.width=1.7320508f*scale_;
    panel_.height=panel_.width/aspect;
    // Radius is the opening distance, so the curve is centred on where the
    // head was. The arc keeps the flat panel's width and angular size.
    panel_.curveRadius=curved_ ? distance_ : 0.f;
    const auto updateHand=[&](const auto& hand) {
    const bool aim=frame.state==xr::SessionState::Focused && frame.actionsSynced &&
        frame.headPoseTracked && hand.aimPoseValid && hand.aimPoseTracked &&
        Finite(hand.aim.pos) && Rotation(hand.aim.rot);
    const bool input=aim && hand.triggerActive &&
        std::isfinite(hand.triggerAxis) && hand.triggerAxis>=0 && hand.triggerAxis<=1;
    if (aim) {
        const auto direction=hand.aim.rot.Rotate({0,0,-1});
        pointer_.rayVisible=true;
        pointer_.rayStart=hand.aim.pos;
        // A visible beam lets the user find the panel before the first hit.
        // The previous hit-only beam gave no aiming feedback on a miss.
        pointer_.rayEnd=hand.aim.pos+direction*3.f;
        pointer_.hit=IntersectSpatialMenu(panel_,hand.aim.pos,direction,
            pointer_.u,pointer_.v,pointer_.rayEnd);
    }
    if (!input || !pointer_.hit || recenter || discontinuity || handChanged) {
        armed_=false; scrollArmed_=false; scrollDirection_=0;
        pointer_.released=pointer_.cancelled=wasDown; return true;
    }
    if (hand.triggerAxis<=.1f) {
        armed_=true; pointer_.released=wasDown;
    } else if (armed_ && hand.triggerAxis>=.55f) {
        pointer_.down=true; pointer_.pressed=!wasDown;
    } else if (armed_ && wasDown) pointer_.down=true;
    // The pointer hand's stick scrolls. Require neutral on entry,
    // loss and after dragging; repeat by elapsed XR time, never frame count.
    if (!hand.stickActive || !std::isfinite(hand.stickY) || std::abs(hand.stickY)>1 || pointer_.down) {
        scrollArmed_=false; scrollDirection_=0;
    } else if (std::abs(hand.stickY)<=.2f) {
        scrollArmed_=true; scrollDirection_=0;
    } else if (scrollArmed_ && std::abs(hand.stickY)>=.6f) {
        const int direction=hand.stickY>0 ? 1 : -1;
        if (scrollDirection_==0) {
            pointer_.scrollSteps=direction; scrollDirection_=direction;
            nextScrollTime_=frame.predictedDisplayTime+.35;
        } else if (direction!=scrollDirection_) {
            // Crossing direction without a sampled neutral must not jump lists.
            scrollArmed_=false; scrollDirection_=0;
        } else if (frame.predictedDisplayTime>=nextScrollTime_) {
            pointer_.scrollSteps=direction; nextScrollTime_=frame.predictedDisplayTime+.12;
        }
    }
    return true;
    };
    return pointerHand_==0 ? updateHand(frame.handLeft) : updateHand(frame.handRight);
}
}
