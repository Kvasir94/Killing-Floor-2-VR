#pragma once
#include <algorithm>
#include <array>
#include <cmath>

namespace kf2vr::adapter {

struct HapticPulse { float amplitude=0, duration=0; };
struct RecoilHaptics { HapticPulse primary, support; };

// Match OpenXrD3D11Backend::QueueHaptic: invalid requests are discarded;
// positive pulses are bounded before the legacy and per-hand lanes merge.
inline HapticPulse BoundedHaptic(HapticPulse pulse) {
    if (!std::isfinite(pulse.amplitude) || !std::isfinite(pulse.duration) ||
        pulse.amplitude<=0.f || pulse.duration<=0.f) return {};
    return {std::clamp(pulse.amplitude,0.f,1.f),std::clamp(pulse.duration,.005f,.3f)};
}

// Existing producers keep their shared pulse/mask. New producers can supply
// distinct left/right contact feedback without the stronger hand overwriting
// the other. Merge only requested, tracked hands, exactly as separate backend
// calls would merge pulses queued during the same frame.
inline std::array<HapticPulse,2> ResolveScriptHaptics(int validMask,
    int legacyMask,HapticPulse legacy,int handMask,HapticPulse left,HapticPulse right) {
    std::array<HapticPulse,2> out{};
    const std::array<HapticPulse,2> hands{left,right};
    legacy=BoundedHaptic(legacy);
    for (unsigned hand=0;hand<out.size();++hand) {
        const int bit=1<<hand;
        if (!(validMask&bit)) continue;
        if (legacyMask&bit) out[hand]=legacy;
        if (handMask&bit) {
            const auto pulse=BoundedHaptic(hands[hand]);
            out[hand].amplitude=std::max(out[hand].amplitude,pulse.amplitude);
            out[hand].duration=std::max(out[hand].duration,pulse.duration);
        }
    }
    return out;
}

// Shot feedback follows each gun's stock kick rather than one pulse for all.
// Stock maxRecoilPitch spans roughly 50 (MP7) to 1200 (M99); a log scale keeps
// the 9mm, AR-15 and Minigun distinguishable from a shotgun or an anti-materiel
// rifle. A bracing/supporting hand feels a softer share of the same shot.
inline RecoilHaptics RecoilHapticsFor(float maxRecoilPitch, bool supported) {
    constexpr float Light=50.f, Heavy=1200.f;
    const float pitch=std::isfinite(maxRecoilPitch) ? std::clamp(maxRecoilPitch,Light,Heavy) : 250.f;
    const float t=std::log(pitch/Light)/std::log(Heavy/Light);
    RecoilHaptics out;
    out.primary={.22f+.78f*t,.02f+.07f*t};
    if (supported) out.support={out.primary.amplitude*.6f,out.primary.duration*.8f};
    return out;
}

}
