// Charged fist against small and medium Zeds. Knockdown power clears the
// stock threshold even at the Husk's 0.4 knockdown vulnerability, so the
// affliction system itself plays the knockdown; its impulse is the knockback.
class VRDT_ChargedFist extends KFDT_Bludgeon abstract;

defaultproperties
{
    // Bare-hand and body-slam melee counts as Berserker melee (post-playtest
    // perk pass): stock lists no perk for these VR-only attacks.
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=3000
    KDeathVel=500
    KDeathUpKick=150
    KnockdownPower=300
    StumblePower=300
    MeleeHitPower=100
}
