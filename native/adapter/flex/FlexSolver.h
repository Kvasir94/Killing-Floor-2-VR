#pragma once
// Portable particle solver behind the FleX 1.0.5 interface KF2 drives.
// Position-based dynamics on the CPU: position-based fluids for blood and
// bile, shape matching for gib rigids, distance springs for strands, and
// collision with the world triangles and convex shapes KF2 gathers each frame.
// No graphics API or vendor runtime is involved; KF2 reads the results from
// host memory and draws them with its own shaders.
#include "FlexAbi.h"

#include <array>
#include <cstdint>
#include <vector>

namespace kf2vr::flex {

struct Vec3 { float x=0,y=0,z=0; };

class Solver {
public:
    explicit Solver(int maxParticles);

    int MaxParticles() const { return maxParticles_; }
    void SetParams(const Params& params);
    const Params& GetParams() const { return params_; }

    // Host-side copies; counts are clamped to MaxParticles().
    void SetActive(const int* indices,int count);
    int ActiveCount() const { return static_cast<int>(active_.size()); }
    void GetActive(int* indices) const;
    void SetParticles(const float* xyzw,int count);
    void GetParticles(float* xyzw,int count) const;
    void SetVelocities(const float* xyz,int count);
    void GetVelocities(float* xyz,int count) const;
    void SetPhases(const int* phases,int count);
    void GetPhases(int* phases,int count) const;
    void SetNormals(const float* xyzw,int count);
    void GetNormals(float* xyzw,int count) const;
    void GetDensities(float* densities,int count) const;
    void GetBounds(float* lower,float* upper) const;

    void SetSprings(const int* pairs,const float* restLengths,const float* stiffness,int count);
    // offsets has rigidCount+1 entries into indices/restPositions (xyz, local to the rigid centre).
    void SetRigids(const int* offsets,const int* indices,const float* restPositions,const float* stiffness,
        const float* rotations,const float* translations,int rigidCount);
    void GetRigidTransforms(float* rotations,float* translations) const;
    void SetDynamicTriangles(const int* indices,int triangleCount);

    // World collision. Triangles are a soup of xyzw vertices, three per triangle.
    void SetTriangles(const float* vertices,int triangleCount,float cellSize);
    void SetConvexes(const float* aabbMin,const float* aabbMax,const int* planeOffsets,const int* planeCounts,
        const float* planes,const float* positions,const float* rotations,const int* flags,int convexCount,int planeCount);
    void SetForceFields(const ForceField* fields,int count);

    void Update(float dt,int substeps);

private:
    struct Rigid { int begin=0,end=0; float stiffness=1; std::array<float,4> rotation{0,0,0,1}; Vec3 translation; };
    struct Convex { Vec3 lower,upper,position; std::array<float,4> rotation{0,0,0,1}; int planeBegin=0,planeCount=0; };
    struct ParticleContact { Vec3 normal; float depth=0; bool touching=false; };

    void Step(float h);
    void ApplyForceFields(float h);
    void BuildNeighbors();
    void ComputeDensities();
    void SolveFluid(std::vector<Vec3>& delta) const;
    void SolveContacts(std::vector<Vec3>& delta) const;
    void SolveShapes();
    void SolveSprings();
    void SolveWorld(float h);
    void ApplyFluidVelocityTerms(float h);
    void ComputeOutputs();
    bool IsFluid(int index) const;
    bool Collide(int a,int b) const;
    void CollideTriangles(int index,Vec3& predicted,const Vec3& previous,ParticleContact& contact) const;
    void CollideConvexes(int index,Vec3& predicted,ParticleContact& contact) const;
    void RebuildKernel();

    int maxParticles_;
    Params params_{};
    std::vector<int> active_;
    std::vector<std::array<float,4>> position_;
    std::vector<Vec3> velocity_;
    std::vector<int> phase_;
    std::vector<std::array<float,4>> normal_;
    std::vector<float> density_;
    std::vector<std::uint8_t> structural_; // 1 for rigid/spring members, never fluid

    // Per-substep scratch, indexed by particle.
    std::vector<Vec3> predicted_;
    std::vector<Vec3> previous_;
    std::vector<float> lambda_;
    std::vector<ParticleContact> contact_;
    std::vector<Vec3> delta_,scratchVelocity_;
    std::vector<int> neighborCount_;
    std::vector<int> neighbors_;
    static constexpr int MaxNeighbors=48;
    std::vector<std::uint32_t> cellKey_;
    std::vector<int> cellStart_,cellEnd_,sorted_;
    float cellSize_=1;

    std::vector<int> springPairs_;
    std::vector<float> springRest_,springStiffness_;
    std::vector<Rigid> rigids_;
    std::vector<int> rigidIndices_;
    std::vector<Vec3> rigidRest_;
    std::vector<int> triangles_;

    std::vector<Vec3> worldVertices_;  // three per triangle
    std::vector<Vec3> worldNormals_;   // one per triangle
    std::vector<int> triCellStart_,triCellItems_;
    std::vector<std::uint32_t> triCellKeys_;
    float triCellSize_=64;
    std::vector<Convex> convexes_;
    std::vector<std::array<float,4>> convexPlanes_;
    std::vector<ForceField> forceFields_;

    float restDensity_=1,poly6_=0,spikyGradient_=0,kernelRadius_=1;
    Vec3 lower_,upper_;
};

// Pure helpers shared with the native tests.
std::array<float,4> ExtractRotation(const float a[9],std::array<float,4> q,int iterations);
// Column-major rotation matrix to an x,y,z,w quaternion.
std::array<float,4> QuaternionFromMatrix(const float m[9]);
float LatticeRestDensity(float radius,float spacing);

} // namespace kf2vr::flex
