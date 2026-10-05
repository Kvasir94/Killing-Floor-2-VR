#include "FrameDrilldown.h"
#include <cmath>
#include <cstring>
#include <numeric>

using namespace kf2vr::adapter::timing;
int main() {
    enabled=true;drilldownEnabled=true;
    auto& state=Current();state=State{};
    FrameDrilldown capture;tmpfile_s(&capture.file);tmpfile_s(&capture.spans);
    if(!capture.file || !capture.spans) return 1;
    capture.Header();state.Advance();capture.Capture(state,2);
    const double start=state.last;
    {
        Scope world(WorldTick);Sleep(2);
        { Scope scene(LeftScene);Sleep(2); }
        Sleep(2);
    }
    state.Advance();
    const double total=std::accumulate(state.frameMilliseconds.begin(),state.frameMilliseconds.end(),0.0);
    if(std::abs(total-(state.last-start))>.001 || state.frameMilliseconds[WorldTick]<=0 || state.frameMilliseconds[LeftScene]<=0) return 2;
    // A five-second coarse-report reset must not lose per-frame attribution.
    state.milliseconds={};state.calls={};
    if(std::accumulate(state.frameMilliseconds.begin(),state.frameMilliseconds.end(),0.0)!=total) return 3;
    capture.Capture(state,2);
    if(state.spanCount || state.spanOverflow || capture.sequence!=1 || capture.failed) return 4;
    std::rewind(capture.file);char line[4096]{};
    if(!std::fgets(line,sizeof(line),capture.file) || !std::strstr(line,"diagnosticOutputMs")) return 5;
    if(!std::fgets(line,sizeof(line),capture.file)) return 6;
    state.spanCount=state.spans.size();state.Advance();if(!state.spanOverflow) return 7;
    drilldownEnabled=false;if(StageEnabled(WorldTick)) return 8;
    std::fclose(capture.file);std::fclose(capture.spans);
    std::puts("Frame accounting, nesting, coarse reset, bounded spans and capture passed");return 0;
}
