// Only the camera-derived backblast pose needs replacing. RPG CustomFire
// still owns projectile creation, the stock explosion, damage and effects.
class VRLauncherSupport extends Object;

static simulated function bool ResolveBackBlast(VRHandsBridge B, KFWeap_RocketLauncher_RPG7 W,
    out vector BlastLocation, out rotator BlastRotation)
{
    local rotator ExhaustRotation;
    if (B == None || W == None || W != B.ActiveWeapon || W.Instigator != B.Human
        || !B.bCalibrated || B.NativeWeaponReady == 0 || W.MySkelMesh == None) return false;
    // The cooked RPG mesh authors +X forward for both sockets. Exhaust is
    // the rear of the tube, so its blast points along the negative socket X.
    if (!W.MySkelMesh.GetSocketWorldLocationAndRotation('Exhaust', BlastLocation, ExhaustRotation)) return false;
    BlastRotation = rotator(-vector(ExhaustRotation));
    return true;
}
