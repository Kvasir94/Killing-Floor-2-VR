// Stationary stock enemy for the opt-in network damage fixture. No replacement
// damage calculation: all hits pass through the normal monster implementation.
class KF2VRNetDiagnosticClot extends KFPawn_ZedClot_Cyst;

var repnotify int ObservedHealth;
var repnotify int DamageReceipts;
var repnotify bool bObservedDead;
// Actor instance names are local to each process and may diverge after travel.
// One diagnostic target per pawn lifetime; authority assigns this before firing.
var repnotify string DiagnosticId;

replication
{
    if (bNetDirty && Role == ROLE_Authority)
        ObservedHealth, DamageReceipts, bObservedDead, DiagnosticId;
}

function InitializeDiagnostic(int WorldEpoch, int ConnectionEpoch, int PawnEpoch, optional string Suffix)
{
    if (Role == ROLE_Authority && DiagnosticId == "")
    {
        DiagnosticId = "w" $ WorldEpoch $ "-c" $ ConnectionEpoch $ "-p" $ PawnEpoch;
        if (Suffix != "") DiagnosticId $= "-" $ Suffix;
        ObservedHealth = Health;
        if (Mesh != None)
            Mesh.bForceDiscardRootMotion = true;
        bForceNetUpdate = true;
        `log("KF2VRNet target_spawn target=" $ DiagnosticId $ " actor=" $ self $ " health=" $ Health
            $ " location=" $ Location $ " netmode=" $ WorldInfo.NetMode);
    }
}

event TakeDamage(int Damage, Controller InstigatedBy, vector HitLocation,
    vector Momentum, class<DamageType> DamageType, optional TraceHitInfo HitInfo,
    optional Actor DamageCauser)
{
    local int Before;
    Before = Health;
    Super.TakeDamage(Damage, InstigatedBy, HitLocation, Momentum, DamageType, HitInfo, DamageCauser);
    if (Role != ROLE_Authority) return;
    ++DamageReceipts;
    ObservedHealth = Health;
    bObservedDead = Health <= 0;
    bForceNetUpdate = true;
    `log("KF2VRNet target_damage target=" $ DiagnosticId $ " actor=" $ self $ " receipt=" $ DamageReceipts
        $ " before=" $ Before $ " after=" $ Health $ " damage=" $ Damage
        $ " dead=" $ bObservedDead $ " instigator=" $ InstigatedBy
        $ " weapon=" $ DamageCauser $ " damage_type=" $ DamageType
        $ " netmode=" $ WorldInfo.NetMode);
}

function bool Died(Controller Killer, class<DamageType> DamageType, vector HitLocation)
{
    local bool Result;
    Result = Super.Died(Killer, DamageType, HitLocation);
    `log("KF2VRNet target_death target=" $ DiagnosticId $ " actor=" $ self $ " accepted=" $ Result
        $ " played=" $ bPlayedDeath $ " netmode=" $ WorldInfo.NetMode);
    return Result;
}

simulated event TornOff()
{
    Super.TornOff();
    `log("KF2VRNet target_death target=" $ DiagnosticId $ " actor=" $ self $ " accepted=True"
        $ " played=" $ bPlayedDeath $ " netmode=" $ WorldInfo.NetMode);
}

simulated event ReplicatedEvent(name VarName)
{
    Super.ReplicatedEvent(VarName);
    if (DiagnosticId != "" && (VarName == 'ObservedHealth' || VarName == 'DamageReceipts'
        || VarName == 'bObservedDead' || VarName == 'DiagnosticId'))
        `log("KF2VRNet target_state target=" $ DiagnosticId $ " actor=" $ self $ " receipt=" $ DamageReceipts
            $ " health=" $ ObservedHealth $ " dead=" $ bObservedDead
            $ " netmode=" $ WorldInfo.NetMode);
}

function SetMovementPhysics()
{
    SetPhysics(PHYS_None);
}

defaultproperties
{
    ControllerClass=None
    Physics=PHYS_None
    GroundSpeed=0
    SprintSpeed=0
    bAlwaysRelevant=true
    LifeSpan=60.0
}
