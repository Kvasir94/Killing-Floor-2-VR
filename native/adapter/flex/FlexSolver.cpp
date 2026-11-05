#include "FlexSolver.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <execution>
#include <numeric>

namespace kf2vr::flex {
namespace {
constexpr float Pi=3.14159265358979f;

inline Vec3 operator+(Vec3 a,Vec3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
inline Vec3 operator-(Vec3 a,Vec3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
inline Vec3 operator*(Vec3 a,float s) { return {a.x*s,a.y*s,a.z*s}; }
inline Vec3& operator+=(Vec3& a,Vec3 b) { a.x+=b.x; a.y+=b.y; a.z+=b.z; return a; }
inline Vec3& operator-=(Vec3& a,Vec3 b) { a.x-=b.x; a.y-=b.y; a.z-=b.z; return a; }
inline float Dot(Vec3 a,Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
inline Vec3 Cross(Vec3 a,Vec3 b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
inline float Length(Vec3 a) { return std::sqrt(Dot(a,a)); }
inline Vec3 Min(Vec3 a,Vec3 b) { return {std::min(a.x,b.x),std::min(a.y,b.y),std::min(a.z,b.z)}; }
inline Vec3 Max(Vec3 a,Vec3 b) { return {std::max(a.x,b.x),std::max(a.y,b.y),std::max(a.z,b.z)}; }
inline Vec3 Xyz(const std::array<float,4>& v) { return {v[0],v[1],v[2]}; }

Vec3 FieldNoise(const ForceField& field,Vec3 v,float h) {
    constexpr float epsilon=1e-6f; // shipped gParams+304
    const float lengthSquared=Dot(v,v);
    if(field.noiseStrength<epsilon || lengthSquared<epsilon) return v;
    const float length=std::sqrt(lengthSquared);
    const Vec3 direction=v*(1.0f/length);
    Vec3 axis=direction;
    float best=-1.0f;
    for(const auto& sample:field.noiseVectors) {
        const Vec3 candidate{sample[0],sample[1],sample[2]};
        const float score=Dot(direction,candidate);
        if(score>best) { best=score; axis=candidate; }
    }
    const Vec3 projection=axis*(length*best);
    return v+(Cross(v,projection)-v)*(field.noiseStrength*h);
}

Vec3 FieldForce(const ForceField& field,Vec3 world,float h) {
    const auto* b=field.basis;
    const Vec3 local{
        field.translation[0]+world.x*b[0]+world.y*b[3]+world.z*b[6],
        field.translation[1]+world.x*b[1]+world.y*b[4]+world.z*b[7],
        field.translation[2]+world.x*b[2]+world.y*b[5]+world.z*b[8]};
    const Vec3 noisy=FieldNoise(field,local,h);
    const float halfBounds=std::fabs(field.boundsHeight)*0.5f;
    const float dy=noisy.y-std::clamp(noisy.y,-halfBounds,halfBounds);
    const float distance=std::sqrt(noisy.x*noisy.x+dy*dy+noisy.z*noisy.z);
    const float fraction=distance/field.boundsRadius;
    if(!(fraction<1.0f)) return {}; // includes a zero-radius 0/0 bound

    const float halfHeight=field.height*0.5f;
    float radiusSquared=0;
    if(local.y>-halfHeight && local.y<halfHeight) {
        const float radius=field.bottomRadius+(field.topRadius-field.bottomRadius)*
            (local.y/field.height+0.5f);
        radiusSquared=radius*radius;
    } else if(local.y<=-halfHeight && local.y>=-halfHeight-field.bottomRadius) {
        const float y=local.y+halfHeight;
        radiusSquared=field.bottomRadius*field.bottomRadius-y*y;
    } else if(local.y>=halfHeight && local.y<=halfHeight+field.topRadius) {
        const float y=local.y-halfHeight;
        radiusSquared=field.topRadius*field.topRadius-y*y;
    }
    // The shipped vortex returns its input position on its axis or outside
    // the tapered cross-section; the outer capsule still bounds that force.
    Vec3 force=local;
    const float radialSquared=local.x*local.x+local.z*local.z;
    if(radiusSquared>1e-5f && radialSquared>1e-5f && radialSquared<=radiusSquared) {
        const float radialScale=field.radialStrength/std::sqrt(radialSquared);
        const float angularScale=field.rotationalStrength/std::sqrt(radiusSquared);
        force={local.x*radialScale-local.z*angularScale,field.liftStrength,
            local.z*radialScale+local.x*angularScale};
    }
    // Transpose the host basis back to world space, then perturb the faded
    // force with the same supplied vectors used for bounds admission.
    const Vec3 worldForce{force.x*b[0]+force.y*b[1]+force.z*b[2],
        force.x*b[3]+force.y*b[4]+force.z*b[5],
        force.x*b[6]+force.y*b[7]+force.z*b[8]};
    const float fade=std::clamp((1.0f-fraction)/(field.boundaryFade+1e-6f),0.0f,1.0f);
    return FieldNoise(field,worldForce*fade,h);
}

using Quat=std::array<float,4>; // x,y,z,w
inline Vec3 Rotate(const Quat& q,Vec3 v) {
    const Vec3 u{q[0],q[1],q[2]};
    const Vec3 t=Cross(u,v)*2.0f;
    return v+t*q[3]+Cross(u,t);
}
inline Vec3 RotateInverse(const Quat& q,Vec3 v) { return Rotate(Quat{-q[0],-q[1],-q[2],q[3]},v); }
inline Quat Multiply(const Quat& a,const Quat& b) {
    return {a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1],
            a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0],
            a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3],
            a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2]};
}
inline Quat Normalize(Quat q) {
    const float n=std::sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]);
    if(n<1e-12f) return {0,0,0,1};
    return {q[0]/n,q[1]/n,q[2]/n,q[3]/n};
}
Quat FromMatrixImpl(const float m[9]) { // column-major
    const float trace=m[0]+m[4]+m[8];
    Quat q;
    if(trace>0) {
        const float s=std::sqrt(trace+1.0f)*2;
        q={(m[5]-m[7])/s,(m[6]-m[2])/s,(m[1]-m[3])/s,0.25f*s};
    } else if(m[0]>m[4] && m[0]>m[8]) {
        const float s=std::sqrt(1.0f+m[0]-m[4]-m[8])*2;
        q={0.25f*s,(m[3]+m[1])/s,(m[6]+m[2])/s,(m[5]-m[7])/s};
    } else if(m[4]>m[8]) {
        const float s=std::sqrt(1.0f+m[4]-m[0]-m[8])*2;
        q={(m[3]+m[1])/s,0.25f*s,(m[7]+m[5])/s,(m[6]-m[2])/s};
    } else {
        const float s=std::sqrt(1.0f+m[8]-m[0]-m[4])*2;
        q={(m[6]+m[2])/s,(m[7]+m[5])/s,0.25f*s,(m[1]-m[3])/s};
    }
    return Normalize(q);
}

template<class Fn> void ParallelFor(int count,int grain,Fn&& fn) {
    if(count<=0) return;
    const int chunks=(count+grain-1)/grain;
    if(chunks==1) { fn(0,count); return; }
    std::vector<int> ids(chunks);
    std::iota(ids.begin(),ids.end(),0);
    std::for_each(std::execution::par,ids.begin(),ids.end(),[&](int c) {
        fn(c*grain,std::min(count,(c+1)*grain));
    });
}

inline std::uint32_t HashCell(int x,int y,int z) {
    return static_cast<std::uint32_t>(x)*73856093u^static_cast<std::uint32_t>(y)*19349663u^static_cast<std::uint32_t>(z)*83492791u;
}
inline std::uint64_t PackCell(int x,int y,int z) {
    constexpr std::int64_t bias=1<<20;
    return (static_cast<std::uint64_t>(x+bias)&0x1fffff)|((static_cast<std::uint64_t>(y+bias)&0x1fffff)<<21)|
        ((static_cast<std::uint64_t>(z+bias)&0x1fffff)<<42);
}

Vec3 ClosestOnTriangle(Vec3 p,Vec3 a,Vec3 b,Vec3 c) {
    const Vec3 ab=b-a,ac=c-a,ap=p-a;
    const float d1=Dot(ab,ap),d2=Dot(ac,ap);
    if(d1<=0 && d2<=0) return a;
    const Vec3 bp=p-b; const float d3=Dot(ab,bp),d4=Dot(ac,bp);
    if(d3>=0 && d4<=d3) return b;
    const float vc=d1*d4-d3*d2;
    if(vc<=0 && d1>=0 && d3<=0) return a+ab*(d1/(d1-d3));
    const Vec3 cp=p-c; const float d5=Dot(ab,cp),d6=Dot(ac,cp);
    if(d6>=0 && d5<=d6) return c;
    const float vb=d5*d2-d1*d6;
    if(vb<=0 && d2>=0 && d6<=0) return a+ac*(d2/(d2-d6));
    const float va=d3*d6-d5*d4;
    if(va<=0 && (d4-d3)>=0 && (d5-d6)>=0) return b+(c-b)*((d4-d3)/((d4-d3)+(d5-d6)));
    const float denom=1.0f/(va+vb+vc);
    return a+ab*(vb*denom)+ac*(vc*denom);
}

bool SegmentTriangle(Vec3 from,Vec3 to,Vec3 a,Vec3 b,Vec3 c,float& t) {
    const Vec3 dir=to-from,e1=b-a,e2=c-a,pv=Cross(dir,e2);
    const float det=Dot(e1,pv);
    if(std::fabs(det)<1e-12f) return false;
    const float inv=1.0f/det; const Vec3 tv=from-a;
    const float u=Dot(tv,pv)*inv; if(u<0 || u>1) return false;
    const Vec3 qv=Cross(tv,e1);
    const float v=Dot(dir,qv)*inv; if(v<0 || u+v>1) return false;
    t=Dot(e2,qv)*inv;
    return t>=0 && t<=1;
}
} // namespace

std::array<float,4> ExtractRotation(const float a[9],std::array<float,4> q,int iterations) {
    // Müller et al. 2016, "A Robust Method to Extract the Rotational Part of Deformations".
    const Vec3 a0{a[0],a[1],a[2]},a1{a[3],a[4],a[5]},a2{a[6],a[7],a[8]};
    for(int i=0;i<iterations;++i) {
        const Vec3 r0=Rotate(q,{1,0,0}),r1=Rotate(q,{0,1,0}),r2=Rotate(q,{0,0,1});
        const Vec3 omegaNum=Cross(r0,a0)+Cross(r1,a1)+Cross(r2,a2);
        const float omegaDen=std::fabs(Dot(r0,a0)+Dot(r1,a1)+Dot(r2,a2))+1e-9f;
        const Vec3 omega=omegaNum*(1.0f/omegaDen);
        const float w=Length(omega);
        if(w<1e-9f) break;
        const Vec3 axis=omega*(1.0f/w);
        const float s=std::sin(w*0.5f);
        q=Normalize(Multiply(Quat{axis.x*s,axis.y*s,axis.z*s,std::cos(w*0.5f)},q));
    }
    return q;
}

std::array<float,4> QuaternionFromMatrix(const float m[9]) { return FromMatrixImpl(m); }

float LatticeRestDensity(float radius,float spacing) {
    // Density of a cubic lattice at the requested spacing, as FleX does, so a
    // fluid at rest stays at its authored particle spacing.
    if(radius<=0 || spacing<=0) return 1;
    const float h2=radius*radius,poly6=315.0f/(64.0f*Pi*std::pow(radius,9.0f));
    const int n=static_cast<int>(std::ceil(radius/spacing));
    double sum=0;
    for(int x=-n;x<=n;++x) for(int y=-n;y<=n;++y) for(int z=-n;z<=n;++z) {
        const float r2=(x*x+y*y+z*z)*spacing*spacing;
        if(r2<h2) { const float d=h2-r2; sum+=poly6*d*d*d; }
    }
    return static_cast<float>(sum);
}

Solver::Solver(int maxParticles):maxParticles_(std::max(maxParticles,1)) {
    position_.assign(maxParticles_,{0,0,0,0});
    velocity_.assign(maxParticles_,{});
    phase_.assign(maxParticles_,0);
    normal_.assign(maxParticles_,{0,0,0,0});
    density_.assign(maxParticles_,0);
    structural_.assign(maxParticles_,0);
    predicted_.assign(maxParticles_,{});
    previous_.assign(maxParticles_,{});
    lambda_.assign(maxParticles_,0);
    contact_.assign(maxParticles_,{});
    neighborCount_.assign(maxParticles_,0);
    neighbors_.assign(static_cast<std::size_t>(maxParticles_)*MaxNeighbors,0);
    params_.numIterations=3; params_.gravity[2]=-1000; params_.radius=15;
    params_.solidRestDistance=15; params_.fluidRestDistance=7.5f; params_.relaxationFactor=1;
    params_.maxSpeed=5000; params_.relaxationMode=1;
    RebuildKernel();
}

void Solver::RebuildKernel() {
    kernelRadius_=std::max(params_.radius,1e-3f);
    poly6_=315.0f/(64.0f*Pi*std::pow(kernelRadius_,9.0f));
    spikyGradient_=-45.0f/(Pi*std::pow(kernelRadius_,6.0f));
    const float spacing=params_.fluidRestDistance>0?params_.fluidRestDistance:kernelRadius_*0.5f;
    restDensity_=std::max(LatticeRestDensity(kernelRadius_,spacing),1e-12f);
}

void Solver::SetParams(const Params& params) {
    const bool kernel=params.radius!=params_.radius || params.fluidRestDistance!=params_.fluidRestDistance;
    params_=params;
    if(params_.numIterations<1) params_.numIterations=1;
    if(params_.numIterations>8) params_.numIterations=8;
    if(params_.relaxationFactor<=0) params_.relaxationFactor=1;
    if(kernel) RebuildKernel();
}

void Solver::SetActive(const int* indices,int count) {
    active_.clear();
    if(!indices || count<=0) return;
    active_.reserve(std::min(count,maxParticles_));
    for(int i=0;i<count && i<maxParticles_;++i)
        if(indices[i]>=0 && indices[i]<maxParticles_) active_.push_back(indices[i]);
}
void Solver::GetActive(int* indices) const { if(indices) std::copy(active_.begin(),active_.end(),indices); }
void Solver::SetParticles(const float* xyzw,int count) {
    if(!xyzw) return;
    std::memcpy(position_.data(),xyzw,sizeof(float)*4*std::min(count,maxParticles_));
}
void Solver::GetParticles(float* xyzw,int count) const {
    if(!xyzw) return;
    std::memcpy(xyzw,position_.data(),sizeof(float)*4*std::min(count,maxParticles_));
}
void Solver::SetVelocities(const float* xyz,int count) {
    if(!xyz) return;
    std::memcpy(velocity_.data(),xyz,sizeof(float)*3*std::min(count,maxParticles_));
}
void Solver::GetVelocities(float* xyz,int count) const {
    if(!xyz) return;
    std::memcpy(xyz,velocity_.data(),sizeof(float)*3*std::min(count,maxParticles_));
}
void Solver::SetPhases(const int* phases,int count) {
    if(!phases) return;
    std::memcpy(phase_.data(),phases,sizeof(int)*std::min(count,maxParticles_));
}
void Solver::GetPhases(int* phases,int count) const {
    if(!phases) return;
    std::memcpy(phases,phase_.data(),sizeof(int)*std::min(count,maxParticles_));
}
void Solver::SetNormals(const float* xyzw,int count) {
    if(!xyzw) return;
    std::memcpy(normal_.data(),xyzw,sizeof(float)*4*std::min(count,maxParticles_));
}
void Solver::GetNormals(float* xyzw,int count) const {
    if(!xyzw) return;
    std::memcpy(xyzw,normal_.data(),sizeof(float)*4*std::min(count,maxParticles_));
}
void Solver::GetDensities(float* densities,int count) const {
    if(!densities) return;
    std::memcpy(densities,density_.data(),sizeof(float)*std::min(count,maxParticles_));
}
void Solver::GetBounds(float* lower,float* upper) const {
    if(lower) { lower[0]=lower_.x; lower[1]=lower_.y; lower[2]=lower_.z; }
    if(upper) { upper[0]=upper_.x; upper[1]=upper_.y; upper[2]=upper_.z; }
}

void Solver::SetSprings(const int* pairs,const float* restLengths,const float* stiffness,int count) {
    springPairs_.clear(); springRest_.clear(); springStiffness_.clear();
    if(!pairs || count<=0) return;
    for(int i=0;i<count;++i) {
        const int a=pairs[2*i],b=pairs[2*i+1];
        if(a<0 || b<0 || a>=maxParticles_ || b>=maxParticles_) continue;
        springPairs_.push_back(a); springPairs_.push_back(b);
        springRest_.push_back(restLengths?restLengths[i]:0);
        springStiffness_.push_back(stiffness?std::clamp(stiffness[i],0.0f,1.0f):1.0f);
    }
}

void Solver::SetRigids(const int* offsets,const int* indices,const float* restPositions,const float* stiffness,
    const float* rotations,const float* translations,int rigidCount) {
    rigids_.clear(); rigidIndices_.clear(); rigidRest_.clear();
    if(!offsets || !indices || !restPositions || rigidCount<=0) return;
    const int total=offsets[rigidCount];
    rigidIndices_.assign(indices,indices+total);
    rigidRest_.resize(total);
    for(int i=0;i<total;++i) rigidRest_[i]={restPositions[3*i],restPositions[3*i+1],restPositions[3*i+2]};
    rigids_.resize(rigidCount);
    for(int r=0;r<rigidCount;++r) {
        auto& rigid=rigids_[r];
        rigid.begin=offsets[r]; rigid.end=offsets[r+1];
        rigid.stiffness=stiffness?std::clamp(stiffness[r],0.0f,1.0f):1.0f;
        if(rotations) rigid.rotation=Normalize({rotations[4*r],rotations[4*r+1],rotations[4*r+2],rotations[4*r+3]});
        if(translations) rigid.translation={translations[3*r],translations[3*r+1],translations[3*r+2]};
    }
}

void Solver::GetRigidTransforms(float* rotations,float* translations) const {
    for(std::size_t r=0;r<rigids_.size();++r) {
        const auto& rigid=rigids_[r];
        if(rotations) {
            // Column-major 3x3, as KFGame reads it.
            const Vec3 c0=Rotate(rigid.rotation,{1,0,0}),c1=Rotate(rigid.rotation,{0,1,0}),c2=Rotate(rigid.rotation,{0,0,1});
            float* m=rotations+9*r;
            m[0]=c0.x; m[1]=c0.y; m[2]=c0.z; m[3]=c1.x; m[4]=c1.y; m[5]=c1.z; m[6]=c2.x; m[7]=c2.y; m[8]=c2.z;
        }
        if(translations) {
            translations[3*r]=rigid.translation.x; translations[3*r+1]=rigid.translation.y; translations[3*r+2]=rigid.translation.z;
        }
    }
}

void Solver::SetDynamicTriangles(const int* indices,int triangleCount) {
    triangles_.clear();
    if(indices && triangleCount>0) triangles_.assign(indices,indices+3*triangleCount);
}

void Solver::SetTriangles(const float* vertices,int triangleCount,float cellSize) {
    worldVertices_.clear(); worldNormals_.clear();
    triCellKeys_.clear(); triCellStart_.clear(); triCellItems_.clear();
    if(!vertices || triangleCount<=0) return;
    worldVertices_.resize(static_cast<std::size_t>(triangleCount)*3);
    worldNormals_.resize(triangleCount);
    for(int t=0;t<triangleCount;++t) {
        for(int k=0;k<3;++k) {
            const float* v=vertices+4*(3*t+k);
            worldVertices_[3*t+k]={v[0],v[1],v[2]};
        }
        const Vec3 n=Cross(worldVertices_[3*t+1]-worldVertices_[3*t],worldVertices_[3*t+2]-worldVertices_[3*t]);
        const float length=Length(n);
        worldNormals_[t]=length>1e-12f?n*(1.0f/length):Vec3{0,0,1};
    }
    triCellSize_=std::max({cellSize,params_.radius*2.0f,1.0f});
    const float inv=1.0f/triCellSize_;
    std::vector<std::pair<std::uint64_t,int>> pairs;
    pairs.reserve(static_cast<std::size_t>(triangleCount)*4);
    for(int t=0;t<triangleCount;++t) {
        const Vec3 lo=Min(Min(worldVertices_[3*t],worldVertices_[3*t+1]),worldVertices_[3*t+2]);
        const Vec3 hi=Max(Max(worldVertices_[3*t],worldVertices_[3*t+1]),worldVertices_[3*t+2]);
        const int x0=static_cast<int>(std::floor(lo.x*inv)),x1=static_cast<int>(std::floor(hi.x*inv));
        const int y0=static_cast<int>(std::floor(lo.y*inv)),y1=static_cast<int>(std::floor(hi.y*inv));
        const int z0=static_cast<int>(std::floor(lo.z*inv)),z1=static_cast<int>(std::floor(hi.z*inv));
        // Very large triangles (floors) span many cells; cap the fan-out.
        if(static_cast<long long>(x1-x0+1)*(y1-y0+1)*(z1-z0+1)>4096) {
            pairs.emplace_back(~0ull,t); continue;
        }
        for(int x=x0;x<=x1;++x) for(int y=y0;y<=y1;++y) for(int z=z0;z<=z1;++z) pairs.emplace_back(PackCell(x,y,z),t);
    }
    std::sort(pairs.begin(),pairs.end());
    std::vector<std::uint64_t> keys;
    for(std::size_t i=0;i<pairs.size();++i) {
        if(i==0 || pairs[i].first!=pairs[i-1].first) { keys.push_back(pairs[i].first); triCellStart_.push_back(static_cast<int>(i)); }
        triCellItems_.push_back(pairs[i].second);
    }
    triCellStart_.push_back(static_cast<int>(pairs.size()));
    // Store 64-bit keys split over two 32-bit lanes to keep the header lean.
    triCellKeys_.resize(keys.size()*2);
    for(std::size_t i=0;i<keys.size();++i) {
        triCellKeys_[2*i]=static_cast<std::uint32_t>(keys[i]); triCellKeys_[2*i+1]=static_cast<std::uint32_t>(keys[i]>>32);
    }
}

void Solver::SetConvexes(const float* aabbMin,const float* aabbMax,const int* planeOffsets,const int* planeCounts,
    const float* planes,const float* positions,const float* rotations,const int*,int convexCount,int planeCount) {
    convexes_.clear(); convexPlanes_.clear();
    if(convexCount<=0 || planeCount<=0 || !aabbMin || !aabbMax || !planeOffsets || !planeCounts || !planes ||
       !positions || !rotations) return;
    convexPlanes_.resize(planeCount);
    std::memcpy(convexPlanes_.data(),planes,sizeof(float)*4*planeCount);
    convexes_.resize(convexCount);
    for(int c=0;c<convexCount;++c) {
        auto& convex=convexes_[c];
        convex.lower={aabbMin[4*c],aabbMin[4*c+1],aabbMin[4*c+2]};
        convex.upper={aabbMax[4*c],aabbMax[4*c+1],aabbMax[4*c+2]};
        convex.position={positions[4*c],positions[4*c+1],positions[4*c+2]};
        convex.rotation=Normalize({rotations[4*c],rotations[4*c+1],rotations[4*c+2],rotations[4*c+3]});
        convex.planeBegin=std::clamp(planeOffsets[c],0,planeCount);
        convex.planeCount=std::clamp(planeCounts[c],0,planeCount-convex.planeBegin);
    }
}

void Solver::SetForceFields(const ForceField* fields,int count) {
    forceFields_.clear();
    if(fields && count>0) forceFields_.assign(fields,fields+count);
}

void Solver::ApplyForceFields(float h) {
    if(forceFields_.empty()) return;
    const float cap=params_.maxSpeed;
    ParallelFor(static_cast<int>(active_.size()),1024,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(position_[i][3]<=0) continue;
            Vec3 force{};
            for(const auto& field:forceFields_) force+=FieldForce(field,Xyz(position_[i]),h);
            Vec3 delta=force*(h*position_[i][3]);
            const float squared=Dot(delta,delta);
            if(squared>cap*cap) delta=delta*(cap/std::sqrt(squared));
            velocity_[i]+=delta;
        }
    });
}

bool Solver::IsFluid(int index) const {
    if(structural_[index]) return false;
    const auto phase=static_cast<std::uint32_t>(phase_[index]);
    return (phase&PhaseFluid)!=0 || (params_.fluid && (phase&PhaseGroupMask)==0);
}

bool Solver::Collide(int a,int b) const {
    const auto pa=static_cast<std::uint32_t>(phase_[a]),pb=static_cast<std::uint32_t>(phase_[b]);
    if((pa&PhaseGroupMask)!=(pb&PhaseGroupMask)) return true;
    return (pa&PhaseSelfCollide)!=0;
}

void Solver::Update(float dt,int substeps) {
    if(active_.empty() || !(dt>0)) return;
    // Fluid membership: particles owned by rigids or springs are structural.
    std::fill(structural_.begin(),structural_.end(),std::uint8_t{0});
    for(int i:rigidIndices_) if(i>=0 && i<maxParticles_) structural_[i]=1;
    for(int i:springPairs_) structural_[i]=1;
    const int requestedSubsteps=std::max(substeps,1);
    substeps=std::clamp(substeps,1,8);
    const float h=std::min(dt,0.1f)/substeps;
    // flexUpdateSolver applies fields once before the substep loop, using
    // the substep duration and maxSpeed as its delta-velocity magnitude cap.
    ApplyForceFields(dt/requestedSubsteps);
    for(int s=0;s<substeps;++s) Step(h);
    ComputeOutputs();
}

void Solver::BuildNeighbors() {
    const int count=static_cast<int>(active_.size());
    cellSize_=kernelRadius_;
    const float inv=1.0f/cellSize_;
    std::uint32_t table=1;
    while(table<static_cast<std::uint32_t>(count)*2) table<<=1;
    const std::uint32_t mask=table-1;
    cellKey_.resize(count);
    ParallelFor(count,1024,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const Vec3 p=predicted_[active_[k]];
            cellKey_[k]=HashCell(static_cast<int>(std::floor(p.x*inv)),static_cast<int>(std::floor(p.y*inv)),
                static_cast<int>(std::floor(p.z*inv)))&mask;
        }
    });
    cellStart_.assign(table+1,0);
    for(int k=0;k<count;++k) ++cellStart_[cellKey_[k]+1];
    for(std::uint32_t c=0;c<table;++c) cellStart_[c+1]+=cellStart_[c];
    cellEnd_.assign(cellStart_.begin(),cellStart_.end()-1);
    sorted_.resize(count);
    for(int k=0;k<count;++k) sorted_[cellEnd_[cellKey_[k]]++]=active_[k];
    const float h2=kernelRadius_*kernelRadius_;
    ParallelFor(count,256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            const Vec3 p=predicted_[i];
            const int cx=static_cast<int>(std::floor(p.x*inv)),cy=static_cast<int>(std::floor(p.y*inv)),cz=static_cast<int>(std::floor(p.z*inv));
            int* out=&neighbors_[static_cast<std::size_t>(i)*MaxNeighbors];
            int n=0;
            for(int dx=-1;dx<=1 && n<MaxNeighbors;++dx) for(int dy=-1;dy<=1 && n<MaxNeighbors;++dy) for(int dz=-1;dz<=1 && n<MaxNeighbors;++dz) {
                const std::uint32_t cell=HashCell(cx+dx,cy+dy,cz+dz)&mask;
                for(int s=cellStart_[cell];s<cellStart_[cell+1] && n<MaxNeighbors;++s) {
                    const int j=sorted_[s];
                    if(j==i) continue;
                    const Vec3 d=p-predicted_[j];
                    if(Dot(d,d)<h2) {
                        // Hash collisions can list a particle twice; skip repeats.
                        bool seen=false;
                        for(int q=0;q<n;++q) if(out[q]==j) { seen=true; break; }
                        if(!seen) out[n++]=j;
                    }
                }
            }
            neighborCount_[i]=n;
        }
    });
}

void Solver::ComputeDensities() {
    const int count=static_cast<int>(active_.size());
    const float h2=kernelRadius_*kernelRadius_;
    const float invRest=1.0f/restDensity_;
    const float solidWeight=std::max(params_.solidPressure,0.0f);
    const float epsilon=1e-2f/(kernelRadius_*kernelRadius_);
    ParallelFor(count,256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(!IsFluid(i)) { density_[i]=0; lambda_[i]=0; continue; }
            const Vec3 p=predicted_[i];
            float rho=poly6_*h2*h2*h2;
            Vec3 gradI{};
            float sumGrad2=0;
            const int* list=&neighbors_[static_cast<std::size_t>(i)*MaxNeighbors];
            for(int n=0;n<neighborCount_[i];++n) {
                const int j=list[n];
                const Vec3 d=p-predicted_[j];
                const float r2=Dot(d,d);
                if(r2>=h2) continue;
                const float weight=IsFluid(j)?1.0f:solidWeight;
                if(weight<=0) continue;
                const float w=h2-r2;
                rho+=weight*poly6_*w*w*w;
                const float r=std::sqrt(r2);
                if(r>1e-6f) {
                    const float g=kernelRadius_-r;
                    const Vec3 grad=d*(spikyGradient_*g*g/r*invRest*weight);
                    gradI-=grad;
                    sumGrad2+=Dot(grad,grad);
                }
            }
            sumGrad2+=Dot(gradI,gradI);
            density_[i]=rho*invRest;
            // Unilateral: fluids only resist compression; cohesion handles the surface.
            const float constraint=std::max(density_[i]-1.0f,0.0f);
            lambda_[i]=-constraint/(sumGrad2+epsilon);
        }
    });
}

void Solver::SolveFluid(std::vector<Vec3>& delta) const {
    const int count=static_cast<int>(active_.size());
    const float h2=kernelRadius_*kernelRadius_;
    const float invRest=1.0f/restDensity_;
    const float solidWeight=std::max(params_.solidPressure,0.0f);
    ParallelFor(count,256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(!IsFluid(i) || position_[i][3]<=0) continue;
            const Vec3 p=predicted_[i];
            Vec3 sum{};
            const int* list=&neighbors_[static_cast<std::size_t>(i)*MaxNeighbors];
            for(int n=0;n<neighborCount_[i];++n) {
                const int j=list[n];
                const Vec3 d=p-predicted_[j];
                const float r2=Dot(d,d);
                if(r2>=h2) continue;
                const float r=std::sqrt(r2);
                if(r<1e-6f) continue;
                const float g=kernelRadius_-r;
                const Vec3 grad=d*(spikyGradient_*g*g/r);
                if(IsFluid(j)) sum+=grad*(lambda_[i]+lambda_[j]);
                else if(solidWeight>0) sum+=grad*(lambda_[i]*solidWeight);
            }
            delta[i]+=sum*invRest;
        }
    });
}

void Solver::SolveContacts(std::vector<Vec3>& delta) const {
    const int count=static_cast<int>(active_.size());
    const float rest=std::max(params_.solidRestDistance,1e-3f);
    const float friction=std::clamp(params_.particleFriction,0.0f,1.0f);
    ParallelFor(count,256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            const float wi=position_[i][3];
            if(wi<=0) continue;
            const bool fluidI=IsFluid(i);
            const Vec3 p=predicted_[i];
            Vec3 sum{}; int contacts=0;
            const int* list=&neighbors_[static_cast<std::size_t>(i)*MaxNeighbors];
            for(int n=0;n<neighborCount_[i];++n) {
                const int j=list[n];
                if(fluidI && IsFluid(j)) continue;
                if(!Collide(i,j)) continue;
                const Vec3 d=p-predicted_[j];
                const float r2=Dot(d,d);
                if(r2>=rest*rest) continue;
                const float r=std::sqrt(r2);
                const float wj=position_[j][3];
                const float share=wi/(wi+wj);
                const Vec3 normal=r>1e-6f?d*(1.0f/r):Vec3{0,0,1};
                const float depth=rest-r;
                Vec3 correction=normal*(depth*share);
                if(friction>0) {
                    // Remove a share of the relative tangential motion this substep.
                    const Vec3 relative=(p-previous_[i])-(predicted_[j]-previous_[j]);
                    const Vec3 tangent=relative-normal*Dot(relative,normal);
                    const float length=Length(tangent);
                    if(length>1e-6f) correction-=tangent*(share*std::min(friction*depth/length,1.0f));
                }
                sum+=correction; ++contacts;
            }
            if(contacts) {
                const float scale=params_.relaxationMode==1?params_.relaxationFactor/contacts:params_.relaxationFactor;
                delta[i]+=sum*scale;
            }
        }
    });
}

void Solver::SolveSprings() {
    for(std::size_t s=0;s<springRest_.size();++s) {
        const int a=springPairs_[2*s],b=springPairs_[2*s+1];
        const float wa=position_[a][3],wb=position_[b][3];
        if(wa+wb<=0) continue;
        const Vec3 d=predicted_[a]-predicted_[b];
        const float length=Length(d);
        if(length<1e-6f) continue;
        const Vec3 correction=d*((length-springRest_[s])/(length*(wa+wb))*springStiffness_[s]);
        predicted_[a]-=correction*wa;
        predicted_[b]+=correction*wb;
    }
}

void Solver::SolveShapes() {
    ParallelFor(static_cast<int>(rigids_.size()),8,[&](int begin,int end) {
        for(int r=begin;r<end;++r) {
            auto& rigid=rigids_[r];
            if(rigid.end<=rigid.begin) continue;
            Vec3 centre{}; float mass=0;
            for(int k=rigid.begin;k<rigid.end;++k) {
                const int i=rigidIndices_[k];
                const float w=position_[i][3];
                const float m=w>0?1.0f/w:1e6f;
                centre+=predicted_[i]*m; mass+=m;
            }
            centre=centre*(1.0f/mass);
            float a[9]{};
            for(int k=rigid.begin;k<rigid.end;++k) {
                const int i=rigidIndices_[k];
                const float w=position_[i][3];
                const float m=w>0?1.0f/w:1e6f;
                const Vec3 p=(predicted_[i]-centre)*m,q=rigidRest_[k];
                // a = sum m (p-c) q^T, column-major.
                a[0]+=p.x*q.x; a[1]+=p.y*q.x; a[2]+=p.z*q.x;
                a[3]+=p.x*q.y; a[4]+=p.y*q.y; a[5]+=p.z*q.y;
                a[6]+=p.x*q.z; a[7]+=p.y*q.z; a[8]+=p.z*q.z;
            }
            rigid.rotation=ExtractRotation(a,rigid.rotation,6);
            rigid.translation=centre;
            for(int k=rigid.begin;k<rigid.end;++k) {
                const int i=rigidIndices_[k];
                if(position_[i][3]<=0) continue;
                const Vec3 goal=centre+Rotate(rigid.rotation,rigidRest_[k]);
                predicted_[i]+=(goal-predicted_[i])*rigid.stiffness;
            }
        }
    });
}

void Solver::CollideTriangles(int index,Vec3& predicted,const Vec3& previous,ParticleContact& contact) const {
    if(worldNormals_.empty()) return;
    const bool fluid=IsFluid(index);
    const float distance=std::max(params_.collisionDistance,
        0.5f*(fluid?std::max(params_.fluidRestDistance,1e-3f):std::max(params_.solidRestDistance,1e-3f)));
    const float inv=1.0f/triCellSize_;
    const Vec3 lo=Min(previous,predicted)-Vec3{distance,distance,distance};
    const Vec3 hi=Max(previous,predicted)+Vec3{distance,distance,distance};
    int x0=static_cast<int>(std::floor(lo.x*inv)),x1=static_cast<int>(std::floor(hi.x*inv));
    int y0=static_cast<int>(std::floor(lo.y*inv)),y1=static_cast<int>(std::floor(hi.y*inv));
    int z0=static_cast<int>(std::floor(lo.z*inv)),z1=static_cast<int>(std::floor(hi.z*inv));
    if(static_cast<long long>(x1-x0+1)*(y1-y0+1)*(z1-z0+1)>64) {
        // A very fast particle: only the cells around its end point.
        x0=x1=static_cast<int>(std::floor(predicted.x*inv));
        y0=y1=static_cast<int>(std::floor(predicted.y*inv));
        z0=z1=static_cast<int>(std::floor(predicted.z*inv));
        --x0; --y0; --z0; ++x1; ++y1; ++z1;
    }
    const int cellCount=static_cast<int>(triCellKeys_.size()/2);
    const auto find=[&](std::uint64_t key)->int {
        int lo2=0,hi2=cellCount;
        while(lo2<hi2) {
            const int mid=(lo2+hi2)/2;
            const std::uint64_t k=static_cast<std::uint64_t>(triCellKeys_[2*mid])|(static_cast<std::uint64_t>(triCellKeys_[2*mid+1])<<32);
            if(k<key) lo2=mid+1; else hi2=mid;
        }
        if(lo2<cellCount) {
            const std::uint64_t k=static_cast<std::uint64_t>(triCellKeys_[2*lo2])|(static_cast<std::uint64_t>(triCellKeys_[2*lo2+1])<<32);
            if(k==key) return lo2;
        }
        return -1;
    };
    int visited[64]; int visitedCount=0;
    float depthTotal=0; Vec3 lastNormal{};
    const auto test=[&](int t) {
        for(int v=0;v<visitedCount;++v) if(visited[v]==t) return;
        if(visitedCount<64) visited[visitedCount++]=t;
        const Vec3 a=worldVertices_[3*t],b=worldVertices_[3*t+1],c=worldVertices_[3*t+2];
        const Vec3 faceNormal=worldNormals_[t];
        const float sidePrevious=Dot(previous-a,faceNormal);
        const float side=sidePrevious>=0?1.0f:-1.0f;
        float hit=0;
        if(params_.enableCcd>0 || Length(predicted-previous)>distance) {
            if(SegmentTriangle(previous,predicted,a,b,c,hit)) {
                const Vec3 point=previous+(predicted-previous)*hit;
                const Vec3 resolved=point+faceNormal*(side*distance);
                depthTotal+=Length(resolved-predicted);
                predicted=resolved; lastNormal=faceNormal*side; contact.touching=true;
            }
        }
        const Vec3 q=ClosestOnTriangle(predicted,a,b,c);
        const Vec3 d=predicted-q;
        const float dist=Length(d);
        if(dist>=distance) return;
        Vec3 normal=faceNormal*side;
        if(dist>1e-5f) {
            const Vec3 feature=d*(1.0f/dist);
            // Keep the side the particle came from; a feature normal that
            // points through the surface means it already crossed.
            if(Dot(feature,faceNormal)*side>-1e-3f) normal=feature;
        }
        const Vec3 resolved=q+normal*distance;
        depthTotal+=Length(resolved-predicted);
        predicted=resolved; lastNormal=normal; contact.touching=true;
    };
    for(int x=x0;x<=x1;++x) for(int y=y0;y<=y1;++y) for(int z=z0;z<=z1;++z) {
        const int cell=find(PackCell(x,y,z));
        if(cell<0) continue;
        for(int s=triCellStart_[cell];s<triCellStart_[cell+1];++s) test(triCellItems_[s]);
    }
    const int oversized=find(~0ull);
    if(oversized>=0) for(int s=triCellStart_[oversized];s<triCellStart_[oversized+1];++s) test(triCellItems_[s]);
    if(contact.touching && depthTotal>0) {
        contact.normal=lastNormal; contact.depth=depthTotal;
        // Coulomb friction on the substep displacement (Macklin et al. 2014).
        const Vec3 moved=predicted-previous;
        const Vec3 tangent=moved-lastNormal*Dot(moved,lastNormal);
        const float length=Length(tangent);
        if(length>1e-6f) {
            if(length<params_.staticFriction*depthTotal) predicted-=tangent;
            else predicted-=tangent*std::min(params_.dynamicFriction*depthTotal/length,1.0f);
        }
    }
}

void Solver::CollideConvexes(int index,Vec3& predicted,ParticleContact& contact) const {
    if(convexes_.empty()) return;
    const bool fluid=IsFluid(index);
    const float distance=std::max(params_.collisionDistance,
        0.5f*(fluid?std::max(params_.fluidRestDistance,1e-3f):std::max(params_.solidRestDistance,1e-3f)));
    for(const auto& convex:convexes_) {
        if(predicted.x<convex.lower.x-distance || predicted.y<convex.lower.y-distance || predicted.z<convex.lower.z-distance ||
           predicted.x>convex.upper.x+distance || predicted.y>convex.upper.y+distance || predicted.z>convex.upper.z+distance) continue;
        const Vec3 local=RotateInverse(convex.rotation,predicted-convex.position);
        float best=-1e30f; int bestPlane=-1;
        for(int p=0;p<convex.planeCount;++p) {
            const auto& plane=convexPlanes_[convex.planeBegin+p];
            const float d=plane[0]*local.x+plane[1]*local.y+plane[2]*local.z+plane[3];
            if(d>best) { best=d; bestPlane=p; }
        }
        if(bestPlane<0 || best>=distance) continue;
        const auto& plane=convexPlanes_[convex.planeBegin+bestPlane];
        const Vec3 n{plane[0],plane[1],plane[2]};
        const Vec3 resolved=convex.position+Rotate(convex.rotation,local+n*(distance-best));
        contact.depth+=Length(resolved-predicted);
        predicted=resolved;
        contact.normal=Rotate(convex.rotation,n); contact.touching=true;
    }
}

void Solver::SolveWorld(float) {
    ParallelFor(static_cast<int>(active_.size()),256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(position_[i][3]<=0) continue;
            Vec3 p=predicted_[i];
            CollideTriangles(i,p,previous_[i],contact_[i]);
            CollideConvexes(i,p,contact_[i]);
            for(int plane=0;plane<std::clamp(params_.numPlanes,0,8);++plane) {
                const float* pl=params_.planes[plane];
                const float d=pl[0]*p.x+pl[1]*p.y+pl[2]*p.z+pl[3];
                const float distance=std::max(params_.collisionDistance,0.5f*params_.solidRestDistance);
                if(d<distance) { p+=Vec3{pl[0],pl[1],pl[2]}*(distance-d); contact_[i].touching=true; contact_[i].normal={pl[0],pl[1],pl[2]}; }
            }
            predicted_[i]=p;
        }
    });
}

void Solver::ApplyFluidVelocityTerms(float h) {
    const int count=static_cast<int>(active_.size());
    const float viscosity=std::clamp(params_.viscosity,0.0f,1.0f);
    const float cohesion=std::max(params_.cohesion,0.0f);
    const float adhesion=std::clamp(params_.adhesion,0.0f,1.0f);
    const float rest=std::max(params_.fluidRestDistance,1e-3f);
    const float h2=kernelRadius_*kernelRadius_;
    if(viscosity<=0 && cohesion<=0 && adhesion<=0) return;
    auto& next=scratchVelocity_;
    next.resize(velocity_.size());
    ParallelFor(count,256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            Vec3 v=velocity_[i];
            if(IsFluid(i) && position_[i][3]>0) {
                const Vec3 p=predicted_[i];
                Vec3 smooth{}; float weightSum=0; Vec3 pull{}; int pulled=0;
                const int* list=&neighbors_[static_cast<std::size_t>(i)*MaxNeighbors];
                for(int n=0;n<neighborCount_[i];++n) {
                    const int j=list[n];
                    if(!IsFluid(j)) continue;
                    const Vec3 d=predicted_[j]-p;
                    const float r2=Dot(d,d);
                    if(r2>=h2) continue;
                    const float w=h2-r2,weight=w*w*w;
                    smooth+=(velocity_[j]-v)*weight; weightSum+=weight;
                    const float r=std::sqrt(r2);
                    if(r>1e-6f) { pull+=d*((r-rest)/r*(1.0f-r/kernelRadius_)); ++pulled; }
                }
                if(weightSum>0) v+=smooth*(viscosity/weightSum);
                if(pulled) v+=pull*(cohesion/(h*pulled));
                const auto& contact=contact_[i];
                if(contact.touching && adhesion>0) {
                    // Stick to the surface it touched: damp separation and sliding.
                    const float vn=Dot(v,contact.normal);
                    if(vn>0) v-=contact.normal*(vn*adhesion);
                    const Vec3 tangent=v-contact.normal*Dot(v,contact.normal);
                    v-=tangent*(adhesion*0.5f);
                }
            }
            next[i]=v;
        }
    });
    for(int i:active_) velocity_[i]=next[i];
}

void Solver::Step(float h) {
    const int count=static_cast<int>(active_.size());
    const Vec3 gravity{params_.gravity[0],params_.gravity[1],params_.gravity[2]};
    const float maxSpeed=params_.maxSpeed>0?params_.maxSpeed:1e9f;
    ParallelFor(count,1024,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            const Vec3 x=Xyz(position_[i]);
            previous_[i]=x;
            contact_[i]={};
            if(position_[i][3]<=0) { velocity_[i]={}; predicted_[i]=x; continue; }
            Vec3 v=velocity_[i]+gravity*h;
            const float speed=Length(v);
            if(speed>maxSpeed) v=v*(maxSpeed/speed);
            velocity_[i]=v;
            predicted_[i]=x+v*h;
        }
    });
    BuildNeighbors();
    bool anyFluid=false;
    for(int i:active_) if(IsFluid(i)) { anyFluid=true; break; }
    auto& delta=delta_;
    delta.resize(maxParticles_);
    for(int iteration=0;iteration<params_.numIterations;++iteration) {
        for(int i:active_) delta[i]={};
        if(anyFluid) { ComputeDensities(); SolveFluid(delta); }
        SolveContacts(delta);
        ParallelFor(count,1024,[&](int begin,int end) {
            for(int k=begin;k<end;++k) { const int i=active_[k]; if(position_[i][3]>0) predicted_[i]+=delta[i]; }
        });
        SolveSprings();
        SolveShapes();
        SolveWorld(h);
    }
    const float inv=1.0f/h;
    ParallelFor(count,1024,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(position_[i][3]<=0) continue;
            Vec3 v=(predicted_[i]-previous_[i])*inv;
            const auto& contact=contact_[i];
            const float normalLength=Length(contact.normal);
            if(contact.touching && normalLength>1e-6f) {
                const Vec3 normal=contact.normal*(1.0f/normalLength);
                // velocity_ still holds the incoming, gravity-integrated
                // velocity. Positional pushout is not an impact velocity:
                // reflecting it would add energy when resolving overlap.
                const float incoming=Dot(velocity_[i],normal);
                float outgoing=std::max(incoming,0.0f);
                // Gravity alone at a resting contact must not cause a bounce.
                const float gravityClosing=std::max(-Dot(gravity,normal)*h,0.0f);
                if(incoming < -gravityClosing-1e-4f)
                    outgoing=-std::clamp(params_.restitution,0.0f,1.0f)*incoming;
                // Preserve the tangential velocity after positional friction.
                // Separating particles retain their incoming normal speed;
                // neither restitution nor overlap correction amplifies it.
                v+=normal*(outgoing-Dot(v,normal));
            }
            const float speed=Length(v);
            if(speed>maxSpeed) v=v*(maxSpeed/speed);
            if(params_.dissipation>0 && contact_[i].touching) v=v*(1.0f/(1.0f+params_.dissipation*h));
            velocity_[i]=v;
        }
    });
    if(anyFluid) ApplyFluidVelocityTerms(h);
    ParallelFor(count,1024,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(position_[i][3]<=0) continue;
            if(params_.sleepThreshold>0 && Length(velocity_[i])<params_.sleepThreshold) {
                velocity_[i]={};
                // An inelastic impact can sleep immediately, but its solved
                // contact position must still resolve approach and overlap.
                if(!contact_[i].touching) continue;
            }
            position_[i][0]=predicted_[i].x; position_[i][1]=predicted_[i].y; position_[i][2]=predicted_[i].z;
        }
    });
}

void Solver::ComputeOutputs() {
    // Fluid surface normals point out of the fluid, from the density gradient.
    const float h2=kernelRadius_*kernelRadius_;
    ParallelFor(static_cast<int>(active_.size()),256,[&](int begin,int end) {
        for(int k=begin;k<end;++k) {
            const int i=active_[k];
            if(!IsFluid(i)) continue;
            const Vec3 p=Xyz(position_[i]);
            Vec3 gradient{};
            const int* list=&neighbors_[static_cast<std::size_t>(i)*MaxNeighbors];
            for(int n=0;n<neighborCount_[i];++n) {
                const int j=list[n];
                if(!IsFluid(j)) continue;
                const Vec3 d=p-Xyz(position_[j]);
                const float r2=Dot(d,d);
                if(r2>=h2 || r2<1e-12f) continue;
                const float r=std::sqrt(r2),g=kernelRadius_-r;
                gradient+=d*(g*g/r);
            }
            const float length=Length(gradient);
            if(length>1e-9f) gradient=gradient*(1.0f/length);
            normal_[i]={gradient.x,gradient.y,gradient.z,0};
        }
    });
    if(!triangles_.empty()) {
        for(std::size_t t=0;t+2<triangles_.size();t+=3)
            for(int k=0;k<3;++k) if(triangles_[t+k]>=0 && triangles_[t+k]<maxParticles_) normal_[triangles_[t+k]]={0,0,0,0};
        for(std::size_t t=0;t+2<triangles_.size();t+=3) {
            const int a=triangles_[t],b=triangles_[t+1],c=triangles_[t+2];
            if(a<0 || b<0 || c<0 || a>=maxParticles_ || b>=maxParticles_ || c>=maxParticles_) continue;
            const Vec3 n=Cross(Xyz(position_[b])-Xyz(position_[a]),Xyz(position_[c])-Xyz(position_[a]));
            for(int v:{a,b,c}) { normal_[v][0]+=n.x; normal_[v][1]+=n.y; normal_[v][2]+=n.z; }
        }
        for(std::size_t t=0;t+2<triangles_.size();t+=3) for(int k=0;k<3;++k) {
            const int v=triangles_[t+k];
            if(v<0 || v>=maxParticles_) continue;
            const float length=std::sqrt(normal_[v][0]*normal_[v][0]+normal_[v][1]*normal_[v][1]+normal_[v][2]*normal_[v][2]);
            if(length>1e-9f) { normal_[v][0]/=length; normal_[v][1]/=length; normal_[v][2]/=length; }
        }
    }
    Vec3 lo{1e30f,1e30f,1e30f},hi{-1e30f,-1e30f,-1e30f};
    for(int i:active_) { const Vec3 p=Xyz(position_[i]); lo=Min(lo,p); hi=Max(hi,p); }
    if(active_.empty()) lo=hi={};
    lower_=lo; upper_=hi;
}

} // namespace kf2vr::flex
