// Stock AF2011 SpawnProjectile adds/subtracts a world-space BarrelOffset.
// Keep its two stock projectiles and separation, orienting the span across
// this gun's live bore. The original instance value is restored on release.
class VRAF2011Barrels extends Object;

var KFWeap_Pistol_AF2011 Weapon;
var Actor OriginalOwner;
var Pawn OriginalInstigator;
var InventoryManager OriginalManager;
var vector OriginalOffset;
var float Separation;

simulated function bool OwnsWeapon()
{
    return Weapon != None && !Weapon.bDeleteMe && Weapon.Owner == OriginalOwner
        && Weapon.Instigator == OriginalInstigator && Weapon.InvManager == OriginalManager;
}

simulated function Capture(KFWeapon W)
{
    Weapon = KFWeap_Pistol_AF2011(W);
    if (Weapon == None) return;
    OriginalOwner = W.Owner; OriginalInstigator = W.Instigator; OriginalManager = W.InvManager;
    OriginalOffset = Weapon.BarrelOffset;
    Separation = VSize(OriginalOffset);
}

simulated function bool Update(VRHandsBridge B, vector Center)
{
    local vector Offset, HitLocation, HitNormal;
    if (!OwnsWeapon() || B == None || B.ActiveWeapon != Weapon || Weapon.MySkelMesh == None
        || !(Separation > 0 && Separation < 100)) return false;
    Offset = QuatRotateVector(Weapon.MySkelMesh.GetBoneQuaternion('RW_Weapon'), vect(0,1,0)) * Separation;
    if (!(Abs(VSize(Offset) - Separation) < 0.01)) return false;
    // Both offset origins must remain on the player's side of world geometry.
    if (B.Trace(HitLocation, HitNormal, Center + Offset * 0.5, B.HeadPosition, false) != None
        || B.Trace(HitLocation, HitNormal, Center - Offset * 0.5, B.HeadPosition, false) != None) return false;
    Weapon.BarrelOffset = Offset;
    return true;
}

simulated function Suspend()
{
    if (OwnsWeapon()) Weapon.BarrelOffset = OriginalOffset;
}

simulated function Release(bool bAbandon)
{
    if (!bAbandon) Suspend();
    Weapon = None; OriginalOwner = None; OriginalInstigator = None; OriginalManager = None;
}
