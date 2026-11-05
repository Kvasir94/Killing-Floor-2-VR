// Reaction power only. World drops never call TakeDamage.
class VRWorldDropImpact extends KFDamageType abstract;

defaultproperties
{
    GunHitPower=35
    StumblePower=0
    KnockdownPower=0
    StunPower=0
    KDamageImpulse=0
    // A non-damaging prop impact must not inherit a previous explosion's
    // stored HitFxRadialInfo falloff on the victim.
    bCanApplyRadialCalculationtoAffliction=false
}
