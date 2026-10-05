#include "../PortalCapturePolicy.h"
#include <cstdio>
#include <cstdlib>

using namespace kf2vr::portal;
namespace {
unsigned checks{};
void Check(bool value,const char* message) {
    ++checks;
    if (!value) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
bool Close(float a,float b,float tolerance=2.e-4f) { return std::abs(a-b)<tolerance; }
bool Close(CaptureVector a,CaptureVector b) { return Close(a.x,b.x)&&Close(a.y,b.y)&&Close(a.z,b.z); }
CaptureMatrix Projection(float xOffset,float yOffset) {
    CaptureMatrix p;
    p.m[0][0]=1.3f; p.m[1][1]=1.8f;
    p.m[2][0]=xOffset; p.m[2][1]=yOffset;
    p.m[2][2]=1.001f; p.m[2][3]=1.f; p.m[3][2]=-10.01f;
    return p;
}
std::array<float,4> Project(std::array<float,4> point,const CaptureMatrix& m) {
    std::array<float,4> out{};
    for (int c=0;c<4;++c) for (int r=0;r<4;++r) out[c]+=point[r]*m.m[r][c];
    return out;
}
}
int main() {
    CaptureMatrix m; CapturePlane plane;
    Check(MakePortalTransform({0,0,0},{},{100,0,0},{},m,plane),"identity portal frame builds");
    Check(Close(TransformPoint({90,-3,4},m),{10,3,4}),"exit-to-entry map changes normal and right signs");
    Check(Close(plane.x,-1)&&Close(plane.y,0)&&Close(plane.z,0)&&Close(plane.w,0),"source clip points into mounting plane");
    Check(MakePortalTransform({5,6,7},{},{100,200,300},{0,0,16384},m,plane),"rolled portal frame builds");
    Check(Close(TransformPoint({90,204,303},m),{15,9,11}),"full exit roll retained instead of normal-only reconstruction");
    CaptureMatrix inverseMap; CapturePlane otherPlane;
    Check(MakePortalTransform({100,200,300},{0,0,16384},{5,6,7},{},inverseMap,otherPlane),"reverse rolled map builds");
    const CaptureVector left{42,22,91},right{48.4f,22,91};
    Check(Close(TransformPoint(TransformPoint(left,m),inverseMap),left),"round trip returns full eye position");
    const auto mappedLeft=TransformPoint(left,m),mappedRight=TransformPoint(right,m);
    const auto delta=mappedRight-mappedLeft;
    Check(Close(Dot(delta,delta),6.4f*6.4f,.001f),"mapped eye pair preserves IPD");
    Check(!MakePortalTransform({std::numeric_limits<float>::infinity(),0,0},{},{},{},m,plane),"nonfinite portal frame rejected");

    CaptureMatrix identity;
    for (int i=0;i<4;++i) identity.m[i][i]=1;
    Check(ClassifyAperture({0,0,100},{-16384,0,0},5,10,identity,Projection(0,0))==ApertureVisibility::PotentiallyVisible,
        "front-facing aperture in parent frustum requires capture");
    Check(ClassifyAperture({0,0,100},{16384,0,0},5,10,identity,Projection(0,0))==ApertureVisibility::Hidden,
        "one-sided rear face cannot sample a stale eye target");
    Check(ClassifyAperture({0,0,-100},{16384,0,0},5,10,identity,Projection(0,0))==ApertureVisibility::Hidden,
        "portal behind eye requires no invalid oblique clip");
    Check(ClassifyAperture({10000,0,100},{-16384,0,0},5,10,identity,Projection(.2f,0))==ApertureVisibility::Hidden,
        "offscreen rectangle is conservatively culled");
    Check(ClassifyAperture({70,0,100},{-16384,0,0},5,20,identity,Projection(0,0))==ApertureVisibility::PotentiallyVisible,
        "partially visible aperture remains capture eligible");
    Check(ClassifyAperture({0,0,100},{-16384,0,0},-1,10,identity,Projection(0,0))==ApertureVisibility::Invalid,
        "invalid aperture dimensions reject visibility proof");

    for (const auto offsets: {std::array<float,2>{0,0},std::array<float,2>{.23f,-.17f},std::array<float,2>{-.31f,.11f}}) {
        const auto projection=Projection(offsets[0],offsets[1]);
        const CapturePlane cut{.2f,-.1f,1.f,20.f};
        CaptureMatrix clipped,inverse;
        Check(MakeOblique(projection,cut,clipped),"valid symmetric/asymmetric oblique clip builds");
        Check(Close(clipped.m[2][0],offsets[0])&&Close(clipped.m[2][1],offsets[1]),"eye off-center projection terms preserved");
        const auto onPlane=Project({5,3,19.3f,1},clipped);
        const auto behind=Project({5,3,18.3f,1},clipped);
        const auto beyond=Project({5,3,20.3f,1},clipped);
        Check(Close(onPlane[2],0,.001f),"exit plane maps to near clip Z zero");
        Check(behind[2]<0&&beyond[2]>0,"geometry behind exit plane is clipped");
        Check(Invert(projection,inverse),"projection inverse exists");
        const auto farPoint=Project({1,-1,1,1},inverse);
        const auto farClip=Project(farPoint,clipped);
        Check(Close(farClip[2],farClip[3],.001f),"selected asymmetric far corner remains on far clip plane");
        for (int r=0;r<4;++r) for (int c=0;c<4;++c)
            if (c!=2) Check(Close(clipped.m[r][c],projection.m[r][c]),"clipping only changes clip-depth column");
    }
    CaptureMatrix invalid=Projection(0,0),clipped;
    invalid.m[3][2]=0;
    Check(!MakeOblique(invalid,{0,0,1,20},clipped),"singular/unsupported projection rejected");
    Check(!MakeOblique(Projection(0,0),{0,0,-1,20},clipped),"reversed invisible exit plane rejected");
    invalid=Projection(0,0); invalid.m[0][0]=std::numeric_limits<float>::quiet_NaN();
    Check(!MakeOblique(invalid,{0,0,1,20},clipped),"nonfinite projection rejected");

    {
        // Entry at the origin facing +X; exit at (1000,0,0) facing -Y (yaw -90).
        const CaptureVector entry{0,0,0},exit{1000,0,0};
        const CaptureRotation entryRotation{},exitRotation{0,-16384,0};
        const float halfWidth=80,halfHeight=140;
        const auto parent=Projection(0,0);
        WindowCapture window;
        const CaptureVector eye{200,30,-20};
        Check(MakeWindowCapture(entry,entryRotation,exit,exitRotation,halfWidth,halfHeight,eye,parent,.7f,.5f,window),
            "window capture builds for an eye in front of the entry");
        // Entry-local (200,30,-20) -> exit-local (-200,-30,-20); exit X=(0,-1,0), Y=(1,0,0).
        Check(Close(window.eye,{970,200,-20}),"virtual eye is the eye mapped behind the exit");
        const auto project=[&](CaptureVector world) {
            return Project(Project({world.x,world.y,world.z,1},window.view),window.projection);
        };
        // Exit-local right = +Y_exit = +X world, up = +Z world.
        const auto topRight=project({exit.x+halfWidth,exit.y,exit.z+halfHeight});
        const auto bottomLeft=project({exit.x-halfWidth,exit.y,exit.z-halfHeight});
        Check(Close(topRight[0]/topRight[3],1,.001f)&&Close(topRight[1]/topRight[3],1,.001f),
            "exit top-right corner fills the target's top-right corner");
        Check(Close(bottomLeft[0]/bottomLeft[3],-1,.001f)&&Close(bottomLeft[1]/bottomLeft[3],-1,.001f),
            "exit bottom-left corner fills the target's bottom-left corner");
        // A ray from the eye through entry-local (0,Y,Z) continues through the exit at
        // exit-local (0,-Y,Z); the entry mesh UV must address that texel.
        const float localY=35,localZ=-60;
        const auto mapped=project({exit.x-localY,exit.y,exit.z+localZ});
        const float u=.5f-localY/(2*halfWidth),v=.5f-localZ/(2*halfHeight);
        Check(Close(mapped[0]/mapped[3]*.5f+.5f,u,.001f)&&Close(.5f-mapped[1]/mapped[3]*.5f,v,.001f),
            "entry mesh UV samples the texel the mapped ray lands on");
        const auto nearPoint=project({exit.x,exit.y-.7f,exit.z});
        const auto wall=project({exit.x,exit.y+5,exit.z});
        Check(Close(nearPoint[2]/nearPoint[3],0,.001f),"near plane sits just past the exit rim");
        Check(wall[2]<0,"geometry behind the exit wall is clipped");
        const auto roomPoint=project({exit.x+20,exit.y-500,exit.z+10});
        Check(roomPoint[2]>0&&roomPoint[2]<roomPoint[3],"exit room stays inside the depth range");
        Check(Close(window.depth,200),"eye depth is reported in front of the entry");
        Check(!MakeWindowCapture(entry,entryRotation,exit,exitRotation,halfWidth,halfHeight,{.2f,0,0},parent,.7f,.5f,window),
            "an eye at the entry plane is left to the screen-space path");
        Check(!MakeWindowCapture(entry,entryRotation,exit,exitRotation,halfWidth,halfHeight,{-10,0,0},parent,.7f,.5f,window),
            "an eye behind the entry cannot build a window");
        Check(!MakeWindowCapture(entry,entryRotation,exit,exitRotation,-1,halfHeight,eye,parent,.7f,.5f,window),
            "invalid half extents rejected");
    }
    std::printf("Portal capture policy: %u checks passed\n",checks);
    return 0;
}
