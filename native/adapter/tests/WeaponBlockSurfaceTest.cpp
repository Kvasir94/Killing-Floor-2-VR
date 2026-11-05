#include "WeaponBlockSurface.h"
#include <cstdio>
#include <cmath>
#include <limits>
using namespace kf2vr::adapter::weaponblock;
namespace { int failures=0;void Check(bool ok,const char* label){if(!ok){++failures;std::printf("FAIL %s\n",label);}} }
void HurtboxChecks(){
    const Triangle plate[]={{{-2,-2,0},{2,-2,0},{0,2,0}}};
    Surface surface(plate);Motion weapon{},victim{};Hit hit;
    Hurtbox sphere{HurtboxKind::Sphere,{},1,0};
    victim.before={0,0,3};victim.after={0,0,-3};
    Check(surface.SweepHurtbox(weapon,victim,sphere,hit),"sphere crosses real triangle");
    Check(std::abs(hit.point.z)<1e-5f,"contact stays on triangle");
    Check(hit.normal.z<-.9f,"normal points outward from incoming sphere");
    victim.before={2.1f,2.1f,3};victim.after={2.1f,2.1f,-3};
    Check(!surface.SweepHurtbox(weapon,victim,sphere,hit),"triangle AABB corner is not a hurtbox contact");
    victim.before={0,0,2};victim.after=victim.before;
    Check(!surface.SweepHurtbox(weapon,victim,sphere,hit),"separated resting sphere stays separated");
    Hurtbox capsule{HurtboxKind::Capsule,{},.5f,2};
    victim.before={0,0,4};victim.after={0,0,-4};
    Check(surface.SweepHurtbox(weapon,victim,capsule,hit),"capsule end cap crosses triangle");
    victim.before={3,0,0};victim.after=victim.before;
    Check(!surface.SweepHurtbox(weapon,victim,capsule,hit),"capsule exterior stays separate");
    Hurtbox box{HurtboxKind::Box,{.4f,.4f,.4f},0,0};
    victim.before={0,0,2};victim.after={0,0,-2};
    Check(surface.SweepHurtbox(weapon,victim,box,hit),"box clips triangle");
    victim.before={2,2,0};victim.after=victim.before;
    Check(!surface.SweepHurtbox(weapon,victim,box,hit),"box at empty triangle bound corner is rejected");
    const Triangle tip[]={{{9.8f,-.1f,0},{10.2f,-.1f,0},{10,.1f,0}}};
    Surface spinning(tip);weapon={};victim={};
    weapon.beforeQ={0,0,-.5f,.8660254f};weapon.afterQ={0,0,.5f,.8660254f};
    sphere.radius=.3f;victim.before={10,0,0};victim.after=victim.before;
    Check(spinning.SweepHurtbox(weapon,victim,sphere,hit),"spinning tip reaches real rotational arc");
    victim.before={5,0,0};victim.after=victim.before;
    Check(!spinning.SweepHurtbox(weapon,victim,sphere,hit),"rotational endpoint chord cannot hit");
    victim.after.x=std::numeric_limits<float>::quiet_NaN();
    Check(!spinning.SweepHurtbox(weapon,victim,sphere,hit),"invalid shape motion fails closed");
    victim={};capsule.halfLength=-1;
    Check(!surface.SweepHurtbox({},victim,capsule,hit),"negative capsule segment fails closed");
    sphere.kind=static_cast<HurtboxKind>(99);
    Check(!surface.SweepHurtbox({},victim,sphere,hit),"unknown hurtbox kind fails closed");
    // A diagonal near miss at a box corner exceeds .25 Euclidean UU even
    // though it lies within .25 on each axis.
    const Triangle corner[]={{{.58f,.58f,.58f},{.59f,.58f,.58f},{.58f,.59f,.58f}}};
    Surface nearCorner(corner);box.halfExtent={.4f,.4f,.4f};
    Check(!nearCorner.SweepHurtbox({}, {},box,hit),"box tolerance does not grow at diagonal corners");
    sphere={HurtboxKind::Sphere,{},.1f,0};victim.before={3,-3,.1f};victim.after=victim.before;
    Check(!surface.SweepHurtbox({},victim,sphere,hit),"unscaled prop does not reach scaled-only contact");
    Check(surface.SweepHurtbox({},victim,sphere,hit,2),"uniform world prop scale affects actual collision surface");
    Check(std::abs(hit.localPoint.x-1.5f)<.001f&&std::abs(hit.localPoint.y+1.5f)<.001f,
          "material point remains in original unscaled asset frame");
    Check(!surface.SweepHurtbox({},victim,sphere,hit,0),"zero prop scale fails closed");
    const Vec spinningVelocity=RigidPointVelocity(weapon,{10,0,0},.5f,1);
    Check(std::abs(spinningVelocity.x)<.001f&&std::abs(spinningVelocity.y-20.94395f)<.001f,
          "spinning point velocity includes angular motion at contact");
    Check(RigidPointVelocity(weapon,{10,0,0},.5f,0).y==0,"zero elapsed time cannot produce impact speed");
    // Include a rejected degenerate input and enough scattered faces to force
    // BVH partitioning. Contact identity remains the original array index.
    std::vector<Triangle> labeled(1);
    for(int i=0;i<16;++i){const float x=float((i*7)%16)*10;
        labeled.push_back({{x-1,-1,0},{x+1,-1,0},{x,1,0}});}
    Surface ordered(labeled);victim={};victim.before={70,0,1};victim.after={70,0,-1};
    Check(ordered.SweepHurtbox({},victim,sphere,hit)&&hit.triangleIndex==2,
          "original face identity survives invalid-face filtering and BVH partitioning");
    const Vec indexedVertices[]={{-2,-2,0},{2,-2,0},{0,2,0}};
    const std::array<unsigned,3> indices[]={{{0,1,99}},{{0,1,2}}};
    Surface indexed(IndexedMesh{indexedVertices,indices});victim={};
    victim.before={0,0,1};victim.after={0,0,-1};
    Check(indexed.SweepHurtbox({},victim,sphere,hit)&&hit.triangleIndex==1,
          "indexed catalog rejects invalid indices without changing source identity");
    const SharpEdge edges[]={{{-1,0,10},{-1,0,20}}};
    const SharpRegions sharp{{0,0,21},.75f,.25f,10,true,edges};
    Check(ClassifySharpContact(sharp,{-1,.2f,15})==1,"actual cutting outline classifies as edge");
    Check(ClassifySharpContact(sharp,{1,0,15})==0,"unsharpened spine remains blunt");
    Check(ClassifySharpContact(sharp,{0,0,15})==0,"flat blade interior remains blunt");
    Check(ClassifySharpContact(sharp,{-1,0,9.9f})==0,"guard boundary excludes handle contact");
    Check(ClassifySharpContact(sharp,{0,0,20.5f})==2,"actual tip neighborhood classifies as tip");

}
int main(){
    HurtboxChecks();
    {
        RigidBodyState body{};body.inverseMass=.5f;body.inverseInertia={.25f,.25f,.25f};
        body.linear={-10,5,0};Vec impulse,velocity;
        Check(ContactImpulse(body,{},{1,0,0},{},.5f,impulse,velocity),"centered impact computes a physical response");
        Check(std::abs(impulse.x-30)<.001f&&std::abs(impulse.y+4.5f)<.001f,
              "normal restitution and bounded tangent friction share one impulse");
        const float centeredEnergy=std::pow(-10+.5f*impulse.x,2)+std::pow(5+.5f*impulse.y,2);
        Check(centeredEnergy<125,"stationary contact friction and restitution dissipate energy");
        body.center={10,0,0};body.linear={-10,0,0};
        body.inverseInertia={.25f,1,.01f};body.inertiaQ={0,.70710678f,0,.70710678f};
        Check(ContactImpulse(body,{10,2,0},{1,0,0},{},.5f,impulse,velocity),"offset contact uses actual COM frame");
        Check(std::abs(impulse.x-10)<.001f,"rotated anisotropic inverse inertia reduces tip impulse correctly");
        const float linear=-10+.5f*impulse.x,angular=-.25f*2*impulse.x;
        Check(std::abs(linear-angular*2-5)<.001f,"offset point reaches requested normal restitution");
        Check(linear*linear+2*angular*angular<100,"off-center impulse cannot create kinetic energy");
        body.angular={0,0,3};
        Check(ContactImpulse(body,{10,2,0},{1,0,0},{},0,impulse,velocity)&&std::abs(velocity.x+16)<.001f,
              "incoming angular motion contributes to actual contact velocity");
        body.inverseMass=0;
        Check(!ContactImpulse(body,{10,2,0},{1,0,0},{},.5f,impulse,velocity),"fixed body has no invented mass fallback");
    }
    const Triangle receiver[] = {{{-2,-2,0},{2,-2,0},{0,2,0}}};
    const Triangle blade[] = {{{-.5f,-.5f,0},{.5f,-.5f,0},{0,.5f,0}}};
    Surface gun(receiver);Motion held{},attack{};Hit hit;
    attack.before={0,0,3};attack.after={0,0,-3};
    Check(gun.Sweep(blade,held,attack,1,hit),"stationary held receiver stops moving blade");
    Check(hit.point.z<.26f&&hit.point.z>-.26f,"contact lies on the receiver surface");
    attack.before={0,0,0};attack.after={0,0,0};held.before={0,0,-3};held.after={0,0,3};
    Check(gun.Sweep(blade,held,attack,1,hit),"moving receiver meets stationary blade");
    held={};attack.before={0,0,.8f};attack.after={0,0,.8f};
    Check(!gun.Sweep(blade,held,attack,1,hit),"near parallel surfaces do not invent contact");
    held.before={0,0,3};held.after={0,0,6};attack.before={0,0,0};attack.after={0,0,3};
    Check(!gun.Sweep(blade,held,attack,1,hit),"common translation preserves separated surfaces");
    held={};attack.before={10,0,3};attack.after={10,0,-3};
    Check(!gun.Sweep(blade,held,attack,1,hit),"finite receiver bounds reject blade off its edge");
    attack.before={0,0,100};attack.after={0,0,-100};
    Check(!gun.Sweep(blade,held,attack,1,hit),"teleport interval cannot create a block");
    attack.before={0,0,3};attack.after={0,0,-3};attack.afterQ.w=std::numeric_limits<float>::quiet_NaN();
    Check(!gun.Sweep(blade,held,attack,1,hit),"invalid rotation fails closed");
    attack.afterQ={};held.beforeQ={0,0,.70710678f,.70710678f};held.afterQ=held.beforeQ;
    Check(gun.Sweep(blade,held,attack,1,hit),"rotated rigid receiver retains contact");
    // A narrow blade travels around a pivot, not across its endpoint chord.
    const Triangle tip[]={{{9.8f,-.1f,0},{10.2f,-.1f,0},{10,.1f,0}}};
    const Triangle chordReceiver[]={{{4.8f,-.4f,0},{5.2f,-.4f,0},{5,.4f,0}}};
    const Triangle arcReceiver[]={{{9.7f,-.4f,0},{10.3f,-.4f,0},{10,.4f,0}}};
    Surface chord(chordReceiver),arc(arcReceiver);held={};attack={};
    attack.beforeQ={0,0,-.5f,.8660254f};attack.afterQ={0,0,.5f,.8660254f};
    Check(!chord.Sweep(tip,held,attack,1,hit),"rotating blade cannot hit endpoint chord interior");
    Check(arc.Sweep(tip,held,attack,1,hit),"rotating blade hits the actual rigid arc");
    Check(!Catalog(0)&&!Catalog(100000),"unknown exact mesh ID has no contact geometry");
    for(int id=1;id<=13;++id)Check(Catalog(id)!=nullptr,"all measured fixed-body catalogs load");
    held={};attack={};attack.before={60,0,15};attack.after={60,0,0};
    Check(Catalog(13)->Sweep(blade,held,attack,1,hit),"M4 original barrel surface stops a transverse blade");
    attack.before={60,6,15};attack.after={60,6,0};
    Check(!Catalog(13)->Sweep(blade,held,attack,1,hit),"M4 barrel exterior does not expand into empty space");
    return failures?1:0;
}
