// The Ripcord's line carries current: small ticks of EMP damage while a Zed is
// on the tether. The stock EMP group gives the arcs and sizzle on the Zed; no
// impulses, so the ragdoll is moved by the reel alone.
class BreacherDT_Shock extends KFDT_EMP abstract hidedropdown;

defaultproperties
{
    EMPPower=12
    StumblePower=0
    GunHitPower=0
    KDamageImpulse=0
    KDeathUpKick=0
    KDeathVel=0
    bNoPain=true
    GoreDamageGroup=DGT_EMP
    EffectGroup=FXG_Electricity
}
