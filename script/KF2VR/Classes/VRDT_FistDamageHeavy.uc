// Bare-knuckle fist punch thrown at speed (VRPhysicalFist.HeavyPunchAlpha and
// above). Staggers small Zeds and can occasionally drop one; the charged fist
// is the reliable knockdown.
class VRDT_FistDamageHeavy extends KFDT_Bludgeon abstract;

defaultproperties
{
    // Bare-hand and body-slam melee counts as Berserker melee (post-playtest
    // perk pass): stock lists no perk for these VR-only attacks.
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=1600
    KDeathVel=750
    KDeathUpKick=250
    StumblePower=250
    KnockdownPower=60
    MeleeHitPower=100
}
