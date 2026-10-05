// Optional equipment: owning or removing this weapon never grants/removes a
// building kit. Manual control belongs to the owner's current sentry only.
class VREngineerWrangler extends VREngineerWeapon;

var VREngineerSentry ControlledSentry;
var vector LaserPoint, LaserNormal;
var float LaserReadyAt, NextProfileCheck;
var bool bDeployed, bLaserActive, bTrackingSuspended;
var VREngineerLaserDot Dot;

struct FriendlyTraceState
{
    var Pawn Target;
    var bool Collides, Blocks, IgnoreEncroachers;
};

simulated function bool CanUseSourceWeapon()
{
    return WorldInfo.NetMode == NM_Standalone && Role == ROLE_Authority
        && IsSelectedTool(true)
        && !IsInState('Inactive') && !IsInState('WeaponEquipping') && !IsInState('WeaponPuttingDown')
        && !bTrackingSuspended;
}

simulated function UpdateTrackedInput(VRHandsBridge Bridge)
{
    if (Bridge == None || (Bridge.NativeValidMask & (1 << Bridge.WeaponHand)) == 0)
    { CancelTrackedInput(); return; }
    bTrackingSuspended = false;
    Super.UpdateTrackedInput(Bridge);
}

simulated function CancelTrackedInput()
{
    if (!bTrackedPose && !HasManagedHands()) return;
    bTrackingSuspended = true;
    CancelSourceInput();
}

simulated function StartFire(byte FireModeNum)
{
    if (!CanStartSourceAction()) return;
    if (FireModeNum == 0) bPrimaryHeld = true;
    if (FireModeNum == 1) bSecondaryHeld = true;
}

simulated function StopFire(byte FireModeNum)
{
    Super.StopFire(FireModeNum);
    if (ControlledSentry == None) return;
    if (FireModeNum == 0) ControlledSentry.bManualBullet = false;
    if (FireModeNum == 1) ControlledSentry.bManualRocket = false;
}

simulated function CancelSourceInput()
{
    Super.CancelSourceInput();
    if (ControlledSentry != None) ControlledSentry.EndManualControl(self);
    ControlledSentry = None;
    bDeployed = false;
    bLaserActive = false;
    if (Dot != None) { Dot.Destroy(); Dot = None; }
}

// Ignore teammates and friendly buildings, as the Source laser trace does.
// Retrace the complete segment with each intercepted friendly temporarily
// excluded so an adjacent wall cannot be skipped by advancing the start.
simulated function Actor TraceLaser(vector Start, vector End, out vector Hit, out vector HitNormal)
{
    local Actor Victim;
    local Pawn Friendly;
    local array<FriendlyTraceState> Masked;
    local FriendlyTraceState Saved;
    local int I;
    Victim = Trace(Hit, HitNormal, End, Start, true);
    Friendly = Pawn(Victim);
    while (Friendly != None && Friendly.GetTeamNum() == Instigator.GetTeamNum() && Masked.Length < 32)
    {
        Saved.Target = Friendly; Saved.Collides = Friendly.bCollideActors;
        Saved.Blocks = Friendly.bBlockActors; Saved.IgnoreEncroachers = Friendly.bIgnoreEncroachers;
        Masked.AddItem(Saved);
        Friendly.SetCollision(false, false);
        Victim = Trace(Hit, HitNormal, End, Start, true);
        Friendly = Pawn(Victim);
    }
    for (I = Masked.Length - 1; I >= 0; --I)
        Masked[I].Target.SetCollision(Masked[I].Collides, Masked[I].Blocks, Masked[I].IgnoreEncroachers);
    if (Victim == None) { Hit = End; HitNormal = vect(0,0,0); }
    return Victim;
}

simulated event Tick(float DeltaTime)
{
    local VREngineerPDA PDA;
    local VRHandsBridge Bridge;
    local Actor Victim;
    local vector Start;
    Super(KFWeapon).Tick(DeltaTime);
    if (Instigator == None) { CancelSourceInput(); return; }
    // A Wrangler can be bought before the kit and survives its sale. Resolve
    // the current kit, including a later re-purchase, without creating one.
    PDA = VREngineerPDA(Instigator.FindInventoryType(class'VREngineerPDA'));
    Engineer = PDA != None ? PDA.Engineer : None;
    if (WorldInfo.TimeSeconds >= NextProfileCheck)
    {
        NextProfileCheck = WorldInfo.TimeSeconds + 0.5;
        foreach WorldInfo.AllActors(class'VRHandsBridge', Bridge)
            if (Bridge.Human == Instigator) class'VREngineerVR'.static.RegisterTools(Bridge);
    }
    if (!IsSelectedTool() || IsInState('Inactive')
        || IsInState('WeaponPuttingDown') || bTrackingSuspended)
    { CancelSourceInput(); return; }
    if (!bDeployed)
    {
        bDeployed = true;
        LaserReadyAt = WorldInfo.TimeSeconds + 0.5;
    }
    if (!CanUseSourceWeapon()) return;
    if (WorldInfo.TimeSeconds < LaserReadyAt) return;
    bLaserActive = true;
    Start = SourceOrigin();
    Victim = TraceLaser(Start, Start + SourceDirection() * 144162.89, LaserPoint, LaserNormal);
    if (Dot == None) Dot = Spawn(class'VREngineerLaserDot', self);
    if (Dot != None) Dot.Place(KFPlayerController(Instigator.Controller), LaserPoint, LaserNormal);
    if (Engineer == None || !Engineer.IsOwnerAlive() || Engineer.Sentry == None)
    {
        if (ControlledSentry != None) ControlledSentry.EndManualControl(self);
        ControlledSentry = None;
        return;
    }
    if (ControlledSentry != None && ControlledSentry != Engineer.Sentry)
        ControlledSentry.EndManualControl(self);
    ControlledSentry = Engineer.Sentry;
    ControlledSentry.UpdateManualControl(self, LaserPoint, KFPawn_Monster(Victim), bPrimaryHeld, bSecondaryHeld);
}

defaultproperties
{
    bBuildingKitPart=false
    FirstPersonMeshName="KF2VREngineer.Wrangler"
    PickupMeshName=""
    GroupPriority=207
    InventorySize=1
}
