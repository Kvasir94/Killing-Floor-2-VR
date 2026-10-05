// Named coordinate frames.
//
// Every frame is a distinct, never-instantiated C++ type. Transform<From, To>
// is parameterised on two of them, so a transform between the wrong pair of
// frames does not compile. This exists because of a specific, expensive KF1
// failure recorded in the research pack:
//
//   "KF1 found a separate first-person weapon scene path and double-applied
//    head/eye transforms."
//
// Double application is not a bug you can review your way out of once the code
// has several render paths. Here it is a type error.
//
// Two coordinate conventions are in play, and the frame tag tells you which:
//
//   XR convention   metres, right-handed, +X right, +Y up, -Z forward.
//                   Frames: Tracking.
//   Unreal          Unreal units, left-handed, +X forward, +Y right, +Z up.
//                   Frames: PlayerOrigin, World.
//
// `Tracking` is the only frame in XR convention. Crossing out of it goes
// through exactly one function, ToUnreal() in Basis.h, which owns the
// handedness flip and the unit scale. There is no other route from a headset
// pose to a world pose, which is what "apply tracking transforms exactly once"
// means in practice.
#pragma once

namespace kf2vr::frames {

// ---- XR convention -------------------------------------------------------

// The XR runtime's tracking origin (stage or seated, per Calibration).
// Raw runtime poses are expressed relative to this.
struct Tracking;

// ---- Unreal convention ---------------------------------------------------

// Where the player's play area sits in the KF2 world.
//
// Recentre and artificial turn move THIS frame and nothing else. Because head,
// both eyes and both hands all reach World by composing through the same
// PlayerOrigin->World transform, they cannot drift out of agreement — the
// research pack's "recenter and artificial turning must transform hands and
// head consistently" is structural here, not a convention to remember.
struct PlayerOrigin;

// KF2 world space.
struct World;

// ---- Rigid bodies (convention depends on what they are composed against) ---

// Centre-eye / HMD pose.
struct Head;

// Per-eye poses. Distinct types so a left-eye transform cannot be submitted to
// the right eye.
struct EyeL;
struct EyeR;

// Controller grip poses. Distinct types for the same reason.
struct GripLeft;
struct GripRight;

// Runtime aim poses are distinct from grip poses: an interaction ray is not
// the controller's hand attachment, nor a weapon's authored muzzle direction.
struct AimLeft;
struct AimRight;

// Weapon root, reached from a grip via the per-weapon fit correction.
struct Weapon;

// Where the round actually leaves the barrel.
//
// The research pack is blunt about why this is its own frame: "A gun drawn at
// the controller is not a controller-aimed gun." Barrel visual, muzzle effect,
// aim ray, shot origin and the network fire request must all derive from this
// one transform. A debug laser drawn from anywhere else proves nothing.
struct Muzzle;

}  // namespace kf2vr::frames
