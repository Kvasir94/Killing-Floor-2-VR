// A wad of dosh to the face: a token point of damage and a stumble. The power
// clears the stock threshold for trash Zeds; medium Zeds stumble only where
// their own vulnerability allows. No knockdown, stun or melee flinch.
class VRDT_DoshStagger extends KFDT_Bludgeon abstract;

defaultproperties
{
    KDamageImpulse=200
    StumblePower=200
    KnockdownPower=0
    StunPower=0
    MeleeHitPower=0
}
