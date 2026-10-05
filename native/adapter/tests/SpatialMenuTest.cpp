#include "SpatialMenu.h"
#include "MenuPointerInput.h"
#include "MenuCursor.h"
#include "MenuRenderLayers.h"
#include "VRSessionInput.h"
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
using namespace kf2vr;
using namespace kf2vr::adapter;
namespace {
int checks=0,failures=0;
void Test(bool pass,const char* label) { ++checks; if (!pass) { ++failures; std::printf("FAIL %s\n",label); } }
bool Near(float a,float b) { return std::abs(a-b)<.0001f; }
void DesktopCursorTests() {
    using menu_native::Point;
    Point point{};
    Test(MapDesktopMenuPoint({683,524},1280,720,2244,2352,point) && point.x==1197 && point.y==1711,
        "desktop client point maps independently to each full eye-buffer axis");
    Test(MapDesktopMenuPoint({640,360},1280,720,2244,2352,point) && point.x==1122 && point.y==1176,
        "desktop center maps to render center");
    Test(MapDesktopMenuPoint({0,0},1280,720,2244,2352,point) && point.x==0 && point.y==0,
        "desktop origin maps to render origin");
    Test(MapDesktopMenuPoint({1280,720},1280,720,2244,2352,point) && point.x==2244 && point.y==2352,
        "outside right and bottom edges stay outside instead of clicking an edge widget");
    Test(MapDesktopMenuPoint({-1,-1},1280,720,640,360,point) && point.x==-1 && point.y==-1,
        "negative points remain outside even when downscaled");
    Test(MapDesktopMenuPoint({640,360},1280,720,1684,1764,point) && point.x==842 && point.y==882,
        "mapping uses current reduced render extent rather than runtime recommendation");
    Test(MapDesktopMenuPoint({-5,800},1280,720,1280,720,point) && point.x==-5 && point.y==800,
        "matching extents preserve stock coordinates");
    point={17,19};
    Test(!MapDesktopMenuPoint({5,6},0,720,2244,2352,point) && point.x==17 && point.y==19,
        "minimized client rejects mapping without mutating output");
    Test(!MapDesktopMenuPoint({5,6},1280,720,16385,2352,point),"unbounded render extent is rejected");
    Test(!MapDesktopMenuPoint({std::numeric_limits<int>::max(),0},1,1,16384,16384,point),
        "overflowing outside point is rejected");
    bool active=false; Point cache{1197,1711}; const Point xr{1683,588};
    {
        ScopedMenuCursor dispatch(active,cache,xr);
        Test(active && cache.x==1683 && cache.y==588,"synthetic move owns cursor only inside dispatch");
    }
    Test(!active && cache.x==1197 && cache.y==1711,"synthetic hover restores desktop cached click point");
    cache={200,300}; // Physical input can occur between XR move and trigger.
    {
        ScopedMenuCursor button(active,cache,xr);
        Test(active && cache.x==1683 && cache.y==588,"synthetic button reasserts XR point after physical mouse move");
    }
    Test(!active && cache.x==200 && cache.y==300,"synthetic button restores later desktop point");
    {
        ScopedMenuCursor cancel(active,cache,{-10000,-10000});
        Test(active && cache.x==-10000 && cache.y==-10000,"cancel supplies outside point without sending a drag move");
    }
    Test(!active && cache.x==200 && cache.y==300,"cancellation cannot strand desktop at outside sentinel");
}
struct FakeMenuSink : MenuInputSink {
    std::string events;
    bool moveOkay=true,buttonOkay=true,cancelOkay=true;
    int x=0,y=0;
    bool Move(int px,int py) override { events+='M'; x=px; y=py; return moveOkay; }
    bool Button(bool down) override { events+=down?'D':'U'; return buttonOkay; }
    bool Wheel(int steps) override { events+=steps>0?'+':'-'; return true; }
    bool Cancel() override { events+='C'; return cancelOkay; }
};
void InputTests() {
    MenuPointerInput input; FakeMenuSink sink;
    SpatialMenuPointer p; p.hit=true; p.u=.75f; p.v=.25f;
    p.pressed=p.down=true;
    Test(input.Update(p,2244,2352,true,sink) && sink.events=="MD" && input.Held(),"press moves virtual cursor before mouse-down");
    Test(sink.x==1683 && sink.y==588,"UV maps to full render surface without desktop-size clamp");
    p.pressed=false; p.u=.25f; sink.events.clear();
    Test(input.Update(p,2244,2352,true,sink) && sink.events=="M" && input.Held(),"held trigger moves a captured slider without duplicate down");
    p.down=false; p.released=true; sink.events.clear();
    Test(input.Update(p,2244,2352,true,sink) && sink.events=="MU" && !input.Held(),"normal release ends drag at current position");
    p.released=false; p.pressed=p.down=true; input.Update(p,2244,2352,true,sink);
    p.hit=false; p.cancelled=true; sink.events.clear();
    Test(!input.Update(p,2244,2352,true,sink) && sink.events=="C" && !input.Held(),"loss uses cancellation without an out-of-bounds drag move");
    p={}; p.hit=true; p.u=p.v=.5f; p.pressed=p.down=true; input.Update(p,2244,2352,true,sink);
    sink.moveOkay=false; p.pressed=false; sink.events.clear();
    Test(!input.Update(p,2244,2352,true,sink) && sink.events=="MC" && !input.Held(),"failed coordinate receipt cancels instead of releasing on a stale button");
    sink.moveOkay=true; p.pressed=true; input.Update(p,2244,2352,true,sink);
    sink.cancelOkay=false; sink.events.clear(); input.Update(p,2244,2352,false,sink);
    Test(sink.events=="C" && input.Held(),"unacknowledged cancel retains ownership for retry");
    sink.events.clear(); input.Update(p,2244,2352,true,sink);
    Test(sink.events=="C","pending cancellation blocks all new movement/presses");
    sink.cancelOkay=true; sink.events.clear();
    Test(!input.Update(p,2244,2352,true,sink) && sink.events=="C" && !input.Held(),"successful cancellation retry still requires rearming");
    p.pressed=p.down=false; p.scrollSteps=1; sink.events.clear();
    Test(input.Update(p,2244,2352,true,sink) && sink.events=="M+","scroll uses current pointer location");
    p.u=p.v=1; p.scrollSteps=0; input.Update(p,2244,2352,true,sink);
    Test(sink.x==2243 && sink.y==2351,"menu edges map to final valid pixel");
    p.u=std::numeric_limits<float>::quiet_NaN(); sink.events.clear();
    Test(!input.Update(p,2244,2352,true,sink) && sink.events.empty(),"invalid coordinate never reaches native input");
}
void MovieRecoveryTests() {
    xr::FrameState f;
    f.state=xr::SessionState::Focused; f.shouldRender=f.viewsValid=f.actionsSynced=true;
    f.headPoseValid=f.headPoseTracked=true;
    f.handRight.aimPoseValid=f.handRight.aimPoseTracked=f.handRight.triggerActive=true;
    SpatialMenu menu; MenuPointerInput input; FakeMenuSink sink;
    menu.Update(f,true,2244.f/2352);
    sink.moveOkay=false;
    Test(!input.Update(menu.Pointer(),2244,2352,true,sink),"movie without a cursor receipt declines hover");
    menu.DisarmInput();
    Test(menu.Pointer().rayVisible && menu.Pointer().hit && !menu.Pointer().pressed,
        "declined movie input keeps tracked aiming feedback");
    f.handRight.triggerAxis=.8f; menu.Update(f,true,2244.f/2352);
    sink.moveOkay=true; sink.events.clear();
    input.Update(menu.Pointer(),2244,2352,true,sink);
    Test(sink.events=="M" && !input.Held(),"movie recovery while trigger is held cannot activate a stale widget");
    f.handRight.triggerAxis=0; menu.Update(f,true,2244.f/2352);
    input.Update(menu.Pointer(),2244,2352,true,sink);
    f.handRight.triggerAxis=.8f; menu.Update(f,true,2244.f/2352); sink.events.clear();
    Test(input.Update(menu.Pointer(),2244,2352,true,sink) && sink.events=="MD" && input.Held(),
        "release then press selects after the movie recovers");
    f.state=xr::SessionState::Visible; menu.Update(f,true,2244.f/2352); sink.events.clear();
    Test(!input.Update(menu.Pointer(),2244,2352,true,sink) && sink.events=="C" && !input.Held(),
        "XR focus loss cancels movie capture even with a retained panel");
    Test(!menu.Pointer().rayVisible && menu.Panel().valid,"runtime overlay focus hides the beam and retains the panel");
}
void MenuRenderTests() {
    struct Sink : MenuRenderSink {
        std::string events;
        char fail=0;
        bool throwing=false;
        bool Step(char step) { events+=step; if (throwing && step=='R') throw 1; return fail!=step; }
        bool BeginWorld() override { return Step('B'); }
        bool WorldEye(unsigned eye) override { return Step(eye?'R':'L'); }
        bool BeginImage() override { return Step('U'); }
        bool Image() override { return Step('I'); }
        bool Restore() noexcept override { events+='X'; return fail!='X'; }
    } sink;
    Test(RenderMenuLayers(sink) && sink.events=="BLRUIX",
        "menu renders two fresh world eyes then isolated UI and restores stock flags");
    sink.events.clear();
    Test(RenderMenuLayers(sink,false) && sink.events=="BUIX",
        "startup and death render only the menu image without a cinematic world camera");
    for (const char failed:std::string("BLRUIX")) {
        sink.events.clear(); sink.fail=failed;
        Test(!RenderMenuLayers(sink) && sink.events.back()=='X' && sink.events.find('X')==sink.events.size()-1,
            "every failed menu phase restores stock state exactly once");
        if (failed=='L' || failed=='R')
            Test(sink.events.find('U')==std::string::npos,"incomplete stereo world cannot produce a mixed menu frame");
    }
    sink.events.clear(); sink.fail=0; sink.throwing=true;
    try { RenderMenuLayers(sink); Test(false,"expected simulated eye failure"); }
    catch (int) { Test(sink.events=="BLRX","render unwind restores hidden movie and viewport state"); }
}
void ConfigureTests() {
    SpatialMenu m;
    xr::FrameState f;
    f.state=xr::SessionState::Focused; f.shouldRender=f.viewsValid=f.actionsSynced=true;
    f.headPoseValid=f.headPoseTracked=true;
    f.head.pos={0,1.6f,0};
    f.handRight.aimPoseValid=f.handRight.aimPoseTracked=f.handRight.triggerActive=true;
    f.handRight.aim.pos=f.head.pos;

    // Default configuration
    Test(Near(m.Distance(), 1.5f), "default spatial menu distance is 1.5m");
    Test(Near(m.Height(), 0.0f), "default spatial menu height is 0m");
    Test(Near(m.Scale(), 1.0f), "default spatial menu scale is 1.0");

    // Configure new valid parameters
    m.Configure(2.0f, 0.2f, 1.2f);
    Test(Near(m.Distance(), 2.0f), "updated distance is 2.0m");
    Test(Near(m.Height(), 0.2f), "updated height is 0.2m");
    Test(Near(m.Scale(), 1.2f), "updated scale is 1.2");

    m.Update(f, true, 16.f/9);
    Test(m.Panel().valid, "panel opens with configured parameters");
    Test(Near(m.Panel().center.z, -2.0f), "panel distance matches 2.0m");
    Test(Near(m.Panel().center.y, 1.8f), "panel height matches head 1.6 + 0.2m = 1.8m");
    Test(Near(m.Panel().width, 1.7320508f * 1.2f), "panel width scales by 1.2");

    // Out-of-bounds parameters rejected
    m.Configure(0.2f, 0.0f, 1.0f); // distance < 0.6 rejected
    Test(Near(m.Distance(), 2.0f), "too close distance rejected");
    m.Configure(5.0f, 0.0f, 1.0f); // distance > 3.0 rejected
    Test(Near(m.Distance(), 2.0f), "too far distance rejected");
    m.Configure(2.0f, -1.5f, 1.0f); // height < -0.8 rejected
    Test(Near(m.Height(), 0.2f), "too low height rejected");
    m.Configure(2.0f, 1.0f, 1.0f); // height > 0.5 rejected
    Test(Near(m.Height(), 0.2f), "too high height rejected");
    m.Configure(2.0f, 0.2f, 0.2f); // scale < 0.5 rejected
    Test(Near(m.Scale(), 1.2f), "too small scale rejected");
    m.Configure(2.0f, 0.2f, 2.5f); // scale > 1.5 rejected
    Test(Near(m.Scale(), 1.2f), "too large scale rejected");

    // Non-finite values rejected
    m.Configure(std::numeric_limits<float>::quiet_NaN(), 0.0f, 1.0f);
    Test(Near(m.Distance(), 2.0f), "NaN distance rejected");

    // Explicit Recenter resets panel and anchors to current head pose
    f.head.pos = {1.0f, 1.7f, 2.0f};
    m.Recenter();
    Test(!m.Panel().valid, "Recenter clears panel immediately");
    m.Update(f, true, 16.f/9);
    Test(m.Panel().valid, "panel re-anchors after Recenter");
    Test(Near(m.Panel().center.x, 1.0f), "re-anchored panel uses new head x");
    Test(Near(m.Panel().center.z, 0.0f), "re-anchored panel uses new head z (2.0 - 2.0 = 0)");
}
void CurvedPanelTests() {
    xr::FrameState f;
    f.state=xr::SessionState::Focused; f.shouldRender=f.viewsValid=f.actionsSynced=true;
    f.headPoseValid=f.headPoseTracked=true; f.head.pos={0,1.6f,0};
    f.handRight.aimPoseValid=f.handRight.aimPoseTracked=f.handRight.triggerActive=true;
    f.handRight.aim.pos=f.head.pos;
    SpatialMenu m; m.SetCurved(true);
    Test(m.Update(f,true,16.f/9) && Near(m.Panel().curveRadius,1.5f),"studio panel curves about the opening head position");
    Test(m.Pointer().hit && Near(m.Pointer().u,.5f) && Near(m.Pointer().v,.5f) && Near(m.Pointer().rayEnd.z,-1.5f),
        "curved centre still meets the aim ray at the opening distance");
    float u=0,v=0; Vec3 hit;
    // From the axis every column is equidistant: an angle maps linearly to u.
    const float angle=.4f,expectedU=.5f+1.5f*angle/m.Panel().width;
    Test(IntersectSpatialMenu(m.Panel(),{0,1.6f,0},{std::sin(angle),0,-std::cos(angle)},u,v,hit)
        && std::abs(u-expectedU)<.0005f && std::abs((hit-Vec3{0,1.6f,0}).Length()-1.5f)<.0005f,
        "off-axis ray lands on the cylinder at the opening distance");
    Test(IntersectSpatialMenu(m.Panel(),{0,1.6f,0},{-std::sin(angle),0,-std::cos(angle)},u,v,hit)
        && std::abs(u-(1-expectedU))<.0005f,"curve is symmetric about the centre");
    // Edge angle for the default width (arc 1.732 m at radius 1.5 m): 33 deg.
    Test(!IntersectSpatialMenu(m.Panel(),{0,1.6f,0},{std::sin(.65f),0,-std::cos(.65f)},u,v,hit),
        "rays past the arc's edge miss");
    Test(!IntersectSpatialMenu(m.Panel(),{0,1.6f,-2},{0,0,1},u,v,hit),"curved back side rejected");
    m.SetCurved(false); m.Update(f,true,16.f/9);
    Test(m.Panel().curveRadius==0,"live-world backdrop keeps the flat panel");
}
void SessionInputTests() {
    Test(Near(ScaleSmoothTurnAxis(1.f,.1f),.1f),"smooth turn supports the displayed ten-percent minimum");
    Test(Near(ScaleSmoothTurnAxis(.01f,.5f),.5f) && Near(ScaleSmoothTurnAxis(.9f,.5f),.5f),
        "smooth turn uses the same rate for every live horizontal input");
    Test(Near(ScaleSmoothTurnAxis(-.01f,.1f),-.1f) && ScaleSmoothTurnAxis(0.f,2.f)==0.f,
        "smooth turn preserves direction and neutral at all speeds");
    Test(ScaleSmoothTurnAxis(1.f,2.f)==1.f && ScaleSmoothTurnAxis(-1.0001f,2.f)==-1.f,
        "high smooth sensitivity saturates both signs before gamepad conversion");
    Test(Near(ScaleSmoothTurnAxis(1.f,std::numeric_limits<float>::quiet_NaN()),.5f),
        "invalid smooth scale recovers the default");
    Test(ScaleSmoothTurnAxis(std::numeric_limits<float>::quiet_NaN(),1.f)==0.f,
        "invalid turn axis cannot rotate");
    SnapTurnInput turn;
    Test(turn.Update(1,true,30)==0,"held stick at entry cannot turn");
    turn.Update(0,true,30);
    Test(turn.Update(1,true,30)==5461,"neutral then right yields a 30 degree snap");
    Test(turn.Update(1,true,30)==0 && turn.Update(-1,true,30)==0,"hold or reversal needs neutral before another snap");
    turn.Update(0,true,30); turn.Update(0,false,30);
    Test(turn.Update(1,true,30)==0,"tracking loss cannot count as neutral");
    SessionMenuInput menu;
    Test(!menu.Update(true,true,true,true,true,0),"held menu and chord on entry cannot open");
    menu.Update(true,true,false,true,false,.01);
    Test(menu.Update(true,true,true,true,false,.02),"released then pressed menu opens once");
    Test(!menu.Update(true,true,true,true,false,.03),"holding menu cannot repeatedly toggle");
    menu.Update(false,false,false,false,false,.04);
    menu.Update(true,false,false,false,false,.05);
    Test(!menu.Update(true,true,true,true,true,.06),"inactive actions after focus loss do not arm held controls");
    menu.Update(true,true,false,true,false,.07);
    menu.Update(true,true,false,true,true,.10);
    menu.Update(true,true,false,true,true,.30);
    menu.Update(true,true,false,true,true,.50);
    Test(menu.Update(true,true,false,true,true,.71),"Index fallback opens after a deliberate bounded hold");
    Test(!menu.Update(true,true,false,true,true,.80),"fallback hold cannot close the menu again");
    xr::FrameState f; f.state=xr::SessionState::Focused;
    f.shouldRender=f.viewsValid=f.actionsSynced=f.headPoseValid=f.headPoseTracked=true;
    f.handLeft.aimPoseValid=f.handLeft.aimPoseTracked=f.handLeft.triggerActive=true;
    f.handRight.aimPoseValid=f.handRight.aimPoseTracked=f.handRight.triggerActive=true;
    SpatialMenu panel;
    panel.Update(f,true,1.f,0); panel.Update(f,true,1.f,0);
    f.handLeft.triggerAxis=1; panel.Update(f,true,1.f,0);
    Test(panel.Pointer().pressed,"left controller can select the panel");
    f.handRight.triggerAxis=1; panel.Update(f,true,1.f,1);
    Test(panel.Pointer().cancelled && !panel.Pointer().down,"changing pointer hand cancels capture and disarms held trigger");
}
}
int main() {
    xr::FrameState f;
    f.state=xr::SessionState::Focused; f.shouldRender=f.viewsValid=f.actionsSynced=true;
    f.headPoseValid=f.headPoseTracked=true;
    f.head.pos={0,1.6f,0};
    f.handRight.aimPoseValid=f.handRight.aimPoseTracked=f.handRight.triggerActive=true;
    f.handRight.aim.pos=f.head.pos;
    SpatialMenu m;
    Test(m.Update(f,true,16.f/9),"opens on coherent tracked frame");
    Test(Near(m.Panel().center.z,-1.5f) && Near(m.Panel().center.y,1.6f),"opens level 1.5m ahead");
    Test(m.Pointer().rayVisible && m.Pointer().hit && Near(m.Pointer().u,.5f) && Near(m.Pointer().v,.5f),"right aim ray hits menu centre");
    float u=0,v=0; Vec3 hit;
    Test(IntersectSpatialMenu(m.Panel(),{-.032f,1.6f,0},{0,0,-1},u,v,hit) && u<.5f,"left eye ray hits left of centre");
    Test(IntersectSpatialMenu(m.Panel(),{.032f,1.6f,0},{0,0,-1},u,v,hit) && u>.5f,"right eye ray hits right of centre");
    f.head.pos.x=.3f;
    m.Update(f,true,16.f/9);
    Test(Near(m.Panel().center.x,0),"panel stays anchored through head translation");
    f.head.rot=Quat::FromAxisAngle({0,1,0},.4f); m.Update(f,true,16.f/9);
    Test(Near(m.Panel().rotation.w,1),"panel stays anchored through head rotation");
    Test(!IntersectSpatialMenu(m.Panel(),{0,1.6f,-2},{0,0,1},u,v,hit),"back side rejected");
    Test(!IntersectSpatialMenu(m.Panel(),{0,1.6f,0},{1,0,0},u,v,hit),"parallel ray rejected");
    Test(!IntersectSpatialMenu(m.Panel(),{2,1.6f,0},{0,0,-1},u,v,hit),"out of bounds ray rejected");
    f.handRight.triggerAxis=.8f; m.Update(f,true,16.f/9);
    Test(m.Pointer().down && m.Pointer().pressed,"press after release arms");
    m.Update(f,true,16.f/9); Test(m.Pointer().down && !m.Pointer().pressed,"held trigger has one edge");
    f.handRight.triggerAxis=.3f; m.Update(f,true,16.f/9);
    Test(m.Pointer().down,"hysteresis prevents jitter release");
    f.handRight.triggerAxis=0; m.Update(f,true,16.f/9);
    Test(m.Pointer().released && !m.Pointer().cancelled,"valid release commits click");
    f.handRight.triggerAxis=.8f; m.Update(f,true,16.f/9);
    f.predictedDisplayTime+=.5; f.handRight.triggerAxis=0; m.Update(f,true,16.f/9);
    Test(m.Pointer().released && m.Pointer().cancelled,"hitch cannot commit an old press");
    m.Update(f,true,16.f/9);
    f.handRight.triggerAxis=.8f; m.Update(f,true,16.f/9);
    f.handRight.aimPoseValid=false; m.Update(f,true,16.f/9);
    Test(m.Pointer().released && m.Pointer().cancelled && !m.Pointer().hit,"tracking loss cancels click");
    f.handRight.aimPoseValid=true; m.Update(f,true,16.f/9);
    Test(!m.Pointer().down,"held trigger cannot rearm on tracking recovery");
    f.handRight.triggerAxis=0; m.Update(f,true,16.f/9);
    f.handRight.triggerAxis=.8f; m.Update(f,true,16.f/9);
    f.handRight.aim.pos.x=5; m.Update(f,true,16.f/9);
    Test(m.Pointer().released && m.Pointer().cancelled,"leaving panel cancels click");
    Test(m.Pointer().rayVisible && !m.Pointer().hit && Near((m.Pointer().rayEnd-m.Pointer().rayStart).Length(),3.f),
        "off-panel aim retains a bounded visible beam to find the menu");
    f.handRight.aim.pos.x=0; m.Update(f,true,16.f/9); Test(!m.Pointer().down,"reentering panel while held does not select");
    f.actionsSynced=false; m.Update(f,true,16.f/9); Test(!m.Pointer().hit && m.Panel().valid,"focus loss preserves panel without input");
    f.actionsSynced=true; f.head.rot={}; f.head.pos={1,2,3}; ++f.referenceSpaceEpoch;
    m.Update(f,true,16.f/9);
    Test(Near(m.Panel().center.x,1) && Near(m.Panel().center.z,1.5f),"recenter uses new tracking epoch");
    Test(!m.Pointer().down,"recenter disarms held trigger");
    const auto anchor=m.Panel().center;
    m.CancelInput(); f.head.pos.x+=.5f; m.Update(f,true,1.f);
    Test(Near(m.Panel().center.x,anchor.x) && Near(m.Panel().width,m.Panel().height),"resize keeps anchor and updates aspect");
    m.Update(f,false,16.f/9); Test(!m.Panel().valid,"close drops panel");
    f.head.pos={0,1.6f,0}; m.Update(f,true,16.f/9);
    Test(!m.Pointer().down,"opening menu while held does not click");
    f.handRight.triggerAxis=std::numeric_limits<float>::quiet_NaN(); m.Update(f,true,16.f/9);
    Test(m.Pointer().rayVisible && m.Pointer().hit && !m.Pointer().down,"NaN trigger cannot click but retains tracked aiming feedback");
    f.handRight.triggerAxis=0; f.handRight.triggerActive=false; m.Update(f,true,16.f/9);
    Test(m.Pointer().rayVisible && m.Pointer().hit && !m.Pointer().down,"inactive trigger does not erase the aim ray");
    f.handRight.triggerActive=true; f.handRight.triggerAxis=.8f; m.Update(f,true,16.f/9);
    Test(!m.Pointer().down,"inactive trigger was not mistaken for a release when the action recovers");
    Test(!m.Update(f,true,0),"invalid aspect rejected");
    // Scrolling shares menu focus/hit gates and must not burst after a hitch.
    m.Reset(); f.head.pos={0,1.6f,0}; f.handRight.aim.pos=f.head.pos;
    f.handRight.triggerAxis=0; f.handRight.stickActive=true; f.handRight.stickY=1;
    f.predictedDisplayTime=1; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==0,"held stick at menu entry does not scroll");
    f.handRight.stickY=0; f.predictedDisplayTime+=.01; m.Update(f,true,16.f/9);
    f.handRight.stickY=1; f.predictedDisplayTime+=.01; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==1,"neutral then up emits one wheel step");
    f.predictedDisplayTime+=.2; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==0,"scroll waits for initial repeat delay");
    f.predictedDisplayTime+=.16; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==1,"held stick repeats by elapsed time");
    f.predictedDisplayTime+=.01; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==0,"render frequency does not multiply wheel steps");
    f.predictedDisplayTime+=1; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==0,"long hitch disarms scrolling without catch-up burst");
    f.predictedDisplayTime+=.01; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==0,"held stick cannot resume after hitch without neutral");
    f.handRight.stickY=0; m.Update(f,true,16.f/9);
    f.handRight.stickY=-1; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==-1,"neutral then down reverses scrolling");
    f.handRight.triggerAxis=.8f; m.Update(f,true,16.f/9);
    Test(m.Pointer().scrollSteps==0 && m.Pointer().down,"dragging suppresses wheel movement");
    f.handRight.triggerAxis=0; f.handRight.stickY=0; m.Update(f,true,16.f/9);
    ++f.referenceSpaceEpoch; f.head.rot=Quat::FromAxisAngle({1,0,0},1.5707963f);
    f.handRight.stickY=1; m.Update(f,true,16.f/9);
    Test(!m.Panel().valid && m.Pointer().scrollSteps==0,"vertical recenter waits for a stable panel yaw");
    f.head.rot={}; m.Update(f,true,16.f/9);
    Test(m.Panel().valid && m.Pointer().scrollSteps==0,"held stick stays disarmed when recenter placement recovers");
    InputTests();
    DesktopCursorTests();
    MovieRecoveryTests();
    MenuRenderTests();
    ConfigureTests();
    SessionInputTests();
    CurvedPanelTests();
    std::printf("Spatial menu checks=%d failures=%d\n",checks,failures);
    return failures?1:0;
}
