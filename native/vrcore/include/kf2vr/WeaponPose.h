// The grip -> weapon -> muzzle chain, and the single fire pose derived from it.
//
// The research pack's rule for this file, verbatim:
//
//   "Drive the visible barrel, muzzle effects, aim ray, shot origin, and
//    network request from one documented weapon pose."
//
// So there is exactly one function that produces a fire pose, and it is the
// only thing any of those five consumers is allowed to read. A debug laser is
// an observation aid; if it is drawn from anything but FirePose, it is lying.
#pragma once

#include "kf2vr/Transform.h"

namespace kf2vr {

// Per-weapon fit, authored once per weapon and stored as data, not code.
//
// Every field here is unknown until measured against the actual KF2 asset.
// The pack is explicit: "Do not assume the old KF1 gun bone name, scale
// factor, grip correction, muzzle offset or material segmentation transfers."
struct WeaponProfile {
    // Human-readable id, matching the UnrealScript class (e.g. "KFWeap_Pistol_9mm").
    const char* weaponClass = "";

    // Skeleton socket the muzzle transform is read from, in the shipped asset.
    // Empty until the skeleton has actually been audited in the editor.
    const char* muzzleSocket = "";

    // Grip -> Weapon: how the weapon sits in the hand. Rotation corrects for
    // the controller's grip pose not matching the weapon's natural axis;
    // translation moves the weapon root off the grip point.
    Transform<frames::Weapon, frames::GripRight> weaponInGrip{};

    // Muzzle -> Weapon: taken from the asset's muzzle socket, in Unreal units.
    Transform<frames::Muzzle, frames::Weapon> muzzleInWeapon{};

    // Set true only once weaponInGrip and muzzleInWeapon come from a measured
    // audit of the shipped asset rather than a placeholder. Diagnostics report
    // this so an unmeasured profile is never mistaken for a calibrated one.
    bool measured = false;
};

// Origin and direction a shot actually leaves from, in world space.
struct FirePose {
    Vec3 origin;     // Unreal units, world space
    Vec3 direction;  // unit vector, world space
    bool fromMeasuredProfile = false;
};

// Compose grip -> weapon -> muzzle and read off the fire pose.
//
// Takes the grip already in world space, which means it has already been
// through ToUnreal() exactly once and composed through PlayerOrigin. There is
// no overload taking a tracking-space grip, on purpose.
inline MuzzleInWorld MuzzleFromGrip(
    const Transform<frames::GripRight, frames::World>& gripInWorld,
    const WeaponProfile& profile) {
    return profile.muzzleInWeapon
        .Then(profile.weaponInGrip)
        .Then(gripInWorld);
}

inline FirePose MakeFirePose(
    const Transform<frames::GripRight, frames::World>& gripInWorld,
    const WeaponProfile& profile) {
    const MuzzleInWorld muzzle = MuzzleFromGrip(gripInWorld, profile);
    return FirePose{
        muzzle.pos,
        // +X is forward in Unreal. The muzzle frame's forward axis is the
        // barrel axis; anything else would make the visible barrel and the
        // shot disagree, which is the exact KF1 failure this guards.
        muzzle.ApplyDirection({1.f, 0.f, 0.f}).Normalized(),
        profile.measured};
}

}  // namespace kf2vr
