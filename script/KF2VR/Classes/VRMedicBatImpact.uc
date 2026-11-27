// Hemoclobber (KFWeap_Blunt_MedicBat) for tracked swings, melee spec M20.
// Stock heals a struck teammate and sets off the heavy attack's healing blast
// from its attack states' collision callback, which a tracked swing never
// enters. These run the same stock amounts, dart costs, charge and blast.
class VRMedicBatImpact extends Object dependson(Actor);

// A living teammate: healed by the bat, never damaged by it.
static function bool IsAlly(Pawn Source, Actor Target)
{
    local KFPawn P;
    P = KFPawn(Target);
    return Source != None && P != None && P != Source && !P.bDeleteMe && P.Health > 0 && !P.bPlayedDeath
        && P.GetTeamNum() == Source.GetTeamNum();
}

// The held bat's runtime when a blast may fire now: a charge loaded and the
// stock fire interval since the last one (the runtime's shared blast clock).
static simulated function VRWeaponRuntime ReadyRuntime(VRHandsBridge B, KFWeap_Blunt_MedicBat W)
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

static simulated function bool Detonate(VRHandsBridge B, KFWeap_Blunt_MedicBat W, ImpactInfo Impact)
{
    local VRWeaponRuntime R;
    R = ReadyRuntime(B, W);
    if (R == None || !DetonateAuthority(W, Impact)) return false;
    R.PulverizerReadyAt = W.WorldInfo.TimeSeconds + W.GetFireInterval(class'KFWeapon'.const.CUSTOM_FIREMODE);
    return true;
}

// The stock heavy-attack blast at the contact: pays one charge and runs the
// weapon's own CustomFire (perk radius, toxic damage to Zeds, healing gas).
// The caller owns the per-item interval and the held-contact admission.
static function bool DetonateAuthority(KFWeap_Blunt_MedicBat W, ImpactInfo Impact)
{
    local KFPawn_Human Human;
    local byte SavedMode;
    if (W == None || W.bDeleteMe || W.Role != ROLE_Authority
        || !W.HasAmmo(class'KFWeapon'.const.CUSTOM_FIREMODE)
        || W.default.ExplosionTemplate == None || W.default.ExplosionActorClass == None) return false;
    Human = KFPawn_Human(W.Instigator);
    if (!class'VRPhysicalInteraction'.static.Allowed(Human) || Human.Controller == None
        || Human.Controller.Pawn != Human || W.Owner != Human || W.InvManager != Human.InvManager) return false;
    W.BlastHitLocation = Impact.HitLocation;
    W.BlastAttachee = Impact.HitActor;
    SavedMode = W.CurrentFireMode;
    W.CurrentFireMode = class'KFWeapon'.const.CUSTOM_FIREMODE;
    W.HandleWeaponShotTaken(W.CurrentFireMode);
    W.ConsumeAmmo(W.CurrentFireMode);
    W.CustomFire();
    W.CurrentFireMode = SavedMode;
    return true;
}

// The stock heal for a swing of this mode that touched a teammate. Stock
// itself requires a hurt, living teammate and enough darts.
static function bool HealAuthority(KFWeap_Blunt_MedicBat W, Actor Ally, vector HitLocation, byte Mode)
{
    if (W == None || W.bDeleteMe || W.Role != ROLE_Authority || !IsAlly(W.Instigator, Ally)) return false;
    if (Mode >= W.AttackHealAmounts.Length || Mode >= W.AttackHealCosts.Length) Mode = 0;
    W.HealTeammateWithAttack(Ally, HitLocation, W.AttackHealAmounts[Mode], W.AttackHealCosts[Mode]);
    return true;
}
