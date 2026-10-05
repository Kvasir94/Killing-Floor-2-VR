#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace kf2vr::adapter {

// The headset image shown while KF2 loads: startup, every map travel and the
// wait for a network handshake. UE3 presents its loading movie on a temporary
// thread and draws nothing the XR layer can use, so this plate is baked once
// into a static OpenXR quad and submitted without any D3D work.
//
// Pure pixel generation in KF2's menu palette (near-black maroon, a dim red
// horizon glow, faint scanlines, a red rule) with the word LOADING in a
// blocky 5x7 face. Output is display-encoded sRGB RGBA8, row-major.
struct LoadingPlateImage {
    std::uint32_t width=0,height=0;
    std::vector<std::uint8_t> rgba;
};

namespace loading_plate_detail {
// 5x7 glyphs, one byte per row, bit 4 is the left column.
struct Glyph { char c; std::uint8_t rows[7]; };
inline constexpr Glyph kGlyphs[]={
    {'L',{0x10,0x10,0x10,0x10,0x10,0x10,0x1F}},
    {'O',{0x0E,0x11,0x11,0x11,0x11,0x11,0x0E}},
    {'A',{0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}},
    {'D',{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E}},
    {'I',{0x1F,0x04,0x04,0x04,0x04,0x04,0x1F}},
    {'N',{0x11,0x19,0x15,0x13,0x11,0x11,0x11}},
    {'G',{0x0F,0x10,0x10,0x17,0x11,0x11,0x0F}},
};
inline const Glyph* FindGlyph(char c) {
    for (const auto& g : kGlyphs) if (g.c==c) return &g;
    return nullptr;
}
inline std::uint8_t ToByte(float v) {
    return static_cast<std::uint8_t>(std::clamp(v,0.f,1.f)*255.f+.5f);
}
} // namespace loading_plate_detail

inline LoadingPlateImage GenerateLoadingPlate(std::uint32_t width=1024,std::uint32_t height=512) {
    using namespace loading_plate_detail;
    LoadingPlateImage image;
    if (width<64 || height<32) return image;
    image.width=width; image.height=height;
    image.rgba.assign(static_cast<std::size_t>(width)*height*4,0);
    const float cx=width*.5f, cy=height*.5f;
    const float radius=std::sqrt(cx*cx+cy*cy);
    for (std::uint32_t y=0;y<height;++y) {
        for (std::uint32_t x=0;x<width;++x) {
            const float dx=(x+.5f-cx)/radius, dy=(y+.5f-cy)/radius;
            const float vignette=std::clamp(1.f-std::sqrt(dx*dx+dy*dy)*1.15f,0.f,1.f);
            // Maroon base, darker toward the edges.
            float r=.03f+.10f*vignette, g=.008f+.022f*vignette, b=.010f+.028f*vignette;
            // Dim red horizon glow a little below centre, as the stock menu backdrop.
            const float horizon=(y+.5f)/height-.62f;
            const float glow=std::exp(-horizon*horizon*140.f)*.22f*(0.4f+0.6f*vignette);
            r+=glow; g+=glow*.12f; b+=glow*.15f;
            // Faint scanlines.
            if ((y%3)==0) { r*=.86f; g*=.86f; b*=.86f; }
            auto* px=&image.rgba[(static_cast<std::size_t>(y)*width+x)*4];
            px[0]=ToByte(r); px[1]=ToByte(g); px[2]=ToByte(b); px[3]=255;
        }
    }
    // LOADING, centred, glyphs scaled so the word spans about 40% of the width.
    const char* word="LOADING";
    const std::uint32_t letters=7;
    const std::uint32_t scale=std::max<std::uint32_t>(2,(width*45/100)/(6*letters));
    const std::uint32_t advance=6*scale, wordWidth=advance*letters-scale, glyphHeight=7*scale;
    const std::uint32_t originX=(width-wordWidth)/2, originY=(height-glyphHeight)/2;
    const auto plot=[&](std::uint32_t x,std::uint32_t y,float r,float g,float b) {
        if (x>=width || y>=height) return;
        auto* px=&image.rgba[(static_cast<std::size_t>(y)*width+x)*4];
        px[0]=ToByte(r); px[1]=ToByte(g); px[2]=ToByte(b); px[3]=255;
    };
    for (std::uint32_t i=0;i<letters;++i) {
        const Glyph* glyph=FindGlyph(word[i]);
        if (!glyph) continue;
        for (std::uint32_t row=0;row<7;++row)
            for (std::uint32_t col=0;col<5;++col) {
                if (!(glyph->rows[row]&(0x10>>col))) continue;
                for (std::uint32_t sy=0;sy<scale;++sy)
                    for (std::uint32_t sx=0;sx<scale;++sx) {
                        const std::uint32_t x=originX+i*advance+col*scale+sx, y=originY+row*scale+sy;
                        // Soft dark shadow one cell down-right, then the off-white glyph.
                        plot(x+scale/4,y+scale/4,.02f,.005f,.006f);
                    }
            }
    }
    for (std::uint32_t i=0;i<letters;++i) {
        const Glyph* glyph=FindGlyph(word[i]);
        if (!glyph) continue;
        for (std::uint32_t row=0;row<7;++row)
            for (std::uint32_t col=0;col<5;++col) {
                if (!(glyph->rows[row]&(0x10>>col))) continue;
                for (std::uint32_t sy=0;sy<scale;++sy)
                    for (std::uint32_t sx=0;sx<scale;++sx)
                        plot(originX+i*advance+col*scale+sx,originY+row*scale+sy,.92f,.89f,.86f);
            }
    }
    // KF2's red leading rule under the word.
    const std::uint32_t ruleY=originY+glyphHeight+scale;
    for (std::uint32_t t=0;t<std::max<std::uint32_t>(2,scale/4);++t)
        for (std::uint32_t x=originX;x<originX+wordWidth;++x) plot(x,ruleY+t,.75f,.12f,.15f);
    return image;
}

} // namespace kf2vr::adapter
