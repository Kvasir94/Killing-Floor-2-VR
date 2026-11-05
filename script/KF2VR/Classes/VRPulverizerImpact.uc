// Contact-centered stock Pulverizer payload. A private explosion template
// avoids changing the cooked archetype or another held item's blast.
class VRPulverizerImpact extends Object dependson(Actor);

static simulated function VRWeaponRuntime ReadyRuntime(VRHandsBridge B, KFWeap_Blunt_Pulverizer W)
{
    local VRHandsBridge Root;
    local VRWeaponRuntime R;
    if (B == None || W == None || W.bDeleteMe || W.Instigator != B.Human
        || !W.HasAmmo(class'KFWeapon'.const.CUSTOM_FIREMODE)) return None;
    Root = B.RootBridge != None ? B.RootBridge : B;
    if (Root.HandInventory == None || Root.HandInventory.Registry == None) return None;
    R = Root.HandInventory.Registry.FindItem(W);
    if (R == None || !R.IsCurrent() || R.Item != W || R.FinishProfileToken > 0
        || W.WorldInfo.TimeSeconds < R.PulverizerReadyAt) return None;
    return R;
}

static simulated function bool Detonate(VRHandsBridge B, KFWeap_Blunt_Pulverizer W, ImpactInfo Impact)
{
    local VRWeaponRuntime R;
    R = ReadyRuntime(B, W);
    if (R == None || !DetonateAuthority(W, Impact)) return false;
    R.PulverizerReadyAt = W.WorldInfo.TimeSeconds + W.GetFireInterval(class'KFWeapon'.const.CUSTOM_FIREMODE);
    return true;
}

// Both local and network accepted contacts use the same payload and payment.
// The caller owns the per-item cooldown and held-contact admission.
static function bool DetonateAuthority(KFWeap_Blunt_Pulverizer W, ImpactInfo Impact)
{
    local KFGameExplosion Template;
    local KFExplosionActor Explosion;
    local class<KFExplosionActor> ExplosionClass;
    local KFPlayerReplicationInfo PRI;
    local KFPerk Perk;
    local vector Origin, Direction, HitLocation, HitNormal;
    local byte SavedMode;
    local KFPawn_Human Human;
    if (W == None || W.bDeleteMe || W.Role != ROLE_Authority
        || !W.HasAmmo(class'KFWeapon'.const.CUSTOM_FIREMODE)
        || W.default.ExplosionTemplate == None || W.default.ExplosionActorClass == None) return false;
    Human = KFPawn_Human(W.Instigator);
    if (!class'VRPhysicalInteraction'.static.Allowed(Human) || Human.Controller == None
        || Human.Controller.Pawn != Human || W.Owner != Human || W.InvManager != Human.InvManager) return false;
    Direction = Normal(Impact.RayDir);
    if (VSizeSq(Direction) < 0.99) return false;
    Origin = Impact.HitLocation - Direction * 3;
    if (!W.FastTrace(Origin, Impact.StartTrace))
    {
        if (W.Trace(HitLocation, HitNormal, Origin, Impact.StartTrace, false) == None) return false;
        Origin = HitLocation + HitNormal * 2;
    }
    ExplosionClass = W.default.ExplosionActorClass;
    PRI = KFPlayerReplicationInfo(Human.PlayerReplicationInfo);
    if (W.WorldInfo.TimeDilation < 1 && PRI != None && PRI.bNukeActive)
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
        if (W.WorldInfo.TimeDilation < 1 && PRI != None && PRI.bConcussiveActive && W.AltExploEffects != None)
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
    Explosion.Instigator = Human; Explosion.InstigatorController = Human.Controller;
    Explosion.bReplicateInstigator = true;
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
    W.IncrementFlashCount();
    W.CurrentFireMode = SavedMode;
    return true;
}
