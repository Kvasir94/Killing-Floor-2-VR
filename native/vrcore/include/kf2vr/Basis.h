// The single crossing point between XR tracking space and Unreal world space.
//
// This file owns two things that are wrong everywhere else in the codebase:
// the right-to-left handedness flip, and the metres-to-Unreal-units scale.
// Nothing else may perform either. Because `frames::Tracking` appears in no
// other conversion, the type system enforces that.
#pragma once

#include "kf2vr/Transform.h"

namespace kf2vr {

// Unreal units per metre.
//
// PROVISIONAL AND UNVERIFIED. The research pack is explicit that this must not
// be assumed: "Calibrate units from known in-game geometry and measured weapon
// dimensions rather than assuming all Unreal versions use the same units."
//
// KF2's KFPawn default capsule has half-height 86 and BaseEyeHeight 68.
// 100 puts that 172-unit character near human scale; 50 made it 3.44 metres
// tall and gave the headset an oversized world with weak stereo depth.
// This is a geometry-informed prototype value, pending physical calibration.
inline constexpr float kProvisionalUnrealUnitsPerMetre = 100.0f;

// Whether the provisional scale above has been replaced by a real measurement.
// Diagnostics surface this so no capture or timing is ever reported as
// calibrated when it is not.
inline constexpr bool kWorldScaleIsMeasured = false;

// Basis change from XR axes to Unreal axes.
//
//   XR      +X right, +Y up, -Z forward   (right-handed, metres)
//   Unreal  +X forward, +Y right, +Z up   (left-handed, Unreal units)
//
//   ue.x = -xr.z    XR forward (0,0,-1) -> UE (1,0,0)  forward
//   ue.y =  xr.x    XR right   (1,0,0)  -> UE (0,1,0)  right
//   ue.z =  xr.y    XR up      (0,1,0)  -> UE (0,0,1)  up
//
// The determinant of this map is -1: it is a reflection, not a rotation, which
// is precisely why it cannot live inside a Quat and needs the Mat3 detour
// below.
inline constexpr Vec3 BasisXrToUnreal(const Vec3& v) { return {-v.z, v.x, v.y}; }
inline constexpr Vec3 BasisUnrealToXr(const Vec3& v) { return {v.y, v.z, -v.x}; }

namespace detail {
inline Mat3 XrToUnrealMat() {
    Mat3 m;
    m.m[0][0] = 0; m.m[0][1] = 0; m.m[0][2] = -1;
    m.m[1][0] = 1; m.m[1][1] = 0; m.m[1][2] = 0;
    m.m[2][0] = 0; m.m[2][1] = 1; m.m[2][2] = 0;
    return m;
}
inline Mat3 UnrealToXrMat() {
    Mat3 m;
    m.m[0][0] = 0; m.m[0][1] = 1; m.m[0][2] = 0;
    m.m[1][0] = 0; m.m[1][1] = 0; m.m[1][2] = 1;
    m.m[2][0] = -1; m.m[2][1] = 0; m.m[2][2] = 0;
    return m;
}
}  // namespace detail

// Conjugate a rotation through the basis change: R_ue = M * R_xr * M^-1.
// M has determinant -1 and so does M^-1, leaving R_ue a proper rotation.
inline Quat BasisXrToUnreal(const Quat& q) {
    return (detail::XrToUnrealMat() * Mat3::FromQuat(q) * detail::UnrealToXrMat()).ToQuat();
}

// Re-express both the body's local convention and its tracking-space pose in
// Unreal axes and units. Downstream body-local points (including asset sockets)
// are already in Unreal units. Therefore the unit conversion affects position,
// not the resulting pose's dimensionless scale. Keeping a metres-to-UU scale
// here would multiply weapon/muzzle offsets a second time during composition.
//
// This is the only function in the project that produces a transform out of
// `frames::Tracking`. Call it once per pose per frame, on a coherent pose
// sample, and compose the result forward -- never call it twice on the same
// pose, and never hand a Tracking-space transform to anything downstream.
template <typename Body>
Transform<Body, frames::PlayerOrigin> ToUnreal(
    const Transform<Body, frames::Tracking>& xr,
    float unrealUnitsPerMetre = kProvisionalUnrealUnitsPerMetre) {
    return Transform<Body, frames::PlayerOrigin>{
        BasisXrToUnreal(xr.rot),
        BasisXrToUnreal(xr.pos) * unrealUnitsPerMetre,
        xr.scale};
}

}  // namespace kf2vr
