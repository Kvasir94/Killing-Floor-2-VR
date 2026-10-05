#pragma once
#include <array>
#include <chrono>
#include <cstdint>
#include <algorithm>
#include <cmath>

namespace kf2vr::adapter::timing {
enum Stage { Other, Controller, Simulation, ScriptDispatch, ScriptBody,
    LeftView, RightView, XrBegin, XrSubmit, DesktopPresent, PortalCapture, WorldScene, EyeCopy,
    ViewSetup, SceneSetup, ViewportSetup, WorldTick, LeftScene, RightScene, DiagnosticOutput, Count };
inline bool drilldownEnabled=false;
inline constexpr const char* StageNames[Count]={"otherMs","controllerMs","simulationMs","vmDispatchMs","vmBodyMs",
    "leftMs","rightMs","xrBeginMs","xrSubmitMs","presentMs","portalMs","worldMs","eyeCopyMs",
    "viewSetupMs","sceneSetupMs","viewportSetupMs","worldTickMs","leftSceneMs","rightSceneMs","diagnosticOutputMs"};
inline bool enabled=false; // Set once before hooks are enabled.
inline bool scriptEnabled=false; // Expensive per-VM-call tracing is a separate opt-in.
inline bool StageEnabled(Stage stage) {
    return enabled && (drilldownEnabled || stage<WorldTick) &&
        (scriptEnabled || (stage!=ScriptDispatch && stage!=ScriptBody));
}
// Bounded storage; percentile samples and overflow are reported explicitly.
// Present intervals are application pacing, not compositor/delivery statistics.
struct Intervals {
    std::array<double,4096> samples{};
    std::size_t count=0;
    std::uint64_t overflow=0,over90=0,over120=0;
    double total=0,maximum=0;
    void Add(double ms) {
        if (!std::isfinite(ms) || ms<0) return;
        total+=ms;maximum=std::max(maximum,ms);
        over90+=ms>1000.0/90;over120+=ms>1000.0/120;
        if(count<samples.size()) samples[count++]=ms; else ++overflow;
    }
    double Percentile(double fraction) {
        if(!count) return 0;
        std::sort(samples.begin(),samples.begin()+count);
        const auto rank=static_cast<std::size_t>(std::ceil(std::clamp(fraction,0.0,1.0)*count));
        return samples[rank ? rank-1 : 0];
    }
};
inline double Now() {
    return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
struct State {
    struct Span { double start,end;Stage stage; };
    Stage active=Other;
    double last=Now(),since=last;
    std::array<double,Count> milliseconds{};
    std::array<double,Count> frameMilliseconds{};
    std::array<Span,2048> spans{};
    std::size_t spanCount=0;
    std::uint64_t spanOverflow=0;
    std::array<std::uint64_t,Count> calls{};
    std::uint64_t presents=0;
    double previousPresent=0;
    Intervals intervals;
    void Advance() {
        const auto now=Now();const auto elapsed=now-last;
        milliseconds[active]+=elapsed;
        if(drilldownEnabled) {
            frameMilliseconds[active]+=elapsed;
            if(spanCount<spans.size()) spans[spanCount++]={last,now,active};else ++spanOverflow;
        }
        last=now;
    }
};
inline State& Current() { thread_local State state;return state; }
// Nested scopes subtract their time from the enclosing scope. In particular,
// script dispatch overhead is separated from the original VM body it calls.
class Scope {
    bool enabled_=false;
    Stage previous_=Other;
public:
    explicit Scope(Stage stage) {
        enabled_=StageEnabled(stage);
        if(!enabled_) return;
        auto& state=Current();state.Advance();previous_=state.active;
        state.active=stage;++state.calls[stage];
    }
    ~Scope() {
        if(!enabled_) return;
        auto& state=Current();state.Advance();state.active=previous_;
    }
};
}
