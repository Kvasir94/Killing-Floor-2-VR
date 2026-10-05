// Charged boxing-glove blow (VRBoxingGloves) to a small or medium Zed, or to a
// large Zed's head. Knockdown power clears every stock threshold, so the
// affliction system ragdolls the Zed and the impulse launches it.
class VRDT_GloveCharged extends KFDT_Bludgeon abstract;

defaultproperties
{
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=12000
    KDeathVel=2500
    KDeathUpKick=800
    KnockdownPower=1000
    StumblePower=1000
    MeleeHitPower=100
}
