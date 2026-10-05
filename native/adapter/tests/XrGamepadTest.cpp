#include "XrGamepad.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <thread>
using namespace kf2vr;
int checks=0, failures=0;
void Test(bool condition,const char* label) { ++checks; if(!condition) { ++failures; std::printf("FAIL %s\n",label); } }
int main() {
    // Independent hands own every weapon action on both the standalone and the
    // network client. What reaches stock input is exactly what PumpNativeInput
    // leaves after RemoveScriptWeaponActions and its face/stick-click mask.
    XINPUT_GAMEPAD rawPad{};
    rawPad.wButtons=XINPUT_GAMEPAD_RIGHT_THUMB|XINPUT_GAMEPAD_LEFT_THUMB|XINPUT_GAMEPAD_A|
        XINPUT_GAMEPAD_B|XINPUT_GAMEPAD_X|XINPUT_GAMEPAD_Y|XINPUT_GAMEPAD_RIGHT_SHOULDER|
        XINPUT_GAMEPAD_LEFT_SHOULDER|XINPUT_GAMEPAD_START;
    rawPad.bLeftTrigger=rawPad.bRightTrigger=255;
    rawPad.sThumbLX=1234; rawPad.sThumbLY=30000;
    rawPad.sThumbRX=-21000; rawPad.sThumbRY=8000;
    auto scriptOwned=rawPad;
    adapter::RemoveScriptWeaponActions(scriptOwned);
    scriptOwned.wButtons &= ~(XINPUT_GAMEPAD_B|XINPUT_GAMEPAD_A|XINPUT_GAMEPAD_LEFT_THUMB|XINPUT_GAMEPAD_RIGHT_THUMB);
    Test(scriptOwned.bLeftTrigger==0 && scriptOwned.bRightTrigger==0,
        "script-owned hands never leak a stock trigger");
    Test(scriptOwned.wButtons==XINPUT_GAMEPAD_START,
        "script-owned hands leave only the session menu button to stock input");
    Test(scriptOwned.sThumbLX==1234 && scriptOwned.sThumbLY==30000 && scriptOwned.sThumbRX==-21000,
        "suppression touches no axis; script locomotion overwrites them afterwards");
    xr::FrameState neutral;
    neutral.state=xr::SessionState::Focused;
    neutral.actionsSynced=neutral.headPoseValid=neutral.viewsValid=true;
    auto activate=[](auto& h) {
        h.poseValid=h.poseTracked=true;
        h.triggerActive=h.gripActive=h.stickActive=h.primaryActive=h.secondaryActive=h.stickClickActive=h.menuActive=true;
    };
    activate(neutral.handLeft); activate(neutral.handRight);
    adapter::XrGamepad pad(20);
    double time=0;
    auto submit=[&](const auto& frame) { pad.SetFrame(frame,time+=.01); XINPUT_STATE state{}; Test(pad.GetState(0,&state)==ERROR_SUCCESS,"index0 returns success"); return state; };
    XINPUT_STATE state{};
    Test(pad.GetState(0,&state)==ERROR_SUCCESS && state.Gamepad.wButtons==0 && state.Gamepad.bRightTrigger==0,"initial connected neutral");
    Test(pad.GetState(1,&state)==ERROR_DEVICE_NOT_CONNECTED,"other pad index remains for forwarding");
    Test(pad.GetState(0,nullptr)==ERROR_BAD_ARGUMENTS,"null state pointer rejected");
    XINPUT_CAPABILITIES caps{};
    Test(pad.GetCapabilities(0,XINPUT_FLAG_GAMEPAD,&caps)==ERROR_SUCCESS && caps.Type==XINPUT_DEVTYPE_GAMEPAD && caps.SubType==XINPUT_DEVSUBTYPE_GAMEPAD,"virtual gamepad capabilities");
    Test(caps.Gamepad.sThumbRY==0 && caps.Vibration.wLeftMotorSpeed==0 && caps.Vibration.wRightMotorSpeed==0,"unimplemented pitch/rumble not advertised");
    Test(caps.Gamepad.bLeftTrigger==0 && caps.Gamepad.bRightTrigger==255,"interaction never advertises an ironsights trigger axis");
    Test(pad.GetCapabilities(0,2,&caps)==ERROR_BAD_ARGUMENTS,"unsupported capabilities flags rejected");
    auto held=neutral; held.handRight.triggerAxis=1;
    Test(submit(held).Gamepad.bRightTrigger==0,"initially held trigger suppressed");
    submit(neutral);
    state=submit(held); Test(state.Gamepad.bRightTrigger==255,"fresh trigger press forwarded");
    const auto packet=state.dwPacketNumber;
    Test(submit(held).dwPacketNumber==packet,"unchanged XInput state preserves packet number");
    auto unavailable=held; unavailable.handRight.triggerActive=false;
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"inactive action releases trigger");
    Test(submit(held).Gamepad.bRightTrigger==0,"reactivated held action remains suppressed");
    submit(neutral); Test(submit(held).Gamepad.bRightTrigger==255,"physical release rearms inactive trigger");
    unavailable=held; unavailable.actionsSynced=false;
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"unsynced actions override cached focused state");
    Test(submit(held).Gamepad.bRightTrigger==0,"held trigger suppressed after action sync returns");
    submit(neutral); submit(held);
    unavailable=held; unavailable.state=xr::SessionState::Visible;
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"dashboard focus loss releases");
    Test(submit(held).Gamepad.bRightTrigger==0,"dashboard return does not fire held trigger");
    submit(neutral); submit(held);
    unavailable=held; unavailable.handRight.poseValid=false; unavailable.handRight.triggerAxis=0;
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"tracking loss neutralizes controller");
    Test(submit(held).Gamepad.bRightTrigger==0,"zero during tracking loss is not a real release");
    submit(neutral); submit(held);
    unavailable=held; unavailable.headPoseValid=false;
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"head tracking loss neutralizes gamepad");
    submit(neutral); submit(held);
    unavailable=held; unavailable.viewsValid=false;
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"invalid stereo tracking neutralizes gamepad");
    submit(neutral);
    auto moving=neutral; moving.handLeft.stickX=-1; moving.handLeft.stickY=1; moving.handRight.stickX=.8f; moving.handRight.stickY=.7f;
    state=submit(moving);
    Test(state.Gamepad.sThumbLX<0 && state.Gamepad.sThumbLY>0,"left stick strafe and forward preserve signs");
    Test(std::abs(int(state.Gamepad.sThumbLX)+23170)<2 && std::abs(int(state.Gamepad.sThumbLY)-23170)<2,"diagonal magnitude bounded");
    Test(state.Gamepad.sThumbRX>20000 && state.Gamepad.sThumbRY==0,"right stick turns yaw and never introduces pitch");
    pad.Cancel(); Test(submit(moving).Gamepad.sThumbLX==0 && submit(moving).Gamepad.sThumbRX==0,"movement requires recenter after cancel");
    submit(neutral); Test(submit(moving).Gamepad.sThumbLX<0,"centered stick rearms movement");
    auto turning=neutral; turning.handRight.stickX=.12f;
    submit(neutral); Test(submit(turning).Gamepad.sThumbRX==0,"turn deadzone edge stays still");
    turning.handRight.stickX=.13f; Test(std::abs(int(submit(turning).Gamepad.sThumbRX)-372)<3,"turn ramps from zero past deadzone");
    turning.handRight.stickX=-.56f; Test(std::abs(int(submit(turning).Gamepad.sThumbRX)+16384)<3,"turn deadzone rescales linearly");
    turning.handRight.stickX=1; Test(submit(turning).Gamepad.sThumbRX==32767,"full turn deflection preserved");
    turning.handRight.stickX=.1f; turning.handRight.stickY=.9f; Test(submit(turning).Gamepad.sThumbRX==0,"vertical push adds no turn");
    auto checkButton=[&](auto mutate,WORD expected,const char* label) {
        submit(neutral); auto frame=neutral; mutate(frame); Test(submit(frame).Gamepad.wButtons==expected,label);
    };
    checkButton([](auto& f){f.handLeft.primaryPressed=true;},XINPUT_GAMEPAD_X,"left primary = reload X");
    checkButton([](auto& f){f.handLeft.secondaryPressed=true;},XINPUT_GAMEPAD_Y,"left secondary = weapon Y");
    checkButton([](auto& f){f.handRight.primaryPressed=true;},XINPUT_GAMEPAD_X,"physical A = reload only, never jump");
    checkButton([](auto& f){f.handRight.secondaryPressed=true;},XINPUT_GAMEPAD_A,"physical B = jump only, never use");
    checkButton([](auto& f){f.handLeft.stickPressed=true;},XINPUT_GAMEPAD_LEFT_THUMB,"left stick click = sprint/crouch");
    checkButton([](auto& f){f.handRight.stickPressed=true;},XINPUT_GAMEPAD_RIGHT_THUMB,"right stick click = bash");
    checkButton([](auto& f){f.handLeft.menuPressed=true;},XINPUT_GAMEPAD_START,"left menu = start");
    checkButton([](auto& f){f.handRight.menuPressed=true;},XINPUT_GAMEPAD_START,"right menu = start");
    checkButton([](auto& f){f.handLeft.gripAxis=1;},XINPUT_GAMEPAD_LEFT_SHOULDER,"left grip = grenade");
    checkButton([](auto& f){f.handRight.gripAxis=1;},XINPUT_GAMEPAD_RIGHT_SHOULDER,"right grip = alt fire");
    auto grip=neutral; grip.handRight.gripAxis=.6f;
    Test((submit(grip).Gamepad.wButtons&XINPUT_GAMEPAD_RIGHT_SHOULDER)!=0,"squeeze hysteresis holds across .75 threshold jitter");
    grip.handRight.gripAxis=.2f;
    Test((submit(grip).Gamepad.wButtons&XINPUT_GAMEPAD_RIGHT_SHOULDER)==0,"squeeze releases below lower threshold");
    grip.handRight.gripAxis=.6f;
    Test((submit(grip).Gamepad.wButtons&XINPUT_GAMEPAD_RIGHT_SHOULDER)==0,"squeeze does not press until high threshold");

    // Left trigger uses stock pad B, with no analog sights axis. Hysteresis
    // and release-to-rearm must hold across jitter, inactive actions and focus.
    submit(neutral);
    auto interact=neutral; interact.handLeft.triggerAxis=.54f;
    state=submit(interact);
    Test(state.Gamepad.wButtons==0 && state.Gamepad.bLeftTrigger==0,"partial left trigger neither interacts nor aims");
    interact.handLeft.triggerAxis=.56f;
    state=submit(interact);
    Test(state.Gamepad.wButtons==XINPUT_GAMEPAD_B && state.Gamepad.bLeftTrigger==0,"left trigger interacts without ironsights");
    interact.handLeft.triggerAxis=.4f;
    Test(submit(interact).Gamepad.wButtons==XINPUT_GAMEPAD_B,"interaction stays pressed through threshold jitter");
    interact.handLeft.triggerAxis=.08f;
    Test(submit(interact).Gamepad.wButtons==0,"physical trigger release ends interaction");
    interact.handLeft.triggerAxis=1;
    submit(interact);
    unavailable=interact; unavailable.handLeft.triggerActive=false;
    Test(submit(unavailable).Gamepad.wButtons==0,"inactive left trigger releases interaction");
    Test(submit(interact).Gamepad.wButtons==0,"active held left trigger cannot resume interaction");
    submit(neutral); submit(interact);
    unavailable=interact; unavailable.state=xr::SessionState::Visible;
    Test(submit(unavailable).Gamepad.wButtons==0,"focus loss releases interaction");
    Test(submit(interact).Gamepad.wButtons==0,"focus return requires physical interact release");
    submit(neutral);
    Test(submit(interact).Gamepad.wButtons==XINPUT_GAMEPAD_B,"released left trigger rearms interaction");

    // A and X have independent physical gates despite sharing stock reload.
    auto rightReload=neutral; rightReload.handRight.primaryPressed=true;
    pad.Cancel();
    Test(submit(rightReload).Gamepad.wButtons==0,"held A cannot reload after cancel");
    auto bothReload=rightReload; bothReload.handLeft.primaryPressed=true;
    Test(submit(bothReload).Gamepad.wButtons==XINPUT_GAMEPAD_X,"released X can reload while A remains suppressed");
    Test(submit(rightReload).Gamepad.wButtons==0,"X release does not rearm held A");
    submit(neutral);
    Test(submit(rightReload).Gamepad.wButtons==XINPUT_GAMEPAD_X,"A independently rearms after physical release");

    // Script ingress retains physical identity, validates each source hand,
    // and preserves the existing flashlight-only right-grip + X chord.
    auto scriptFrame=neutral;
    scriptFrame.handLeft.primaryPressed=scriptFrame.handRight.primaryPressed=true;
    auto buttons=adapter::MapHandWeaponButtons(scriptFrame,3);
    Test(buttons.pressedMask==9 && (buttons.activeMask&9)==9,"script X/A reload retain separate ingress bits1/8");
    scriptFrame.handRight.gripAxis=1;
    buttons=adapter::MapHandWeaponButtons(scriptFrame,3);
    Test(buttons.pressedMask==12,"flashlight chord consumes X only; A still reloads");
    scriptFrame.handLeft.secondaryPressed=true;
    scriptFrame.handRight.secondaryPressed=true;
    buttons=adapter::MapHandWeaponButtons(scriptFrame,3);
    Test(buttons.pressedMask==14,"Y cycles; B stays off script weapon path");
    buttons=adapter::MapHandWeaponButtons(scriptFrame,2);
    Test(buttons.activeMask==8 && buttons.pressedMask==8,"left tracking loss disables both X and its flashlight chord");
    buttons=adapter::MapHandWeaponButtons(scriptFrame,0);
    Test(buttons.activeMask==0 && buttons.pressedMask==0,"invalid hand poses never count as released script actions");
    scriptFrame.handRight.primaryActive=false;
    buttons=adapter::MapHandWeaponButtons(scriptFrame,3);
    Test((buttons.activeMask&8)==0 && (buttons.pressedMask&8)==0,"inactive physical A cannot reload in script");

    submit(neutral);
    auto allActions=neutral;
    allActions.handLeft.primaryPressed=allActions.handRight.primaryPressed=true;
    allActions.handLeft.secondaryPressed=allActions.handRight.secondaryPressed=true;
    allActions.handLeft.triggerAxis=allActions.handRight.triggerAxis=1;
    allActions.handLeft.gripAxis=allActions.handRight.gripAxis=1;
    allActions.handLeft.stickX=1; allActions.handRight.stickPressed=true;
    state=submit(allActions);
    adapter::RemoveScriptWeaponActions(state.Gamepad);
    Test(state.Gamepad.wButtons==(XINPUT_GAMEPAD_A|XINPUT_GAMEPAD_B|XINPUT_GAMEPAD_RIGHT_THUMB)
        && state.Gamepad.bLeftTrigger==0 && state.Gamepad.bRightTrigger==0,
        "script ownership removes duplicate weapon actions while preserving jump/use/bash");
    Test(state.Gamepad.sThumbLX==32767,"script weapon ownership preserves locomotion");
    submit(neutral); submit(held);
    unavailable=held; unavailable.handRight.triggerAxis=std::numeric_limits<float>::quiet_NaN();
    Test(submit(unavailable).Gamepad.bRightTrigger==0,"NaN trigger cancels safely");
    Test(submit(held).Gamepad.bRightTrigger==0,"invalid trigger sample cannot rearm held control");
    submit(neutral); submit(held);
    pad.SetFrame(held,std::numeric_limits<double>::quiet_NaN()); pad.GetState(0,&state);
    Test(state.Gamepad.bRightTrigger==0,"invalid timestamp cancels safely");
    submit(neutral); submit(held);
    std::this_thread::sleep_for(std::chrono::milliseconds(35));
    pad.GetState(0,&state);
    Test(state.Gamepad.bRightTrigger==0,"stale frame watchdog releases in game callback");
    Test(submit(held).Gamepad.bRightTrigger==0,"freshness recovery requires physical trigger release");
    submit(neutral); submit(held); pad.Cancel(); pad.GetState(0,&state);
    Test(state.Gamepad.bRightTrigger==0 && state.Gamepad.wButtons==0,"explicit shutdown/cancel returns connected neutral");
    // Publish a compound state concurrently. The reader must never observe a
    // mixture of the two snapshots; no XR runtime or physical XInput is called.
    adapter::XrGamepad concurrent(1000);
    concurrent.SetFrame(neutral,0);
    auto compound=neutral; compound.handRight.triggerAxis=1; compound.handRight.primaryPressed=true; compound.handLeft.stickX=1;
    std::atomic<bool> stop=false,bad=false;
    std::thread reader([&] {
        while(!stop.load()) {
            XINPUT_STATE value{}; concurrent.GetState(0,&value);
            const bool empty=value.Gamepad.bRightTrigger==0 && value.Gamepad.wButtons==0 && value.Gamepad.sThumbLX==0;
            const bool full=value.Gamepad.bRightTrigger==255 && value.Gamepad.wButtons==XINPUT_GAMEPAD_X && value.Gamepad.sThumbLX==32767;
            if(!empty&&!full) bad=true;
        }
    });
    for(unsigned i=1;i<=20000;++i) concurrent.SetFrame(i%2?compound:neutral,double(i));
    stop=true; reader.join();
    Test(!bad.load(),"SRW-protected concurrent snapshots remain coherent");
    std::printf("XrGamepad checks=%d failures=%d; no hooks/runtime/physical controller calls\n",checks,failures);
    return failures?1:0;
}
