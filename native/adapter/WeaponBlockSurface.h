#pragma once
#include <array>
#include <span>
#include <vector>

namespace kf2vr::adapter::weaponblock {
struct Vec { float x{}, y{}, z{}; };
struct Quat { float x{}, y{}, z{}, w{1}; };
struct Triangle { Vec a,b,c; };
struct IndexedMesh { std::span<const Vec> vertices; std::span<const std::array<unsigned,3>> triangles; };
struct Motion { Vec before, after; Quat beforeQ, afterQ; };
struct Hit {
    Vec point, normal, localPoint, victimLocalPoint;
    float fraction{};
    unsigned triangleIndex{};
};
enum class HurtboxKind { Sphere, Capsule, Box };
struct Hurtbox {
    HurtboxKind kind{};
    Vec halfExtent{};
    float radius{},halfLength{};
};
// World UU/s, radians/s, kg^-1 and (kg*UU^2)^-1. Inertia axes include
// the body's actual center-of-mass rotation, not the visible mesh frame.
struct RigidBodyState {
    Vec center,linear,angular,inverseInertia;
    Quat inertiaQ;
    float inverseMass{};
};
bool ContactImpulse(const RigidBodyState&,Vec at,Vec normal,Vec victimVelocity,float restitution,
                    Vec& impulse,Vec& pointVelocity);
struct FaceInfo { int sourceFace{-1},material{-1},region{}; };
struct SharpEdge { Vec a,b,axis; };
struct SharpRegions {
    Vec tip{};
    float tipRadius{},edgeRadius{},edgeMinZ{};
    bool projectY{};
    std::span<const SharpEdge> edges{};
    Vec tipAxis{},edgeAxis{};
};
// Immutable mesh hierarchy, built once when a supported held mesh is admitted.
class Surface {
    struct Box { Vec low,high; };
    struct Node { Box box; unsigned begin{},end{},left{},right{}; };
    std::vector<Triangle> faces_;
    // BVH partitioning never changes original catalog face/material identity.
    std::vector<unsigned> order_;
    std::vector<Node> nodes_;
    void Initialize();
    unsigned Build(unsigned begin,unsigned end);
public:
    explicit Surface(std::span<const Triangle> faces);
    explicit Surface(IndexedMesh mesh);
    bool Sweep(std::span<const Triangle> blade,const Motion& weapon,const Motion& attack,
               float bladeScale,Hit& hit) const;
    bool SweepHurtbox(const Motion& weapon,const Motion& victim,const Hurtbox& shape,Hit& hit,float weaponScale=1) const;
};
// IDs are selected only by exact authored first-person mesh name in script.
const Surface* Catalog(int id);
bool CatalogIsWorld(int id);
std::span<const Triangle> GorefastBlade();
FaceInfo CatalogFaceInfo(int id,unsigned triangle);
int ClassifySharpContact(const SharpRegions& regions,Vec localPoint,int faceRegion=0);
int ClassifyCatalogContact(int id,unsigned triangle,Vec localPoint);
// Blade zone at a catalog-local point with every zone radius widened by slack:
// 0 blunt, 1 edge, 2 tip (VRWorldGunRigs.SharpAt).
int ClassifyCatalogPoint(int id,Vec localPoint,float slack);
void CatalogContactAxes(int id,Vec localPoint,Vec& tipAxis,Vec& edgeAxis,Vec& edgeTangent);
Vec RigidPointVelocity(const Motion& motion,Vec local,float fraction,float seconds);
}
