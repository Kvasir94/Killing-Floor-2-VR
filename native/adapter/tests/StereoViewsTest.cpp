#include "StereoViews.h"
#include <DirectXMath.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <stdexcept>

using namespace kf2vr;
using namespace kf2vr::adapter;
namespace dx = DirectX;

static void Check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static bool Near(float a, float b, float epsilon = 0.0001f) { return std::abs(a - b) < epsilon; }
static pinned::NativeMatrix4 Matrix(dx::FXMMATRIX matrix) {
    dx::XMFLOAT4X4 stored;
    dx::XMStoreFloat4x4(&stored, matrix);
    pinned::NativeMatrix4 result;
    std::memcpy(result.m, &stored, sizeof(stored));
    return result;
}
static pinned::NativeMatrix4 Identity() { return Matrix(dx::XMMatrixIdentity()); }
static pinned::NativeMatrix4 Projection() {
    pinned::NativeMatrix4 result{};
    result.m[0][0] = result.m[1][1] = result.m[2][2] = result.m[2][3] = 1;
    result.m[3][2] = -10;
    return result;
}
static xr::FrameState Frame() {
    xr::FrameState frame;
    frame.shouldRender = frame.viewsValid = frame.headPoseValid = true;
    frame.eyeLeft.poseValid = frame.eyeRight.poseValid = true;
    frame.eyeLeft.pose.pos.x = -0.032f;
    frame.eyeRight.pose.pos.x = 0.032f;
    frame.eyeLeft.fov = {-0.85f, 0.7f, 0.8f, -0.65f};
    frame.eyeRight.fov = {-0.7f, 0.85f, 0.8f, -0.65f};
    return frame;
}
static void Bounds(const pinned::NativeMatrix4& p, const xr::FovRadians& fov) {
    const float w = p.m[2][3];
    Check(Near((std::tan(fov.angleLeft) * p.m[0][0] + p.m[2][0]) / w, -1), "left clip boundary");
    Check(Near((std::tan(fov.angleRight) * p.m[0][0] + p.m[2][0]) / w, 1), "right clip boundary");
    Check(Near((std::tan(fov.angleDown) * p.m[1][1] + p.m[2][1]) / w, -1), "down clip boundary");
    Check(Near((std::tan(fov.angleUp) * p.m[1][1] + p.m[2][1]) / w, 1), "up clip boundary");
}
static void Equal(const pinned::NativeMatrix4& a, const pinned::NativeMatrix4& b, float epsilon = 0.0001f) {
    for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c)
        Check(Near(a.m[r][c], b.m[r][c], epsilon), "matrix equality");
}
static pinned::NativeMatrix4 CameraToWorld(const pinned::NativeMatrix4& view) {
    dx::XMFLOAT4X4 stored;
    std::memcpy(&stored, view.m, sizeof(stored));
    return Matrix(dx::XMMatrixInverse(nullptr, dx::XMLoadFloat4x4(&stored)));
}
static Vec3 Position(const pinned::NativeMatrix4& cameraToWorld) {
    return {cameraToWorld.m[3][0], cameraToWorld.m[3][1], cameraToWorld.m[3][2]};
}
static void EqualPosition(Vec3 actual, Vec3 expected) {
    Check(Near(actual.x, expected.x, 0.002f) && Near(actual.y, expected.y, 0.002f) &&
        Near(actual.z, expected.z, 0.002f), "world position equality");
}
static void CheckWorldOffset(const pinned::NativeMatrix4& baseView, const HeadInTracking& reference,
                             const xr::FrameState& frame, const Quat& applied = {}) {
    std::array<EyeMatrices, 2> ordinary, explicitZero, shifted;
    std::string error;
    const Vec3 offset{-245, 63, 37};
    Check(BuildStereoMatrices(baseView, Projection(), reference, frame, ordinary, error, applied), "ordinary eyes");
    Check(BuildStereoMatrices(baseView, Projection(), reference, frame, explicitZero, error, applied, {}), "zero offset eyes");
    Check(BuildStereoMatrices(baseView, Projection(), reference, frame, shifted, error, applied, offset), "offset eyes");
    std::array<Vec3, 2> originalPositions, shiftedPositions;
    for (unsigned eye = 0; eye < 2; ++eye) {
        Check(std::memcmp(ordinary[eye].view.m, explicitZero[eye].view.m, sizeof(ordinary[eye].view.m)) == 0,
            "zero offset preserves view bit-for-bit");
        Check(std::memcmp(ordinary[eye].projection.m, explicitZero[eye].projection.m,
            sizeof(ordinary[eye].projection.m)) == 0, "zero offset preserves projection bit-for-bit");
        const auto originalWorld = CameraToWorld(ordinary[eye].view);
        const auto shiftedWorld = CameraToWorld(shifted[eye].view);
        originalPositions[eye] = Position(originalWorld);
        shiftedPositions[eye] = Position(shiftedWorld);
        EqualPosition(shiftedPositions[eye] - originalPositions[eye], offset);
        for (unsigned r = 0; r < 3; ++r) for (unsigned c = 0; c < 3; ++c)
            Check(Near(originalWorld.m[r][c], shiftedWorld.m[r][c]), "offset preserves eye orientation");
        Check(std::memcmp(ordinary[eye].projection.m, shifted[eye].projection.m,
            sizeof(ordinary[eye].projection.m)) == 0, "offset preserves asymmetric eye projection exactly");
    }
    EqualPosition(shiftedPositions[1] - shiftedPositions[0], originalPositions[1] - originalPositions[0]);
    Check(Near((shiftedPositions[1] - shiftedPositions[0]).LengthSq(), 6.4f * 6.4f, 0.02f),
        "world offset preserves physical eye separation");
}

int main() {
    try {
        auto frame = Frame();
        std::array<EyeMatrices, 2> eyes;
        std::string error;
        const auto stockProjection = Projection();
        Check(BuildStereoMatrices(Identity(), stockProjection, {}, frame, eyes, error), "valid sample");
        Check(Near(eyes[0].view.m[3][0], 3.2f), "left eye has correct IPD at KF2 prototype scale");
        Check(Near(eyes[1].view.m[3][0], -3.2f), "right eye has correct IPD at KF2 prototype scale");
        Bounds(eyes[0].projection, frame.eyeLeft.fov);
        Bounds(eyes[1].projection, frame.eyeRight.fov);
        for (const auto& eye : eyes) {
            Check(eye.projection.m[2][2] == stockProjection.m[2][2], "depth scale preserved");
            Check(eye.projection.m[2][3] == stockProjection.m[2][3], "homogeneous depth preserved");
            Check(eye.projection.m[3][2] == stockProjection.m[3][2], "near depth preserved");
        }

        // A nonidentity capture pose must still produce neutral IPD-only eyes.
        HeadInTracking reference{Quat::FromAxisAngle({0,1,0}, 0.7f), {1,2,3}};
        frame.head = reference;
        frame.eyeLeft.pose = {reference.rot, reference.Apply({-0.032f,0,0})};
        frame.eyeRight.pose = {reference.rot, reference.Apply({0.032f,0,0})};
        const auto baseWorld = dx::XMMatrixRotationY(0.4f) * dx::XMMatrixTranslation(100,200,300);
        const auto baseView = dx::XMMatrixInverse(nullptr, baseWorld);
        Check(BuildStereoMatrices(Matrix(baseView), stockProjection, reference, frame, eyes, error), "nonidentity reference");
        Equal(eyes[0].view, Matrix(dx::XMMatrixInverse(nullptr, dx::XMMatrixTranslation(-3.2f,0,0) * baseWorld)), 0.001f);
        Equal(eyes[1].view, Matrix(dx::XMMatrixInverse(nullptr, dx::XMMatrixTranslation(3.2f,0,0) * baseWorld)), 0.001f);

        // Tracking forward is -Z; native camera forward is +Z.
        frame = Frame();
        frame.head.pos.z = frame.eyeLeft.pose.pos.z = frame.eyeRight.pose.pos.z = -0.3f;
        Check(BuildStereoMatrices(Identity(), stockProjection, {}, frame, eyes, error), "forward lean");
        Check(Near(eyes[0].view.m[3][2], -30), "forward lean is not reflected twice");
        frame = Frame();
        frame.head.rot = Quat::FromAxisAngle({1,0,0}, 0.5f);
        frame.eyeLeft.pose = {frame.head.rot, frame.head.rot.Rotate({-0.032f,0,0})};
        frame.eyeRight.pose = {frame.head.rot, frame.head.rot.Rotate({0.032f,0,0})};
        Check(BuildStereoMatrices(Identity(), stockProjection, {}, frame, eyes, error), "head pitch");
        const auto expectedWorld = dx::XMMatrixTranslation(-3.2f,0,0) * dx::XMMatrixRotationX(-0.5f);
        Equal(eyes[0].view, Matrix(dx::XMMatrixInverse(nullptr, expectedWorld)));

        // An inspection pullback is identical in world axes for both eyes,
        // independent of body rotation, recenter reference, head pose or IPD.
        CheckWorldOffset(Identity(), {}, Frame());
        frame = Frame();
        const Quat localHead = (Quat::FromAxisAngle({0,1,0}, 0.45f) *
            Quat::FromAxisAngle({1,0,0}, -0.25f) * Quat::FromAxisAngle({0,0,1}, 0.2f)).Normalized();
        const Vec3 lean{0.12f, -0.08f, -0.21f};
        frame.head = {(reference.rot * localHead).Normalized(), reference.Apply(lean)};
        frame.eyeLeft.pose = {frame.head.rot, reference.Apply(lean + localHead.Rotate({-0.032f,0,0}))};
        frame.eyeRight.pose = {frame.head.rot, reference.Apply(lean + localHead.Rotate({0.032f,0,0}))};
        const Quat applied = (Quat::FromAxisAngle({0,1,0}, -0.45f) *
            Quat::FromAxisAngle({1,0,0}, 0.25f)).Normalized();
        const auto rotatedBody = dx::XMMatrixRotationRollPitchYaw(0.15f, 0.8f, -0.1f) *
            dx::XMMatrixTranslation(173, -212, 81);
        const auto trackedCamera = dx::XMMatrixRotationQuaternion(
            dx::XMVectorSet(applied.x, applied.y, applied.z, applied.w)) * rotatedBody;
        CheckWorldOffset(Matrix(dx::XMMatrixInverse(nullptr, trackedCamera)), reference, frame, applied);

        // Bad utility offsets fail atomically; the ordinary view remains valid.
        Check(IsValidWorldViewOffset({400,0,0}), "inclusive offset radius");
        Check(IsValidWorldViewOffset({-240,320,0}), "vector radius boundary");
        Check(BuildStereoMatrices(Identity(), stockProjection, {}, Frame(), eyes, error, {}, {400,0,0}),
            "maximum bounded offset accepted");
        const auto beforeInvalidOffset = eyes;
        const float nan = (std::numeric_limits<float>::quiet_NaN)();
        const float infinity = (std::numeric_limits<float>::infinity)();
        for (const auto offset : std::array<Vec3, 7>{{{400.01f,0,0}, {0,-401,0}, {300,300,0},
                {nan,0,0}, {0,infinity,0}, {0,0,-infinity}, {(std::numeric_limits<float>::max)(),0,0}}}) {
            Check(!IsValidWorldViewOffset(offset), "invalid offset selector rejected");
            Check(!BuildStereoMatrices(Identity(), stockProjection, {}, Frame(), eyes, error, {}, offset),
                "invalid offset rendering rejected");
            Check(!error.empty(), "invalid offset explains reason");
            for (unsigned eye = 0; eye < 2; ++eye) {
                Equal(eyes[eye].view, beforeInvalidOffset[eye].view);
                Equal(eyes[eye].projection, beforeInvalidOffset[eye].projection);
            }
        }

        const auto saved = eyes;
        frame.eyeLeft.fov.angleRight = frame.eyeLeft.fov.angleLeft;
        Check(!BuildStereoMatrices(Identity(), stockProjection, {}, frame, eyes, error), "invalid FOV rejected");
        Check(!error.empty(), "failure explains reason");
        Equal(eyes[0].view, saved[0].view);
        frame = Frame();
        frame.eyeRight.pose.pos.x = (std::numeric_limits<float>::quiet_NaN)();
        Check(!BuildStereoMatrices(Identity(), stockProjection, {}, frame, eyes, error), "invalid tracking rejected");
        Check(!BuildStereoMatrices(Identity(), Identity(), {}, Frame(), eyes, error), "orthographic rejected");
        Check(!BuildStereoMatrices({}, stockProjection, {}, Frame(), eyes, error), "singular base rejected");

        // No engine calls: bad family must fail before any callable boundary.
        StereoViews bridge;
        Check(!bridge.SubmitStereoPair(nullptr, Frame(), nullptr, nullptr, 0, error), "null family fails closed");
        Check(!bridge.ReferenceReady(), "failure does not capture reference");
        std::puts("Stereo math checks passed: projection, depth, IPD, reference, lean, pitch, world offset, invalid inputs");
    } catch (const std::exception& exception) {
        std::fprintf(stderr, "FAIL: %s\n", exception.what());
        return 1;
    }
    return 0;
}
