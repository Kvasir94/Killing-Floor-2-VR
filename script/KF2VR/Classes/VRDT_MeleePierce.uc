// Melee plan ruling A (Kvasir94 2026-11-09, #227): a point that is not the
// weapon's stock stab, such as the back pick of the Fire Axe's head, pierces.
// Stock knife-stab reactions (melee hit power 25, no stumble); the amount is
// the weapon's own stock bash at the part-hit scale (VRPhysicalMelee).
class VRDT_MeleePierce extends KFDT_Piercing abstract;

defaultproperties
{
    KDamageImpulse=200
    KDeathUpKick=250
    StumblePower=0
    StunPower=0
    MeleeHitPower=25
}
