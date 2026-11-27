#pragma once
#include <cstdint>

namespace kf2vr::adapter {
// KF2's screen-space skin scattering pass (KFGame.exe 0x306ed0; see
// docs/re/10-skin-scattering-pass.md) loops over the scene's views, but each
// run blurs the whole scene buffer: binding its targets resets the viewport
// the loop had set. With a single-pass pair every flagged pixel in both eyes
// was therefore blurred twice. Its kernel step is also a fraction of the
// buffer (SSSParams.x / depth in buffer UV), so in a buffer two eyes wide the
// sideways reach in each eye doubled.
//
// For a pair the adapter runs the pass once and scales the step to the eye:
// the pass uploads its parameters twice per run, for the horizontal pass and
// then the vertical one, and each upload takes the eye's share of the buffer
// along that axis.
class SkinScattering {
    float scale_[2]{1.0f,1.0f};
    unsigned uploads_=0;
    bool active_=false;
public:
    // Rectangles are x, y, width, height in buffer pixels. Only an equal-sized
    // pair inside the buffer is taken over; anything else stays stock.
    bool Begin(const std::int32_t rects[2][4],std::int32_t count,std::int32_t bufferX,std::int32_t bufferY) noexcept {
        active_=false; uploads_=0; scale_[0]=scale_[1]=1.0f;
        if (!rects || count!=2 || bufferX<1 || bufferY<1 || bufferX>16384 || bufferY>16384) return false;
        for (int i=0;i<2;++i) {
            const auto* r=rects[i];
            if (r[0]<0 || r[1]<0 || r[2]<1 || r[3]<1 || r[2]>bufferX-r[0] || r[3]>bufferY-r[1]) return false;
        }
        if (rects[0][2]!=rects[1][2] || rects[0][3]!=rects[1][3]) return false;
        scale_[0]=static_cast<float>(rects[0][2])/static_cast<float>(bufferX);
        scale_[1]=static_cast<float>(rects[0][3])/static_cast<float>(bufferY);
        active_=true;
        return true;
    }
    void End() noexcept { active_=false; }
    bool Active() const noexcept { return active_; }
    // The scale for the next parameter upload: horizontal, vertical, ...
    float Next() noexcept { return scale_[uploads_++ & 1u]; }
    unsigned Uploads() const noexcept { return uploads_; }
    // SSSParams as the game computes them (x = M[0][0] / 3 / 2, y = M[0][0]),
    // with the step scaled to the eye. The depth falloff (y) is unchanged.
    static void Parameters(float projection00,float scale,float out[2]) noexcept {
        out[0]=projection00*(1.0f/3.0f)*0.5f*scale;
        out[1]=projection00;
    }
};
} // namespace kf2vr::adapter
