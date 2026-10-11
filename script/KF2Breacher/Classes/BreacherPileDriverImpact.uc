// Supplemental Pile Driver damage is distinct from the original slam. Shield
// charging must exclude it; callbacks originate from contact owners, not damage.
class BreacherPileDriverImpact extends KFDT_Bludgeon abstract hidedropdown;

defaultproperties
{
    ModifierPerkList(0)=class'BreacherPerk'
    KDamageImpulse=0
    KDeathUpKick=0
    KDeathVel=0
    GunHitPower=0
    StumblePower=0
    KnockdownPower=0
    bCanApplyRadialCalculationtoAffliction=false
}
