#pragma once
#include <cstdint>
#include <string_view>

namespace kf2vr::adapter {
// Linear percentage: 75 means 56.25% of the scene pixels. XR output/FOV stay
// runtime recommended; AtlasBlit resamples the completed scene to that output.
inline bool ParseEyeRenderPercent(std::wstring_view text, unsigned& percent) {
    if(text.empty() || text.size()>3) return false;
    unsigned value=0;
    for(auto ch:text) {
        if(ch<L'0' || ch>L'9') return false;
        value=value*10+static_cast<unsigned>(ch-L'0');
    }
    if(value<50 || value>100) return false;
    percent=value;return true;
}
inline unsigned ScaledEyeExtent(unsigned recommended,unsigned percent) {
    if(!recommended || percent<50 || percent>100) return 0;
    return static_cast<unsigned>((static_cast<std::uint64_t>(recommended)*percent+50)/100);
}
}
