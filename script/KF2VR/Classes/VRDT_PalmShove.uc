// Open-palm shove (VRPalmShove, melee roadmap item 13): a token point of
// damage and a stock stumble, like dosh to the face. No knockdown or stun.
class VRDT_PalmShove extends KFDT_Bludgeon abstract;

defaultproperties
{
    ModifierPerkList(0)=class'KFPerk_Berserker'
    WeaponDef=class'VRWeapDef_BareHands'
    KDamageImpulse=250
    StumblePower=200
    KnockdownPower=0
    StunPower=0
    MeleeHitPower=0
}
