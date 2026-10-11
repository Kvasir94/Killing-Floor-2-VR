// Deadbolt keeps the previous piercing resistance/impact tuning while owning
// its attribution. Cascade owns pinning; no stock nail projectile is spawned.
class BreacherDeadboltDamage extends KFDT_Piercing abstract hidedropdown;

defaultproperties
{
    BloodSpread=0.4
    BloodScale=0.6
    KDamageImpulse=600
    KDeathUpKick=200
    KDeathVel=150
    StumblePower=20
    GunHitPower=20
    WeaponDef=class'BreacherDeadboltDefinition'
    ModifierPerkList(0)=class'BreacherPerk'
}
