#pragma once
#include "FrameTiming.h"

namespace kf2vr::adapter::timing {
inline bool vmSamplingEnabled=false;
struct VmSampleScope;
struct VmSampleState {
    std::uint64_t calls=0,samples=0;
    double dispatchMs=0,bodyMs=0;
    std::uint32_t random=0x6d2b79f5;
    VmSampleScope* current=nullptr;
    bool Select() {
        random^=random<<13;random^=random>>17;random^=random<<5;
        return (random&255)==0; // Randomized 1/256 avoids periodic callback aliasing.
    }
    void ResetTotals() { calls=0;samples=0;dispatchMs=0;bodyMs=0; }
};
inline VmSampleState& VmSamples() { thread_local VmSampleState state;return state; }
struct VmSampleScope {
    bool enabled=vmSamplingEnabled,sampled=false;
    VmSampleScope* previous=nullptr;
    double start=0,body=0;
    VmSampleScope() {
        if (!enabled) return;
        auto& state=VmSamples();previous=state.current;state.current=this;++state.calls;
        sampled=state.Select();
        if(sampled) start=Now();
    }
    ~VmSampleScope() {
        if(!enabled) return;
        auto& state=VmSamples();
        if(sampled) { ++state.samples;state.dispatchMs+=std::max(0.0,Now()-start-body);state.bodyMs+=body; }
        state.current=previous;
    }
};
// Only the original ProcessInternal body is excluded. Recursive callbacks own
// their own scopes, so their body time cannot be subtracted twice from a parent.
struct VmBodySample {
    VmSampleScope* owner=nullptr;
    double start=0;
    VmBodySample() {
        if(vmSamplingEnabled) { owner=VmSamples().current;if(owner && owner->sampled) start=Now();else owner=nullptr; }
    }
    ~VmBodySample() { if(owner) owner->body+=Now()-start; }
};
}
