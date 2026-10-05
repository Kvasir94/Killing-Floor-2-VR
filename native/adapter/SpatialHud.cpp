#include "SpatialHud.h"
#include <algorithm>
#include <cmath>

namespace kf2vr::adapter {
namespace {
bool Finite(Vec3 p) { return std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z); }
bool Rotation(Quat q) { return std::isfinite(q.LengthSq())&&std::abs(q.LengthSq()-1.f)<.01f; }
constexpr float kPi=3.14159265358979323846f;
float Radians(float degrees) { return degrees*kPi/180.f; }
float FollowOutsideDeadZone(float current,float target,float deadZone,float factor,bool angular) {
    const float difference=angular ? std::remainder(target-current,2.f*kPi) : target-current;
    if (std::abs(difference)<=deadZone) return current;
    const float desiredDifference=difference-std::copysign(deadZone,difference);
    return current+desiredDifference*factor;
}
Quat Face(Vec3 towardViewer) {
    const auto z=towardViewer.Normalized();
    const auto x=Vec3{0,1,0}.Cross(z).Normalized();
    const auto y=z.Cross(x);
    Mat3 basis{{{x.x,y.x,z.x},{x.y,y.y,z.y},{x.z,y.z,z.z}}};
    return basis.ToQuat();
}
}
void SpatialHud::Update(const xr::FrameState& f,int weaponHand,unsigned heldWeaponMask,bool enabled,
                        unsigned suppressedHands,bool selectorActive,const SpatialHudSettings& requested) {
    const auto previous=panels_; panels_={};
    if (!enabled || weaponHand<0 || weaponHand>1 || f.state!=xr::SessionState::Focused ||
        !f.actionsSynced || !f.shouldRender || !f.viewsValid || !f.headPoseTracked ||
        !f.headPoseValid || !Finite(f.head.pos) || !Rotation(f.head.rot) ||
        !std::isfinite(f.predictedDisplayTime)) { Reset(); return; }
    const double elapsed=f.predictedDisplayTime-lastTime_;
    if (anchored_ && (elapsed<0 || elapsed>.25)) { Reset(); return; }
    lastTime_=f.predictedDisplayTime;
    const auto forward=f.head.rot.Rotate({0,0,-1});
    auto flat=forward; flat.y=0;
    // Keep a stable session anchor when looking straight up/down. Returning
    // an empty layout here would incorrectly restore the flat stats while
    // all otherwise valid wrist resources are simply outside the view.
    const float headYaw=flat.LengthSq()>=.01f ? std::atan2(-flat.x,-flat.z) :
        (anchored_ && epoch_==f.referenceSpaceEpoch ? yaw_ : 0.f);
    const float headPitch=std::asin(std::clamp(forward.y,-1.f,1.f));
    const int followMode=requested.followMode==1 ? 1 : 0;
    const float hudDistance=std::clamp(std::isfinite(requested.distance) ? requested.distance : 1.65f,1.1f,2.5f);
    const float height=std::clamp(std::isfinite(requested.height) ? requested.height : .4f,.12f,.75f);
    const float scale=std::clamp(std::isfinite(requested.scale) ? requested.scale : 1.f,.65f,1.6f);
    const float yawDead=Radians(std::clamp(std::isfinite(requested.yawDeadZoneDegrees) ? requested.yawDeadZoneDegrees : 12.f,0.f,35.f));
    const float pitchDead=Radians(std::clamp(std::isfinite(requested.pitchDeadZoneDegrees) ? requested.pitchDeadZoneDegrees : 8.f,0.f,25.f));
    const float translationDead=std::clamp(std::isfinite(requested.translationDeadZone) ? requested.translationDeadZone : .12f,0.f,.4f);
    const float detailAngle=Radians(std::clamp(std::isfinite(requested.detailLookDegrees) ? requested.detailLookDegrees : 12.f,5.f,30.f));
    if (!anchored_ || epoch_!=f.referenceSpaceEpoch) {
        wrists_={};
        yaw_=headYaw; pitch_=std::clamp(headPitch,Radians(-25.f),Radians(30.f)); anchorHead_=f.head.pos;
        epoch_=f.referenceSpaceEpoch; anchored_=true; detailVisible_=followMode==1; detailSince_=-1;
    } else if (followMode==1) {
        yaw_=headYaw; pitch_=std::clamp(headPitch,Radians(-25.f),Radians(30.f)); anchorHead_=f.head.pos;
        detailVisible_=true; detailSince_=-1;
    } else {
        const float angularFollow=1.f-std::exp(-6.f*static_cast<float>(std::max(0.,elapsed)));
        yaw_=FollowOutsideDeadZone(yaw_,headYaw,yawDead,angularFollow,true);
        pitch_=FollowOutsideDeadZone(pitch_,std::clamp(headPitch,Radians(-25.f),Radians(30.f)),pitchDead,angularFollow,false);
        const auto translation=f.head.pos-anchorHead_;
        const float translationLength=translation.Length();
        if (translationLength>translationDead) {
            const float positionFollow=1.f-std::exp(-4.f*static_cast<float>(std::max(0.,elapsed)));
            anchorHead_=anchorHead_+translation.Normalized()*(translationLength-translationDead)*positionFollow;
        }
    }
    const auto yawRot=Quat::FromAxisAngle({0,1,0},yaw_);
    const auto right=yawRot.Rotate({1,0,0});
    // Positive OpenXR pitch looks upward. The old negation made the ribbon
    // travel down when the player looked up.
    const auto heading=yawRot*Quat::FromAxisAngle({1,0,0},pitch_);
    auto& session=panels_[3];
    session.center=anchorHead_+heading.Rotate({0,0,-hudDistance})+Vec3{0,height,0};
    session.rotation=Face(f.head.pos-session.center);
    session.width=.72f*scale; session.height=.36f*scale; session.valid=true;
    auto& alert=panels_[4];
    alert.center=anchorHead_+heading.Rotate({0,0,-std::max(1.1f,hudDistance-.18f)})+Vec3{0,-.32f,0};
    alert.rotation=Face(f.head.pos-alert.center);
    alert.width=.62f*scale; alert.height=.15f*scale; alert.valid=true;
    if (followMode==0) {
        const auto toSession=(session.center-f.head.pos).Normalized();
        const float lookAngle=std::acos(std::clamp(forward.Dot(toSession),-1.f,1.f));
        if (lookAngle<=detailAngle) {
            if (detailSince_<0) detailSince_=f.predictedDisplayTime;
            if (f.predictedDisplayTime-detailSince_>=.25) detailVisible_=true;
        } else if (lookAngle>detailAngle*1.5f) {
            detailSince_=-1; detailVisible_=false;
        }
    }
    for (int handIndex=0;handIndex<2;++handIndex) {
        auto& reveal=wrists_[handIndex];
        const bool tracked=handIndex==0 ? f.handLeft.poseValid&&f.handLeft.poseTracked : f.handRight.poseValid&&f.handRight.poseTracked;
        const auto position=handIndex==0 ? f.handLeft.grip.pos : f.handRight.grip.pos;
        const auto rotation=handIndex==0 ? f.handLeft.grip.rot : f.handRight.grip.rot;
        // handLeft and handRight are distinct instantiations, so one
        // reference cannot bind both. Pull the fields, as above.
        const bool gripActive=handIndex==0 ? f.handLeft.gripActive : f.handRight.gripActive;
        const float gripAxis=handIndex==0 ? f.handLeft.gripAxis : f.handRight.gripAxis;
        if (!tracked || !Finite(position) || !Rotation(rotation) || selectorActive ||
            (suppressedHands&(1u<<handIndex)) || (gripActive && gripAxis>.2f)) { reveal={}; continue; }
        // OpenXR grip +X points out of the LEFT palm and into the RIGHT palm.
        // Use physical grip orientation, never weapon aim calibration, recoil,
        // or an animated hand bone. Merely raising a normally held gun is not
        // a wrist-up gesture. See the OpenXR standard pose identifiers.
        const auto palm=rotation.Rotate({handIndex==0 ? 1.f : -1.f,0,0});
        const auto towardHead=f.head.pos-position;
        const float distance=towardHead.Length();
        const bool occupied=(heldWeaponMask&(1u<<handIndex))!=0;
        // Tracked grip -Z is used for the lowered-weapon gate, never calibrated
        // aim or recoil. Looking at the wrist must be substantially deliberate.
        const auto physicalForward=rotation.Rotate({0,0,-1});
        const bool lowered=!occupied || (physicalForward.Dot(forward)<.75f && position.y<f.head.pos.y-.15f);
        const bool readable=distance>.25f && distance<(occupied?.85f:1.2f) && lowered &&
            (-towardHead.Normalized()).Dot(forward)>(occupied?.7f:.4f) &&
            palm.Dot(towardHead.Normalized())>(reveal.visible ? .05f : .15f);
        // A short deliberate hold avoids flashes during reload/turn gestures.
        // Angular hysteresis prevents threshold jitter; lowering the wrist or
        // losing tracking hides immediately and requires a fresh hold.
        if (!readable || palm.y<(reveal.visible ? .45f : .65f)) { reveal={}; continue; }
        if (reveal.raisedAt<0) reveal.raisedAt=f.predictedDisplayTime;
        if (f.predictedDisplayTime-reveal.raisedAt>=.23) reveal.visible=true;
    }
    for (int index=0;index<3;++index) {
        // Vitals stay on the free/support wrist, including the non-dominant
        // wrist when dual wielding. The two plates stack when it holds a gun.
        const int statusHand=heldWeaponMask==1 ? 1 : (heldWeaponMask==2 ? 0 : 1-weaponHand);
        const int handIndex=index==0 ? statusHand : index-1;
        const auto handPosition=handIndex==0 ? f.handLeft.grip.pos : f.handRight.grip.pos;
        if (!wrists_[handIndex].visible) continue;
        const float side=handIndex==0 ? -1.f : 1.f;
        auto& p=panels_[index];
        p.width=index==0 ? .28f : .22f;
        p.height=index==0 ? .14f : .12f;
        p.center=handPosition+right*(side*.14f)+Vec3{0,index==0 ? .13f : -.105f,0};
        const auto toPanel=p.center-f.head.pos;
        const float distance=toPanel.Length();
        // Hysteresis prevents a display flickering on a range boundary.
        // Turning away does not restore flat widgets: off-screen world HUD
        // naturally remains available when the user looks back at the hand.
        // Never push a too-close panel through the face to keep it visible.
        const bool wasVisible=previous[index].valid;
        if (distance<(wasVisible?.32f:.38f) || distance>(wasVisible?1.4f:1.3f) ||
            std::abs(toPanel.Normalized().y)>.94f) continue;
        p.rotation=Face(-toPanel); p.valid=true;
    }
}
}
