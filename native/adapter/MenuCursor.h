#pragma once
#include "MenuNativeLayout.h"
#include <cstdint>
#include <limits>

namespace kf2vr::adapter {
// The desktop mirrors the entire render buffer into its client rectangle.
// Preserve outside points so releasing outside never hits a boundary widget.
inline bool MapDesktopMenuPoint(menu_native::Point source,int clientWidth,int clientHeight,
    int renderWidth,int renderHeight,menu_native::Point& result) noexcept {
    const auto extent=[](int n) { return n>0 && n<=16384; };
    if (!extent(clientWidth) || !extent(clientHeight) ||
        !extent(renderWidth) || !extent(renderHeight)) return false;
    const auto scale=[](int value,int from,int to) {
        const std::int64_t product=std::int64_t(value)*to;
        return product>=0 ? product/from : -((-product+from-1)/from);
    };
    const auto x=scale(source.x,clientWidth,renderWidth);
    const auto y=scale(source.y,clientHeight,renderHeight);
    if (x<std::numeric_limits<std::int32_t>::min() || x>std::numeric_limits<std::int32_t>::max() ||
        y<std::numeric_limits<std::int32_t>::min() || y>std::numeric_limits<std::int32_t>::max()) return false;
    result={static_cast<std::int32_t>(x),static_cast<std::int32_t>(y)};
    return true;
}

// Each synchronous synthetic event sees its XR point, including mouse-up and
// wheel events that read only GFx's cache. Desktop events retain their cache.
class ScopedMenuCursor {
public:
    ScopedMenuCursor(bool& active,menu_native::Point& cache,menu_native::Point point) noexcept
        : active_(active),cache_(cache),wasActive_(active),saved_(cache) {
        active_=true; cache_=point;
    }
    ~ScopedMenuCursor() { cache_=saved_; active_=wasActive_; }
    ScopedMenuCursor(const ScopedMenuCursor&)=delete;
    ScopedMenuCursor& operator=(const ScopedMenuCursor&)=delete;
private:
    bool& active_;
    menu_native::Point& cache_;
    bool wasActive_;
    menu_native::Point saved_;
};
}
