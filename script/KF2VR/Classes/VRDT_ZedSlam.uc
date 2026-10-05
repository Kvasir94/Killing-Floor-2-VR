// A held Zed or corpse used as a club: two held Zeds smashed together, or a
// held body swung into another Zed. Heavier than a fist -- the thing being
// swung weighs as much as a person.
class VRDT_ZedSlam extends KFDT_Bludgeon abstract;

defaultproperties
{
    // Bare-hand and body-slam melee counts as Berserker melee (post-playtest
    // perk pass): stock lists no perk for these VR-only attacks.
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=900
    KDeathVel=450
    KDeathUpKick=150
    StumblePower=300
    KnockdownPower=150
    MeleeHitPower=100
}
