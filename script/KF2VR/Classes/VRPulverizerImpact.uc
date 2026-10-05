// Contact-centered stock Pulverizer payload. A private explosion template
// avoids changing the cooked archetype or another held item's blast.
class VRPulverizerImpact extends Object dependson(Actor);

static simulated function bool Detonate(VRHandsBridge B, KFWeap_Blunt_Pulverizer W, ImpactInfo Impact)
{
    local KFGameExplosion Template;
    local KFExplosionActor Explosion;
    local class<KFExplosionActor> ExplosionClass;
    local KFPlayerReplicationInfo PRI;
    local KFPerk Perk;
    local vector Origin, Direction, HitLocation, HitNormal;
    local byte SavedMode;
    if (B == None || W == None || W.bDeleteMe || W.Instigator != B.Human
        || B.WorldInfo.NetMode != NM_Standalone || !W.HasAmmo(class'KFWeapon'.const.CUSTOM_FIREMODE)
        || W.default.ExplosionTemplate == None || W.default.ExplosionActorClass == None) return false;
    Direction = Normal(Impact.RayDir);
    if (VSizeSq(Direction) < 0.99) return false;
    Origin = Impact.HitLocation - Direction * 3;
    if (!B.FastTrace(Origin, Impact.StartTrace))
    {
        if (B.Trace(HitLocation, HitNormal, Origin, Impact.StartTrace, false) == None) return false;
        Origin = HitLocation + HitNormal * 2;
    }
    ExplosionClass = W.default.ExplosionActorClass;
    PRI = KFPlayerReplicationInfo(B.Human.PlayerReplicationInfo);
    if (B.WorldInfo.TimeDilation < 1 && PRI != None && PRI.bNukeActive)
    {
        Template = new(W) class'KFGameExplosion'(class'KFPerk_Demolitionist'.static.GetNukeExplosionTemplate());
        if (Template == None) return false;
        Template.Damage *= class'KFPerk_Demolitionist'.static.GetNukeDamageModifier();
        Template.DamageRadius *= class'KFPerk_Demolitionist'.static.GetNukeRadiusModifier();
        ExplosionClass = W.NukeExplosionActorClass;
    }
    else
    {
        Template = new(W) class'KFGameExplosion'(W.default.ExplosionTemplate);
        if (Template == None) return false;
        if (B.WorldInfo.TimeDilation < 1 && PRI != None && PRI.bConcussiveActive && W.AltExploEffects != None)
        {
            Template.ExplosionEffects = W.AltExploEffects;
            Template.ExplosionSound = class'KFPerk_Demolitionist'.static.GetConcussiveExplosionSound();
        }
    }
    Perk = W.GetPerk();
    if (Perk != None) Template.DamageRadius *= Perk.GetAoERadiusModifier();
    Template.bFullDamageToAttachee = true;
    Explosion = W.Spawn(ExplosionClass, W,, Origin, rotator(Direction),, true);
    if (Explosion == None) return false;
    Explosion.Instigator = B.Human; Explosion.InstigatorController = B.PC;
    Explosion.Attachee = Impact.HitActor;
    // The stock muzzle-sync path consults Pawn.Weapon and could put an
    // off-hand impact's particles at the other gun. This blast owns its origin.
    Explosion.SetSyncToMuzzleLocation(false);
    SavedMode = W.CurrentFireMode;
    W.CurrentFireMode = class'KFWeapon'.const.CUSTOM_FIREMODE;
    W.HandleWeaponShotTaken(W.CurrentFireMode);
    W.ConsumeAmmo(W.CurrentFireMode);
    Explosion.Explode(Template, Direction);
    W.NotifyWeaponFired(W.CurrentFireMode);
    W.PlayFiringSound(W.CurrentFireMode);
    W.CauseMuzzleFlash(W.CurrentFireMode);
    W.CurrentFireMode = SavedMode;
    return true;
}
