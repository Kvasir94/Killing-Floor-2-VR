// Function-first stock placeholder; NOT the final palm-free forearm presentation.
class BreacherDeadbolt extends KFWeap_HRG_Nailgun;

simulated function string GetHumanReadableName() { return "Deadbolt (experimental)"; }
// One deliberate shot mode in this slice. Stock reload, sight and bash remain.
simulated function AltFireMode() {}

defaultproperties
{
    FiringStatesArray(0)=WeaponSingleFiring
    FiringStatesArray(1)=WeaponSingleFiring
    WeaponProjectiles(0)=class'BreacherCascadeProjectile'
    WeaponProjectiles(1)=class'BreacherCascadeProjectile'
    NumPellets(0)=1
    NumPellets(1)=1
    Spread(0)=0.0
    Spread(1)=0.0
    FireInterval(0)=0.55
    FireInterval(1)=0.55
    InstantHitDamage(0)=40
    InstantHitDamage(1)=40
    bLoopingFireAnim(0)=false
    bLoopingFireAnim(1)=false
    // Temporary slice tuning, not approved progression or perk balance.
    MagazineCapacity(0)=8
    SpareAmmoCapacity(0)=80
    AssociatedPerkClasses.Empty()
    AssociatedPerkClasses(0)=class'BreacherPerk'
    WeaponUpgrades.Empty()
}
