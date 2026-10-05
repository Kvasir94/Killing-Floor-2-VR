// Boxing-glove jab (VRBoxingGloves): the bare-knuckle jab with the weight of
// the gloves behind it. Staggers where the bare jab only flinches.
class VRDT_GloveFist extends KFDT_Bludgeon abstract;

defaultproperties
{
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=1800
    KDeathVel=900
    KDeathUpKick=300
    StumblePower=200
    KnockdownPower=40
    MeleeHitPower=100
}
