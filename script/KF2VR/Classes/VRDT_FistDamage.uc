// Bare-knuckle fist punch below VRPhysicalFist.HeavyPunchAlpha: a jab. It
// flinches but does not stagger; the heavy type does that.
class VRDT_FistDamage extends KFDT_Bludgeon abstract;

defaultproperties
{
    // Bare-hand and body-slam melee counts as Berserker melee (post-playtest
    // perk pass): stock lists no perk for these VR-only attacks.
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=700
    KDeathVel=450
    KDeathUpKick=150
    StumblePower=60
    KnockdownPower=0
    MeleeHitPower=100
}
