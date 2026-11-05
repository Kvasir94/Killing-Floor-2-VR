// Explicitly summoned, nonshipping real-world state fixture. No XR input spoofing.
class VRReloadStateProbe extends Actor;

var float StartedAt;
var bool bFinished;
var bool bReadyRequested;
var VRMagazineStateCases Cases;
var VRPouchMagazineStateCases PouchCases;
var VRSelectorStateCases SelectorCases;
var VRAutomaticReloadStateCases AutomaticCases;
var int TotalChecks, TotalFailures;

event PostBeginPlay()
{
    super.PostBeginPlay();
    StartedAt = WorldInfo.RealTimeSeconds;
    SetTimer(0.25, true, 'TryRun');
}

function Finish(bool Passed, string Reason)
{
    if (bFinished) return;
    bFinished = true;
    ClearTimer('TryRun');
    ClearTimer('AwaitPouchCases');
    `log("KF2VR_RELOAD_RUNTIME complete=" $ (Passed ? "passed" : "failed")
        $ " reason=" $ Reason $ " input=synthetic_direct_state physical_input=none");
    Destroy();
}

function TryRun()
{
    local VRLocalTestControl Control, C;
    local VRDemo Demo;
    local VRHandsBridge B;
    local KFPlayerController PC;
    local KFPlayerReplicationInfo PRI;
    local KFPerk Perk;
    local VRInteractiveReload LiveReload;
    local int Hand;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority)
    { Finish(false, "requires-standalone-authority"); return; }
    foreach WorldInfo.AllActors(class'VRLocalTestControl', C)
        if (C.Authorized()) { Control = C; break; }
    if (Control == None) { Finish(false, "requires-explicit-local-control"); return; }
    foreach WorldInfo.AllActors(class'VRDemo', Demo)
        if (Demo.HandsBridge != None && Demo.HandsBridge.IsLocalVRContext())
        { B = Demo.HandsBridge; break; }
    if (B == None || B.Human == None || B.Human.Health <= 0 || B.HandInventory == None)
    {
        // Exercise the stock Ready button callback; never change tracking,
        // diagnostic admission, perk selection or the normal match countdown.
        if (!bReadyRequested)
            foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
                if (PC.IsLocalController() && LocalPlayer(PC.Player) != None)
                {
                    PRI = KFPlayerReplicationInfo(PC.PlayerReplicationInfo);
                    Perk = PC.GetPerk();
                    if (PRI != None && Perk != None && Perk.bInitialized && PC.MyGFxManager != None
                        && PC.MyGFxManager.CurrentMenu != None && PC.MyGFxManager.CurrentPopup == None)
                    {
                        if (!PRI.bReadyToPlay) PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true);
                        bReadyRequested = PRI.bReadyToPlay;
                    }
                    break;
                }
        if (WorldInfo.RealTimeSeconds - StartedAt > 60) Finish(false, "live-player-context-unavailable");
        return;
    }
    // A spawned pawn can precede the lobby's asynchronous menu-close event.
    // Use the production input admission before any fixture mutates roles or
    // dispatches callbacks; never override its menu/connection/camera gates.
    if (B.HandInventory.Input == None || !B.HandInventory.Input.ContextValid())
    {
        if (WorldInfo.RealTimeSeconds - StartedAt > 60) Finish(false, "live-input-context-unavailable");
        return;
    }
    if (B.NativeGripMask != 0 || B.NativeTriggerMask != 0
        || (B.HandInventory.ZedGrab != None && B.HandInventory.ZedGrab.IsHoldingAny()))
    { Finish(false, "player-interaction-active"); return; }
    LiveReload = B.HandInventory.Input.Reloads;
    if (B.PouchAmmoPending()) { Finish(false, "pouch-receipt-pending"); return; }
    if (B.MagazineActionBusy()) { Finish(false, "magazine-action-receipt-pending"); return; }
    for (Hand = 0; Hand < 2; ++Hand)
        if (LiveReload != None && LiveReload.MagazineRemovals[Hand] != None
            && LiveReload.MagazineRemovals[Hand].Status == 1)
        { Finish(false, "magazine-removal-receipt-pending"); return; }
    if (B.HandInventory.Input.HandCarrying(0) || B.HandInventory.Input.HandCarrying(1)
        || (LiveReload != None && (LiveReload.bActive || LiveReload.bIdleBound
            || LiveReload.DedicatedReloadBusy()
            || (LiveReload.DualCylinders[0] != None && LiveReload.DualCylinders[0].Active())
            || (LiveReload.DualCylinders[1] != None && LiveReload.DualCylinders[1].Active()))))
    { Finish(false, "reload-or-carried-item-active"); return; }
    ClearTimer('TryRun');
    Cases = Spawn(class'VRMagazineStateCases', self);
    if (Cases == None) { Finish(false, "case-spawn-failed"); return; }
    Cases.RunCases(B);
    TotalChecks = Cases.Checks; TotalFailures = Cases.Failures;
    SelectorCases = Spawn(class'VRSelectorStateCases', self);
    if (SelectorCases == None) { Finish(false, "selector-case-spawn-failed"); return; }
    SelectorCases.RunCases(B);
    TotalChecks += SelectorCases.Checks; TotalFailures += SelectorCases.Failures;
    AutomaticCases = Spawn(class'VRAutomaticReloadStateCases', self);
    if (AutomaticCases == None) { Finish(false, "automatic-case-spawn-failed"); return; }
    AutomaticCases.RunCases(B);
    TotalChecks += AutomaticCases.Checks; TotalFailures += AutomaticCases.Failures;
    PouchCases = Spawn(class'VRPouchMagazineStateCases', self);
    if (PouchCases == None) { Finish(false, "pouch-case-spawn-failed"); return; }
    PouchCases.RunCases(B);
    SetTimer(0.1, true, 'AwaitPouchCases');
}

function AwaitPouchCases()
{
    if (PouchCases == None) { Finish(false, "pouch-case-lost"); return; }
    if (!PouchCases.bFinished) return;
    TotalChecks += PouchCases.Checks; TotalFailures += PouchCases.Failures;
    `log("KF2VR_RELOAD_RUNTIME checks=" $ TotalChecks $ " failures=" $ TotalFailures);
    Finish(TotalChecks > 0 && TotalFailures == 0, "production-state-cases");
}

event Destroyed()
{
    if (Cases != None && !Cases.bDeleteMe) Cases.Destroy();
    if (PouchCases != None && !PouchCases.bDeleteMe) PouchCases.Destroy();
    if (SelectorCases != None && !SelectorCases.bDeleteMe) SelectorCases.Destroy();
    if (AutomaticCases != None && !AutomaticCases.bDeleteMe) AutomaticCases.Destroy();
    super.Destroyed();
}

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
    bAlwaysRelevant=false
    bCollideActors=false
    LifeSpan=90
}
