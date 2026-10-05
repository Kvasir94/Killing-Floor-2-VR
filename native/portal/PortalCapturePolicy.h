#pragma once

#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace kf2vr::portal {

struct CaptureVector { float x{}, y{}, z{}; };
struct CaptureRotation { std::int32_t pitch{}, yaw{}, roll{}; };
struct CaptureMatrix { float m[4][4]{}; };
// UE FPlane stores dot(normal, point)=w, not a signed homogeneous constant.
struct CapturePlane { float x{}, y{}, z{}, w{}; };
inline CaptureVector operator+(CaptureVector a,CaptureVector b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
inline CaptureVector operator-(CaptureVector a,CaptureVector b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
inline CaptureVector operator*(CaptureVector a,float b) { return {a.x*b,a.y*b,a.z*b}; }
inline float Dot(CaptureVector a,CaptureVector b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
inline bool Finite(CaptureVector a) { return std::isfinite(a.x)&&std::isfinite(a.y)&&std::isfinite(a.z); }
inline bool Finite(const CaptureMatrix& a) {
    for (const auto& row:a.m) for (float v:row) if (!std::isfinite(v)) return false;
    return true;
}
inline CaptureMatrix Multiply(const CaptureMatrix& a,const CaptureMatrix& b) {
    CaptureMatrix result;
    for (int r=0;r<4;++r) for (int c=0;c<4;++c)
        for (int k=0;k<4;++k) result.m[r][c]+=a.m[r][k]*b.m[k][c];
    return result;
}
inline CaptureVector TransformPoint(CaptureVector p,const CaptureMatrix& m) {
    return {p.x*m.m[0][0]+p.y*m.m[1][0]+p.z*m.m[2][0]+m.m[3][0],
            p.x*m.m[0][1]+p.y*m.m[1][1]+p.z*m.m[2][1]+m.m[3][1],
            p.x*m.m[0][2]+p.y*m.m[1][2]+p.z*m.m[2][2]+m.m[3][2]};
}
inline bool Invert(const CaptureMatrix& input,CaptureMatrix& output) {
    if (!Finite(input)) return false;
    double a[4][8]{};
    for (int r=0;r<4;++r) for (int c=0;c<4;++c) { a[r][c]=input.m[r][c]; a[r][c+4]=r==c?1:0; }
    for (int c=0;c<4;++c) {
        int pivot=c;
        for (int r=c+1;r<4;++r) if (std::abs(a[r][c])>std::abs(a[pivot][c])) pivot=r;
        if (std::abs(a[pivot][c])<1.e-12) return false;
        for (int k=0;k<8;++k) std::swap(a[c][k],a[pivot][k]);
        const double divisor=a[c][c];
        for (double& v:a[c]) v/=divisor;
        for (int r=0;r<4;++r) if (r!=c) {
            const double factor=a[r][c];
            for (int k=0;k<8;++k) a[r][k]-=factor*a[c][k];
        }
    }
    for (int r=0;r<4;++r) for (int c=0;c<4;++c) output.m[r][c]=static_cast<float>(a[r][c+4]);
    return Finite(output);
}
inline std::array<CaptureVector,3> Basis(CaptureRotation rotation) {
    constexpr double unit=6.283185307179586476925286766559/65536.0;
    const double p=rotation.pitch*unit,y=rotation.yaw*unit,r=rotation.roll*unit;
    const float cp=static_cast<float>(std::cos(p)),sp=static_cast<float>(std::sin(p));
    const float cy=static_cast<float>(std::cos(y)),sy=static_cast<float>(std::sin(y));
    const float cr=static_cast<float>(std::cos(r)),sr=static_cast<float>(std::sin(r));
    return {{{cp*cy,cp*sy,sp}, {sr*sp*cy-cr*sy,sr*sp*sy+cr*cy,-sr*cp},
             {-cr*sp*cy-sr*sy,sr*cy-cr*sp*sy,cr*cp}}};
}
enum class ApertureVisibility { Invalid,Hidden,PotentiallyVisible };
// Conservative rectangular bound of the one-sided oval. Cull only if every
// corner is outside one homogeneous D3D frustum plane, or the eye is behind
// the mesh. A false positive only spends another capture; no false negative
// may allow a visible aperture to sample a previous eye's texture.
inline ApertureVisibility ClassifyAperture(CaptureVector center,CaptureRotation rotation,
    float halfWidth,float halfHeight,const CaptureMatrix& view,const CaptureMatrix& projection) {
    if (!Finite(center)||!std::isfinite(halfWidth)||!std::isfinite(halfHeight)
        ||halfWidth<=0||halfHeight<=0||!Finite(projection)) return ApertureVisibility::Invalid;
    CaptureMatrix inverseView;
    if (!Invert(view,inverseView)) return ApertureVisibility::Invalid;
    const auto axes=Basis(rotation);
    const auto eye=TransformPoint({},inverseView);
    // Mesh translation is +0.5 along its local X normal. Enlarge the bound
    // slightly to avoid edge rejection from roundoff or aperture tessellation.
    center=center+axes[0]*.5f;
    if (Dot(eye-center,axes[0])<-.01f) return ApertureVisibility::Hidden;
    const auto vp=Multiply(view,projection);
    std::array<unsigned,6> outside{};
    for (int y:{-1,1}) for (int z:{-1,1}) {
        const auto p=center+axes[1]*(y*(halfWidth+.01f))+axes[2]*(z*(halfHeight+.01f));
        const float in[]{p.x,p.y,p.z,1};
        float clip[4]{};
        for (int c=0;c<4;++c) for (int r=0;r<4;++r) clip[c]+=in[r]*vp.m[r][c];
        for (float v:clip) if (!std::isfinite(v)) return ApertureVisibility::Invalid;
        const float planes[]{clip[3]+clip[0],clip[3]-clip[0],clip[3]+clip[1],clip[3]-clip[1],clip[2],clip[3]-clip[2]};
        for (unsigned i=0;i<outside.size();++i) if (planes[i]<-.001f) ++outside[i];
    }
    return std::any_of(outside.begin(),outside.end(),[](unsigned n){return n==4;})
        ?ApertureVisibility::Hidden:ApertureVisibility::PotentiallyVisible;
}
// The probe premultiplies the parent's world-to-view matrix. Therefore this
// matrix maps EXIT world coordinates back to ENTRY world coordinates.
inline bool MakePortalTransform(CaptureVector entry,CaptureRotation entryRotation,
    CaptureVector exit,CaptureRotation exitRotation,CaptureMatrix& matrix,CapturePlane& plane) {
    if (!Finite(entry)||!Finite(exit)) return false;
    const auto a=Basis(entryRotation),b=Basis(exitRotation);
    auto map=[&](CaptureVector v) { return a[0]*-Dot(v,b[0])+a[1]*-Dot(v,b[1])+a[2]*Dot(v,b[2]); };
    const CaptureVector rows[]{map({1,0,0}),map({0,1,0}),map({0,0,1}),entry-map(exit)};
    matrix={};
    for (int i=0;i<4;++i) { matrix.m[i][0]=rows[i].x; matrix.m[i][1]=rows[i].y; matrix.m[i][2]=rows[i].z; }
    matrix.m[3][3]=1;
    const auto n=a[0]*-1.f;
    plane={n.x,n.y,n.z,Dot(n,entry)};
    return Finite(matrix);
}
// D3D conventional depth: replace clip Z with the camera-space exit plane.
// Unlike KF2's native helper, use the inverse matrix so asymmetric XR frusta
// keep their off-center terms and map the far clip corner consistently.
inline bool MakeOblique(const CaptureMatrix& projection,CapturePlane plane,CaptureMatrix& output) {
    if (!std::isfinite(plane.x)||!std::isfinite(plane.y)||!std::isfinite(plane.z)||!std::isfinite(plane.w)
        ||std::abs(projection.m[2][3]-1.f)>1.e-4f||std::abs(projection.m[3][3])>1.e-5f
        ||projection.m[3][2]>=0.f) return false;
    CaptureMatrix inverse;
    if (!Invert(projection,inverse)) return false;
    const float corner[]{plane.x<0?-1.f:1.f,plane.y<0?-1.f:1.f,1.f,1.f};
    double q[4]{};
    for (int c=0;c<4;++c) for (int r=0;r<4;++r) q[c]+=corner[r]*inverse.m[r][c];
    const double denominator=plane.x*q[0]+plane.y*q[1]+plane.z*q[2]-plane.w*q[3];
    if (!std::isfinite(denominator)||denominator<=1.e-6) return false;
    output=projection;
    const float scale=static_cast<float>(1.0/denominator);
    output.m[0][2]=plane.x*scale; output.m[1][2]=plane.y*scale;
    output.m[2][2]=plane.z*scale; output.m[3][2]=-plane.w*scale;
    return Finite(output);
}

// Portal 2 restricts each portal view to the portal's screen area (stencil
// plus scissor) and to a frustum through the portal outline. UE3 only offers
// a render-target capture, so the equivalent is a "window" capture: a virtual
// eye behind the exit, looking straight out of it, with an off-axis frustum
// whose image plane is exactly the exit rectangle. Every target texel lands
// on the portal, culling is exactly through the hole, and the near plane on
// the exit plane replaces the oblique clip. The entry surface samples the
// target with its own mesh UVs: u=0.5-localY/(2*halfWidth),
// v=0.5-localZ/(2*halfHeight), so no per-eye material parameter is needed.
// See docs/re/PORTAL2_REFERENCE.md.
struct WindowCapture {
    CaptureMatrix view;       // world -> virtual eye, UE3 axes (x right, y up, z forward)
    CaptureMatrix projection; // off-axis; parent's depth convention, near just past the exit
    CaptureVector eye;        // virtual eye in world space
    float depth{};            // eye distance in front of the entry plane
};
inline bool MakeWindowCapture(CaptureVector entry,CaptureRotation entryRotation,
    CaptureVector exit,CaptureRotation exitRotation,float halfWidth,float halfHeight,
    CaptureVector eye,const CaptureMatrix& parentProjection,float nearOffset,float minimumDepth,
    WindowCapture& out) {
    if (!Finite(entry)||!Finite(exit)||!Finite(eye)||!std::isfinite(halfWidth)||!std::isfinite(halfHeight)
        ||halfWidth<=0||halfHeight<=0||!std::isfinite(nearOffset)||nearOffset<0||!(minimumDepth>0)
        ||!Finite(parentProjection)||std::abs(parentProjection.m[2][3]-1.f)>1.e-4f
        ||std::abs(parentProjection.m[3][3])>1.e-5f||parentProjection.m[2][2]<=0.f) return false;
    const auto a=Basis(entryRotation),b=Basis(exitRotation);
    const auto local=eye-entry;
    const float x=Dot(local,a[0]),y=Dot(local,a[1]),z=Dot(local,a[2]);
    if (!(x>=minimumDepth)) return false;
    // Entry local (x,y,z) -> exit local (-x,-y,z): the virtual eye sits behind the exit.
    const auto virtualEye=exit+b[0]*-x+b[1]*-y+b[2]*z;
    out={};
    const CaptureVector axes[3]{b[1],b[2],b[0]};
    for (int c=0;c<3;++c) {
        out.view.m[0][c]=axes[c].x; out.view.m[1][c]=axes[c].y; out.view.m[2][c]=axes[c].z;
        out.view.m[3][c]=-Dot(virtualEye,axes[c]);
    }
    out.view.m[3][3]=1;
    // Exit rectangle in virtual-eye space: depth x, centred at (y,-z).
    const float left=y-halfWidth,right=y+halfWidth,bottom=-z-halfHeight,top=-z+halfHeight;
    auto& p=out.projection.m;
    p[0][0]=2*x/(right-left); p[2][0]=-(right+left)/(right-left);
    p[1][1]=2*x/(top-bottom); p[2][1]=-(top+bottom)/(top-bottom);
    p[2][2]=parentProjection.m[2][2]; p[2][3]=1;
    p[3][2]=-(x+nearOffset)*parentProjection.m[2][2];
    out.eye=virtualEye; out.depth=x;
    return Finite(out.view)&&Finite(out.projection);
}
}
