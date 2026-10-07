#include "../Dlss.h"

#include <cmath>
#include <cstdio>

using namespace kf2vr::adapter;
namespace pinned=kf2vr::adapter::pinned;

namespace {
int failures=0;
void Expect(bool condition, const char* what) {
    if (!condition) { std::printf("FAIL: %s\n",what); ++failures; }
}
bool Near(double a, double b, double tolerance=1e-4) { return std::fabs(a-b)<=tolerance; }

// UE3-style row-vector view: world -> (x right, y up, z forward) at origin.
pinned::NativeMatrix4 View(double ox, double oy, double oz, double yawRadians) {
    // Camera forward along +X rotated by yaw, up +Z (UE world).
    const double c=std::cos(yawRadians), s=std::sin(yawRadians);
    const double forward[3]{c,s,0}, right[3]{-s,c,0}, up[3]{0,0,1};
    pinned::NativeMatrix4 v{};
    for (int i=0;i<3;++i) { v.m[i][0]=float(right[i]); v.m[i][1]=float(up[i]); v.m[i][2]=float(forward[i]); }
    const double o[3]{ox,oy,oz};
    for (int j=0;j<3;++j) {
        double sum=0; for (int i=0;i<3;++i) sum+=o[i]*v.m[i][j];
        v.m[3][j]=float(-sum);
    }
    v.m[3][3]=1;
    return v;
}
// Standard-depth perspective (D3D, z in [0,1]), UE3 row-vector layout.
pinned::NativeMatrix4 Projection(double tanHalf, double nearPlane, double farPlane) {
    pinned::NativeMatrix4 p{};
    p.m[0][0]=float(1/tanHalf); p.m[1][1]=float(1/tanHalf);
    p.m[2][2]=float(farPlane/(farPlane-nearPlane)); p.m[2][3]=1;
    p.m[3][2]=float(-nearPlane*farPlane/(farPlane-nearPlane));
    return p;
}
void Transform(const double p[4], const pinned::NativeMatrix4& m, double out[4]) {
    for (int c=0;c<4;++c) { double sum=0; for (int k=0;k<4;++k) sum+=p[k]*m.m[k][c]; out[c]=sum; }
}
void TransformF(const double p[4], const float m[4][4], double out[4]) {
    for (int c=0;c<4;++c) { double sum=0; for (int k=0;k<4;++k) sum+=p[k]*m[k][c]; out[c]=sum; }
}
} // namespace

int main() {
    DlssMode mode{};
    Expect(ParseDlssMode(L"Quality",mode) && mode==DlssMode::Quality,"parse quality");
    Expect(ParseDlssMode(L"ultra_performance",mode) && mode==DlssMode::UltraPerformance,"parse ultra performance");
    Expect(ParseDlssMode(L"DLAA",mode) && mode==DlssMode::Dlaa,"parse dlaa");
    Expect(ParseDlssMode(L"",mode) && mode==DlssMode::Off,"parse empty as off");
    Expect(!ParseDlssMode(L"ultra",mode),"reject unknown mode");

    Expect(DlssRenderExtent(2688,DlssMode::Dlaa)==2688,"dlaa extent");
    Expect(DlssRenderExtent(2688,DlssMode::Quality)==1792,"quality extent");
    Expect(DlssRenderExtent(2688,DlssMode::Balanced)==1559,"balanced extent");
    Expect(DlssRenderExtent(2688,DlssMode::Performance)==1344,"performance extent");
    Expect(DlssRenderExtent(2688,DlssMode::UltraPerformance)==896,"ultra performance extent");

    // Jitter offsets stay inside the pixel and cover several distinct phases.
    for (std::uint32_t i=0;i<64;++i) {
        const auto j=DlssJitterForPhase(i,1792,2688);
        Expect(j.x>=-0.5f && j.x<0.5f && j.y>=-0.5f && j.y<0.5f,"jitter in pixel");
    }
    const auto a=DlssJitterForPhase(1,1792,2688), b=DlssJitterForPhase(2,1792,2688);
    Expect(a.x!=b.x || a.y!=b.y,"jitter phases differ");

    // A sample offset of +0.25 px right moves content left: NDC x of a fixed
    // point decreases by 2*0.25/width; +0.25 px down raises NDC y.
    {
        auto p=Projection(1.0,10,100000);
        const auto base=p;
        ApplyDlssJitter(p,{0.25f,0.25f},1000,800);
        const double point[4]{30,20,500,1};
        double c0[4],c1[4];
        Transform(point,base,c0); Transform(point,p,c1);
        Expect(Near(c1[0]/c1[3]-c0[0]/c0[3],-0.0005),"jitter x shift");
        Expect(Near(c1[1]/c1[3]-c0[1]/c0[3],0.000625),"jitter y shift");
    }

    // Camera origin recovers from a UE3 view at large world coordinates.
    {
        const auto v=View(51234.5,-20333.25,812.0,0.7);
        double o[3]; DlssViewOrigin(v,o);
        Expect(Near(o[0],51234.5,0.05) && Near(o[1],-20333.25,0.05) && Near(o[2],812.0,0.05),"view origin");
    }

    // Reprojection: identical cameras map clip to itself; a moved camera maps
    // a world point's current clip to its previous clip.
    {
        const auto proj=Projection(1.0,10,100000);
        const auto vc=View(40000,12000,300,0.30), vp=View(39990,12004,301,0.31);
        float same[4][4];
        Expect(DlssReprojection(vc,proj,vc,proj,same),"identity reprojection");
        for (int r=0;r<4;++r) for (int c=0;c<4;++c)
            Expect(Near(same[r][c]*1.0/same[3][3],r==c ? 1.0 : 0.0,1e-3),"identity matrix");
        float m[4][4];
        Expect(DlssReprojection(vc,proj,vp,proj,m),"moved reprojection");
        const double world[4]{40300,12100,350,1};
        double view[4],cur[4],prevView[4],prev[4],mapped[4];
        Transform(world,vc,view); Transform(view,proj,cur);
        Transform(world,vp,prevView); Transform(prevView,proj,prev);
        const double curNdc[4]{cur[0]/cur[3],cur[1]/cur[3],cur[2]/cur[3],1};
        TransformF(curNdc,m,mapped);
        Expect(Near(mapped[0]/mapped[3],prev[0]/prev[3],2e-4) && Near(mapped[1]/mapped[3],prev[1]/prev[3],2e-4),
               "reprojected point matches previous camera");
    }

    if (failures) { std::printf("%d DLSS math check(s) failed\n",failures); return 1; }
    std::printf("DLSS math checks passed\n");
    return 0;
}
