// A thrown owned gun is a small blunt impact, independent of its fire modes.
class VRDT_ThrownWeaponImpact extends KFDamageType abstract;

defaultproperties
{
    GunHitPower=35
    StumblePower=35
    KnockdownPower=0
    StunPower=0
    KDamageImpulse=0
    bCanApplyRadialCalculationtoAffliction=false
    bCanObliterate=false
    bCausesFracture=false
}
