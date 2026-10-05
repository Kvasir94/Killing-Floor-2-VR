// Golden tests for the frame-typed transform graph and the single basis
// crossing. These are the tests that would have caught KF1's double-applied
// head/eye transform.
#include "TestMain.h"
#include "kf2vr/Basis.h"
#include "kf2vr/Transform.h"

using namespace kf2vr;
using namespace kf2vr::frames;

namespace {
constexpr float kEps = 1e-4f;

// Throwaway frame tags, for algebraic properties that do not care about
// physical meaning.
struct A; struct B; struct C;
}  // namespace

TEST(Transform_ApplyMatchesManualComposition) {
    kf2test::Rng rng(1);
    for (int i = 0; i < 500; ++i) {
        const Quat  r = rng.Rot();
        const Vec3  t = rng.Vec();
        const float s = rng.Range(0.25f, 4.f);
        const Transform<A, B> x{r, t, s};
        const Vec3 p = rng.Vec();
        CHECK_VEC(x.Apply(p), r.Rotate(p * s) + t, kEps * 10.f);
    }
}

TEST(Transform_ThenIsFunctionComposition) {
    // (a.Then(b)).Apply(p) must equal b.Apply(a.Apply(p)) exactly in intent.
    kf2test::Rng rng(2);
    for (int i = 0; i < 500; ++i) {
        const Transform<A, B> ab{rng.Rot(), rng.Vec(), rng.Range(0.5f, 2.f)};
        const Transform<B, C> bc{rng.Rot(), rng.Vec(), rng.Range(0.5f, 2.f)};
        const Vec3 p = rng.Vec();
        CHECK_VEC(ab.Then(bc).Apply(p), bc.Apply(ab.Apply(p)), 1e-3f);
    }
}

TEST(Transform_InverseRoundTrips) {
    kf2test::Rng rng(3);
    for (int i = 0; i < 500; ++i) {
        const Transform<A, B> x{rng.Rot(), rng.Vec(), rng.Range(0.5f, 2.f)};
        const Vec3 p = rng.Vec();
        CHECK_VEC(x.Inverse().Apply(x.Apply(p)), p, 1e-3f);
        CHECK_VEC(x.Then(x.Inverse()).Apply(p), p, 1e-3f);
    }
}

TEST(Basis_AxesMapAsDocumented) {
    // XR forward (0,0,-1) -> Unreal forward (1,0,0)
    CHECK_VEC(BasisXrToUnreal(Vec3{0, 0, -1}), (Vec3{1, 0, 0}), kEps);
    // XR right (1,0,0) -> Unreal right (0,1,0)
    CHECK_VEC(BasisXrToUnreal(Vec3{1, 0, 0}), (Vec3{0, 1, 0}), kEps);
    // XR up (0,1,0) -> Unreal up (0,0,1)
    CHECK_VEC(BasisXrToUnreal(Vec3{0, 1, 0}), (Vec3{0, 0, 1}), kEps);
}

TEST(Basis_IsAHandednessFlip) {
    // right x up should give BACK-ward in one convention and FORWARD in the
    // other; that sign disagreement is the whole point of the flip, and a
    // basis change that silently preserved it would be wrong.
    const Vec3 xrCross = Vec3{1, 0, 0}.Cross(Vec3{0, 1, 0});          // XR: (0,0,1) = backward
    const Vec3 ueCross = Vec3{0, 1, 0}.Cross(Vec3{0, 0, 1});          // UE: (1,0,0) = forward
    CHECK_VEC(BasisXrToUnreal(xrCross), (Vec3{-1, 0, 0}), kEps);      // maps to UE backward
    CHECK_VEC(ueCross, (Vec3{1, 0, 0}), kEps);
}

TEST(Basis_VectorRoundTrips) {
    kf2test::Rng rng(4);
    for (int i = 0; i < 200; ++i) {
        const Vec3 v = rng.Vec();
        CHECK_VEC(BasisUnrealToXr(BasisXrToUnreal(v)), v, kEps);
    }
}

TEST(Basis_RotationConversionIsAHomomorphism) {
    // The one test that actually catches a botched handedness conversion:
    // converting a rotated vector must equal rotating the converted vector
    // with the converted rotation.
    kf2test::Rng rng(5);
    for (int i = 0; i < 1000; ++i) {
        const Quat rXr = rng.Rot();
        const Vec3 vXr = rng.Vec();
        const Vec3 lhs = BasisXrToUnreal(rXr.Rotate(vXr));
        const Vec3 rhs = BasisXrToUnreal(rXr).Rotate(BasisXrToUnreal(vXr));
        CHECK_VEC(lhs, rhs, 1e-3f);
    }
}

TEST(Basis_ConvertedRotationStaysUnit) {
    kf2test::Rng rng(6);
    for (int i = 0; i < 500; ++i) {
        CHECK_NEAR(BasisXrToUnreal(rng.Rot()).LengthSq(), 1.f, 1e-3f);
    }
}

TEST(ToUnreal_AppliesScaleOnceAndOnly) {
    const float uu = 50.f;
    HeadInTracking head{Quat::Identity(), Vec3{0.f, 1.7f, 0.f}};  // 1.7 m up
    const HeadInOrigin inOrigin = ToUnreal(head, uu);
    // 1.7 m up in XR is +Z in Unreal, scaled once.
    CHECK_VEC(inOrigin.pos, (Vec3{0.f, 0.f, 1.7f * uu}), 1e-2f);
    CHECK_NEAR(inOrigin.scale, 1.f, kEps);
}

TEST(ToUnreal_ConvertsBodyLocalPointsConsistently) {
    // A local XR point first transformed by the XR pose then converted must
    // match converting that local point and applying the converted pose.
    kf2test::Rng rng(7);
    for (int i = 0; i < 500; ++i) {
        const HeadInTracking pose{rng.Rot(), rng.Vec(), rng.Range(0.5f, 2.f)};
        const Vec3 localXr = rng.Vec();
        const float units = rng.Range(30.f, 100.f);
        const auto unreal = ToUnreal(pose, units);
        CHECK_VEC(unreal.Apply(BasisXrToUnreal(localXr) * units),
                  BasisXrToUnreal(pose.Apply(localXr)) * units, 1e-3f);
        CHECK_NEAR(unreal.scale, pose.scale, kEps);
    }
}

TEST(ToUnreal_DoubleApplicationIsDetectablyWrong) {
    // The KF1 regression, written down. Applying the tracking transform twice
    // does NOT land where applying it once lands -- so any render path that
    // reaches world space by a second route is measurably broken, not subtly
    // off. (Applying it twice does not even typecheck here; this test asserts
    // that the type rule is protecting a real numeric difference, not a
    // cosmetic one.)
    const float uu = 50.f;
    HeadInTracking head{Quat::FromAxisAngle({0, 1, 0}, 0.7f), Vec3{0.2f, 1.7f, -0.3f}};

    const HeadInOrigin once = ToUnreal(head, uu);

    // Simulate the bug: feed the already-converted pose back through the
    // conversion by re-labelling it as tracking-space.
    HeadInTracking relabelled{once.rot, once.pos};
    const HeadInOrigin twice = ToUnreal(relabelled, uu);

    CHECK(!kf2test::NearVec(once.pos, twice.pos, 1.f));
    CHECK(!kf2test::NearQuat(once.rot, twice.rot, 1e-2f));
}

TEST(Chain_HeadAndHandShareOneOriginTransform) {
    // Head and hand both reach world through the same PlayerOrigin->World
    // transform. Rotating the origin must rotate both by the same amount --
    // the research pack's "recenter and artificial turning must transform
    // hands and head consistently", asserted numerically.
    const float uu = 50.f;
    HeadInTracking headXr{Quat::Identity(), Vec3{0.f, 1.7f, 0.f}};
    Transform<GripRight, Tracking> gripXr{Quat::Identity(), Vec3{0.3f, 1.2f, -0.4f}};

    const auto headOrigin = ToUnreal(headXr, uu);
    const auto gripOrigin = ToUnreal(gripXr, uu);

    const OriginInWorld before{Quat::Identity(), Vec3{100, 200, 0}};
    const float yaw = 0.5f;
    const OriginInWorld after{Quat::FromAxisAngle({0, 0, 1}, yaw), Vec3{100, 200, 0}};

    const Vec3 headBefore = headOrigin.Then(before).pos;
    const Vec3 gripBefore = gripOrigin.Then(before).pos;
    const Vec3 headAfter  = headOrigin.Then(after).pos;
    const Vec3 gripAfter  = gripOrigin.Then(after).pos;

    // Both must have rotated about the origin position by exactly `yaw`.
    const Quat r = Quat::FromAxisAngle({0, 0, 1}, yaw);
    CHECK_VEC(headAfter, r.Rotate(headBefore - before.pos) + before.pos, 1e-2f);
    CHECK_VEC(gripAfter, r.Rotate(gripBefore - before.pos) + before.pos, 1e-2f);
}
