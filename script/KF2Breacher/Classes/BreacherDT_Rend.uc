// Tearing a Zed apart by hand: a slashing kill whose hit bone is the limb the
// two hands pulled away, so the stock death gore detaches it. Every zone can
// come off; the hands decide which.
class BreacherDT_Rend extends KFDT_Slashing abstract hidedropdown;

static simulated function bool CanDismemberHitZone(name InHitZoneName) { return true; }

defaultproperties
{
    KDamageImpulse=0
    KDeathUpKick=0
    KDeathVel=0
    bCanGib=false
    GoreDamageGroup=DGT_MeleeSlash
    EffectGroup=FXG_Slashing
}
