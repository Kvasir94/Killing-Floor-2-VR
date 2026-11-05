#include "WeaponHaptics.h"
#include "kf2vr/xr/HapticPlayback.h"
#include <cmath>
#include <cstdio>
#include <limits>

using namespace kf2vr::adapter;
namespace {
int failures=0;
void Check(bool ok,const char* message) {
    if (!ok) { ++failures; std::printf("FAIL: %s\n",message); }
}
}
int main() {
    kf2vr::xr::HapticPlayback playback;
    Check(!playback.ShouldStop(1000,false),"an idle hand needs no stop request");
    playback.Applied(1000,.5f,.02f,true);
    Check(!playback.ShouldStop(1019,true),"a valid pulse is not cut short");
    Check(playback.ShouldStop(1021,true),"an expired pulse explicitly stops");
    Check(playback.ShouldStop(1001,false),"tracking loss stops a live pulse immediately");
    playback.Applied(1010,.5f,.03f,false);
    Check(playback.ShouldStop(1021,true),"a failed replacement retains the prior expiry");
    playback.Applied(1010,.5f,.03f,true);
    Check(!playback.ShouldStop(1039,true) && playback.ShouldStop(1041,true),
          "a successful repeated pulse owns its new bounded duration");
    playback.Stopped();
    Check(!playback.ShouldStop(2000,true),"a stopped pulse does not repeatedly stop");
    playback.Applied(2000,.5f,std::numeric_limits<float>::infinity(),true);
    Check(!playback.playing,"a nonfinite duration cannot create an indefinite pulse");
    playback.Applied(3000,.5f,.045f,true);
    Check(!playback.Allows(3008,.1f),"a spring cue cannot truncate a selector detent next frame");
    playback.Applied(3008,.1f,.3f,true);
    Check(playback.ShouldStop(3046,true),"discarded weak feedback never prolongs the stronger pulse");
    Check(playback.Allows(playback.until,.1f),"weak feedback resumes at the exact original deadline");
    Check(playback.Allows(3008,.5f) && playback.Allows(3008,.8f),
          "equal repeated shots and stronger impacts remain responsive");
    Check(playback.ShouldStop(3008,false),"priority never prevents tracking-loss cancellation");
    Check(!playback.Allows(3008,std::numeric_limits<float>::infinity()) && !playback.Allows(3008,0.f),
          "invalid replacement amplitudes are refused");
    const auto mp7=RecoilHapticsFor(50.f,false), pistol=RecoilHapticsFor(250.f,false);
    const auto shotgun=RecoilHapticsFor(900.f,false), m99=RecoilHapticsFor(1200.f,false);
    Check(mp7.primary.amplitude<pistol.primary.amplitude && pistol.primary.amplitude<shotgun.primary.amplitude &&
          shotgun.primary.amplitude<m99.primary.amplitude,"harder-kicking guns pulse harder");
    Check(mp7.primary.duration<m99.primary.duration,"harder-kicking guns pulse longer");
    Check(m99.primary.amplitude<=1.f && m99.primary.duration<=.1f,"the heaviest gun stays within the backend's limits");
    Check(mp7.primary.amplitude>=.2f,"the lightest gun is still felt");
    Check(RecoilHapticsFor(0.f,false).primary.amplitude==mp7.primary.amplitude,"a missing field reads as the lightest kick");
    Check(RecoilHapticsFor(1e6f,false).primary.amplitude==m99.primary.amplitude,"an implausible kick is capped");
    const auto nan=RecoilHapticsFor(std::nanf(""),false);
    Check(std::isfinite(nan.primary.amplitude) && nan.primary.amplitude>0,"a corrupt read still pulses");
    Check(pistol.support.amplitude==0,"no support pulse without a supporting hand");
    const auto braced=RecoilHapticsFor(250.f,true);
    Check(braced.support.amplitude>0 && braced.support.amplitude<braced.primary.amplitude,
          "the supporting hand feels a softer share of the shot");

    const auto contact=ResolveScriptHaptics(3,0,{},3,{.7f,.025f},{.35f,.015f});
    Check(contact[0].amplitude==.7f && contact[1].amplitude==.35f &&
          contact[0].duration==.025f && contact[1].duration==.015f,
          "simultaneous offhand and gun contact retain distinct strength and duration");
    const auto rightOnly=ResolveScriptHaptics(2,3,{.2f,.01f},3,{.7f,.025f},{.35f,.015f});
    Check(rightOnly[0].amplitude==0.f && rightOnly[0].duration==0.f &&
          rightOnly[1].amplitude==.35f && rightOnly[1].duration==.015f,
          "an invalid left hand drops both lanes without suppressing the tracked right hand");
    const auto legacy=ResolveScriptHaptics(3,3,{.6f,.04f},0,{1.f,.1f},{1.f,.1f});
    Check(legacy[0].amplitude==.6f && legacy[1].amplitude==.6f &&
          legacy[0].duration==.04f && legacy[1].duration==.04f,
          "untouched legacy producers retain their shared pulse and ignore unrequested hand values");
    const auto mixed=ResolveScriptHaptics(3,1,{.8f,.04f},3,{.7f,.06f},{.35f,.015f});
    Check(mixed[0].amplitude==.8f && mixed[0].duration==.06f &&
          mixed[1].amplitude==.35f && mixed[1].duration==.015f,
          "legacy merges only into its requested hand using the backend's strongest-longest rule");
    const auto leftOnly=ResolveScriptHaptics(3,0,{},1,{.7f,.025f},{1.f,.1f});
    Check(leftOnly[0].amplitude==.7f && leftOnly[1].amplitude==0.f && leftOnly[1].duration==0.f,
          "stale right values never create a request without the right-hand mask bit");
    const auto invalid=ResolveScriptHaptics(3,3,{std::nanf(""),.04f},3,
        {.7f,std::numeric_limits<float>::infinity()},{.35f,.015f});
    Check(invalid[0].amplitude==0.f && invalid[0].duration==0.f && invalid[1].amplitude==.35f,
          "nonfinite requests are dropped independently rather than contaminating the other hand");
    const auto goodLegacy=ResolveScriptHaptics(3,3,{.2f,.02f},3,{-1.f,.1f},{.7f,0.f});
    Check(goodLegacy[0].amplitude==.2f && goodLegacy[0].duration==.02f &&
          goodLegacy[1].amplitude==.2f && goodLegacy[1].duration==.02f,
          "invalid per-hand requests do not erase valid legacy feedback");
    const auto bounded=ResolveScriptHaptics(3,0,{},3,{2.f,10.f},{.4f,.001f});
    Check(bounded[0].amplitude==1.f && bounded[0].duration==.3f &&
          bounded[1].amplitude==.4f && bounded[1].duration==.005f,
          "new requests obey the existing backend amplitude and duration limits");
    const auto noTracking=ResolveScriptHaptics(0,3,{1.f,.1f},3,{1.f,.1f},{1.f,.1f});
    Check(noTracking[0].amplitude==0.f && noTracking[1].amplitude==0.f,
          "no tracking produces no queued haptics from either lane");
    if (failures==0) std::printf("weapon haptics: all checks passed\n");
    return failures==0?0:1;
}
