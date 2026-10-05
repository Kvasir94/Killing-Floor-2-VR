#pragma once
#include "FrameTiming.h"
#include <cstdio>
#include <windows.h>

namespace kf2vr::adapter::timing {
// Buffered, bounded-duration diagnostic capture. No GPU flush or query wait.
// Snapshot differences align to consecutive owner-thread Present completions.
struct FrameDrilldown {
    FILE* file=nullptr;
    FILE* spans=nullptr;
    double previous=0;
    unsigned long long previousCpu=0,sequence=0;
    int previousPhase=0;
    bool previousCpuValid=false,failed=false;
    static bool ThreadCpu(unsigned long long& value) {
        FILETIME created{},exited{},kernel{},user{};
        if(!GetThreadTimes(GetCurrentThread(),&created,&exited,&kernel,&user)) return false;
        value=(static_cast<unsigned long long>(kernel.dwHighDateTime)<<32)+kernel.dwLowDateTime+
              (static_cast<unsigned long long>(user.dwHighDateTime)<<32)+user.dwLowDateTime;
        return true;
    }
    void Header() {
        std::fputs("tickMs,frame,threadId,phase,phaseStable,intervalMs,threadCpuMs,cpuCounterValid,spanOverflow",file);
        for(auto name:StageNames) std::fprintf(file,",%s",name);
        std::fputc('\n',file);
        std::fputs("startMs,endMs,frame,stage\n",spans);
    }
    void Capture(State& state,int phase) {
        unsigned long long cpu=0;const bool cpuValid=ThreadCpu(cpu);
        if(previous && !failed) {
            std::fprintf(file,"%.6f,%llu,%lu,%d,%d,%.6f,%.6f,%d,%llu",state.last,++sequence,GetCurrentThreadId(),
                phase,phase==previousPhase,state.last-previous,
                cpuValid && previousCpuValid ? (cpu-previousCpu)/10000.0 : 0.0,cpuValid && previousCpuValid,state.spanOverflow);
            for(auto value:state.frameMilliseconds) std::fprintf(file,",%.6f",value);
            std::fputc('\n',file);
            for(std::size_t i=0;i<state.spanCount;++i) {
                const auto& span=state.spans[i];
                std::fprintf(spans,"%.6f,%.6f,%llu,%s\n",span.start,span.end,sequence,StageNames[span.stage]);
            }
        }
        if(phase!=previousPhase) { std::fflush(file);std::fflush(spans); }
        failed=failed || std::ferror(file)!=0 || std::ferror(spans)!=0;
        state.frameMilliseconds={};previous=state.last;previousPhase=phase;
        state.spanCount=0;state.spanOverflow=0;
        previousCpu=cpu;previousCpuValid=cpuValid;
    }
};
}
