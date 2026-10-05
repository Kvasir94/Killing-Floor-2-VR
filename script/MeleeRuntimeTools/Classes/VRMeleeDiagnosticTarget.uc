// Stock Cyst damage is unchanged; expose hit-zone/perk conditions for the fixture.
class VRMeleeDiagnosticTarget extends KF2VRNetDiagnosticClot;
event TakeDamage(int Damage, Controller InstigatedBy, vector HitLocation,
    vector Momentum, class<DamageType> DamageType, optional TraceHitInfo HitInfo,
    optional Actor DamageCauser)
{
    local KFWeapon W;
    W = KFWeapon(DamageCauser);
    if (Role == ROLE_Authority)
        `log("KF2VR_MELEE_FIXTURE phase=impact target=" $ DiagnosticId $ " bone=" $ HitInfo.BoneName
            $ " incoming=" $ Damage $ " type=" $ DamageType $ " upgrade=" $ (W != None ? W.CurrentWeaponUpgradeIndex : -1)
            $ " volume_scale=" $ VolumeDamageScale);
    Super.TakeDamage(Damage, InstigatedBy, HitLocation, Momentum, DamageType, HitInfo, DamageCauser);
}
