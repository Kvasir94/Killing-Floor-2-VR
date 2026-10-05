// Charged boxing-glove blow to a large Zed's body (VRBoxingGloves): a stun
// wherever it lands, where the bare charged fist needs the head.
class VRDT_GloveChargedStun extends KFDT_Bludgeon abstract;

defaultproperties
{
    ModifierPerkList(0)=class'KFPerk_Berserker'
    KDamageImpulse=3000
    KDeathVel=1200
    StunPower=1000
    MeleeHitPower=100
}
