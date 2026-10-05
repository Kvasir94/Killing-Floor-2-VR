// Test-only stock inventory grants and targets. Production contact and RPC own damage.
class VRMeleeFixtureCoordinator extends Actor;
var int CaseIndex;
var float NextAt;
var bool bStarted;
var KFWeapon CaseWeapon;
var KF2VRNetDiagnosticClot Target;
var VRMeleeAuthoredBridge LocalBridge;
var int CaptureMarker, CaptureCase, LastCapture, CaptureHealth, CaptureReceipts;
var VRMeleeObserverCamera ObserverCamera;
var bool bDone;
var float LocalExitAt;

replication
{
    if (bNetDirty && Role == ROLE_Authority) Target, CaptureMarker, CaptureCase, CaptureHealth, CaptureReceipts, bDone;
}

function BeginCase()
{
    local KF2VRNetPlayerController C;
    local class<KFWeapon> Kind;
    C = KF2VRNetPlayerController(Owner);
    if (C == None || C.Pawn == None || C.Pawn.InvManager == None) return;
    if (C.GetPerk() == None || !C.GetPerk().bInitialized) return;
    if (((C.GetPerk().Class == class'KFPerk_Berserker' || C.GetPerk().Class == class'KFPerk_Survivalist')
        && C.GetPerk().GetLevel() > 0) || KFPawn_Human(C.Pawn).GetHealingDamageBoostModifier() != 1.0)
    {
        `log("KF2VR_MELEE_FIXTURE phase=blocked reason=nonneutral_perk perk=" $ C.GetPerk().Class $ " level=" $ C.GetPerk().GetLevel());
        NextAt = WorldInfo.RealTimeSeconds + 30; return;
    }
    `log("KF2VR_MELEE_FIXTURE phase=precondition perk=" $ C.GetPerk().Class $ " level=" $ C.GetPerk().GetLevel());
    if (CaseIndex < 2) Kind = class'KFWeap_Blunt_MaceAndShield';
    else if (CaseIndex == 2) Kind = class'KFWeap_Edged_Katana';
    else Kind = class'KFWeap_Edged_Zweihander';
    CaseWeapon = KFWeapon(C.Pawn.FindInventoryType(Kind));
    if (CaseWeapon == None) CaseWeapon = KFWeapon(C.Pawn.InvManager.CreateInventory(Kind, true));
    if (Target != None) Target.Destroy();
    Target = Spawn(class'VRMeleeDiagnosticTarget', self,, C.Pawn.Location + (vect(150,0,0) >> C.Pawn.Rotation));
    if (CaseWeapon == None || Target == None) return;
    Target.Health = 1000; Target.HealthMax = 1000; Target.LifeSpan = 0;
    Target.InitializeDiagnostic(C.NetChannel.WorldEpoch, C.NetChannel.ConnectionEpoch, C.NetChannel.PawnEpoch, "melee" $ CaseIndex);
    `log("KF2VR_MELEE_FIXTURE phase=case case=" $ CaseIndex $ " weapon=" $ CaseWeapon.Class $ " target=" $ Target.DiagnosticId);
    CaptureMarker = 0; bForceNetUpdate = true;
    bStarted = true; NextAt = WorldInfo.RealTimeSeconds + 12;
}

reliable client function ClientBeginCase(int Index, KFWeapon W, KF2VRNetDiagnosticClot T)
{
    local KF2VRNetPlayerController C;
    local KF2VRNetHandsBridge Previous;
    C = KF2VRNetPlayerController(Owner);
    if (C == None || !C.IsLocalPlayerController()) return;
    if (LocalBridge == None)
    {
        Previous = KF2VRNetHandsBridge(C.LocalVRBridge);
        LocalBridge = Spawn(class'VRMeleeAuthoredBridge', C);
        if (LocalBridge == None) return;
        // Preserve the live production reference calibration across this fixture-only bridge handoff.
        LocalBridge.AdoptFreeHandCalibration(Previous);
        if (Previous != None) Previous.Destroy();
        C.LocalVRBridge = LocalBridge;
        LocalBridge.Coordinator = self;
    }
    LocalBridge.BeginCase(Index, W, T);
}

reliable server function ServerPlaceTarget(int Index, vector HeadCenter)
{
    local KF2VRNetPlayerController C;
    local vector Destination;
    local bool bPlaced;
    C = KF2VRNetPlayerController(Owner);
    if (Index != CaseIndex || C == None || C.Pawn == None || Target == None
        || !class'VRGrenadeThrow'.static.Bounded(HeadCenter - C.Pawn.Location, 300))
    { ServerFixtureFailed(Index, "target_placement_bound"); return; }
    Destination = HeadCenter + (vect(0,40,-30) >> C.Pawn.Rotation);
    // Stock collision remains enabled. Do not start the stroke until a real move is acknowledged.
    bPlaced = Target.SetLocation(Destination) && VSizeSq(Target.Location - Destination) < 1;
    Target.bForceNetUpdate = true;
    `log("KF2VR_MELEE_FIXTURE phase=placed case=" $ CaseIndex $ " target=" $ Target.DiagnosticId
        $ " success=" $ bPlaced $ " location=" $ Target.Location $ " requested=" $ Destination);
    if (!bPlaced) { ServerFixtureFailed(Index, "target_placement_collision"); return; }
    ClientTargetPlaced(Index);
}

reliable client function ClientTargetPlaced(int Index)
{
    if (LocalBridge != None) LocalBridge.TargetPlaced(Index);
}

reliable server function ServerFixtureFailed(int Index, string Reason)
{
    if (Index != CaseIndex) return;
    `log("KF2VR_MELEE_FIXTURE phase=blocked case=" $ Index $ " reason=" $ Reason);
    bDone = true; bForceNetUpdate = true; CaseIndex = 4; NextAt = WorldInfo.RealTimeSeconds + 8;
}

reliable server function ServerMarkPhase(int Index, int Phase)
{
    if (Index != CaseIndex || Target == None || Phase < 1 || Phase > 3) return;
    CaptureHealth = Target.Health; CaptureReceipts = Target.DamageReceipts;
    CaptureCase = Index; CaptureMarker = Index * 10 + Phase; bForceNetUpdate = true;
    `log("KF2VR_MELEE_FIXTURE phase=health case=" $ Index $ " stage=" $ Phase $ " target=" $ Target.DiagnosticId
        $ " health=" $ Target.Health $ " receipts=" $ Target.DamageReceipts);
}

simulated event Tick(float Delta)
{
    local KF2VRNetPlayerController C;
    if (Role != ROLE_Authority)
    {
        if (CaptureMarker > 0 && CaptureMarker != LastCapture && Target != None
            && Target.ObservedHealth == CaptureHealth && Target.DamageReceipts == CaptureReceipts)
        {
            foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', C)
                if (C.IsLocalPlayerController() && C.PlayerReplicationInfo != None && C.PlayerReplicationInfo.bOnlySpectator)
                {
                    if (ObserverCamera == None) ObserverCamera = Spawn(class'VRMeleeObserverCamera', C);
                    if (ObserverCamera == None) return;
                    if (ObserverCamera.Target != Target || C.GetViewTarget() != ObserverCamera)
                    {
                        ObserverCamera.Target = Target;
                        C.bDiagnosticObserverOnly = false;
                        C.SetViewTarget(ObserverCamera);
                        return; // Capture only after the camera renders one frame.
                    }
                    LastCapture = CaptureMarker;
                    C.ConsoleCommand("shot");
                    `log("KF2VR_MELEE_OBSERVER case=" $ CaptureCase $ " marker=" $ CaptureMarker $ " target=" $ Target.DiagnosticId
                        $ " health=" $ Target.ObservedHealth $ " receipts=" $ Target.DamageReceipts $ " capture=shot netmode=" $ WorldInfo.NetMode);
                }
        }
        if (bDone)
        {
            if (LocalExitAt == 0) LocalExitAt = WorldInfo.RealTimeSeconds + 5;
            if (WorldInfo.RealTimeSeconds >= LocalExitAt)
                foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', C)
                    if (C.IsLocalPlayerController()) C.ConsoleCommand("quit");
        }
        return;
    }
    if (WorldInfo.RealTimeSeconds < NextAt) return;
    if (CaseIndex >= 4)
    {
        WorldInfo.Game.ConsoleCommand("exit"); return;
    }
    if (!bStarted) { BeginCase(); return; }
    ClientBeginCase(CaseIndex, CaseWeapon, Target); NextAt = WorldInfo.RealTimeSeconds + 2;
}

reliable server function ServerCaseComplete(int Index)
{
    if (Index != CaseIndex || !bStarted) return;
    `log("KF2VR_MELEE_FIXTURE phase=complete case=" $ Index $ " target=" $ Target.DiagnosticId
        $ " health=" $ Target.Health $ " receipts=" $ Target.DamageReceipts);
    ServerMarkPhase(Index, 3);
    ++CaseIndex; bStarted = false; NextAt = WorldInfo.RealTimeSeconds + 1;
    if (CaseIndex >= 4) { bDone = true; bForceNetUpdate = true; NextAt = WorldInfo.RealTimeSeconds + 8; }
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bAlwaysTick=true
    NetUpdateFrequency=30
}
