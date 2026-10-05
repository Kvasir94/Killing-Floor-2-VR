#include "SpatialHud.h"
#include <cmath>
#include <cstdio>
#include <limits>
using namespace kf2vr;
using namespace kf2vr::adapter;
namespace {
int checks=0, failures=0;
void Test(bool value,const char* message) { ++checks; if (!value) { ++failures; std::printf("FAIL %s\n",message); } }
bool Near(Vec3 a,Vec3 b,float tolerance=.0001f) { return (a-b).Length()<tolerance; }
xr::FrameState Frame() {
    xr::FrameState f; f.state=xr::SessionState::Focused;
    f.shouldRender=f.viewsValid=f.actionsSynced=f.headPoseValid=f.headPoseTracked=true;
    f.predictedDisplayTime=1;
    f.head.pos={0,1.6f,0};
    f.handLeft.poseValid=f.handLeft.poseTracked=true;
    f.handRight.poseValid=f.handRight.poseTracked=true;
    f.handLeft.grip.pos={-.22f,1.3f,-.55f}; f.handRight.grip.pos={.18f,1.3f,-.55f};
    f.handLeft.grip.rot=Quat::FromAxisAngle({0,0,1},1.5707963f)*Quat::FromAxisAngle({1,0,0},1.f);
    f.handRight.grip.rot=Quat::FromAxisAngle({0,0,1},-1.5707963f)*Quat::FromAxisAngle({1,0,0},1.f);
    return f;
}
void Reveal(SpatialHud& hud,xr::FrameState& f,int weaponHand=1,unsigned mask=2) {
    hud.Update(f,weaponHand,mask,true);
    f.predictedDisplayTime+=.24;
    hud.Update(f,weaponHand,mask,true);
}
}
int main() {
    SpatialHud hud; auto f=Frame(); Reveal(hud,f);
    auto p=hud.Panels();
    Test(p[0].valid && p[1].valid && p[2].valid && p[3].valid && p[4].valid,"deliberately raised wrists produce all five layout surfaces");
    Test(p[0].center.x<0 && p[2].center.x>0,"status on support side and ammo outside weapon side");
    Test(std::abs(p[3].center.z - (-1.65f)) < .001f && p[3].center.y > f.head.pos.y,"session panel has finite depth at center top");
    Test((p[0].center-p[2].center).Length()>(p[0].width+p[2].width)/2,"ordinary hand poses separate the surfaces");
    for (int i=0;i<5;++i) {
        Test(p[i].rotation.Rotate({0,0,1}).Dot((f.head.pos-p[i].center).Normalized())>.999f,"display front faces the viewer in a shared stereo space");
        Test(p[i].rotation.Rotate({0,1,0}).y>.8f,"text remains upright");
    }
    f.predictedDisplayTime+=.01; f.head.rot=Quat::FromAxisAngle({0,1,0},.3f); hud.Update(f,1,2,true);
    Test((hud.Panels()[3].center-p[3].center).Length()>0 && (hud.Panels()[3].center-p[3].center).Length()<.25f,"head turn follows with smooth lag");
    for (int step=0; step<50; ++step) { f.predictedDisplayTime+=.016; hud.Update(f,1,2,true); }
    Test((hud.Panels()[3].center-f.head.pos).Length()>1.5f,"soft anchor retains comfortable viewing distance");
    Test(std::abs(hud.Panels()[3].width/hud.Panels()[3].height-2.f)<.01f,"session module keeps the high-resolution 2:1 surface aspect");
    Test(hud.Panels()[3].center.y>f.head.pos.y+.3f && hud.Panels()[3].center.y<f.head.pos.y+.5f,"session module rides center top, not the gaze line");
    auto before=hud.Panels()[3].center; f.head.pos.x+=.05f; f.predictedDisplayTime+=.01; hud.Update(f,1,2,true);
    Test(Near(hud.Panels()[3].center,before),"small headset translation remains inside the comfort dead zone");
    f.head.pos.x+=.35f; f.predictedDisplayTime+=.05; hud.Update(f,1,2,true);
    Test(hud.Panels()[3].center.x>before.x && hud.Panels()[3].center.x<f.head.pos.x,"large translation starts bounded catch-up without face locking");
    f=Frame(); hud.Reset(); Reveal(hud,f,0,1);
    Test(hud.Panels()[0].center.x>0 && hud.Panels()[1].center.x<0,"handedness swaps support and weapon displays");
    f.handLeft.poseTracked=false; hud.Update(f,0,1,true);
    Test(!hud.Panels()[1].valid && hud.Panels()[0].valid && hud.Panels()[3].valid,"lost weapon tracking only removes its surface");
    f=Frame(); f.handLeft.grip.pos=f.head.pos; hud.Reset(); Reveal(hud,f);
    Test(!hud.Panels()[0].valid,"near-face display is hidden instead of being pushed into the view");
    f=Frame(); f.actionsSynced=false; hud.Update(f,1,2,true);
    Test(!hud.Panels()[0].valid && !hud.Panels()[3].valid,"focus/action loss clears the whole HUD");
    f=Frame(); hud.Update(f,1,2,false);
    Test(!hud.Panels()[3].valid,"modal menu suppresses gameplay HUD");
    hud.Update(f,1,2,true); f.predictedDisplayTime+=1; hud.Update(f,1,2,true);
    Test(!hud.Panels()[0].valid && !hud.Panels()[3].valid,"stale frame does not carry old HUD placements");
    f=Frame(); hud.Reset(); Reveal(hud,f);
    ++f.referenceSpaceEpoch; f.head.pos.x=2; f.head.rot=Quat::FromAxisAngle({0,1,0},1.f); hud.Update(f,1,2,true);
    Test(hud.Panels()[3].valid && Near(hud.Panels()[3].center,f.head.pos+f.head.rot.Rotate({0,0,-1.65f})+Vec3{0,.4f,0}),"origin changes reanchor immediately");
    Test(!hud.Panels()[0].valid && !hud.Panels()[2].valid,"origin change clears wrist reveal history");
    f.head.pos.x=std::numeric_limits<float>::quiet_NaN(); hud.Update(f,1,2,true);
    Test(!hud.Panels()[3].valid,"nonfinite head pose rejected");
    f=Frame(); f.handRight.grip.pos.x=std::numeric_limits<float>::infinity(); hud.Update(f,1,2,true);
    Test(!hud.Panels()[2].valid && hud.Panels()[3].valid,"invalid hand cannot contaminate the session panel");
    f=Frame(); f.head.rot=Quat::FromAxisAngle({1,0,0},1.5707963f); hud.Update(f,1,2,true);
    Test(hud.Panels()[3].valid && std::isfinite(hud.Panels()[3].rotation.LengthSq()) &&
        std::abs(hud.Panels()[3].rotation.LengthSq()-1.f)<.001f,
        "vertical gaze retains stable spatial mode without restoring flat stats");
    f=Frame(); hud.Reset(); hud.Update(f,1,2,true); before=hud.Panels()[3].center;
    f.head.rot=Quat::FromAxisAngle({1,0,0},.35f);
    for (int step=0; step<30; ++step) { f.predictedDisplayTime+=.016; hud.Update(f,1,2,true); }
    Test(hud.Panels()[3].center.y>before.y,"looking up moves the comfort anchor up rather than inverting pitch");
    Test(hud.Panels()[3].rotation.Rotate({0,1,0}).y>.8f,"session module ignores headset roll and stays upright");
    SpatialHudSettings locked; locked.followMode=1;
    f=Frame(); hud.Reset(); hud.Update(f,1,2,true,0,false,locked);
    Test(hud.DetailVisible() && Near(hud.Panels()[3].center,f.head.pos+Vec3{0,.4f,-1.65f}),"screen-stable accessibility mode follows immediately and exposes detail");
    f=Frame(); hud.Reset(); Reveal(hud,f,1,3);
    const auto dual=hud.Panels();
    Test(dual[1].valid && dual[2].valid && dual[1].center.x<0 && dual[2].center.x>0,"dual-wield layout retains separate physical left and right displays");
    Test(dual[0].valid && dual[0].center.x<0 && dual[0].center.y>dual[1].center.y,
        "dual-wield vitals stay above ammo on the non-dominant wrist");
    Test((dual[0].center-dual[1].center).Length()>(dual[0].height+dual[1].height)/2,
        "vitals and ammo stack with a gap on an occupied wrist");
    f.handLeft.grip.pos.x-=.12f; hud.Update(f,1,3,true);
    Test(Near(hud.Panels()[2].center,dual[2].center) && !Near(hud.Panels()[0].center,dual[0].center)
        && !Near(hud.Panels()[1].center,dual[1].center),"moving left wrist moves its vitals and ammo independently of right ammo");
    f.handLeft.poseTracked=false; hud.Update(f,1,3,true);
    Test(!hud.Panels()[1].valid && hud.Panels()[2].valid && !hud.Panels()[0].valid,"lost left wrist hides its stats while right ammo remains available");

    f=Frame(); hud.Reset();
    f.handLeft.grip.rot=f.handRight.grip.rot={};
    Reveal(hud,f,1,3);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid && !hud.Panels()[2].valid && hud.Panels()[3].valid,
        "normal gun grip keeps all personal stats hidden while the session display remains");
    f.handLeft.grip.rot=Quat::FromAxisAngle({0,0,1},1.5707963f)*Quat::FromAxisAngle({1,0,0},1.f);
    hud.Update(f,1,3,true);
    f.predictedDisplayTime+=.08; hud.Update(f,1,3,true);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid,"brief wrist roll does not flash vitals or ammo");
    f.predictedDisplayTime+=.16; hud.Update(f,1,3,true);
    Test(hud.Panels()[0].valid && hud.Panels()[1].valid && !hud.Panels()[2].valid,
        "raising only left wrist reveals only its vitals and actual weapon slot");
    f.handLeft.grip.rot=Quat::FromAxisAngle({0,0,1},std::asin(.6f))*Quat::FromAxisAngle({1,0,0},1.f);
    hud.Update(f,1,3,true);
    Test(hud.Panels()[0].valid && hud.Panels()[1].valid,"angular hysteresis keeps a readable wrist stable near entry threshold");
    f.handLeft.grip.rot=Quat::FromAxisAngle({0,0,1},std::asin(.4f))*Quat::FromAxisAngle({1,0,0},1.f);
    hud.Update(f,1,3,true);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid,"lowering wrist hides both stats immediately");
    f.handLeft.grip.rot=Quat::FromAxisAngle({0,0,1},std::asin(.6f))*Quat::FromAxisAngle({1,0,0},1.f);
    Reveal(hud,f,1,3);
    Test(!hud.Panels()[0].valid,"entry threshold is stricter than hold threshold");
    f.handRight.grip.rot=Quat::FromAxisAngle({0,0,1},-1.5707963f)*Quat::FromAxisAngle({1,0,0},1.f);
    Reveal(hud,f,1,3);
    Test(hud.Panels()[2].valid && !hud.Panels()[0].valid,"right wrist uses mirrored grip palm axis independently of left");
    f.handRight.aim.rot=Quat::FromAxisAngle({0,0,1},1.5707963f);
    hud.Update(f,1,3,true);
    Test(hud.Panels()[2].valid,"weapon aim calibration cannot change physical wrist visibility");
    f.handRight.poseTracked=false; hud.Update(f,1,3,true);
    f.handRight.poseTracked=true; hud.Update(f,1,3,true);
    Test(!hud.Panels()[2].valid,"reacquired hand requires a new deliberate wrist hold");
    f.predictedDisplayTime+=.24; hud.Update(f,1,3,true);
    Test(hud.Panels()[2].valid,"tracked raised wrist recovers after fresh hold");
    f.handRight.grip.rot.w=std::numeric_limits<float>::quiet_NaN(); hud.Update(f,1,3,true);
    Test(!hud.Panels()[2].valid && hud.Panels()[3].valid,"nonfinite grip orientation hides that wrist without corrupting session display");
    f=Frame(); hud.Reset(); f.handRight.grip.rot={0,0,0,2}; Reveal(hud,f);
    Test(!hud.Panels()[2].valid,"nonunit grip quaternion is rejected");
    f=Frame(); hud.Reset();
    f.handLeft.grip.rot=Quat::FromAxisAngle({0,0,1},-1.5707963f)*Quat::FromAxisAngle({1,0,0},1.f);
    f.handRight.grip.rot=Quat::FromAxisAngle({0,0,1},1.5707963f)*Quat::FromAxisAngle({1,0,0},1.f);
    Reveal(hud,f,1,3);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid && !hud.Panels()[2].valid,"palm-down roll never reveals personal stats");
    f=Frame(); hud.Reset(); f.handLeft.grip.pos.z=f.handRight.grip.pos.z=.55f; Reveal(hud,f,1,3);
    Test(!hud.Panels()[0].valid && !hud.Panels()[2].valid,"raised wrists behind the head do not reveal stats");
    f=Frame(); hud.Reset(); Reveal(hud,f,0,3);
    Test(hud.Panels()[0].valid && hud.Panels()[0].center.x>0,"left-handed dual wield puts vitals on right wrist");
    f.head.rot=Quat::FromAxisAngle({1,0,0},1.5707963f);
    f.handRight.poseTracked=false;
    f.predictedDisplayTime+=.24; hud.Update(f,0,3,true);
    Test(hud.Panels()[3].valid && !hud.Panels()[0].valid,"vertical head gaze still processes lost wrist tracking");
    f.head.rot={}; f.handRight.poseTracked=true;
    hud.Update(f,0,3,true);
    Test(!hud.Panels()[0].valid && !hud.Panels()[2].valid,"returning from vertical gaze cannot reuse stale wrist reveal");
    f.predictedDisplayTime+=.24; hud.Update(f,0,3,true);
    Test(hud.Panels()[0].valid && hud.Panels()[2].valid,"wrist reveal recovers after a fresh hold following pole gaze tracking loss");

    // --- Section 10 & Acceptance: HUD suppression & deliberate primary inspection tests ---

    // 1. Support hand suppression via suppressedHands bitmask
    f=Frame(); hud.Reset();
    hud.Update(f, 1, 2, true, 1u, false);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true, 1u, false);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid,
        "suppressed support hand bitmask suppresses wrist HUD reveal");
    Test(hud.Panels()[2].valid && hud.Panels()[3].valid,
        "unsuppressed weapon hand and session display remain available");

    // Suppress both hands
    f=Frame(); hud.Reset();
    hud.Update(f, 1, 2, true, 3u, false);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true, 3u, false);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid && !hud.Panels()[2].valid,
        "suppressing both hands suppresses both wrist HUDs");
    Test(hud.Panels()[3].valid, "session display remains when both wrists suppressed");

    // 2. Active grip contact suppression (gripAxis > 0.2f)
    f=Frame(); hud.Reset();
    f.handLeft.gripActive=true; f.handLeft.gripAxis=.45f;
    Reveal(hud, f, 1, 2);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid,
        "active grip contact suppresses wrist HUD reveal");
    Test(hud.Panels()[2].valid, "ungripped hand still reveals");

    // Grip released (gripAxis <= 0.2f) allows reveal after fresh dwell
    f.handLeft.gripAxis=.1f;
    hud.Update(f, 1, 2, true);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true);
    Test(hud.Panels()[0].valid, "releasing grip contact allows wrist reveal after dwell");

    // 3. Weapon selector active suppression
    f=Frame(); hud.Reset();
    hud.Update(f, 1, 2, true, 0u, true);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true, 0u, true);
    Test(!hud.Panels()[0].valid && !hud.Panels()[1].valid && !hud.Panels()[2].valid,
        "active weapon selector suppresses all wrist HUD reveals");
    Test(hud.Panels()[3].valid, "session display remains valid during selector");

    // Selector closed restores ability to reveal
    hud.Update(f, 1, 2, true, 0u, false);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true, 0u, false);
    Test(hud.Panels()[0].valid && hud.Panels()[2].valid,
        "closing selector allows wrist reveals after dwell");

    // 4. Occupied primary deliberate inspection gates:
    // Gun pointing forward (aiming orientation): physicalForward.Dot(forward) >= .75f
    f=Frame(); hud.Reset();
    f.handRight.grip.rot=Quat::FromAxisAngle({0,0,1},-1.5707963f); // gun points forward along -Z (Dot == 1.0)
    hud.Update(f, 1, 2, true);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true);
    Test(!hud.Panels()[2].valid, "occupied hand pointing gun forward does not reveal wrist HUD");

    // Gun raised too high: position.y >= f.head.pos.y - .15f
    f=Frame(); hud.Reset();
    f.handRight.grip.pos.y = 1.55f; // gun raised near eye level
    Reveal(hud, f, 1, 2);
    Test(!hud.Panels()[2].valid, "occupied hand held high / not lowered rejects HUD reveal");

    // Gun lowered away from eye level reveals when palm is up and dwelled
    f.handRight.grip.pos.y = 1.3f; // 30cm below eye level
    hud.Update(f, 1, 2, true);
    f.predictedDisplayTime+=.24;
    hud.Update(f, 1, 2, true);
    Test(hud.Panels()[2].valid, "occupied hand lowered away from eye level allows HUD reveal");

    // Dwell gate: < 230ms hold does not reveal
    f=Frame(); hud.Reset();
    hud.Update(f, 1, 2, true);
    f.predictedDisplayTime+=.20; // 200 ms < 230 ms
    hud.Update(f, 1, 2, true);
    Test(!hud.Panels()[2].valid, "occupied hand dwell under 230ms leaves HUD hidden");
    f.predictedDisplayTime+=.04; // 200 + 40 = 240 ms >= 230 ms
    hud.Update(f, 1, 2, true);
    Test(hud.Panels()[2].valid, "occupied hand dwell reaching 230ms reveals HUD");

    // Prompt hide: losing the deliberate inspection pose hides immediately
    f.handRight.grip.rot={}; // gun rotated back to forward/neutral grip
    hud.Update(f, 1, 2, true);
    Test(!hud.Panels()[2].valid, "losing deliberate inspection pose promptly hides wrist HUD");

    // Tracking loss prompt hide and fresh dwell requirement
    f=Frame(); hud.Reset(); Reveal(hud, f, 1, 2);
    Test(hud.Panels()[2].valid, "occupied hand revealed");
    f.handRight.poseTracked=false;
    hud.Update(f, 1, 2, true);
    Test(!hud.Panels()[2].valid, "tracking loss immediately hides HUD");
    f.handRight.poseTracked=true;
    f.predictedDisplayTime+=.10; // 100 ms < 230 ms
    hud.Update(f, 1, 2, true);
    Test(!hud.Panels()[2].valid, "reacquired tracking requires fresh dwell >= 230ms");
    f.predictedDisplayTime+=.24; // fresh dwell >= 230 ms
    hud.Update(f, 1, 2, true);
    Test(hud.Panels()[2].valid, "reacquired tracking reveals after full 230ms dwell");

    // Reset clears reveal
    hud.Reset();
    Test(!hud.Panels()[0].valid && !hud.Panels()[2].valid && !hud.Panels()[3].valid && !hud.Panels()[4].valid,
        "hud.Reset() immediately clears all panels and reveal state");

    std::printf("Spatial HUD checks=%d failures=%d\n",checks,failures);
    return failures?1:0;
}
