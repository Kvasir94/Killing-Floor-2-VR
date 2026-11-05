#include "flex/FlexSolver.h"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace kf2vr::flex;

namespace {
int failures=0;
void Check(bool ok,const char* what) { if(!ok) { ++failures; std::printf("FAIL %s\n",what); } }

Params BaseParams(bool fluid) {
    Params p{};
    p.numIterations=3; p.gravity[2]=-1000; p.radius=10; p.solidRestDistance=10; p.fluidRestDistance=5;
    p.dynamicFriction=0.3f; p.staticFriction=0.3f; p.particleFriction=0.1f; p.maxSpeed=5000;
    p.fluid=fluid?1:0; p.cohesion=0.02f; p.viscosity=0.05f; p.solidPressure=1; p.relaxationMode=1; p.relaxationFactor=1;
    return p;
}

// A 400x400 floor made of two triangles at z=0, as KF2's collision gather uploads it.
std::vector<float> Floor() {
    const float s=200;
    return {-s,-s,0,0, s,-s,0,0, s,s,0,0,  -s,-s,0,0, s,s,0,0, -s,s,0,0};
}

void RotationExtraction() {
    // A = R * S with S symmetric positive definite: the rotation is recovered.
    const float angle=1.1f;
    const float c=std::cos(angle),s=std::sin(angle);
    const float r[9]{c,s,0, -s,c,0, 0,0,1}; // column-major rotation about z
    const float sym[9]{2,0.3f,0, 0.3f,1.5f,0.1f, 0,0.1f,1};
    float a[9]{};
    for(int col=0;col<3;++col) for(int row=0;row<3;++row)
        for(int k=0;k<3;++k) a[3*col+row]+=r[3*k+row]*sym[3*col+k];
    const auto q=ExtractRotation(a,{0,0,0,1},40);
    const auto expected=QuaternionFromMatrix(r);
    const float dot=std::fabs(q[0]*expected[0]+q[1]*expected[1]+q[2]*expected[2]+q[3]*expected[3]);
    Check(dot>0.9999f,"rotation extraction recovers R from R*S");
}

void RestDensity() {
    const float rho=LatticeRestDensity(10,5);
    Check(rho>0,"lattice rest density is positive");
    Check(LatticeRestDensity(10,4)>rho,"denser lattice has higher rest density");
}

ForceField CapsuleField() {
    ForceField field{};
    field.basis[0]=field.basis[4]=field.basis[8]=1;
    field.boundsRadius=field.bottomRadius=field.topRadius=10;
    field.boundsHeight=field.height=20;
    return field;
}

Vec3 FieldStep(const ForceField* fields,int count,Vec3 position={2,0,0},float massInverse=1,
    float dt=0.1f,int substeps=1,float cap=5000,Vec3 initialVelocity={}) {
    Solver solver(1);
    auto params=BaseParams(false); params.gravity[2]=0; params.maxSpeed=cap;
    solver.SetParams(params);
    const float particle[4]{position.x,position.y,position.z,massInverse};
    const float velocity[3]{initialVelocity.x,initialVelocity.y,initialVelocity.z};
    const int active=0;
    solver.SetParticles(particle,1); solver.SetVelocities(velocity,1); solver.SetActive(&active,1);
    solver.SetForceFields(fields,count);
    solver.Update(dt,substeps);
    float result[3]; solver.GetVelocities(result,1);
    return {result[0],result[1],result[2]};
}

void CheckVelocity(Vec3 actual,Vec3 expected,const char* what) {
    Check(std::fabs(actual.x-expected.x)<0.002f && std::fabs(actual.y-expected.y)<0.002f &&
        std::fabs(actual.z-expected.z)<0.002f,what);
}

void ForceFieldMath() {
    auto field=CapsuleField();
    field.radialStrength=4; field.rotationalStrength=6; field.liftStrength=8;
    // At (2,0,0), radial force is 4, tangential force is 6*(2/10), lift is 8.
    CheckVelocity(FieldStep(&field,1),{0.4f,0.8f,0.12f},"capsule radial rotational and lift strengths");
    CheckVelocity(FieldStep(&field,1,{2,0,0},0.5f),{0.2f,0.4f,0.06f},"field force uses inverse mass");
    CheckVelocity(FieldStep(&field,1,{2,0,0},1,0.1f,2),{0.2f,0.4f,0.06f},
        "fields apply once before substeps with dt divided by substeps");
    CheckVelocity(FieldStep(&field,1,{2,0,0},1,0.2f,2),{0.4f,0.8f,0.12f},
        "field duration uses supplied dt independently of solver integration clamp");
    CheckVelocity(FieldStep(&field,1,{2,0,0},1,0.1f,16),{0.025f,0.05f,0.0075f},
        "field duration preserves requested substeps above the integration budget");
    field.radialStrength=-4; field.rotationalStrength=-6; field.liftStrength=-8;
    CheckVelocity(FieldStep(&field,1),{-0.4f,-0.8f,-0.12f},"field strengths retain their signs");
    field.radialStrength=4; field.rotationalStrength=6; field.liftStrength=8;
    // Translate to (10,20,0), with the local X axis along world Y.
    field.basis[0]=field.basis[4]=0; field.basis[1]=-1; field.basis[3]=1;
    field.translation[0]=-20; field.translation[1]=10;
    CheckVelocity(FieldStep(&field,1,{10,22,0}),{-0.8f,0.4f,0.12f},
        "field transforms positions and returns forces through the transposed basis");

    field=CapsuleField(); field.radialStrength=4;
    CheckVelocity(FieldStep(&field,1,{10,0,0}),{},"outer capsule boundary is excluded");
    CheckVelocity(FieldStep(&field,1,{0,20.1f,0}),{},"outer capsule end bounds the field");
    field.boundaryFade=0.5f;
    CheckVelocity(FieldStep(&field,1,{7.5f,0,0}),{0.2f,0,0},"outer half-radius fade scales force");
    field.boundaryFade=0; field.rotationalStrength=6; field.topRadius=6;
    CheckVelocity(FieldStep(&field,1),{0.4f,0,0.15f},"taper interpolates the vortex cross-section");
    field.boundsRadius=field.bottomRadius=field.topRadius=5;
    field.boundsHeight=field.height=10;
    // Four units beyond either cap center gives cross-section sqrt(25-16)=3.
    CheckVelocity(FieldStep(&field,1,{2,9,0}),{0.4f,0,0.4f},"top hemisphere sets tangential radius");
    CheckVelocity(FieldStep(&field,1,{2,-9,0}),{0.4f,0,0.4f},"bottom hemisphere sets tangential radius");
    field.boundsHeight=field.height=0;
    CheckVelocity(FieldStep(&field,1,{2,3,0}),{0.4f,0,0.3f},"zero-height capsule retains spherical caps");
    field.boundsRadius=0;
    CheckVelocity(FieldStep(&field,1,{0,0,0}),{},"zero-radius bounds do not introduce NaN velocity");
    field=CapsuleField(); field.radialStrength=4; field.liftStrength=8;
    CheckVelocity(FieldStep(&field,1,{0,2,0}),{0,0.2f,0},"shipped vortex axis fallback retains local position");
    field.bottomRadius=field.topRadius=2;
    CheckVelocity(FieldStep(&field,1,{3,0,0}),{0.3f,0,0},
        "shipped cross-section fallback remains bounded by the outer capsule");
    field.radialStrength=field.liftStrength=0;
    CheckVelocity(FieldStep(&field,1,{0,2,0}),{0,0.2f,0},
        "zero authored strengths still retain the shipped axis fallback");
    CheckVelocity(FieldStep(&field,1,{3,0,0}),{0.3f,0,0},
        "zero authored strengths still retain the shipped cross-section fallback");
    CheckVelocity(FieldStep(&field,1,{1,0,0}),{},
        "zero authored strengths give zero force inside the non-axis vortex");

    field=CapsuleField(); field.radialStrength=10; field.noiseStrength=1;
    // The diagonal wins over -X/-Y/-Z. At force (10,0,0), its projection is
    // (5,5,0); cross product is (0,0,50). A 0.1 blend yields force (9,0,5).
    field.noiseVectors[0][0]=-1;
    field.noiseVectors[1][0]=field.noiseVectors[1][1]=std::sqrt(0.5f);
    field.noiseVectors[2][1]=-1; field.noiseVectors[3][2]=-1;
    CheckVelocity(FieldStep(&field,1),{0.9f,0,0.5f},"supplied noise direction selection and cross product");
    for(auto& axis:field.noiseVectors) { axis[0]=1; axis[1]=axis[2]=0; }
    // Noise moves the admission position from 10.5 to 9.45. The unperturbed
    // vortex position lies outside its cross-section, then its fallback is
    // perturbed from 10.5 to 9.45 again before force integration.
    CheckVelocity(FieldStep(&field,1,{10.5f,0,0}),{0.945f,0,0},"noise also perturbs capsule admission");
    field.noiseStrength=0;
    CheckVelocity(FieldStep(&field,1),{1,0,0},"disabled noise ignores supplied vectors");

    ForceField fields[2]{CapsuleField(),CapsuleField()};
    fields[0].radialStrength=80; fields[1].radialStrength=-40;
    CheckVelocity(FieldStep(fields,2,{2,0,0},1,0.1f,1,5),{4,0,0},
        "opposing fields accumulate before the delta velocity cap");
    fields[0].radialStrength=fields[1].radialStrength=40;
    CheckVelocity(FieldStep(fields,2,{2,0,0},1,0.1f,1,5,{-3,0,0}),{2,0,0},
        "field cap limits delta velocity before adding existing velocity");
    CheckVelocity(FieldStep(fields,2,{2,0,0},1,0.1f,1,0),{},"zero field delta velocity cap suppresses force");
}

void ForceFieldState() {
    Solver solver(3);
    auto params=BaseParams(false); params.gravity[2]=0; solver.SetParams(params);
    const float particles[12]{4,0,0,0, 3,0,0,1, 2,0,0,1};
    const float velocities[9]{1,2,3, 7,8,9, 0,0,0};
    const int active[2]{2,0};
    solver.SetParticles(particles,3); solver.SetVelocities(velocities,3); solver.SetActive(active,2);
    auto field=CapsuleField(); field.radialStrength=10;
    solver.SetForceFields(&field,1);
    field.radialStrength=1000; // caller storage may change immediately after upload
    solver.Update(0.1f,1);
    float out[12],v[9]; solver.GetParticles(out,3); solver.GetVelocities(v,3);
    CheckVelocity({v[6],v[7],v[8]},{1,0,0},"force fields copy caller storage and address active particle indices");
    CheckVelocity({v[0],v[1],v[2]},{},"pinned particle keeps existing zero-velocity solver behavior");
    CheckVelocity({out[0],out[1],out[2]},{4,0,0},"field does not move pinned particle");
    CheckVelocity({v[3],v[4],v[5]},{7,8,9},"field does not change inactive velocity");
    CheckVelocity({out[4],out[5],out[6]},{3,0,0},"field does not move inactive particle");
    // Each supported clear form must replace the prior upload, not leave it
    // active. Re-upload between forms so stale-force bugs cannot hide.
    field.radialStrength=10;
    for(int clear=0;clear<3;++clear) {
        solver.SetForceFields(&field,1);
        if(clear==0) solver.SetForceFields(nullptr,1);
        else if(clear==1) solver.SetForceFields(&field,0);
        else solver.SetForceFields(&field,-1);
        solver.SetParticles(particles,3); solver.SetVelocities(velocities,3);
        solver.Update(0.1f,1); solver.GetVelocities(v,3);
        CheckVelocity({v[6],v[7],v[8]},{},"clearing force fields removes the previous copied upload");
    }
}

void SetContactSurface(Solver& solver,bool convex,float side) {
    if(!convex) {
        const auto floor=Floor();
        solver.SetTriangles(floor.data(),2,40);
        return;
    }
    // A box below the floor, or above the ceiling, with outward unit planes.
    const float lo=side>0?-200.0f:0.0f,hi=side>0?0.0f:200.0f;
    const float lower[4]{-200,-200,lo,0},upper[4]{200,200,hi,0};
    const float planes[24]{1,0,0,-200, -1,0,0,-200, 0,1,0,-200,
        0,-1,0,-200, 0,0,1,-hi, 0,0,-1,lo};
    const int offset=0,count=6,flags=0;
    const float position[4]{},rotation[4]{0,0,0,1};
    solver.SetConvexes(lower,upper,&offset,&count,planes,position,rotation,&flags,1,6);
}

struct ContactResult { float position[4]; float velocity[3]; };

ContactResult ContactStep(bool convex,float side,float restitution,float height,float normalVelocity,
    float tangentVelocity=0,float sleepThreshold=0) {
    Solver solver(1);
    auto p=BaseParams(false);
    p.gravity[2]=0; p.restitution=restitution; p.staticFriction=0; p.sleepThreshold=sleepThreshold;
    solver.SetParams(p);
    const float particle[4]{10,-20,side*height,1};
    const float velocity[3]{tangentVelocity,0,side*normalVelocity};
    const int active=0;
    solver.SetParticles(particle,1); solver.SetVelocities(velocity,1); solver.SetActive(&active,1);
    SetContactSurface(solver,convex,side);
    solver.Update(1.0f/60,1);
    ContactResult result{};
    solver.GetParticles(result.position,1); solver.GetVelocities(result.velocity,1);
    return result;
}

void ContactRestitution() {
    // Exercise both world geometry paths and both contact-normal signs. The
    // particle travels from distance 6 to 4; collision holds it at distance 5.
    for(bool convex:{false,true}) for(float side:{-1.0f,1.0f}) {
        for(float restitution:{0.0f,0.5f,1.0f}) {
            const auto hit=ContactStep(convex,side,restitution,6,-120);
            Check(std::fabs(side*hit.position[2]-5)<0.001f,"contact corrects penetration");
            Check(std::fabs(side*hit.velocity[2]-120*restitution)<0.01f,
                "contact bounce follows authored restitution and outward normal");
        }
        const auto slide=ContactStep(convex,side,0,6,-120,60);
        const auto bounce=ContactStep(convex,side,1,6,-120,60);
        Check(std::fabs(slide.velocity[0]-bounce.velocity[0])<0.01f,
            "restitution preserves tangential friction");
        if(!convex) Check(slide.velocity[0]>0 && slide.velocity[0]<60,
            "triangle contact actually applies sliding friction");
        // Start inside the collision margin so these cases resolve a contact,
        // rather than merely checking an untouched free-flight particle.
        for(float restitution:{0.0f,1.0f}) {
            const auto leaving=ContactStep(convex,side,restitution,4.75f,6);
            Check(std::fabs(side*leaving.position[2]-5)<0.001f,"separating overlap is corrected");
            Check(std::fabs(side*leaving.velocity[2]-6)<0.01f,
                "separating contact gains no normal energy");
            const auto still=ContactStep(convex,side,restitution,4.75f,0);
            Check(std::fabs(still.velocity[2])<0.01f,"resting overlap correction adds no bounce");
        }
        const auto sleepingHit=ContactStep(convex,side,0,6,-120,0,1);
        Check(std::fabs(side*sleepingHit.position[2]-5)<0.001f &&
            std::fabs(sleepingHit.velocity[2])<0.01f,
            "sleeping inelastic impact commits its contact position");
        const auto sleepingOverlap=ContactStep(convex,side,1,4.75f,0,0,1);
        Check(std::fabs(side*sleepingOverlap.position[2]-5)<0.001f &&
            std::fabs(sleepingOverlap.velocity[2])<0.01f,
            "sleeping overlap still depenetrates without gaining velocity");
        Solver resting(1);
        auto p=BaseParams(false); p.gravity[2]=-side*1000; p.restitution=1;
        resting.SetParams(p);
        const float particle[4]{10,-20,side*5,1}; const int active=0;
        resting.SetParticles(particle,1); resting.SetActive(&active,1);
        SetContactSurface(resting,convex,side);
        float position[4],velocity[3];
        for(int step=0;step<120;++step) {
            resting.Update(1.0f/120,1);
            resting.GetParticles(position,1); resting.GetVelocities(velocity,1);
            Check(std::fabs(side*position[2]-5)<0.001f && std::fabs(velocity[2])<0.01f,
                "gravity at resting contact does not inject bounce energy");
        }
    }
}

void RigidRestsOnFloor() {
    Solver solver(64);
    solver.SetParams(BaseParams(false));
    // Eight particles in a cube, one rigid body.
    std::vector<float> particles,rest;
    std::vector<int> indices;
    for(int i=0;i<8;++i) {
        const float x=(i&1)?5.f:-5.f,y=(i&2)?5.f:-5.f,z=(i&4)?5.f:-5.f;
        particles.insert(particles.end(),{x,y,z+60,1});
        rest.insert(rest.end(),{x,y,z});
        indices.push_back(i);
    }
    solver.SetParticles(particles.data(),8);
    solver.SetActive(indices.data(),8);
    std::vector<int> phases(8,1);
    solver.SetPhases(phases.data(),8);
    const int offsets[2]{0,8};
    const float stiffness=1,rotation[4]{0,0,0,1},translation[3]{0,0,60};
    solver.SetRigids(offsets,indices.data(),rest.data(),&stiffness,rotation,translation,1);
    const auto floor=Floor();
    solver.SetTriangles(floor.data(),2,40);
    for(int frame=0;frame<180;++frame) solver.Update(1.0f/60,2);
    solver.GetParticles(particles.data(),8);
    float lowest=1e9f; bool rigid=true;
    for(int i=0;i<8;++i) lowest=std::min(lowest,particles[4*i+2]);
    for(int i=0;i<8;++i) for(int j=i+1;j<8;++j) {
        const float dx=particles[4*i]-particles[4*j],dy=particles[4*i+1]-particles[4*j+1],dz=particles[4*i+2]-particles[4*j+2];
        const float rx=rest[3*i]-rest[3*j],ry=rest[3*i+1]-rest[3*j+1],rz=rest[3*i+2]-rest[3*j+2];
        if(std::fabs(std::sqrt(dx*dx+dy*dy+dz*dz)-std::sqrt(rx*rx+ry*ry+rz*rz))>0.5f) rigid=false;
    }
    Check(lowest>0 && lowest<10,"rigid comes to rest on the floor without passing through");
    Check(rigid,"rigid keeps its shape");
    float rotations[9],translations[3];
    solver.GetRigidTransforms(rotations,translations);
    Check(translations[2]>0 && translations[2]<15,"rigid transform follows its particles");
}

void FluidSettles() {
    constexpr int side=6,count=side*side*side;
    Solver solver(count);
    solver.SetParams(BaseParams(true));
    std::vector<float> particles; std::vector<int> indices;
    for(int i=0;i<count;++i) {
        const int x=i%side,y=(i/side)%side,z=i/(side*side);
        particles.insert(particles.end(),{x*5.0f,y*5.0f,10+z*5.0f,1});
        indices.push_back(i);
    }
    solver.SetParticles(particles.data(),count);
    solver.SetActive(indices.data(),count);
    std::vector<int> phases(count,0); // phase 0 is fluid when Params::fluid is set, as KF2 spawns it
    solver.SetPhases(phases.data(),count);
    const auto floor=Floor();
    solver.SetTriangles(floor.data(),2,40);
    for(int frame=0;frame<240;++frame) solver.Update(1.0f/60,2);
    solver.GetParticles(particles.data(),count);
    std::vector<float> velocities(3*count),densities(count);
    solver.GetVelocities(velocities.data(),count);
    solver.GetDensities(densities.data(),count);
    bool above=true,calm=true,finite=true; float densest=0;
    for(int i=0;i<count;++i) {
        if(particles[4*i+2]<=0) above=false;
        const float v=std::sqrt(velocities[3*i]*velocities[3*i]+velocities[3*i+1]*velocities[3*i+1]+velocities[3*i+2]*velocities[3*i+2]);
        if(v>200) calm=false;
        if(!std::isfinite(particles[4*i]) || !std::isfinite(v)) finite=false;
        densest=std::max(densest,densities[i]);
    }
    Check(finite,"fluid stays finite");
    Check(above,"fluid stays above the floor");
    Check(calm,"fluid settles instead of exploding");
    Check(densest>0.5f && densest<2.0f,"fluid density stays near rest");
    float lower[3],upper[3];
    solver.GetBounds(lower,upper);
    Check(lower[2]>0 && upper[0]>lower[0],"bounds cover the active particles");
}

void PhaseGroups() {
    // Fluid membership follows KF2: phase 0 is fluid only in a fluid container.
    Solver solver(4);
    Params p=BaseParams(false);
    solver.SetParams(p);
    const float particles[16]{0,0,100,1, 3,0,100,1, 100,0,100,1, 103,0,100,1};
    solver.SetParticles(particles,4);
    const int indices[4]{0,1,2,3};
    solver.SetActive(indices,4);
    const int phases[4]{1,2,3,3}; // different groups collide, same group without SelfCollide does not
    solver.SetPhases(phases,4);
    p.gravity[2]=0; solver.SetParams(p);
    solver.Update(1.0f/60,1);
    float out[16]; solver.GetParticles(out,4);
    Check(out[4]-out[0]>3.5f,"different groups push apart");
    Check(std::fabs((out[12]-out[8])-3.0f)<0.01f,"same group without SelfCollide does not collide");
}
} // namespace

int main() {
    RotationExtraction();
    RestDensity();
    ForceFieldMath();
    ForceFieldState();
    ContactRestitution();
    RigidRestsOnFloor();
    FluidSettles();
    PhaseGroups();
    std::printf("FleX portable solver failures: %d\n",failures);
    return failures?1:0;
}
