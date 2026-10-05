// Boxing-glove full swing (VRBoxingGloves): knocks small Zeds down outright
// and staggers the rest; corpses fly.
class VRDT_GloveFistHeavy extends KFDT_Bludgeon abstract;

defaultproperties
{
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=4000
    KDeathVel=1600
    KDeathUpKick=500
    StumblePower=400
    KnockdownPower=180
    MeleeHitPower=100
}
