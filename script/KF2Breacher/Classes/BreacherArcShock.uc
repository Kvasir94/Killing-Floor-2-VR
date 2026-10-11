// ArcFence exposure uses stock EMP accumulation/resistance/cooldown. The 0.25s
// tick supplies 20 power: 80/s before resistance versus stock 50/s dissipation.
// Health damage is deliberately independent and small; overlaps share one tick.
class BreacherArcShock extends KFDT_EMP abstract hidedropdown;

defaultproperties
{
    ModifierPerkList(0)=class'BreacherPerk'
    EMPPower=20
    KDamageImpulse=0
    KDeathUpKick=0
    KDeathVel=0
    StumblePower=0
    GunHitPower=0
    bNoPain=true
    EffectGroup=FXG_Electricity
}
