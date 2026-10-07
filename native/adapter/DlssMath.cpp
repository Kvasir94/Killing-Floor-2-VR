#include "Dlss.h"

#include <d3d11_1.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwctype>


namespace kf2vr::adapter {
namespace {
using Microsoft::WRL::ComPtr;

void Multiply(const double a[4][4], const double b[4][4], double out[4][4]) {
    for (int r=0;r<4;++r) for (int c=0;c<4;++c) {
        double sum=0; for (int k=0;k<4;++k) sum+=a[r][k]*b[k][c];
        out[r][c]=sum;
    }
}
void Widen(const pinned::NativeMatrix4& m, double out[4][4]) {
    for (int r=0;r<4;++r) for (int c=0;c<4;++c) out[r][c]=m.m[r][c];
}
bool Invert(const double m[4][4], double out[4][4]) {
    double a[4][8];
    for (int r=0;r<4;++r) for (int c=0;c<8;++c) a[r][c]=c<4 ? m[r][c] : (c-4==r ? 1.0 : 0.0);
    for (int col=0;col<4;++col) {
        int pivot=col;
        for (int r=col+1;r<4;++r) if (std::fabs(a[r][col])>std::fabs(a[pivot][col])) pivot=r;
        if (!(std::fabs(a[pivot][col])>1e-30)) return false;
        if (pivot!=col) for (int c=0;c<8;++c) std::swap(a[pivot][c],a[col][c]);
        const double scale=1.0/a[col][col];
        for (int c=0;c<8;++c) a[col][c]*=scale;
        for (int r=0;r<4;++r) if (r!=col) {
            const double f=a[r][col];
            if (f!=0) for (int c=0;c<8;++c) a[r][c]-=f*a[col][c];
        }
    }
    for (int r=0;r<4;++r) for (int c=0;c<4;++c) out[r][c]=a[r][c+4];
    return true;
}
float Halton(std::uint32_t index, std::uint32_t base) {
    float f=1.0f, r=0.0f;
    while (index) { f/=static_cast<float>(base); r+=f*static_cast<float>(index%base); index/=base; }
    return r;
}
} // namespace

bool ParseDlssMode(std::wstring_view text, DlssMode& mode) noexcept {
    std::wstring lower;
    for (auto ch:text) if (ch!=L' ' && ch!=L'_' && ch!=L'-') lower+=static_cast<wchar_t>(std::towlower(ch));
    if (lower.empty() || lower==L"off" || lower==L"0") { mode=DlssMode::Off; return true; }
    if (lower==L"dlaa") { mode=DlssMode::Dlaa; return true; }
    if (lower==L"quality") { mode=DlssMode::Quality; return true; }
    if (lower==L"balanced") { mode=DlssMode::Balanced; return true; }
    if (lower==L"performance") { mode=DlssMode::Performance; return true; }
    if (lower==L"ultraperformance") { mode=DlssMode::UltraPerformance; return true; }
    return false;
}
const char* DlssModeName(DlssMode mode) noexcept {
    switch (mode) {
    case DlssMode::Dlaa: return "DLAA";
    case DlssMode::Quality: return "Quality";
    case DlssMode::Balanced: return "Balanced";
    case DlssMode::Performance: return "Performance";
    case DlssMode::UltraPerformance: return "UltraPerformance";
    default: return "Off";
    }
}
double DlssRenderRatio(DlssMode mode) noexcept {
    switch (mode) {
    case DlssMode::Dlaa: return 1.0;
    case DlssMode::Quality: return 2.0/3.0;
    case DlssMode::Balanced: return 0.58;
    case DlssMode::Performance: return 0.5;
    case DlssMode::UltraPerformance: return 1.0/3.0;
    default: return 1.0;
    }
}
unsigned DlssRenderExtent(unsigned output, DlssMode mode) noexcept {
    if (!output) return 0;
    const auto value=static_cast<unsigned>(std::lround(static_cast<double>(output)*DlssRenderRatio(mode)));
    return std::clamp(value,1u,output);
}
DlssJitter DlssJitterForPhase(std::uint32_t phase, unsigned renderWidth, unsigned outputWidth) noexcept {
    // NVIDIA's guidance: at least 8 phases, times the squared upscale factor.
    const double scale=renderWidth ? static_cast<double>(outputWidth)/renderWidth : 1.0;
    const auto phases=std::clamp(static_cast<std::uint32_t>(std::ceil(8.0*scale*scale)),8u,72u);
    const std::uint32_t k=phase%phases+1;
    return {Halton(k,2)-0.5f, Halton(k,3)-0.5f};
}
bool DlssReprojection(const pinned::NativeMatrix4& viewCur, const pinned::NativeMatrix4& projCur,
                      const pinned::NativeMatrix4& viewPrev, const pinned::NativeMatrix4& projPrev,
                      float out[4][4]) noexcept {
    double vc[4][4],pc[4][4],vp[4][4],pp[4][4],cur[4][4],prev[4][4],inverse[4][4],result[4][4];
    Widen(viewCur,vc);Widen(projCur,pc);Widen(viewPrev,vp);Widen(projPrev,pp);
    Multiply(vc,pc,cur);Multiply(vp,pp,prev);
    if (!Invert(cur,inverse)) return false;
    Multiply(inverse,prev,result);
    for (int r=0;r<4;++r) for (int c=0;c<4;++c) {
        if (!std::isfinite(result[r][c])) return false;
        out[r][c]=static_cast<float>(result[r][c]);
    }
    return true;
}
void DlssViewOrigin(const pinned::NativeMatrix4& view, double origin[3]) noexcept {
    for (int j=0;j<3;++j) {
        double sum=0;
        for (int i=0;i<3;++i) sum+=static_cast<double>(view.m[3][i])*view.m[j][i];
        origin[j]=-sum;
    }
}

} // namespace kf2vr::adapter
