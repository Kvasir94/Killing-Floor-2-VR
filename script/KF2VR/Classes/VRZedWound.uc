// One living Zed's experimental wounds (VRLivingWounds), told to every machine.
// Stock Zeds cannot carry new replicated state, so the authority spawns this
// beside a wounded Zed, owned by and based on it, which makes the engine use the
// Zed's own network relevancy for it. A player who joins
// late, or who gets the Zed back after losing sight of it, receives the wound
// again with the Zed. Each machine shows it only while its own player has the
// living-gore switch on and stock gore allows mutilation.
class VRZedWound extends Actor;

const WOUND_GUT = 1;

var KFPawn_Monster Zed;
var byte Wounds;

var KFPawn_Monster ShownOn;
var byte Shown;
var float NextTry;
var VRHandsBridge LocalBridge;

replication
{
    if (bNetDirty) Zed, Wounds;
}

static function VRZedWound FindFor(KFPawn_Monster M)
{
    local VRZedWound W;
    if (M == None) return None;
    foreach M.WorldInfo.DynamicActors(class'VRZedWound', W)
        if (W.Zed == M && !W.bDeleteMe) return W;
    return None;
}

static function bool Has(KFPawn_Monster M, byte Bit)
{
    local VRZedWound W;
    W = FindFor(M);
    return W != None && (W.Wounds & Bit) != 0;
}

static function bool ServerAdd(KFPawn_Monster M, byte Bit)
{
    local VRZedWound W;
    if (M == None || M.Role != ROLE_Authority) return false;
    W = FindFor(M);
    if (W == None)
    {
        W = M.Spawn(class'VRZedWound', M,, M.Location);
        if (W == None) return false;
        W.Zed = M;
        W.SetBase(M);
    }
    W.Wounds = W.Wounds | Bit;
    W.bForceNetUpdate = true;
    return true;
}

simulated function bool ShowAllowed()
{
    local VRHandsBridge B;
    if (LocalBridge == None || LocalBridge.bDeleteMe)
    {
        LocalBridge = None;
        foreach WorldInfo.AllActors(class'VRHandsBridge', B)
            if (B.PC != None && B.PC.IsLocalPlayerController()) { LocalBridge = B; break; }
    }
    return LocalBridge != None && LocalBridge.LivingArmLossEnabled();
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (Role == ROLE_Authority && (Zed == None || Zed.bDeleteMe || Zed.bPlayedDeath || Zed.Health <= 0))
    {
        // The corpse keeps what each machine already drew.
        Destroy();
        return;
    }
    if (WorldInfo.NetMode == NM_DedicatedServer || Zed == None || (Zed == ShownOn && Shown == Wounds)) return;
    if (WorldInfo.RealTimeSeconds < NextTry) return;
    NextTry = WorldInfo.RealTimeSeconds + 0.5;
    if (!class'VRLivingWounds'.static.Living(Zed) || !ShowAllowed()) return;
    if ((Wounds & WOUND_GUT) != 0 && !class'VRLivingWounds'.static.PlayGut(Zed)) return;
    ShownOn = Zed;
    Shown = Wounds;
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bReplicateMovement=false
    bSkipActorPropertyReplication=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=2
    NetPriority=1.5
}
