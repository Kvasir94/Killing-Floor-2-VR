// The embedded RAVEN-7 shocks its host zed: small electric ticks that build
// the stock EMP affliction (KFDT_EMP power; Arc Generator zap sound/sparks
// through FXG_Electricity). No stumble or flinch, so the host keeps moving
// until the EMP itself lands.
class VRDT_TomahawkShock extends KFDT_EMP;

defaultproperties
{
    KDamageImpulse=0
    StumblePower=0
    GunHitPower=0
    MeleeHitPower=0
    EMPPower=35
    EffectGroup=FXG_Electricity
    WeaponDef=class'VRWeapDef_Tomahawk'
    ModifierPerkList(0)=class'KFPerk_Berserker'
}
