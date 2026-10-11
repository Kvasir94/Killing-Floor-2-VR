// Exact presentation identity established while the original pawn is alive.
// This actor survives that pawn's tear-off long enough for short finish events;
// it carries no collision, pose, damage, or authority over the corpse.
class BreacherBodyIdentity extends Actor;

var repnotify KFPawn_Monster Target;
var repnotify bool bRetired, bTerminal;
var private KFPawn_Monster CachedTarget;
var private GameReplicationInfo ScopeGRI;
var private bool bMapped, bInvalid;
var private float TerminalAt;

replication
{
    if (bNetDirty) Target, bRetired, bTerminal;
}

static function BreacherBodyIdentity Find(KFPawn_Monster M)
{
    local BreacherBodyIdentity Identity;
    if (M==None) return None;
    foreach M.DynamicActors(class'BreacherBodyIdentity',Identity)
        if (!Identity.bDeleteMe && !Identity.bInvalid && Identity.Target==M) return Identity;
    return None;
}

static function Register(Actor RegistryOwner, KFPawn_Monster M)
{
    local BreacherBodyIdentity Identity;
    local int Count;
    if (RegistryOwner==None || RegistryOwner.Role!=ROLE_Authority || M==None || M.bDeleteMe
        || M.Health<=0 || M.bPlayedDeath || M.bTearOff || M.IsABoss()) return;
    foreach RegistryOwner.DynamicActors(class'BreacherBodyIdentity',Identity)
    {
        if (Identity.bDeleteMe) continue;
        if (Identity.Target==M) return;
        if (++Count>=256) return; // never evict another still usable mapping
    }
    Identity=RegistryOwner.Spawn(class'BreacherBodyIdentity',RegistryOwner);
    if (Identity==None) return;
    Identity.Target=M;
    Identity.CacheTarget();
    Identity.bNetDirty=true;
    Identity.bForceNetUpdate=true;
}

simulated function bool SameWorld()
{
    if (ScopeGRI==None) ScopeGRI=WorldInfo.GRI;
    return ScopeGRI==WorldInfo.GRI;
}

simulated function CacheTarget()
{
    if (bInvalid || !SameWorld()) { bInvalid=true; return; }
    if (bMapped)
    {
        // A cleared torn-off reference must not erase the already exact local
        // mapping. A different non-null pawn can never replace it.
        if (Target!=None && Target!=CachedTarget) bInvalid=true;
        return;
    }
    if (bRetired || bTerminal || Target==None || Target.bDeleteMe || Target.bTearOff
        || Target.bPlayedDeath || Target.Health<=0) return;
    CachedTarget=Target;
    bMapped=true;
}

simulated function KFPawn_Monster Resolve()
{
    CacheTarget();
    if (!bMapped || bInvalid || CachedTarget==None || CachedTarget.bDeleteMe || !SameWorld()) return None;
    return CachedTarget;
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName=='Target' || VarName=='bRetired' || VarName=='bTerminal') CacheTarget();
    else Super.ReplicatedEvent(VarName);
}

simulated event Tick(float Delta)
{
    if (Role==ROLE_Authority && (Owner==None || Owner.bDeleteMe)) { Destroy(); return; }
    CacheTarget();
    if (bInvalid) { Destroy(); return; }
    if (Role==ROLE_Authority && !bRetired
        && (Target==None || Target.bDeleteMe || Target.Health<=0 || Target.bPlayedDeath || Target.bTearOff))
    {
        bRetired=true; bNetDirty=true; bForceNetUpdate=true;
    }
    // Held corpses can outlive stock cleanup. Keep their original mapping as
    // long as that exact authoritative pawn exists; grace starts on its loss.
    if (Role==ROLE_Authority && !bTerminal && (Target==None || Target.bDeleteMe))
    {
        bTerminal=true; bNetDirty=true; bForceNetUpdate=true;
        LifeSpan=35;
    }
    // No identity is included in seamless-travel persistence. This also closes
    // an old client replica if its replication channel ends late.
    if (bTerminal)
    {
        if (TerminalAt<=0) TerminalAt=WorldInfo.RealTimeSeconds;
        else if (WorldInfo.RealTimeSeconds-TerminalAt>40) Destroy();
    }
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bGameRelevant=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    bReplicateMovement=false
    NetUpdateFrequency=5
}
