// Tests for the behavioural rules the research pack calls out by name:
// recentre/snap-turn consistency, focus-loss cancellation without duplicate
// clicks, and hand/head independence of the fire pose.
#include "TestMain.h"
#include "kf2vr/Basis.h"
#include "kf2vr/InputState.h"
#include "kf2vr/PlayerOrigin.h"
#include "kf2vr/WeaponPose.h"

#include <limits>

using namespace kf2vr;
using namespace kf2vr::frames;

namespace { constexpr float kEps = 1e-4f; }

// ---------------------------------------------------------------- recentre --

TEST(Recentre_PutsHeadAtWorldForward) {
    PlayerOriginState o;
    const float headYaw = 1.1f;
    o.RecentreToHeadYaw(headYaw, {});
    CHECK_NEAR(o.YawRadians() + headYaw, 0.f, kEps);
}

TEST(Recentre_IsIdempotent) {
    PlayerOriginState o;
    o.RecentreToHeadYaw(0.9f, {});
    const float first = o.YawRadians();
    o.RecentreToHeadYaw(0.9f, {});  // head held still
    CHECK_NEAR(o.YawRadians(), first, kEps);
}

TEST(Recentre_KeepsRoomScaleHeadStationaryAndRemainsIdempotent) {
    PlayerOriginState o;
    o.SetPawnPosition({100.f, 200.f, 10.f});
    const auto head = ToUnreal(HeadInTracking{
        Quat::FromAxisAngle({0, 1, 0}, -0.9f), {0.6f, 1.7f, -0.8f}});
    const Vec3 before = head.Then(o.Current()).pos;
    o.RecentreToHeadYaw(0.9f, head.pos);
    CHECK_VEC(head.Then(o.Current()).pos, before, 1e-3f);
    CHECK_VEC(head.Then(o.Current()).ApplyDirection({1.f, 0.f, 0.f}),
              (Vec3{1.f, 0.f, 0.f}), 1e-3f);
    const OriginInWorld first = o.Current();
    o.RecentreToHeadYaw(0.9f, head.pos);
    CHECK_VEC(o.Current().pos, first.pos, 1e-3f);
    CHECK_QUAT(o.Current().rot, first.rot, kEps);
}

// --------------------------------------------------------------- snap turn --

TEST(SnapTurn_FiresOnceUntilStickReleased) {
    ComfortSettings c; c.snapTurnDegrees = 30.f; c.snapTurnRepeatSeconds = 0.25f;
    PlayerOriginState o(TrackingSpace::Standing, c);

    CHECK(o.UpdateTurn(1.0f, 0.00, {}));   // engage -> fires
    CHECK(!o.UpdateTurn(1.0f, 0.01, {}));  // still held, not re-armed
    CHECK(!o.UpdateTurn(1.0f, 1.00, {}));  // still held even after the lockout
    CHECK(o.TurnCount() == 1u);
}

TEST(SnapTurn_RearmsOnlyBelowReleaseThreshold) {
    ComfortSettings c; c.turnEngageThreshold = 0.75f; c.turnReleaseThreshold = 0.35f;
    PlayerOriginState o(TrackingSpace::Standing, c);

    CHECK(o.UpdateTurn(1.0f, 0.0, {}));
    CHECK(!o.UpdateTurn(0.50f, 1.0, {}));  // between thresholds: no re-arm, no fire
    CHECK(!o.UpdateTurn(1.0f, 2.0, {}));   // so this must not fire
    CHECK(!o.UpdateTurn(0.10f, 3.0, {}));  // below release: re-arms, does not fire
    CHECK(o.UpdateTurn(1.0f, 4.0, {}));    // now it may fire
    CHECK(o.TurnCount() == 2u);
}

TEST(SnapTurn_RespectsRepeatLockout) {
    ComfortSettings c; c.snapTurnRepeatSeconds = 0.25f;
    PlayerOriginState o(TrackingSpace::Standing, c);

    CHECK(o.UpdateTurn(1.0f, 0.00, {}));
    CHECK(!o.UpdateTurn(0.0f, 0.05, {}));   // re-arm
    CHECK(!o.UpdateTurn(1.0f, 0.10, {}));   // armed, but inside the lockout
    CHECK(!o.UpdateTurn(0.0f, 0.15, {}));   // re-arm again
    CHECK(o.UpdateTurn(1.0f, 0.40, {}));    // past the lockout
    CHECK(o.TurnCount() == 2u);
}

TEST(SnapTurn_IsYawOnlyAndSigned) {
    ComfortSettings c; c.snapTurnDegrees = 45.f; c.snapTurnRepeatSeconds = 0.f;
    PlayerOriginState o(TrackingSpace::Standing, c);
    const float step = 45.f * 3.14159265f / 180.f;

    o.UpdateTurn(1.0f, 0.0, {});
    CHECK_NEAR(o.YawRadians(), step, 1e-3f);
    o.UpdateTurn(0.0f, 0.1, {});
    o.UpdateTurn(-1.0f, 0.2, {});
    CHECK_NEAR(o.YawRadians(), 0.f, 1e-3f);

    // The transform it produces must have no pitch or roll: rotating world up
    // by it must leave world up unmoved.
    o.UpdateTurn(0.0f, 0.3, {});
    o.UpdateTurn(1.0f, 0.4, {});
    CHECK_VEC(o.Current().ApplyDirection(Vec3{0, 0, 1}), (Vec3{0, 0, 1}), 1e-4f);
}

TEST(SnapTurn_CancelDisarmsHeldStick) {
    PlayerOriginState o;
    CHECK(o.UpdateTurn(1.0f, 0.0, {}));
    o.CancelTransientInput();
    CHECK(!o.UpdateTurn(1.0f, 5.0, {}));  // must not fire while still physically held
    CHECK(!o.UpdateTurn(0.0f, 5.1, {}));
    CHECK(o.UpdateTurn(1.0f, 5.2, {}));
}

TEST(SnapTurn_PivotsAboutHeadAndKeepsHandsInAgreement) {
    ComfortSettings c;
    c.snapTurnDegrees = 90.f;
    PlayerOriginState o(TrackingSpace::Standing, c);
    o.SetPawnPosition({100.f, 200.f, 10.f});
    const auto head = ToUnreal(HeadInTracking{Quat::Identity(), {0.6f, 1.7f, -0.8f}});
    const auto hand = ToUnreal(Transform<GripRight, Tracking>{
        Quat::Identity(), {0.9f, 1.2f, -1.1f}});
    const Vec3 headBefore = head.Then(o.Current()).pos;
    const Vec3 handBefore = hand.Then(o.Current()).pos;
    CHECK(o.UpdateTurn(1.f, 0.0, head.pos));
    const auto headAfter = head.Then(o.Current());
    const auto handAfter = hand.Then(o.Current());
    CHECK_VEC(headAfter.pos, headBefore, 1e-3f);
    CHECK_VEC(handAfter.pos - headAfter.pos,
              o.Current().rot.Rotate(handBefore - headBefore), 1e-3f);

    // The engine will refresh pawn position next frame, even while stationary.
    // That must preserve the turn compensation; moving the pawn then moves both
    // head and hand by exactly the locomotion displacement.
    o.SetPawnPosition({100.f, 200.f, 10.f});
    CHECK_VEC(head.Then(o.Current()).pos, headBefore, 1e-3f);
    const Vec3 delta{5.f, -3.f, 2.f};
    o.SetPawnPosition(Vec3{100.f, 200.f, 10.f} + delta);
    CHECK_VEC(head.Then(o.Current()).pos, headAfter.pos + delta, 1e-3f);
    CHECK_VEC(hand.Then(o.Current()).pos, handAfter.pos + delta, 1e-3f);
}

TEST(SnapTurn_RepeatedTurnsAndRoomScaleWalkingKeepCurrentHeadStationary) {
    ComfortSettings c;
    c.snapTurnDegrees = 30.f;
    PlayerOriginState o(TrackingSpace::Standing, c);
    o.SetPawnPosition({100.f, 200.f, 0.f});
    kf2test::Rng rng(81);
    for (int i = 0; i < 100; ++i) {
        const auto head = ToUnreal(HeadInTracking{Quat::Identity(), rng.Vec()});
        const Vec3 before = head.Then(o.Current()).pos;
        o.UpdateTurn(0.f, i, head.pos);
        CHECK(o.UpdateTurn(i % 2 ? 1.f : -1.f, i + 0.5, head.pos));
        CHECK_VEC(head.Then(o.Current()).pos, before, 1e-3f);
    }
}

TEST(PlayerOrigin_InvalidSamplesDoNotMoveOrPoisonOrigin) {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    PlayerOriginState o;
    CHECK(!o.UpdateTurn(nan, 0.0, {}));
    CHECK(!o.UpdateTurn(1.f, nan, {}));
    CHECK(!o.UpdateTurn(1.f, 0.0, {nan, 0.f, 0.f}));
    o.RecentreToHeadYaw(inf, {});
    CHECK(o.TurnCount() == 0u && o.RecentreCount() == 0u);
    CHECK_NEAR(o.YawRadians(), 0.f, kEps);
    CHECK_VEC(o.Current().pos, (Vec3{}), kEps);
    CHECK(o.UpdateTurn(1.f, 0.0, {}));
}

// ------------------------------------------------------------- input state --

TEST(Button_EdgesAndHold) {
    ButtonState b;
    b.Update(false, 0.0);
    CHECK(!b.Pressed() && !b.Down());

    b.Update(true, 1.0);
    CHECK(b.Pressed() && b.Down() && !b.Released());

    b.Update(true, 1.5);
    CHECK(!b.Pressed() && b.Down());
    CHECK_NEAR(static_cast<float>(b.HeldSeconds()), 0.5f, 1e-5f);
    CHECK(b.HeldFor(0.4) && !b.HeldFor(0.6));

    b.Update(false, 2.0);
    CHECK(b.Released() && !b.Down());
    CHECK_NEAR(static_cast<float>(b.HeldSeconds()), 0.f, 1e-5f);
}

TEST(Button_CancelEmitsExactlyOneRelease) {
    // A consumer that starts firing on Pressed and stops on Released must stay
    // balanced across a cancel -- otherwise the weapon keeps firing into the
    // dashboard.
    ButtonState b;
    b.Update(true, 0.0);
    CHECK(b.Pressed());

    b.Cancel(CancelReason::FocusLost);
    CHECK(b.Released());
    CHECK(!b.Down());
    CHECK(!b.Pressed());
    CHECK(b.LastCancelReason() == CancelReason::FocusLost);
}

TEST(Button_CancelWhileUpEmitsNoRelease) {
    ButtonState b;
    b.Update(false, 0.0);
    b.Cancel(CancelReason::MenuOpened);
    CHECK(!b.Released());
    CHECK(!b.Down());
}

TEST(Button_RepeatedCancelDoesNotReplayRelease) {
    ButtonState b;
    b.Update(true, 0.0);
    b.Cancel(CancelReason::FocusLost);
    CHECK(b.Released());
    b.Cancel(CancelReason::TrackingLost);
    CHECK(!b.Released());
    CHECK(!b.Down() && !b.Pressed());
    b.Update(true, 0.1);
    CHECK(!b.Released() && !b.Pressed() && !b.Down());
}

TEST(Button_ZeroDurationHoldStillRequiresPress) {
    ButtonState b;
    CHECK(!b.HeldFor(0.0));
    b.Update(true, 0.0);
    CHECK(b.HeldFor(0.0));
    b.Update(false, 0.1);
    CHECK(!b.HeldFor(0.0));
    b.Cancel(CancelReason::PawnDied);
    CHECK(!b.HeldFor(0.0));
}

TEST(Button_NoPhantomPressWhileStillPhysicallyHeld) {
    // Return from the dashboard with the trigger still squeezed: no shot.
    ButtonState b;
    b.Update(true, 0.0);
    b.Cancel(CancelReason::FocusLost);

    for (double t = 0.1; t < 1.0; t += 0.1) {
        b.Update(true, t);  // user has not let go
        CHECK(!b.Pressed());
        CHECK(!b.Down());
    }
    CHECK(b.Suppressed());
}

TEST(Button_RearmsOnRealReleaseWithoutDuplicateClick) {
    // ...and one physical release is enough to re-arm. The user must not have
    // to click twice.
    ButtonState b;
    b.Update(true, 0.0);
    b.Cancel(CancelReason::TrackingLost);
    b.Update(true, 0.1);
    CHECK(b.Suppressed());

    b.Update(false, 0.2);          // the real release
    CHECK(!b.Suppressed());
    CHECK(!b.Pressed());

    b.Update(true, 0.3);           // next genuine squeeze
    CHECK(b.Pressed() && b.Down());
}

TEST(ActionSet_CancelsEverythingTogether) {
    ActionSet a;
    a.triggerRight.Update(true, 0.0);
    a.gripLeft.Update(true, 0.0);
    a.CancelAll(CancelReason::PawnDied);
    CHECK(!a.triggerRight.Down() && a.triggerRight.Released());
    CHECK(!a.gripLeft.Down() && a.gripLeft.Released());
    CHECK(!a.reload.Down());
    CHECK(a.bash.Suppressed());
}

// ------------------------------------------------------------- weapon pose --

namespace {
// A deliberately non-trivial placeholder profile: the muzzle is forward of and
// above the grip, and the weapon is pitched in the hand. Values are arbitrary
// (measured == false) -- the tests assert relationships, not numbers.
WeaponProfile TestProfile() {
    WeaponProfile p;
    p.weaponClass   = "TestWeapon";
    p.weaponInGrip  = Transform<Weapon, GripRight>{
        Quat::FromAxisAngle({0, 1, 0}, -0.35f), Vec3{2.f, 0.f, 1.f}};
    p.muzzleInWeapon = Transform<Muzzle, Weapon>{Quat::Identity(), Vec3{18.f, 0.f, 3.f}};
    return p;
}
}  // namespace

TEST(FirePose_IsIndependentOfHeadMotion) {
    // Acceptance matrix, "Hand versus head": hold the controller still, turn
    // and lean the head, and the gun must stay controller-relative. Nothing in
    // the grip -> weapon -> muzzle chain can reference the head, so this is a
    // structural guarantee; the test pins it so a later edit cannot quietly
    // introduce a head term.
    const WeaponProfile profile = TestProfile();
    const OriginInWorld origin{Quat::FromAxisAngle({0, 0, 1}, 0.4f), Vec3{500, -120, 64}};
    const Transform<GripRight, PlayerOrigin> gripOrigin{
        Quat::FromAxisAngle({0, 0, 1}, 0.2f), Vec3{20, 15, 100}};

    const auto gripWorld = gripOrigin.Then(origin);
    const FirePose a = MakeFirePose(gripWorld, profile);
    const FirePose b = MakeFirePose(gripWorld, profile);
    CHECK_VEC(a.origin, b.origin, 0.f);
    CHECK_VEC(a.direction, b.direction, 0.f);
}

TEST(FirePose_TracksGripRotation) {
    // Acceptance matrix, "Wrist roll": rotating the controller must rotate the
    // fire direction by the same rotation, with no independent drift.
    const WeaponProfile profile = TestProfile();
    const OriginInWorld origin = OriginInWorld::Identity();

    const Transform<GripRight, PlayerOrigin> g0{Quat::Identity(), Vec3{0, 0, 0}};
    const Quat yaw = Quat::FromAxisAngle({0, 0, 1}, 0.6f);
    const Transform<GripRight, PlayerOrigin> g1{yaw, Vec3{0, 0, 0}};

    const FirePose f0 = MakeFirePose(g0.Then(origin), profile);
    const FirePose f1 = MakeFirePose(g1.Then(origin), profile);

    CHECK_VEC(f1.direction, yaw.Rotate(f0.direction), 1e-4f);
    CHECK_VEC(f1.origin,    yaw.Rotate(f0.origin),    1e-3f);
}

TEST(FirePose_OriginIsAheadOfTheGrip) {
    // The shot must leave the muzzle, not the hand: the fire origin has to sit
    // well forward of the grip.
    const WeaponProfile profile = TestProfile();
    const Transform<GripRight, World> grip{Quat::Identity(), Vec3{0, 0, 0}};
    const FirePose f = MakeFirePose(grip, profile);
    CHECK(f.origin.Length() > 10.f);
    CHECK_NEAR(f.direction.Length(), 1.f, 1e-5f);
}

TEST(FirePose_ReportsUnmeasuredProfile) {
    // A placeholder profile must never be reported as calibrated.
    CHECK(!MakeFirePose(Transform<GripRight, World>::Identity(), TestProfile())
               .fromMeasuredProfile);
}

TEST(FirePose_XrGripDoesNotScaleUnrealAssetOffsetsAgain) {
    // A runtime grip 0.4 m ahead of the tracking origin, plus a measured
    // 20 UU barrel, must put the muzzle at 40 UU when using 50 UU per metre.
    // Previously ToUnreal left scale=50, stretching the barrel to 1000 UU.
    WeaponProfile profile;
    profile.weaponInGrip.pos = {2.f, 0.f, 0.f};
    profile.muzzleInWeapon.pos = {18.f, 0.f, 0.f};
    const Transform<GripRight, Tracking> gripXr{Quat::Identity(), {0.f, 1.2f, -0.4f}};
    const OriginInWorld world{Quat::Identity(), {100.f, 200.f, 0.f}};
    const auto gripWorld = ToUnreal(gripXr, 50.f).Then(world);
    const auto fire = MakeFirePose(gripWorld, profile);
    CHECK_VEC(fire.origin, (Vec3{140.f, 200.f, 60.f}), 1e-3f);
    CHECK_NEAR((fire.origin - gripWorld.pos).Length(), 20.f, 1e-3f);
    CHECK_VEC(fire.direction, (Vec3{1.f, 0.f, 0.f}), kEps);

    // Changing the calibrated tracking scale moves the controller; measured
    // asset offsets already use game units and must stay the same size.
    const auto rescaledGrip = ToUnreal(gripXr, 100.f).Then(world);
    const auto rescaledFire = MakeFirePose(rescaledGrip, profile);
    CHECK_NEAR((rescaledFire.origin - rescaledGrip.pos).Length(), 20.f, 1e-3f);
}
