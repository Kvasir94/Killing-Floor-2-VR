// A corpse-only finish. The group checks death and consumes the identity before
// this callback. This type must never kill/obliterate a living survivor.
class BreacherArcMulch extends KFDT_Explosive abstract hidedropdown;

static function bool CheckObliterate(Pawn P, int Damage)
{
    return P != None && P.Health <= 0;
}

defaultproperties
{
    ModifierPerkList(0)=class'BreacherPerk'
    bCanObliterate=true
    GoreDamageGroup=DGT_Obliterate
    KDamageImpulse=0
    KDeathUpKick=0
    KDeathVel=0
}
