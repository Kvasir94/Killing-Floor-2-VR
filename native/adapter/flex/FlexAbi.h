#pragma once
// Binary interface of the NVIDIA FleX 1.0.5 build that KF2 ships
// (flexRelease_x64.dll / flexExtRelease_x64.dll, product version 1.0.5.0).
// Recovered from KFGame.exe's delay-import call sites and the shipped DLLs;
// every layout below is what the pinned executable reads or writes.
#include <cstddef>
#include <cstdint>

namespace kf2vr::flex {

// FleX memory spaces. KF2 always passes 2 (host, asynchronous).
enum Memory : int { MemoryHost=0, MemoryDevice=1, MemoryHostAsync=2, MemoryDeviceAsync=3 };

// Phase word: low 24 bits are the collision group; particles in the same
// group only collide when SelfCollide is set. KF2 spawns fluid sprites with
// phase 0 and relies on FlexParams::fluid to make phase-0 particles fluid.
inline constexpr std::uint32_t PhaseGroupMask=0x00ffffffu;
inline constexpr std::uint32_t PhaseSelfCollide=1u<<24;
inline constexpr std::uint32_t PhaseFluid=1u<<25;

inline constexpr int Version=0x1f; // flexInit refuses any other header version

// 0x13c bytes, filled by KFGame from UFlexContainer (FFlexContainer::SetParams).
struct Params {
    std::int32_t numIterations;      // 0x00 NumIterations
    float gravity[3];                // 0x04 Gravity
    float radius;                    // 0x10 Radius (maximum interaction distance)
    float solidRestDistance;         // 0x14 = Radius
    float fluidRestDistance;         // 0x18 = RestDistance * Radius
    float dynamicFriction;           // 0x1c Friction
    float staticFriction;            // 0x20 StaticFriction
    float particleFriction;          // 0x24 ParticleFriction
    float restitution;               // 0x28 Restitution
    float adhesion;                  // 0x2c Adhesion
    float sleepThreshold;            // 0x30 SleepThreshold
    float maxSpeed;                  // 0x34 MaxVelocity
    float shockPropagation;          // 0x38 ShockPropagation
    float dissipation;               // 0x3c Dissipation
    float enableCcd;                 // 0x40 bEnableCCD as 0 or 1
    float wind[3];                   // 0x44 Wind
    float drag;                      // 0x50 Drag
    float lift;                      // 0x54 Lift
    std::uint8_t fluid;              // 0x58 bFluid: phase-0 particles are fluid
    std::uint8_t pad59[3];
    float cohesion;                  // 0x5c Cohesion
    float surfaceTension;            // 0x60 SurfaceTension (pre-scaled by KF2)
    float viscosity;                 // 0x64 Viscosity
    float vorticityConfinement;      // 0x68 VorticityConfinement
    float anisotropyScale;           // 0x6c always 0 from KF2
    float smoothing;                 // 0x70 always 0 from KF2
    float solidPressure;             // 0x74 SolidPressure
    float buoyancy;                  // 0x78 always 1 from KF2
    float diffuse[8];                // 0x7c diffuse-particle settings (KF2 uses none)
    float plasticThreshold;          // 0x9c PlasticThreshold
    float plasticCreep;              // 0xa0 PlasticCreep
    float collisionDistance;         // 0xa4 CollisionMargin
    float particleCollisionMargin;   // 0xa8 derived from CollisionDistance/Margins
    float shapeCollisionMargin;      // 0xac CollisionDistance
    float planes[8][4];              // 0xb0
    std::int32_t numPlanes;          // 0x130 always 0 from KF2
    std::int32_t relaxationMode;     // 0x134 0 global, 1 local
    float relaxationFactor;          // 0x138 RelaxationFactor
};
static_assert(sizeof(Params)==0x13c);
static_assert(offsetof(Params,fluid)==0x58);
static_assert(offsetof(Params,planes)==0xb0);
static_assert(offsetof(Params,relaxationFactor)==0x138);

// KFGame.exe GetFlexForceFieldProperties (0x1401b1ca0), consumed by the
// shipped UpdateForceFields CUDA kernel. This ABI has one capsule/vortex
// field, not a tagged collection of generic force modes. Local Y is its axis.
struct ForceField {
    float translation[3];           // 0x00 world-to-local translation
    float basis[9];                 // 0x0c column-major world-to-local basis
    float boundsRadius;             // 0x30 max(bottomRadius,topRadius)
    float boundsHeight;             // 0x34 capsule axis length
    float height;                   // 0x38 vortex axis length
    float bottomRadius;             // 0x3c
    float topRadius;                // 0x40
    float radialStrength;           // 0x44 signed outward force
    float rotationalStrength;       // 0x48 tangential force at local radius
    float liftStrength;             // 0x4c local Y force
    float boundaryFade;             // 0x50 fraction of bounds radius
    float noiseStrength;            // 0x54
    float noiseVectors[4][3];        // 0x58 supplied by the host each upload
};
static_assert(sizeof(ForceField)==0x88);
static_assert(offsetof(ForceField,basis)==0x0c);
static_assert(offsetof(ForceField,boundsRadius)==0x30);
static_assert(offsetof(ForceField,radialStrength)==0x44);
static_assert(offsetof(ForceField,noiseVectors)==0x58);

// flexExt asset as built by KFGame from a cooked UFlexAsset (0x68 bytes).
struct ExtAsset {
    float* particles;                // 0x00 local x,y,z,invMass
    std::int32_t* phases;            // 0x08 per-particle phase, offset by the instance
    std::int32_t numParticles;       // 0x10
    std::int32_t pad14;
    std::int32_t* springIndices;     // 0x18 pairs
    float* springCoefficients;       // 0x20
    float* springRestLengths;        // 0x28
    std::int32_t numSprings;         // 0x30
    float rigidStiffness;            // 0x34 >0 makes the whole asset one rigid shape
    float rigidCenter[3];            // 0x38 rest centre subtracted from particles
    std::int32_t pad44;
    std::int32_t* triangleIndices;   // 0x48 cloth faces
    std::int32_t numTriangles;       // 0x50
    std::uint8_t inflatable;         // 0x54
    std::uint8_t pad55[3];
    float inflatableVolume;          // 0x58
    float inflatablePressure;        // 0x5c
    float inflatableStiffness;       // 0x60
    std::int32_t pad64;
};
static_assert(sizeof(ExtAsset)==0x68);
static_assert(offsetof(ExtAsset,rigidStiffness)==0x34);
static_assert(offsetof(ExtAsset,triangleIndices)==0x48);

// flexExt instance (0x68 bytes). KFGame reads particleIndices/numParticles,
// rigidIndex and asset, and writes its render transform into `transform`.
struct ExtInstance {
    std::int32_t* particleIndices;   // 0x00
    std::int32_t numParticles;       // 0x08
    std::int32_t triangleIndex;      // 0x0c
    std::int32_t rigidIndex;         // 0x10 index into the rigid rotation/translation arrays, -1 if none
    std::int32_t inflatableIndex;    // 0x14
    const ExtAsset* asset;           // 0x18
    float transform[16];             // 0x20
    void* userData;                  // 0x60
};
static_assert(sizeof(ExtInstance)==0x68);
static_assert(offsetof(ExtInstance,rigidIndex)==0x10);
static_assert(offsetof(ExtInstance,transform)==0x20);

using ErrorCallback=void(*)(int severity,const char* message,const char* file,int line);

} // namespace kf2vr::flex
