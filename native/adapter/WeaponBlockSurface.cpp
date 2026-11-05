#include "WeaponBlockSurface.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include "WeaponBlockSurfaceCatalog.h"

namespace kf2vr::adapter::weaponblock {
namespace {
Vec operator+(Vec a,Vec b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
Vec operator-(Vec a,Vec b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
Vec operator*(Vec a,float s){return {a.x*s,a.y*s,a.z*s};}
float Dot(Vec a,Vec b){return a.x*b.x+a.y*b.y+a.z*b.z;}
Vec Cross(Vec a,Vec b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
float Length(Vec a){return std::sqrt(Dot(a,a));}
Vec Unit(Vec a){return a*(1/std::max(Length(a),1e-8f));}
Vec Min(Vec a,Vec b){return {std::min(a.x,b.x),std::min(a.y,b.y),std::min(a.z,b.z)};}
Vec Max(Vec a,Vec b){return {std::max(a.x,b.x),std::max(a.y,b.y),std::max(a.z,b.z)};}
Vec Mix(Vec a,Vec b,float t){return a+(b-a)*t;}
Quat Inverse(Quat q){return {-q.x,-q.y,-q.z,q.w};}
Vec Rotate(Quat q,Vec v){Vec u{q.x,q.y,q.z};return v+Cross(u,Cross(u,v)+v*q.w)*2;}
bool Valid(Vec v){return std::isfinite(v.x)&&std::isfinite(v.y)&&std::isfinite(v.z);}
bool Normalize(Quat& q){
    const float n=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w;
    if(!std::isfinite(n)||n<0.5f||n>1.5f)return false;
    const float s=1/std::sqrt(n);q={q.x*s,q.y*s,q.z*s,q.w*s};return true;
}
Quat Mix(Quat a,Quat b,float t){
    float dot=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w;
    if(dot<0){b={-b.x,-b.y,-b.z,-b.w};dot=-dot;}
    if(dot<.9995f){
        float angle=std::acos(std::clamp(dot,0.f,1.f)),den=std::sin(angle);
        float x=std::sin((1-t)*angle)/den,y=std::sin(t*angle)/den;
        return {a.x*x+b.x*y,a.y*x+b.y*y,a.z*x+b.z*y,a.w*x+b.w*y};
    }
    Quat q{a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t,a.w+(b.w-a.w)*t};
    Normalize(q);return q;
}
float Angle(Quat a,Quat b){return 2*std::acos(std::clamp(std::abs(a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w),0.f,1.f));}
bool Inside(Vec p,const Triangle& t,Vec n){
    return Dot(Cross(t.b-t.a,p-t.a),n)>=-1e-5f && Dot(Cross(t.c-t.b,p-t.b),n)>=-1e-5f
        && Dot(Cross(t.a-t.c,p-t.c),n)>=-1e-5f;
}
float Segments(Vec a,Vec b,Vec c,Vec d,Vec& at){
    Vec u=b-a,v=d-c,w=a-c;float aa=Dot(u,u),bb=Dot(u,v),cc=Dot(v,v),dd=Dot(u,w),ee=Dot(v,w);
    float den=aa*cc-bb*bb,s=den>1e-8f?std::clamp((bb*ee-cc*dd)/den,0.f,1.f):0.f;
    float t=cc>1e-8f?(bb*s+ee)/cc:0.f;
    if(t<0){t=0;s=std::clamp(-dd/std::max(aa,1e-8f),0.f,1.f);}
    else if(t>1){t=1;s=std::clamp((bb-dd)/std::max(aa,1e-8f),0.f,1.f);}
    Vec p=a+u*s,q=c+v*t;at=(p+q)*0.5f;return Dot(p-q,p-q);
}
float SegmentFace(Vec p,Vec q,const Triangle& f,Vec& at){
    Vec n=Unit(Cross(f.b-f.a,f.c-f.a)),candidate;
    float dp=Dot(p-f.a,n),dq=Dot(q-f.a,n);
    if(dp*dq<=0&&std::abs(dp-dq)>1e-8f){candidate=p+(q-p)*(dp/(dp-dq));if(Inside(candidate,f,n)){at=candidate;return 0;}}
    float best=Segments(p,q,f.a,f.b,at),v=Segments(p,q,f.b,f.c,candidate);
    if(v<best){best=v;at=candidate;}v=Segments(p,q,f.c,f.a,candidate);if(v<best){best=v;at=candidate;}
    candidate=p-n*dp;if(dp*dp<best&&Inside(candidate,f,n)){best=dp*dp;at=candidate;}
    candidate=q-n*dq;if(dq*dq<best&&Inside(candidate,f,n)){best=dq*dq;at=candidate;}return best;
}
bool Touch(const Triangle& a,const Triangle& b,Vec& at){
    constexpr float margin=0.25f*0.25f;
    return SegmentFace(a.a,a.b,b,at)<=margin||SegmentFace(a.b,a.c,b,at)<=margin||SegmentFace(a.c,a.a,b,at)<=margin
        ||SegmentFace(b.a,b.b,a,at)<=margin||SegmentFace(b.b,b.c,a,at)<=margin||SegmentFace(b.c,b.a,a,at)<=margin;
}
}
Surface::Surface(std::span<const Triangle> faces):faces_(faces.begin(),faces.end()){
    Initialize();
}
Surface::Surface(IndexedMesh mesh){
    faces_.reserve(mesh.triangles.size());
    for(const auto& indices:mesh.triangles){
        if(indices[0]<mesh.vertices.size()&&indices[1]<mesh.vertices.size()&&indices[2]<mesh.vertices.size())
            faces_.push_back({mesh.vertices[indices[0]],mesh.vertices[indices[1]],mesh.vertices[indices[2]]});
        else faces_.push_back({}); // Keep the original source-face ordinal.
    }
    Initialize();
}
void Surface::Initialize(){
    for(unsigned i=0;i<faces_.size();++i){
        const Triangle& t=faces_[i];
        if(Valid(t.a)&&Valid(t.b)&&Valid(t.c)&&Length(Cross(t.b-t.a,t.c-t.a))>=1e-6f)order_.push_back(i);
    }
    if(!order_.empty())Build(0,static_cast<unsigned>(order_.size()));
}
unsigned Surface::Build(unsigned begin,unsigned end){
    const unsigned id=static_cast<unsigned>(nodes_.size());nodes_.push_back({});
    Vec low=faces_[order_[begin]].a,high=low;
    for(unsigned i=begin;i<end;++i){const Triangle& f=faces_[order_[i]];low=Min(low,Min(f.a,Min(f.b,f.c)));high=Max(high,Max(f.a,Max(f.b,f.c)));}
    nodes_[id]={{low,high},begin,end,0,0};
    if(end-begin<=8)return id;
    Vec size=high-low;unsigned axis=size.x>size.y?(size.x>size.z?0:2):(size.y>size.z?1:2);
    const unsigned mid=begin+(end-begin)/2;
    auto center=[axis](const Triangle& t){Vec c=t.a+t.b+t.c;return axis==0?c.x:axis==1?c.y:c.z;};
    std::nth_element(order_.begin()+begin,order_.begin()+mid,order_.begin()+end,[&](unsigned a,unsigned b){return center(faces_[a])<center(faces_[b]);});
    unsigned left=Build(begin,mid),right=Build(mid,end);nodes_[id].left=left;nodes_[id].right=right;return id;
}
bool Surface::Sweep(std::span<const Triangle> blade,const Motion& weapon,const Motion& attack,float scale,Hit& hit)const{
    if(nodes_.empty()||blade.empty()||blade.size()>64||!std::isfinite(scale)||scale<=0||scale>4
        ||!Valid(weapon.before)||!Valid(weapon.after)||!Valid(attack.before)||!Valid(attack.after))return false;
    Quat w0=weapon.beforeQ,w1=weapon.afterQ,b0=attack.beforeQ,b1=attack.afterQ;
    if(!Normalize(w0)||!Normalize(w1)||!Normalize(b0)||!Normalize(b1))return false;
    if(Length(weapon.after-weapon.before)>128||Length(attack.after-attack.before)>128)return false;
    float radius=0;
    for(const Triangle& f:blade)radius=std::max({radius,Length(f.a)*scale,Length(f.b)*scale,Length(f.c)*scale});
    Vec relative0=attack.before-weapon.before,relative1=attack.after-weapon.after;
    float reach=std::max(Length(relative0),Length(relative1))+radius;
    // Arc length bounds motion of every blade vertex in receiver space.
    // Sampling actual rigid transforms avoids phantom contacts on a chord.
    float travel=Length(relative1-relative0)+Angle(b0,b1)*radius+Angle(w0,w1)*reach;
    if(!std::isfinite(travel)||travel>128)return false;
    const unsigned steps=std::clamp(static_cast<unsigned>(std::ceil(travel/.5f)),1u,256u);
    for(unsigned step=0;step<=steps;++step){
      float t=float(step)/float(steps);Quat wq=Mix(w0,w1,t),bq=Mix(b0,b1,t);
      Vec wr=Mix(weapon.before,weapon.after,t),br=Mix(attack.before,attack.after,t);
      auto local=[&](Vec v){return Rotate(Inverse(wq),br+Rotate(bq,v*scale)-wr);};
      for(const Triangle& face:blade){
        Triangle moving{local(face.a),local(face.b),local(face.c)};
        Vec pad{.25f,.25f,.25f},low=Min(moving.a,Min(moving.b,moving.c))-pad;
        Vec high=Max(moving.a,Max(moving.b,moving.c))+pad;
        // Each actual rigid sample has a tight triangle box. No swept hull is
        // accepted as contact, and far leaves never reach triangle tests.
        std::array<unsigned,64> stack{};unsigned pending=1;
        while(pending){const Node& n=nodes_[stack[--pending]];
            if(low.x>n.box.high.x||high.x<n.box.low.x||low.y>n.box.high.y||high.y<n.box.low.y||low.z>n.box.high.z||high.z<n.box.low.z)continue;
            if(n.left){if(pending+2>stack.size())return false;stack[pending++]=n.left;stack[pending++]=n.right;continue;}
            for(unsigned i=n.begin;i<n.end;++i){
                const Triangle& fixed=faces_[order_[i]];
                Vec fl=Min(fixed.a,Min(fixed.b,fixed.c)),fh=Max(fixed.a,Max(fixed.b,fixed.c));
                if(low.x>fh.x||high.x<fl.x||low.y>fh.y||high.y<fl.y||low.z>fh.z||high.z<fl.z)continue;
                Vec at;if(!Touch(moving,fixed,at))continue;
                Vec normal=Unit(Cross(moving.b-moving.a,moving.c-moving.a));
                if(Dot((fixed.a+fixed.b+fixed.c)*(1.f/3)-at,normal)<0)normal=normal*-1;
                hit.point=wr+Rotate(wq,at);hit.normal=Rotate(wq,normal);
                hit.localPoint=at;hit.fraction=t;hit.triangleIndex=order_[i];return true;
            }
        }
      }
    }
    return false;
}
namespace {
Vec ClosestTriangle(Vec p,const Triangle& t) {
    const Vec ab=t.b-t.a,ac=t.c-t.a,ap=p-t.a;
    const float d1=Dot(ab,ap),d2=Dot(ac,ap);
    if(d1<=0&&d2<=0)return t.a;
    const Vec bp=p-t.b;const float d3=Dot(ab,bp),d4=Dot(ac,bp);
    if(d3>=0&&d4<=d3)return t.b;
    const float vc=d1*d4-d3*d2;
    if(vc<=0&&d1>=0&&d3<=0)return t.a+ab*(d1/(d1-d3));
    const Vec cp=p-t.c;const float d5=Dot(ab,cp),d6=Dot(ac,cp);
    if(d6>=0&&d5<=d6)return t.c;
    const float vb=d5*d2-d1*d6;
    if(vb<=0&&d2>=0&&d6<=0)return t.a+ac*(d2/(d2-d6));
    const float va=d3*d6-d5*d4;
    if(va<=0&&(d4-d3)>=0&&(d5-d6)>=0)
        return t.b+(t.c-t.b)*((d4-d3)/((d4-d3)+(d5-d6)));
    const float inv=1/(va+vb+vc);
    return t.a+ab*(vb*inv)+ac*(vc*inv);
}
// Closest PAIR, unlike SegmentFace's midpoint used for two surface meshes.
float ClosestSegments(Vec a,Vec b,Vec c,Vec d,Vec& p,Vec& q) {
    const Vec u=b-a,v=d-c,w=a-c;
    const float aa=Dot(u,u),bb=Dot(u,v),cc=Dot(v,v),dd=Dot(u,w),ee=Dot(v,w);
    const float den=aa*cc-bb*bb;
    float s=den>1e-8f?std::clamp((bb*ee-cc*dd)/den,0.f,1.f):0.f;
    float t=cc>1e-8f?(bb*s+ee)/cc:0.f;
    if(t<0){t=0;s=std::clamp(-dd/std::max(aa,1e-8f),0.f,1.f);}
    else if(t>1){t=1;s=std::clamp((bb-dd)/std::max(aa,1e-8f),0.f,1.f);}
    p=a+u*s;q=c+v*t;return Dot(p-q,p-q);
}
float ClosestSegmentTriangle(Vec a,Vec b,const Triangle& t,Vec& onSegment,Vec& onTriangle) {
    const Vec n=Unit(Cross(t.b-t.a,t.c-t.a));
    const float da=Dot(a-t.a,n),db=Dot(b-t.a,n);
    if(da*db<=0&&std::abs(da-db)>1e-8f) {
        const Vec p=a+(b-a)*(da/(da-db));
        if(Inside(p,t,n)){onSegment=p;onTriangle=p;return 0;}
    }
    onSegment=a;onTriangle=ClosestTriangle(a,t);
    float best=Dot(a-onTriangle,a-onTriangle);
    Vec p=b,q=ClosestTriangle(b,t);float dist=Dot(p-q,p-q);
    if(dist<best){best=dist;onSegment=p;onTriangle=q;}
    for(auto edge:std::array<std::array<Vec,2>,3>{{{t.a,t.b},{t.b,t.c},{t.c,t.a}}}) {
        dist=ClosestSegments(a,b,edge[0],edge[1],p,q);
        if(dist<best){best=dist;onSegment=p;onTriangle=q;}
    }
    return best;
}
// Clip the actual prop triangle by the filled stock box. The accepted point
// remains on that triangle; neither its AABB nor a center ray accepts a hit.
bool BoxTriangle(const Triangle& t,Vec extent,Vec& at,Vec& normal) {
    std::array<Vec,12> poly{},next{};unsigned count=3;
    poly[0]=t.a;poly[1]=t.b;poly[2]=t.c;
    const auto coordinate=[](Vec p,unsigned axis){return axis==0?p.x:axis==1?p.y:p.z;};
    for(unsigned axis=0;axis<3;++axis)for(float sign:{-1.f,1.f}) {
        unsigned output=0;const float bound=coordinate(extent,axis);
        for(unsigned i=0;i<count;++i) {
            const Vec a=poly[i],b=poly[(i+1)%count];
            const float da=sign*coordinate(a,axis)-bound,db=sign*coordinate(b,axis)-bound;
            if(da<=0) {if(output==next.size())return false;next[output++]=a;}
            if((da<=0)!=(db<=0)) {if(output==next.size())return false;next[output++]=a+(b-a)*(da/(da-db));}
        }
        if(!output)return false;poly=next;count=output;
    }
    at={};for(unsigned i=0;i<count;++i)at=at+poly[i];at=at*(1.f/count);
    const Vec gap{extent.x-std::abs(at.x),extent.y-std::abs(at.y),extent.z-std::abs(at.z)};
    if(gap.x<=gap.y&&gap.x<=gap.z)normal={at.x>=0?1.f:-1.f,0,0};
    else if(gap.y<=gap.z)normal={0,at.y>=0?1.f:-1.f,0};
    else normal={0,0,at.z>=0?1.f:-1.f};
    return true;
}
bool HurtboxTriangle(const Triangle& t,const Hurtbox& shape,Vec& at,Vec& normal) {
    constexpr float tolerance=.25f;
    if(shape.kind==HurtboxKind::Box) {
        if(BoxTriangle(t,shape.halfExtent,at,normal))return true;
        // Closest features keep the Euclidean tolerance identical at box
        // corners and faces instead of expanding all three axes at once.
        const Vec e=shape.halfExtent;
        float best=std::numeric_limits<float>::max();Vec boxPoint{};
        for(Vec p:{t.a,t.b,t.c}) {
            const Vec q{std::clamp(p.x,-e.x,e.x),std::clamp(p.y,-e.y,e.y),std::clamp(p.z,-e.z,e.z)};
            const float distance=Dot(p-q,p-q);
            if(distance<best){best=distance;at=p;boxPoint=q;}
        }
        for(unsigned axis=0;axis<3;++axis)for(float a:{-1.f,1.f})for(float b:{-1.f,1.f}) {
            Vec p,q;
            if(axis==0){p={-e.x,a*e.y,b*e.z};q={e.x,a*e.y,b*e.z};}
            else if(axis==1){p={a*e.x,-e.y,b*e.z};q={a*e.x,e.y,b*e.z};}
            else {p={a*e.x,b*e.y,-e.z};q={a*e.x,b*e.y,e.z};}
            Vec onEdge,onTriangle;const float distance=ClosestSegmentTriangle(p,q,t,onEdge,onTriangle);
            if(distance<best){best=distance;at=onTriangle;boxPoint=onEdge;}
        }
        if(best>tolerance*tolerance)return false;
        normal=Unit(at-boxPoint);return true;
    }
    Vec onAxis{};float distance=0;
    if(shape.kind==HurtboxKind::Sphere) {
        at=ClosestTriangle({},t);distance=Dot(at,at);
    } else distance=ClosestSegmentTriangle({0,0,-shape.halfLength},{0,0,shape.halfLength},t,onAxis,at);
    if(distance>(shape.radius+tolerance)*(shape.radius+tolerance))return false;
    normal=Unit(at-onAxis);
    // A triangle piercing the capsule axis has no unique radial normal.
    // Use the real triangle plane, oriented toward its contacted face center.
    if(Length(normal)<.5f) {
        normal=Unit(Cross(t.b-t.a,t.c-t.a));
        if(Dot((t.a+t.b+t.c)*(1.f/3)-onAxis,normal)<0)normal=normal*-1;
    }
    return true;
}
}

bool Surface::SweepHurtbox(const Motion& weapon,const Motion& victim,const Hurtbox& shape,Hit& hit,float weaponScale)const {
    if(nodes_.empty()||!Valid(weapon.before)||!Valid(weapon.after)||!Valid(victim.before)||!Valid(victim.after))return false;
    if(!std::isfinite(weaponScale)||weaponScale<=0||weaponScale>64)return false;
    if(shape.kind!=HurtboxKind::Sphere&&shape.kind!=HurtboxKind::Capsule&&shape.kind!=HurtboxKind::Box)return false;
    if(shape.kind!=HurtboxKind::Box&&(!std::isfinite(shape.radius)||shape.radius<=0))return false;
    if(shape.kind==HurtboxKind::Capsule&&(!std::isfinite(shape.halfLength)||shape.halfLength<0))return false;
    Quat w0=weapon.beforeQ,w1=weapon.afterQ,v0=victim.beforeQ,v1=victim.afterQ;
    if(!Normalize(w0)||!Normalize(w1)||!Normalize(v0)||!Normalize(v1))return false;
    Vec extent=shape.kind==HurtboxKind::Box?shape.halfExtent:Vec{shape.radius,shape.radius,shape.radius+shape.halfLength};
    if(shape.kind==HurtboxKind::Sphere)extent={shape.radius,shape.radius,shape.radius};
    if(!Valid(extent)||extent.x<=0||extent.y<=0||extent.z<=0||Length(extent)>256)return false;
    const Vec relative0=victim.before-weapon.before,relative1=victim.after-weapon.after;
    const float radius=Length(extent),reach=std::max(Length(relative0),Length(relative1))+radius;
    const float travel=Length(relative1-relative0)+Angle(v0,v1)*radius+Angle(w0,w1)*reach;
    if(!std::isfinite(travel)||travel>128||Length(weapon.after-weapon.before)>128||Length(victim.after-victim.before)>128)return false;
    const unsigned steps=std::clamp(static_cast<unsigned>(std::ceil(travel/.25f)),1u,512u);
    for(unsigned step=0;step<=steps;++step) {
        const float fraction=float(step)/steps;
        const Quat wq=Mix(w0,w1,fraction),vq=Mix(v0,v1,fraction);
        const Vec wr=Mix(weapon.before,weapon.after,fraction),vr=Mix(victim.before,victim.after,fraction);
        const auto weaponLocal=[&](Vec p){return Rotate(Inverse(wq),vr+Rotate(vq,p)-wr)*(1/weaponScale);};
        const auto victimLocal=[&](Vec p){return Rotate(Inverse(vq),wr+Rotate(wq,p*weaponScale)-vr);};
        Vec low=weaponLocal(extent),high=low;
        for(float x:{-1.f,1.f})for(float y:{-1.f,1.f})for(float z:{-1.f,1.f}) {
            Vec p=weaponLocal({extent.x*x,extent.y*y,extent.z*z});low=Min(low,p);high=Max(high,p);
        }
        const Vec pad=Vec{.25f,.25f,.25f}*(1/weaponScale);low=low-pad;high=high+pad;
        std::array<unsigned,64> stack{};unsigned pending=1;
        while(pending) {
            const Node& node=nodes_[stack[--pending]];
            if(low.x>node.box.high.x||high.x<node.box.low.x||low.y>node.box.high.y||high.y<node.box.low.y||low.z>node.box.high.z||high.z<node.box.low.z)continue;
            if(node.left) {if(pending+2>stack.size())return false;stack[pending++]=node.left;stack[pending++]=node.right;continue;}
            for(unsigned i=node.begin;i<node.end;++i) {
                const Triangle& original=faces_[order_[i]];
                const Triangle transformed{victimLocal(original.a),victimLocal(original.b),victimLocal(original.c)};
                Vec at,normal;if(!HurtboxTriangle(transformed,shape,at,normal))continue;
                hit.point=vr+Rotate(vq,at);hit.normal=Rotate(vq,normal);
                hit.localPoint=Rotate(Inverse(wq),hit.point-wr)*(1/weaponScale);hit.fraction=fraction;
                hit.triangleIndex=order_[i];hit.victimLocalPoint=at;
                return true;
            }
        }
    }
    return false;
}

// Instantaneous velocity for the same shortest-slerp rigid trajectory used
// by contact sampling. Units: UU/s and quaternion-derived radians/s.
Vec RigidPointVelocity(const Motion& motion,Vec local,float fraction,float dt) {
    if(!std::isfinite(dt)||dt<=0||!std::isfinite(fraction)||fraction<0||fraction>1
        ||!Valid(motion.before)||!Valid(motion.after)||!Valid(local))return {};
    Quat before=motion.beforeQ,after=motion.afterQ;
    if(!Normalize(before)||!Normalize(after))return {};
    Quat delta;
    // Quaternion Hamilton product after * inverse(before).
    const Quat inverse=Inverse(before);
    delta={after.w*inverse.x+after.x*inverse.w+after.y*inverse.z-after.z*inverse.y,
           after.w*inverse.y-after.x*inverse.z+after.y*inverse.w+after.z*inverse.x,
           after.w*inverse.z+after.x*inverse.y-after.y*inverse.x+after.z*inverse.w,
           after.w*inverse.w-after.x*inverse.x-after.y*inverse.y-after.z*inverse.z};
    if(delta.w<0)delta={-delta.x,-delta.y,-delta.z,-delta.w};
    const Vec axis{delta.x,delta.y,delta.z};const float sine=Length(axis);
    const float radians=2*std::atan2(sine,std::clamp(delta.w,0.f,1.f));
    const Vec omega=sine>1e-7f?axis*(radians/(sine*dt)):Vec{};
    return (motion.after-motion.before)*(1/dt)+Cross(omega,Rotate(Mix(before,after,fraction),local));
}


const Surface* Catalog(int id){
    if(id<=0||id>static_cast<int>(catalog::meshes.size()))return nullptr;
    static std::array<std::unique_ptr<Surface>,catalog::meshes.size()> cached;
    auto& mesh=cached[static_cast<unsigned>(id-1)];
    if(!mesh)mesh=std::make_unique<Surface>(catalog::meshes[static_cast<unsigned>(id-1)]);
    return mesh.get();
}
bool ContactImpulse(const RigidBodyState& body,Vec at,Vec normal,Vec victimVelocity,float restitution,
                    Vec& impulse,Vec& pointVelocity){
    impulse={};pointVelocity={};Quat q=body.inertiaQ;
    if(!Valid(body.center)||!Valid(body.linear)||!Valid(body.angular)||!Valid(body.inverseInertia)
        ||!Valid(at)||!Valid(normal)||!Valid(victimVelocity)||!Normalize(q)
        ||!std::isfinite(body.inverseMass)||body.inverseMass<=0
        ||body.inverseInertia.x<0||body.inverseInertia.y<0||body.inverseInertia.z<0
        ||!std::isfinite(restitution)||restitution<0||restitution>1||Length(normal)<.5f)return false;
    normal=Unit(normal);const Vec r=at-body.center;
    if(Length(r)>512)return false;
    const auto angularResponse=[&](Vec applied){
        const Vec local=Rotate(Inverse(q),Cross(r,applied));
        return Rotate(q,{local.x*body.inverseInertia.x,local.y*body.inverseInertia.y,local.z*body.inverseInertia.z});
    };
    const auto response=[&](Vec applied){return applied*body.inverseMass+Cross(angularResponse(applied),r);};
    pointVelocity=body.linear+Cross(body.angular,r);
    const Vec relative=pointVelocity-victimVelocity;
    const float closing=Dot(relative,normal),denominator=Dot(normal,response(normal));
    if(!Valid(pointVelocity)||!std::isfinite(denominator)||denominator<=0||closing>=0)return false;
    const float amount=-(1+restitution)*closing/denominator;
    impulse=normal*amount;
    // Tangent friction uses the velocity AFTER the analytical normal impulse
    // and its own full inverse-inertia denominator. Cap Coulomb friction .15.
    const Vec after=relative+response(impulse),tangent=after-normal*Dot(after,normal);
    const float speed=Length(tangent);
    if(speed>1e-5f){
        const Vec axis=tangent*(1/speed);const float inverse=Dot(axis,response(axis));
        if(!std::isfinite(inverse)||inverse<=0)return false;
        impulse=impulse-axis*std::min(speed/inverse,.15f*amount);
    }
    return Valid(impulse);
}
std::span<const Triangle> GorefastBlade(){return catalog::blade;}
bool CatalogIsWorld(int id){return id>static_cast<int>(catalog::heldCount)&&id<=static_cast<int>(catalog::meshes.size());}
FaceInfo CatalogFaceInfo(int id,unsigned triangle){
    if(id<=0||id>static_cast<int>(catalog::faceInfo.size()))return {};
    const auto info=catalog::faceInfo[static_cast<unsigned>(id-1)];
    return triangle<info.size()?info[triangle]:FaceInfo{};
}
int ClassifySharpContact(const SharpRegions& regions,Vec point,int faceRegion){
    if(!Valid(point))return 0;
    if(regions.tipRadius>0&&Length(point-regions.tip)<=regions.tipRadius)return 2;
    if(regions.edgeRadius>0&&point.z>=regions.edgeMinZ){
        if(regions.projectY)point.y=0;
        for(const auto& edge:regions.edges){
            Vec a=edge.a,b=edge.b;if(regions.projectY){a.y=0;b.y=0;}
            const Vec line=b-a;
            const float along=std::clamp(Dot(point-a,line)/std::max(Dot(line,line),1e-8f),0.f,1.f);
            if(Length(point-(a+line*along))<=regions.edgeRadius)return 1;
        }
    }
    return faceRegion>=0&&faceRegion<=2?faceRegion:0;
}
int ClassifyCatalogPoint(int id,Vec point,float slack){
    if(id<=0||id>static_cast<int>(catalog::sharp.size())||!std::isfinite(slack))return 0;
    auto regions=catalog::sharp[static_cast<unsigned>(id-1)];
    slack=std::clamp(slack,0.f,16.f);
    if(regions.tipRadius>0)regions.tipRadius+=slack;
    if(regions.edgeRadius>0&&!regions.edges.empty())regions.edgeRadius+=slack;
    return ClassifySharpContact(regions,point,0);
}
int ClassifyCatalogContact(int id,unsigned triangle,Vec point){
    if(id<=0||id>static_cast<int>(catalog::sharp.size()))return 0;
    return ClassifySharpContact(catalog::sharp[static_cast<unsigned>(id-1)],point,CatalogFaceInfo(id,triangle).region);
}
void CatalogContactAxes(int id,Vec point,Vec& tipAxis,Vec& edgeAxis,Vec& edgeTangent){
    tipAxis={};edgeAxis={};edgeTangent={};
    if(id<=0||id>static_cast<int>(catalog::sharp.size())||!Valid(point))return;
    const auto& regions=catalog::sharp[static_cast<unsigned>(id-1)];
    tipAxis=Unit(regions.tipAxis);edgeAxis=Unit(regions.edgeAxis);
    if(regions.projectY)point.y=0;
    float best=std::numeric_limits<float>::max();
    for(const auto& edge:regions.edges){
        Vec a=edge.a,b=edge.b;if(regions.projectY){a.y=0;b.y=0;}
        const Vec line=b-a;
        const float t=std::clamp(Dot(point-a,line)/std::max(Dot(line,line),1e-8f),0.f,1.f);
        const float distance=Length(point-(a+line*t));
        if(distance<best){best=distance;edgeTangent=Unit(edge.b-edge.a);if(Length(edge.axis)>.5f)edgeAxis=Unit(edge.axis);}
    }
}
}
