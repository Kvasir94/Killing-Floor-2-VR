#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace kf2vr::xr {
// The runtime receives a finite pulse, but also explicitly stop it at expiry.
// A failed replacement must not forget the pulse that may still be playing.
struct HapticPlayback {
    bool playing = false;
    std::uint64_t until = 0;
    float amplitude = 0;

    // OpenXR replaces the current vibration on every apply call. Background
    // contact/spring cues must not truncate a stronger event on the next frame.
    // Dropping a weaker request does not extend the event's original deadline.
    bool Allows(std::uint64_t now, float strength) const {
        return std::isfinite(strength) && strength > 0
            && (!playing || now >= until || strength >= amplitude);
    }
    void Applied(std::uint64_t now, float strength, float seconds, bool succeeded) {
        if (!succeeded || !Allows(now, strength) || !std::isfinite(seconds) || seconds <= 0) return;
        playing = true;
        amplitude = std::clamp(strength, 0.f, 1.f);
        until = now + static_cast<std::uint64_t>(std::ceil(std::clamp(seconds, .005f, .3f) * 1000.0));
    }
    bool ShouldStop(std::uint64_t now, bool tracked) const {
        return playing && (!tracked || now >= until);
    }
    void Stopped() { playing = false; until = 0; amplitude = 0; }
};
}
