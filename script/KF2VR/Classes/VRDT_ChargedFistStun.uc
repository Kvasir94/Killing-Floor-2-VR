// Charged fist to a large Zed's head. Stun power clears the stock threshold
// at the Fleshpound's 0.55 head vulnerability; no knockdown or stumble, so a
// Scrake or Fleshpound is stopped briefly rather than floored. Duration and
// cooldown are the Zed's own stock stun settings.
class VRDT_ChargedFistStun extends KFDT_Bludgeon abstract;

defaultproperties
{
    // Bare-hand and body-slam melee counts as Berserker melee (post-playtest
    // perk pass): stock lists no perk for these VR-only attacks.
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=900
    KDeathVel=400
    StunPower=250
    MeleeHitPower=100
}
