// Explicit offline reload diagnosis. Initial settings/grant/draw are setup;
// thereafter observations read production owners. The explicit geometry option
// publishes wrist goals for native tracking ingress; it never advances gameplay.
class ReloadObserver extends KFMutator config(Game);

var config string Scenario;
var config string SingleWeaponPath;
var class<KFWeapon> SingleWeaponClass;
var VRLocalTestRegistry WeaponRegistry;
var class<KFWeapon> DualWeaponClass, PairMemberClass;
var bool bExpectedKeep, bExpectedLose, bExpectedRecover;
var config float HoldSeconds, ObservationSeconds;
var config bool bExitOnComplete;
// Explicitly selected diagnostic mode. It records transitions without applying
// the entry/hold verdict to a scenario which intentionally inserts or changes roles.
var config bool bTraceLifecycle;
var config string LifecycleCase;
var config bool bGeometryInput;
var KFPawn_Human GeometryPawn;
var VRWeaponPair GeometryPair;
var int GeometryStep, GeometryCapacity[2], GeometryRemoval[2], GeometryReserve;
var vector GeometryWrist[2];
var rotator GeometryRotation[2];
var bool bGeometryDone, bGeometryBusy;
var byte GeometryContact[2];
var bool bGeometryInitialPress, bGeometryFullPress;
var float GeometryAt, GeometryLast;
var int TraceSequence;
var string PreviousTrace;
var string PreviousRecovery[2];
var int CallbackSequence, CallbackInvocation;
var VRDemo Demo;
var VRHandsBridge B;
var KFWeapon Guns[2];
var VRWeaponRuntime Runtimes[2];
var int Ownership[2], PreviousAmmo[2], Shots[2], PreviousButtons;
var int PreviousFlash[2];
var int Pressed[2], Released[2], SawPhysical[2];
var float PhysicalSince[2];
var string LastState[2];
var float SpawnedAt, StableSince, Started, LastHeartbeat, LastSetupNote;
var bool bConfigured, bGrantAttempted, bDrawRequested, bReady, bCompleted;
var bool bOtherHandShot;
var bool bBatchCase, bCasePassed, bGeometryPassed;
var int BatchIndex;
var string CaseReason;
var BatchObserver SuiteOwner;
struct PendingCapture
{
    var string EventName;
    var float EventTime;
};
var array<PendingCapture> CaptureQueue;
var array<string> CaptureEvents;
var int CaptureCount;
var float LastCaptureAt, LastPeriodicCapture, CompletedAt;

function RecordCapture(string EventName)
{
    local PendingCapture Entry;
    if (!bBatchCase || SuiteOwner == None || SuiteOwner.CapturePrefix == ""
        || CaptureCount + CaptureQueue.Length >= 16 || SuiteOwner.CaptureCount >= 128) return;
    if (EventName == "periodic" && CaptureCount + CaptureQueue.Length >= 14) return;
    if (EventName != "periodic" && CaptureEvents.Find(EventName) >= 0) return;
    if (EventName != "periodic") CaptureEvents.AddItem(EventName);
    Entry.EventName = EventName; Entry.EventTime = WorldInfo.RealTimeSeconds;
    CaptureQueue.AddItem(Entry);
    PumpCaptures();
}

function PumpCaptures()
{
    if (SuiteOwner == None || CaptureQueue.Length == 0
        || WorldInfo.RealTimeSeconds - LastCaptureAt < 0.55) return;
    // Preserve the real geometry motion time gate. Images requested at those
    // boundaries are explicitly labelled deferred and taken once motion ends.
    if (bGeometryInput && bReady && GeometryStep > 0 && !bGeometryDone && !bCompleted) return;
    if (SuiteOwner.DispatchCapture(self, CaptureQueue[0].EventName, CaptureQueue[0].EventTime))
    {
        LastCaptureAt = WorldInfo.RealTimeSeconds;
        CaptureQueue.Remove(0, 1);
    }
    else if (SuiteOwner.CaptureCount >= 128 || CaptureCount >= 16) CaptureQueue.Length = 0;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    SpawnedAt = WorldInfo.RealTimeSeconds;
    Scenario = Locs(Scenario);
}

function KFWeapon FindWeapon(class<KFWeapon> C)
{
    local Inventory I;
    for (I = B.Human.InvManager.InventoryChain; I != None; I = I.Inventory)
        if (I.Class == C) return KFWeapon(I);
    return None;
}

function class<KFWeapon> NormalWeaponClass()
{
    if (B == None || B.NativeConnection != 2 || WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return None;
    if (SingleWeaponPath == "") SingleWeaponPath = "KFGameContent.KFWeap_Pistol_9mm";
    if (WeaponRegistry == None)
    {
        if (bBatchCase && SuiteOwner != None) WeaponRegistry = SuiteOwner.Registry;
        else
        {
            WeaponRegistry = new(self) class'VRLocalTestRegistry';
            WeaponRegistry.Build(false);
        }
    }
    if (WeaponRegistry == None) return None;
    SingleWeaponClass = WeaponRegistry.FindWeapon(SingleWeaponPath);
    return SingleWeaponClass;
}

function ConfigureInitialState()
{
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority || B.NativeConnection != 2) return;
    // Local isolated session only. Do not save preferences or change ammo.
    B.ReloadPreset = 2; B.AmmoRuleSettingsRevision = 1;
    B.bInteractiveReloads = true; B.bFreeWeaponCycling = true;
    B.bKeepChamberedRound = bExpectedKeep; B.bLoseReloadAmmo = bExpectedLose; B.bRecoverMagazineAmmo = bExpectedRecover;
    B.bSupportHandCarry = true; B.bToggleGrip = true;
    B.bWorldWeaponDrops = false; B.bAllowOtherWeaponPickup = false;
    B.bExperimentalInteractions = false; B.bZedGrabEnabled = false;
    B.NativeReplayReady = 0;
    if (bBatchCase) B.NativeReplayCase = BatchIndex;
    bConfigured = true;
    `log("KF2VR_RELOAD_OBSERVER phase=setup case=" $ Scenario
        @ "preset=Advanced inputWrites=False extraInventoryUpdates=False worldWeapons=False");
}

function bool AdvancedReady()
{
    return B.ReloadPreset == 2 && B.AmmoRuleSettingsRevision >= 1
        && B.bInteractiveReloads && B.bFreeWeaponCycling
        && B.bKeepChamberedRound == bExpectedKeep && B.bLoseReloadAmmo == bExpectedLose
        && B.bRecoverMagazineAmmo == bExpectedRecover
        && B.bSupportHandCarry && !B.bWorldWeaponDrops && !B.bExperimentalInteractions && !B.bZedGrabEnabled;
}

function bool PrepareCase()
{
    local class<KFWeapon> Desired;
    local KFWeapon W;
    local KFInventoryManager Manager;
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    local int H, PreviousLimit;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority || B.NativeConnection != 2) return false;
    if (!bConfigured) ConfigureInitialState();
    if (!bDrawRequested)
    {
        if (B.HandInventory.PendingPairConversion != None) return false;
        if (Scenario == "dual") Desired = DualWeaponClass;
        else Desired = NormalWeaponClass();
        if (Desired == None) { Complete(false, "initial-class-unavailable"); return false; }
        W = FindWeapon(Desired);
        // A previously converted initial dual is already the requested grant.
        // Reuse its ordinary draw API rather than minting a second aggregate.
        if (W == None && Scenario == "dual")
        {
            W = FindWeapon(PairMemberClass);
            Pair = class'VRWeaponPair'.static.ForMember(W);
            if (Pair != None && Pair.PairState == 2 && B.HandInventory.Input.ContextValid())
            {
                B.HandInventory.ReleaseHand(0); B.HandInventory.ReleaseHand(1);
                bDrawRequested = B.HandInventory.DrawExistingPair(Pair, 0, Pair.Members[0], Pair.Members[1]);
                return false;
            }
            W = None;
        }
        if (W == None && !bGrantAttempted)
        {
            bGrantAttempted = true;
            Manager = KFInventoryManager(B.Human.InvManager);
            if (Manager == None) return false;
            PreviousLimit = Manager.MaxCarryBlocks;
            Manager.MaxCarryBlocks = Max(PreviousLimit, Manager.CurrentCarryBlocks + Desired.static.GetDefaultModifiedWeightValue(0));
            W = KFWeapon(Manager.CreateInventory(Desired, true));
            if (W == None) { Manager.MaxCarryBlocks = PreviousLimit; Complete(false, "initial-grant-failed"); return false; }
        }
        if (W == None || !B.HandInventory.Input.ContextValid()) return false;
        B.HandInventory.ReleaseHand(0); B.HandInventory.ReleaseHand(1);
        // Draw performs the ordinary asynchronous dual-to-member conversion.
        bDrawRequested = B.HandInventory.Draw(Scenario == "dual" ? 0 : 1, W);
        return false;
    }
    if (B.NativeWorldDropVersion != 9 || !AdvancedReady() || !B.HandInventory.Input.ContextValid()
        || B.HandInventory.PendingPairConversion != None || B.HandInventory.TransferItem != None) return false;
    for (H = 0; H < 2; ++H)
    {
        R = B.HandInventory.Registry.GetPrimary(H);
        if (Scenario == "normal" && H == 0)
        {
            if (R != None) return false;
            continue;
        }
        if (R == None || !R.IsCurrent() || R.PrimaryHand != H || R.Item == None || !R.Item.IsInState('Active')
            || R.Item.MySkelMesh == None || R.Presenter == None || R.NativePoseReady != 1
            || R.Item.AmmoCount[0] <= 0 || R.Item.GetSpareAmmoForHUD() <= 0) return false;
        if (Scenario == "normal" && (R.Item.Class != NormalWeaponClass()
            || (!bTraceLifecycle && !class'VRMagazineCarryRecipe'.static.Supports(R.Item)))) return false;
        if (Scenario == "dual")
        {
            if (R.Item.Class != PairMemberClass) return false;
            if (Pair == None) Pair = class'VRWeaponPair'.static.ForMember(R.Item);
            if (Pair == None || Pair.PairState != 2 || class'VRWeaponPair'.static.ForMember(R.Item) != Pair) return false;
        }
        Guns[H] = R.Item; Runtimes[H] = R;
    }
    return true;
}

// Setup diagnostics only: expose each readiness predicate without advancing
// production owners, preparing another item, or changing any game state.
function LogSetupWait()
{
    local VRWeaponRuntime R;
    local int H, StarterNext, StarterCount;
    local bool HasInventory, HasInput, HasRegistry, Context;
    if (WorldInfo.RealTimeSeconds - LastSetupNote < 1) return;
    LastSetupNote = WorldInfo.RealTimeSeconds;
    HasInventory = B.HandInventory != None;
    HasInput = HasInventory && B.HandInventory.Input != None;
    HasRegistry = HasInventory && B.HandInventory.Registry != None;
    Context = HasInput && B.HandInventory.Input.ContextValid();
    if (Demo.StarterLoadout != None)
    { StarterNext = Demo.StarterLoadout.NextDefinition; StarterCount = Demo.StarterLoadout.Definitions.Length; }
    `log("KF2VR_RELOAD_OBSERVER phase=setup case=" $ Scenario @ "reason=waiting"
        @ "cap=" $ B.NativeWorldDropVersion @ "advanced=" $ AdvancedReady() @ "context=" $ Context
        @ "configured=" $ bConfigured @ "drawRequested=" $ bDrawRequested @ "grantAttempted=" $ bGrantAttempted
        @ "inventory=" $ HasInventory @ "input=" $ HasInput @ "registry=" $ HasRegistry
        @ "pendingPair=" $ (HasInventory && B.HandInventory.PendingPairConversion != None)
        @ "transfer=" $ (HasInventory && B.HandInventory.TransferItem != None)
        @ "starterNext=" $ StarterNext @ "starterCount=" $ StarterCount
        @ "connection=" $ B.NativeConnection @ "valid=" $ B.NativeValidMask @ "gripActive=" $ B.NativeGripActiveMask
        @ "menu=" $ B.NativeMenuActive @ "firstPerson=" $ (B.PC != None && B.PC.UsingFirstPersonCamera())
        @ "stockMenusActive=" $ (B.PC != None && B.PC.MyGFxManager != None && B.PC.MyGFxManager.bMenusActive)
        @ "stockMenusOpen=" $ (B.PC != None && B.PC.MyGFxManager != None && B.PC.MyGFxManager.bMenusOpen)
        @ "stockPopup=" $ (B.PC != None && B.PC.MyGFxManager != None && B.PC.MyGFxManager.CurrentPopup != None)
        @ "stableSince=" $ StableSince);
    for (H = 0; H < 2; ++H)
    {
        R = None;
        if (HasRegistry) R = B.HandInventory.Registry.GetPrimary(H);
        if (R == None || R.Item == None)
            `log("KF2VR_RELOAD_OBSERVER phase=setup case=" $ Scenario @ "reason=waiting hand=" $ H
                @ "identity=None weaponClass=None stage=empty NativePoseReady=0 ammo=-1 spare=-1 current=False");
        else
            `log("KF2VR_RELOAD_OBSERVER phase=setup case=" $ Scenario @ "reason=waiting hand=" $ H
                @ "identity=" $ R.Item.Name @ "weaponClass=" $ R.Item.Class.Name @ "stage=" $ R.Item.GetStateName()
                @ "NativePoseReady=" $ R.NativePoseReady @ "presenterReady=" $ (R.Presenter != None && R.Presenter.NativeWeaponReady != 0)
                @ "ammo=" $ R.Item.AmmoCount[0] @ "spare=" $ R.Item.GetSpareAmmoForHUD() @ "current=" $ R.IsCurrent()
                @ "primaryHand=" $ R.PrimaryHand @ "ownership=" $ R.OwnershipRevision);
    }
}

function bool PhysicalActive(int H)
{
    local VRInteractiveReload Reload;
    Reload = B.HandInventory.Input.Reloads;
    return Guns[H] != None && Reload != None
        && ((Reload.bActive && Reload.Gun == Guns[H])
            || (Reload.DualCylinders[H] != None && Reload.DualCylinders[H].Gun == Guns[H]));
}

// A sampled stock firing state is independent of trigger release: inherited
// WeaponSingleFiring/WeaponBurstFiring remain firing while stock pays shots.
// Replicated pawn flash state may be cleared in the same frame and is not a
// shot counter. Neither a removed magazine nor a mechanism debit is a shot.
function bool PrimaryShotObserved(int H, int Before)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    if (H < 0 || H > 1) return false;
    W = Guns[H]; R = Runtimes[H];
    return W != None && R != None && W.AmmoCount[0] < Before
        && W.IsInState('WeaponFiring') && !W.IsInState('Reloading') && !PhysicalActive(H)
        && W.CurrentFireMode < 2 && W.GetAmmoType(W.CurrentFireMode) == 0
        && !R.MagazineOut() && R.MechanismPending == 0;
}

function bool AuthorityHeld(int H)
{
    local VRInteractiveReload Reload;
    Reload = B.HandInventory.Input.Reloads;
    if (!PhysicalActive(H) || Reload.MagazineRemovals[H] == None
        || Reload.MagazineRemovals[H].Gun != Guns[H] || Reload.MagazineRemovals[H].Status != 2) return false;
    if (Scenario == "dual") return Reload.DualCylinders[H] != None
        && Reload.DualCylinders[H].Gun == Guns[H] && Reload.DualCylinders[H].bAuthorityHeld;
    return true;
}

function string StateRow(int H)
{
    local VRInteractiveReload Reload;
    local VRCylinderSession Cylinder;
    local VRMagazineRemoval Removal;
    local VRWeaponPair Pair;
    local int Request, Session, Status, RemovalRequest, RemovalStatus;
    local string Identity, WeaponClass, Stage;
    if (Guns[H] == None)
        return "hand=" $ H @ "identity=None ownership=0 ammo=-1 reserve=-1 stage=empty physicalActive=False authorityHeld=False worldWeapons=False";
    Reload = B.HandInventory.Input.Reloads;
    Cylinder = Reload.DualCylinders[H]; Removal = Reload.MagazineRemovals[H];
    Pair = class'VRWeaponPair'.static.ForMember(Guns[H]);
    if (Cylinder != None && Cylinder.Gun == Guns[H])
    { Request = Cylinder.AuthorityRequest; Session = Cylinder.AuthoritySession; }
    else if (Reload.CylinderAuthorityGun == Guns[H])
    { Request = Reload.CylinderAuthorityRequest; Session = Reload.CylinderAuthoritySession; }
    if (Pair != None && Session > 0) Status = Pair.PhysicalReloadStatus(Guns[H], Session);
    if (Removal != None && Removal.Gun == Guns[H])
    { RemovalRequest = Removal.Request; RemovalStatus = Removal.Status; }
    Identity = string(Guns[H].Name); WeaponClass = string(Guns[H].Class.Name); Stage = string(Guns[H].GetStateName());
    return "hand=" $ H @ "identity=" $ Identity @ "weaponClass=" $ WeaponClass
        @ "ownership=" $ Runtimes[H].OwnershipRevision @ "primaryHand=" $ Runtimes[H].PrimaryHand
        @ "ammo=" $ Guns[H].AmmoCount[0] @ "reserve=" $ Guns[H].GetSpareAmmoForHUD() @ "stage=" $ Stage
        @ "physicalActive=" $ PhysicalActive(H) @ "authorityHeld=" $ AuthorityHeld(H)
        @ "pairedRequest=" $ Request @ "pairedSession=" $ Session @ "pairedStatus=" $ Status
        @ "removalRequest=" $ RemovalRequest @ "removalStatus=" $ RemovalStatus
        @ "stockRequest=" $ B.HandInventory.Input.InputState[H].StockReloadRequest
        @ "awaitAmmo=" $ (Reload.Gun == Guns[H] && Reload.bAwaitAmmo)
        @ "awaitRack=" $ (Reload.Gun == Guns[H] && Reload.bAwaitRack)
        @ "magFeed=" $ Runtimes[H].MagazineFeedFlags @ "emptyMag=" $ Runtimes[H].EmptyMagazineFlags
        @ "slideLock=" $ Runtimes[H].bSlideLockPending @ "mechanismPending=" $ Runtimes[H].MechanismPending
        @ "buttons=" $ B.NativeButtonMask @ "triggers=" $ B.NativeTriggerMask
        @ "triggerArmed=" $ B.Hands[H].bTriggerArmed @ "valid=" $ B.NativeValidMask
        @ "shots=" $ Shots[H] @ "pressSeen=" $ (Pressed[H] != 0) @ "releaseSeen=" $ (Released[H] != 0)
        @ "nativeFlash=" $ Runtimes[H].NativeFlashCount
        @ "nativeCapability=" $ B.NativeWorldDropVersion @ "worldWeapons=" $ B.bWorldWeaponDrops;
}

function Complete(bool Passed, string Reason)
{
    if (bCompleted) return;
    if (bBatchCase && !Passed && (Reason == "setup-timeout" || Reason == "observation-timeout"))
    {
        `log("KF2VR_REPLAY_SUITE phase=watchdog index=" $ BatchIndex @ "reason=reload-stuck"
            @ "stage=" $ (bReady ? "observation" : "setup")
            @ "elapsed=" $ (WorldInfo.RealTimeSeconds - (bReady ? Started : SpawnedAt))
            @ "physicalLeft=" $ PhysicalActive(0) @ "physicalRight=" $ PhysicalActive(1)
            @ "geometryStep=" $ GeometryStep @ "ready=" $ bReady);
        Reason = "reload-stuck";
    }
    RecordCapture(Reason == "reload-stuck" ? "stuck" : "complete");
    bCompleted = true; CompletedAt = WorldInfo.RealTimeSeconds; bCasePassed = Passed; CaseReason = Reason;
    `log("KF2VR_RELOAD_OBSERVER phase=complete case=" $ Scenario @ "passed=" $ Passed @ "reason=" $ Reason
        @ "coverage=physical-entry-hold-only fullInsertion=False multiplayerAccepted=False"
        @ "otherHandShot=" $ bOtherHandShot);
    if (bExitOnComplete && Demo != None && Demo.DemoController != None)
        Demo.DemoController.ConsoleCommand("quit");
}

// Read production owners after placement; never drive a callback or manufacture
// a stock receipt. Changed poses/inputs are recorded at the game tick cadence.
// Missing callbacks, rendered pixels and network authority remain untested.
function GeometryComplete(bool Passed, string Reason)
{
    if (bGeometryDone) return;
    bGeometryDone = true; bGeometryPassed = Passed; CaseReason = Reason;
    GeometryLedger();
    B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
    B.ReloadCaseTriggerMask = 0; B.ReloadCaseGripMask = 0;
    if (!Passed) B.ReloadCaseEnabled = -1;
    `log("KF2VR_RELOAD_GEOMETRY phase=complete case=" $ LifecycleCase
        @ "passed=" $ Passed @ "reason=" $ Reason @ "busyObserved=" $ bGeometryBusy
        @ "leftContact=" $ (GeometryContact[0] != 0) @ "rightContact=" $ (GeometryContact[1] != 0)
        @ "leftRemoval=" $ GeometryRemoval[0] @ "rightRemoval=" $ GeometryRemoval[1]
        @ "coverage=paired9mm-capacity-removal-both-hip-seats-full-rejection"
        @ "loseAmmo=True cancellation=False reverseOrder=False multiplayerAccepted=False headsetAccepted=False");
    if (bBatchCase && !Passed) Complete(false, Reason);
    PumpCaptures();
}

function GeometryLedger()
{
    local AmmoConservationObserver LedgerObserver;
    foreach WorldInfo.AllActors(class'AmmoConservationObserver', LedgerObserver)
        if (LedgerObserver.Driver == self)
        {
            `log("KF2VR_RELOAD_GEOMETRY phase=ledger case=" $ LifecycleCase
                @ "step=" $ GeometryStep @ LedgerObserver.Snapshot());
            return;
        }
}

// Exact paired-9mm input choreography. The production cylinder supplies both
// ends of the translation, so controller calibration, body origin and cooked
// magazine placement need no copied offsets. Native consumes only these goals.
function GeometryInput()
{
    local VRInteractiveReload Reload;
    local VRCylinderSession Cylinder;
    local VRMagazineRemoval Removal;
    local int H, Other;
    local float Now, DT, Distance;
    local vector At, Target, Delta;
    local quat Q;
    local bool BothRemoved, BothClosed;
    if (!bGeometryInput || !bReady) return;
    if (bGeometryDone)
    {
        if (B.ReloadCaseEnabled > 0) ++B.ReloadCaseSample;
        return;
    }
    if (!bTraceLifecycle || Scenario != "dual"
        || (LifecycleCase != "hip-tactical-at-capacity" && LifecycleCase != "dual-removal-backend-busy"))
    { GeometryComplete(false, "unsupported-case"); return; }
    Now = WorldInfo.RealTimeSeconds;
    Reload = B.HandInventory.Input.Reloads;
    if (GeometryStep == 0)
    {
        // Give the declared readiness screenshot time to render before this
        // case begins its real motion deadline; never relax a live DT gate.
        if (bBatchCase && SuiteOwner != None && SuiteOwner.CapturePrefix != ""
            && Now - LastCaptureAt < 0.75) return;
        GeometryPawn = B.Human; GeometryPair = class'VRWeaponPair'.static.ForMember(Guns[0]);
        if (GeometryPair == None || GeometryPair.PairState != 2 || GeometryPawn == None)
        { GeometryComplete(false, "initial-pair"); return; }
        GeometryReserve = Guns[0].GetSpareAmmoForHUD();
        for (H = 0; H < 2; ++H)
        {
            GeometryCapacity[H] = Guns[H].MagazineCapacity[0];
            if (Guns[H].Class != class'VRWeap_Paired9mm' || Guns[H].bInfiniteSpareAmmo
                || class'VRWeaponPair'.static.ForMember(Guns[H]) != GeometryPair
                || GeometryCapacity[H] != 15 || Guns[H].AmmoCount[0] != GeometryCapacity[H]
                || class'VRWeaponPair'.static.MemberChamberRounds(Guns[H]) != 1
                || Runtimes[H].MagazineOut() || !Runtimes[H].RealisticTopUp()
                || !GeometryPair.PhysicalTopUp(Guns[H], true) || !Guns[H].IsInState('Active'))
            { GeometryComplete(false, "initial-capacity-feed-or-policy"); return; }
            GeometryWrist[H] = H == 0 ? B.LeftPosition : B.RightPosition;
            GeometryRotation[H] = H == 0 ? B.LeftRotation : B.RightRotation;
        }
        if (GeometryReserve < GeometryCapacity[0] + GeometryCapacity[1]
            || Guns[1].GetSpareAmmoForHUD() != GeometryReserve)
        { GeometryComplete(false, "initial-shared-reserve"); return; }
        B.ReloadCaseControlVersion = 2; B.ReloadCaseEnabled = 1;
        B.ReloadCaseValidMask = 3; B.ReloadCaseGripMask = 0; B.ReloadCaseTriggerMask = 0;
        B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
        GeometryStep = 1; GeometryAt = Now; GeometryLast = Now;
        `log("KF2VR_RELOAD_GEOMETRY phase=initial case=" $ LifecycleCase
            @ "left=" $ PathName(Guns[0]) @ "right=" $ PathName(Guns[1])
            @ "pawn=" $ PathName(GeometryPawn) @ "loadedLeft=15 loadedRight=15"
            @ "reserve=" $ GeometryReserve @ "loseAmmo=True authoredInput=True measuredHumanInput=False");
        GeometryLedger();
    }
    if (B.Human != GeometryPawn || GeometryPawn.Health <= 0 || !AdvancedReady()
        || !B.HandInventory.Input.ContextValid() || GeometryPair.PairState != 2
        || (B.NativeValidMask & B.NativeGripActiveMask & 3) != 3)
    { GeometryComplete(false, "context-changed"); return; }
    DT = Now - GeometryLast; GeometryLast = Now;
    if (DT < 0 || DT > 0.1)
    { GeometryComplete(false, "tracking-gap"); return; }
    if (Now - Started > 25)
    {
        `log("KF2VR_REPLAY_SUITE phase=watchdog index=" $ BatchIndex @ "reason=reload-stuck stage=geometry"
            @ "elapsed=" $ (Now - Started) @ "geometryStep=" $ GeometryStep
            @ "physical=" $ Reload.bActive @ "awaitAmmo=" $ Reload.bAwaitAmmo
            @ "awaitRack=" $ Reload.bAwaitRack @ "guide=" $ Reload.GuideProgress @ "rackPull=" $ Reload.RackPull);
        GeometryComplete(false, "reload-stuck"); return;
    }
    if (GeometryStep == 2 && (B.NativePhysicalButtonMask & 9) == 9) bGeometryInitialPress = true;
    if (GeometryStep == 6 && (B.NativePhysicalButtonMask & 9) == 9) bGeometryFullPress = true;
    BothRemoved = true; BothClosed = true;
    for (H = 0; H < 2; ++H)
    {
        Other = 1 - H;
        if (Runtimes[H] == None || !Runtimes[H].IsCurrent() || Runtimes[H].Item != Guns[H]
            || Runtimes[H].OwnershipRevision != Ownership[H] || Runtimes[H].PrimaryHand != H
            || B.HandInventory.Registry.GetPrimary(H) != Runtimes[H]
            || Guns[H].MySkelMesh == None || class'VRWeaponPair'.static.ForMember(Guns[H]) != GeometryPair)
        { GeometryComplete(false, "exact-runtime-changed"); return; }
        Cylinder = Reload.DualCylinders[H]; Removal = Reload.MagazineRemovals[H];
        if (Cylinder != None && Cylinder.Gun == Guns[H] && Cylinder.bAwaitMagazineAdmission
            && B.MagazineActionBusy() && Reload.MagazineRemovals[Other] != None
            && Reload.MagazineRemovals[Other].Gun == Guns[Other]
            && Reload.MagazineRemovals[Other].Status == 1 && !bGeometryBusy)
        {
            bGeometryBusy = true;
            `log("KF2VR_RELOAD_GEOMETRY phase=busy case=" $ LifecycleCase @ "waitingHand=" $ H
                @ "outstandingHand=" $ Other @ "preflightDeferred=True");
        }
        if (Removal != None && Removal.Gun == Guns[H] && Removal.Status == 2)
        {
            if (GeometryRemoval[H] == 0)
            {
                GeometryRemoval[H] = Removal.Request;
                RecordCapture("geometry-removal");
                `log("KF2VR_RELOAD_GEOMETRY phase=removal case=" $ LifecycleCase @ "hand=" $ H
                    @ "request=" $ Removal.Request @ "loaded=" $ Guns[H].AmmoCount[0]
                    @ "reserve=" $ Guns[H].GetSpareAmmoForHUD());
            }
            else if (Removal.Request != GeometryRemoval[H])
            { GeometryComplete(false, "duplicate-removal"); return; }
        }
        if (GeometryRemoval[H] == 0 || !AuthorityHeld(H)) BothRemoved = false;
        if (PhysicalActive(H) || !Guns[H].IsInState('Active') || Runtimes[H].MagazineOut()
            || Guns[H].AmmoCount[0] != GeometryCapacity[H] + 1) BothClosed = false;
        if (Cylinder != None && Cylinder.Gun == Guns[H] && Cylinder.bPresentationReady
            && Cylinder.LoadedBone != '' && Guns[H].MySkelMesh.MatchRefBone(Cylinder.LoadedBone) >= 0)
        {
            Cylinder.HipLoader(At, Q); Target = Guns[H].MySkelMesh.GetBoneLocation(Cylinder.LoadedBone);
            if (!class'VRReloadMotionGuard'.static.ValidPosition(At)
                || !class'VRReloadMotionGuard'.static.ValidPosition(Target))
            { GeometryComplete(false, "invalid-contact-geometry"); return; }
            if (GeometryStep < 4 && Cylinder.AtHipSeat(Target, At))
            { GeometryComplete(false, "contact-before-both-removals"); return; }
            if (GeometryStep == 4)
            {
                // Only the actual production callback certifies hip contact.
                Delta = At - Target; Distance = VSize(Delta);
                if (!(Distance >= 0 && Distance < 150))
                { GeometryComplete(false, "contact-out-of-bounds"); return; }
                if (Distance > 0.01) GeometryWrist[H] += Delta * FMin(1, 60 * DT / Distance);
            }
        }
    }
    if (GeometryStep == 1 && Now - GeometryAt >= 0.5)
    {
        B.ReloadCaseLeftButtons = 1; B.ReloadCaseRightButtons = 1;
        GeometryStep = 2; GeometryAt = Now;
    }
    else if (GeometryStep == 2 && Now - GeometryAt >= 0.15)
    {
        if (!bGeometryInitialPress) { GeometryComplete(false, "initial-native-button-edge-missing"); return; }
        B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
        GeometryStep = 3; GeometryAt = Now;
    }
    else if (GeometryStep == 3 && BothRemoved)
    {
        if (GeometryRemoval[0] == GeometryRemoval[1] || Guns[0].AmmoCount[0] != 1
            || Guns[1].AmmoCount[0] != 1 || !Runtimes[0].MagazineOut() || !Runtimes[1].MagazineOut()
            || Guns[0].GetSpareAmmoForHUD() != GeometryReserve)
        { GeometryComplete(false, "removal-accounting"); return; }
        GeometryStep = 4; GeometryAt = Now;
        GeometryLedger();
        `log("KF2VR_RELOAD_GEOMETRY phase=approach case=" $ LifecycleCase
            @ "bothRemovalReceipts=True speedUUPerSecond=60");
    }
    else if (GeometryStep == 4 && BothClosed)
    {
        if (GeometryContact[0] == 0 || GeometryContact[1] == 0
            || Guns[0].GetSpareAmmoForHUD() != GeometryReserve - GeometryCapacity[0] - GeometryCapacity[1]
            || Guns[1].GetSpareAmmoForHUD() != Guns[0].GetSpareAmmoForHUD())
        { GeometryComplete(false, "seat-contact-or-payment-accounting"); return; }
        GeometryStep = 5; GeometryAt = Now;
        RecordCapture("geometry-seated");
        GeometryLedger();
        `log("KF2VR_RELOAD_GEOMETRY phase=seated case=" $ LifecycleCase
            @ "left=16 right=16 reserve=" $ Guns[0].GetSpareAmmoForHUD() @ "bothRealHipContacts=True");
    }
    else if (GeometryStep == 5 && Now - GeometryAt >= 0.5)
    {
        B.ReloadCaseLeftButtons = 1; B.ReloadCaseRightButtons = 1;
        GeometryStep = 6; GeometryAt = Now;
    }
    else if (GeometryStep == 6 && Now - GeometryAt >= 0.15)
    {
        if (!bGeometryFullPress) { GeometryComplete(false, "full-native-button-edge-missing"); return; }
        B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
        GeometryStep = 7; GeometryAt = Now;
    }
    else if (GeometryStep == 7 && Now - GeometryAt >= 1)
    {
        if (!BothClosed || Runtimes[0].CanStartReload() || Runtimes[1].CanStartReload()
            || Guns[0].GetSpareAmmoForHUD() != GeometryReserve - GeometryCapacity[0] - GeometryCapacity[1])
        { GeometryComplete(false, "true-full-reload-was-not-rejected"); return; }
        GeometryComplete(LifecycleCase != "dual-removal-backend-busy" || bGeometryBusy,
            (LifecycleCase == "dual-removal-backend-busy" && !bGeometryBusy) ? "busy-transient-not-observed" : "authored-contact-path-completed");
    }
    B.ReloadCaseLeftPosition = GeometryWrist[0]; B.ReloadCaseRightPosition = GeometryWrist[1];
    B.ReloadCaseLeftRotation = GeometryRotation[0]; B.ReloadCaseRightRotation = GeometryRotation[1];
    ++B.ReloadCaseSample;
}

function TraceLifecycle()
{
    local int H;
    local string Row, WeaponPath, MeshPath;
    local VRWeaponRuntime R;
    local VRInteractiveReload Reload;
    local VRManualAction Action;
    local VRMagazineRecovery Recovery;
    Reload = B.HandInventory.Input.Reloads;
    Action = Reload.ManualAction;
    Recovery = Reload.Recovery;
    Row = "buttons=" $ B.NativeButtonMask @ "grips=" $ B.NativeGripMask
        @ "triggers=" $ B.NativeTriggerMask @ "valid=" $ B.NativeValidMask
        @ "roomEpoch=" $ B.NativeRoomSpaceEpoch
        @ "left=" $ B.LeftPosition @ "right=" $ B.RightPosition
        @ "leftRotation=" $ B.LeftRotation @ "rightRotation=" $ B.RightRotation
        @ "leftHand=" $ B.Hands[0].Position @ "rightHand=" $ B.Hands[1].Position
        @ "leftRoom=" $ B.NativeRoomLeftPosition @ "rightRoom=" $ B.NativeRoomRightPosition;
    if (Row != PreviousTrace)
    {
        ++TraceSequence;
        `log("KF2VR_RELOAD_TRACE phase=input case=" $ LifecycleCase @ "seq=" $ TraceSequence
            @ "elapsed=" $ (WorldInfo.RealTimeSeconds - Started) @ Row);
        PreviousTrace = Row;
    }
    for (H = 0; H < 2; ++H)
    {
        if (Recovery != None)
        {
            Row = "hand=" $ H @ "active=" $ Recovery.Carries[H].bActive
                @ "claimed=" $ Recovery.Carries[H].bClaimed @ "request=" $ Recovery.Carries[H].Request
                @ "token=" $ Recovery.Carries[H].Token @ "guide=" $ Recovery.Carries[H].bGuide
                @ "requireFresh=" $ Recovery.Carries[H].bRequireFresh
                @ "queuedAction=" $ Recovery.Carries[H].QueuedAction
                @ "remaining=" $ Recovery.Carries[H].Remaining
                @ "source=" $ PathName(Recovery.Carries[H].SourceWeapon)
                @ "target=" $ PathName(Recovery.Carries[H].TargetWeapon)
                @ "insertRuntime=" $ PathName(Recovery.Carries[H].InsertRuntime)
                @ "insertPawn=" $ PathName(Recovery.Carries[H].InsertHuman)
                @ "origin=" $ Recovery.Carries[H].Origin
                @ "handBusy=" $ Reload.HandBusy(H) @ "hipBusy=" $ Reload.HipBusyHand(H);
            if (Row != PreviousRecovery[H])
            {
                ++TraceSequence;
                `log("KF2VR_RELOAD_TRACE phase=recovery case=" $ LifecycleCase @ "seq=" $ TraceSequence @ Row);
                PreviousRecovery[H] = Row;
            }
        }
        R = Runtimes[H];
        if (R == None || R.Item == None) continue;
        WeaponPath = PathName(R.Item); MeshPath = "None";
        if (R.Item.MySkelMesh != None) MeshPath = PathName(R.Item.MySkelMesh);
        Row = "slot=" $ H @ "weapon=" $ WeaponPath @ "pawn=" $ PathName(B.Human)
            @ "world=" $ PathName(WorldInfo) @ "owner=" $ PathName(R.Item.Owner)
            @ "primary=" $ R.PrimaryHand @ "support=" $ R.SupportHand
            @ "carryPrimary=" $ R.CarryPrimaryHand @ "ownership=" $ R.OwnershipRevision
            @ "current=" $ R.IsCurrent() @ "loaded=" $ R.Item.AmmoCount[0]
            @ "reserve=" $ R.Item.GetSpareAmmoForHUD() @ "stockState=" $ R.Item.GetStateName()
            @ "feed=" $ R.MagazineFeedFlags @ "chamberLoaded=" $ R.MagazineHasChamber()
            @ "magOut=" $ R.MagazineOut() @ "mechanismPending=" $ R.MechanismPending
            @ "mesh=" $ MeshPath @ "attached=" $ (R.Item.MySkelMesh != None && R.Item.MySkelMesh.bAttached)
            @ "physical=" $ (Reload.bActive && Reload.Gun == R.Item)
            @ "awaitAmmo=" $ (Reload.Gun == R.Item && Reload.bAwaitAmmo)
            @ "awaitRack=" $ (Reload.Gun == R.Item && Reload.bAwaitRack)
            @ "finishProfile=" $ R.FinishProfileToken @ "finishModes=" $ R.FinishModeMask
            @ "finishAmount=" $ R.FinishAmount @ "finishOut=" $ R.bFinishOut
            @ "finishReturning=" $ R.bFinishReturning
            @ "guide=" $ Reload.GuideProgress @ "rackPull=" $ Reload.RackPull;
        if (Reload.DualCylinders[H] != None && Reload.DualCylinders[H].Gun == R.Item)
            Row = Row @ "awaitRemovalAdmission=" $ Reload.DualCylinders[H].bAwaitMagazineAdmission
                @ "awaitRemovalReceipt=" $ Reload.DualCylinders[H].bAwaitMagazineRemoval;
        if (Action != None && Action.Gun == R.Item)
            Row = Row @ "owed=" $ Action.bNeedsPump @ "progress=" $ Action.Amount
                @ "opened=" $ Action.bOpened @ "engaged=" $ Action.bEngaged
                @ "actionHand=" $ Action.ActionHand @ "gunHand=" $ Action.GunHand;
        if (Row != LastState[H] || WorldInfo.RealTimeSeconds - LastHeartbeat >= 0.25)
        {
            ++TraceSequence;
            `log("KF2VR_RELOAD_TRACE phase=state case=" $ LifecycleCase @ "seq=" $ TraceSequence
                @ "elapsed=" $ (WorldInfo.RealTimeSeconds - Started) @ Row);
            LastState[H] = Row;
        }
    }
    if (Reload.bActive && Reload.Gun != None && Reload.bInsertSampled)
    {
        ++TraceSequence;
        `log("KF2VR_RELOAD_TRACE phase=geometry case=" $ LifecycleCase @ "seq=" $ TraceSequence
            @ "weapon=" $ PathName(Reload.Gun) @ "entry=" $ Reload.AmmoTarget()
            @ "seat=" $ Reload.SeatLocation() @ "entryLocal=" $ Reload.EntryLocal
            @ "seatLocal=" $ Reload.SeatLocal @ "insertTime=" $ Reload.InsertTime
            @ "insertEnd=" $ Reload.InsertEndTime @ "carryTime=" $ Reload.AmmoCarryTime
            @ "cylinderFrame=" $ Reload.CylinderInsertFrame);
    }
    if (WorldInfo.RealTimeSeconds - LastHeartbeat >= 0.25) LastHeartbeat = WorldInfo.RealTimeSeconds;
    if (WorldInfo.RealTimeSeconds - Started >= ObservationSeconds)
    {
        if (bGeometryInput && !bGeometryDone) GeometryComplete(false, "observation-ended");
        if (bGeometryInput)
        {
            B.ReloadCaseEnabled = -1;
            if (bBatchCase && bGeometryDone && bGeometryPassed) B.ReloadCaseEnabled = 0;
        }
        bCompleted = true; CompletedAt = WorldInfo.RealTimeSeconds;
        bCasePassed = bGeometryInput && bGeometryDone && bGeometryPassed;
        if (!bGeometryInput) CaseReason = "observation-ended-without-verdict";
        RecordCapture("complete");
        ++TraceSequence;
        `log("KF2VR_RELOAD_TRACE phase=complete case=" $ LifecycleCase @ "seq=" $ TraceSequence
            @ "status=UNTESTED reason=observation-ended acceptance=False");
        if (bExitOnComplete && Demo.DemoController != None) Demo.DemoController.ConsoleCommand("quit");
    }
}

// Receiver for an opt-in delegate invoked at the actual production callsite.
// No callback is inferred from sampled state. A missing owner/ledger value is
// explicitly Unknown; the analyzer cannot turn it into a zero or a pass.
function int ObserveProductionTransition(string FunctionName, string Phase, KFWeapon W,
    string Action, string Accepted, string Receipt, optional int Call, optional string Detail)
{
    local VRWeaponRuntime R;
    local VRManualAction Manual;
    local int H;
    local string Row;
    if (!bTraceLifecycle || !bReady || bCompleted || B == None || B.NativeConnection != 2) return 0;
    if (Phase == "before") { ++CallbackInvocation; Call = CallbackInvocation; }
    if (Call <= 0) return 0;
    for (H = 0; H < 2; ++H)
        if (Runtimes[H] != None && Runtimes[H].Item == W) R = Runtimes[H];
    if (bGeometryInput && !bGeometryDone && Phase == "after" && Accepted == "True" && R != None)
    {
        H = R.PrimaryHand;
        if (H >= 0 && H <= 1 && W == Guns[H])
        {
            if (FunctionName == "KF2VR.VRCylinderSession.Tick"
                && Detail == ("boundary=seat-contact hand=" $ H @ "hip=True") && GeometryStep == 4)
            {
                GeometryContact[H] = 1;
                `log("KF2VR_RELOAD_GEOMETRY phase=contact case=" $ LifecycleCase
                    @ "hand=" $ H @ "source=production hip=True request=" $ GeometryRemoval[H]);
            }
            if (FunctionName == "KF2VR.VRCylinderSession.BeginMagazine"
                && Detail == ("boundary=admission-wait hand=" $ H) && B.MagazineActionBusy()
                && B.HandInventory.Input.Reloads.MagazineRemovals[1-H] != None
                && B.HandInventory.Input.Reloads.MagazineRemovals[1-H].Status == 1)
            {
                bGeometryBusy = true;
                `log("KF2VR_RELOAD_GEOMETRY phase=busy case=" $ LifecycleCase
                    @ "waitingHand=" $ H @ "outstandingHand=" $ (1-H) @ "source=production preflightDeferred=True");
            }
        }
    }
    Row = "loaded=Unknown reserve=Unknown owed=Unknown progress=Unknown primary=Unknown support=Unknown"
        @ "chamberLoaded=Unknown magOut=Unknown feed=Unknown";
    if (R != None && W != None)
    {
        Row = "loaded=" $ W.AmmoCount[0] @ "reserve=" $ W.GetSpareAmmoForHUD()
            @ "primary=" $ R.PrimaryHand @ "support=" $ R.SupportHand
            @ "chamberLoaded=" $ R.MagazineHasChamber() @ "magOut=" $ R.MagazineOut()
            @ "feed=" $ R.MagazineFeedFlags @ "owed=" $ R.bManualPumpPending @ "progress=Unknown";
        Manual = B.HandInventory.Input.Reloads.ManualAction;
        if (Manual != None && Manual.Gun == W)
            Row = "loaded=" $ W.AmmoCount[0] @ "reserve=" $ W.GetSpareAmmoForHUD()
                @ "primary=" $ R.PrimaryHand @ "support=" $ R.SupportHand
                @ "chamberLoaded=" $ R.MagazineHasChamber() @ "magOut=" $ R.MagazineOut()
                @ "feed=" $ R.MagazineFeedFlags @ "owed=" $ Manual.bNeedsPump @ "progress=" $ Manual.Amount;
    }
    ++CallbackSequence;
    `log("KF2VR_RELOAD_CALLBACK case=" $ LifecycleCase @ "seq=" $ CallbackSequence
        @ "call=" $ Call @ "phase=" $ Phase @ "function=" $ FunctionName
        @ "source=production weapon=" $ PathName(W) @ "action=" $ Action
        @ "accepted=" $ Accepted @ "receipt=" $ Receipt @ Row
        @ "escrow=Unknown shots=Unknown grants=Unknown discarded=Unknown commits=Unknown"
        @ Detail);
    return Call;
}

simulated event Tick(float DT)
{
    local VRDemo D;
    local VRInteractiveReload Reload;
    local VRWeaponPair Pair;
    local int H, Bit, LowerBit, Member, Rounds;
    local bool Heartbeat, AllHeld;
    local string Row;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return;
    if (bCompleted) return;
    if (Demo == None) foreach WorldInfo.AllActors(class'VRDemo', D) { Demo = D; break; }
    if (Demo == None || Demo.HandsBridge == None || Demo.StarterLoadout == None) return;
    B = Demo.HandsBridge;
    // Never configure or grant merely because somebody loaded this mutator
    // into a normal headset session. Connection2 is explicit native replay.
    if (B.NativeConnection != 2) return;
    if (Scenario != "normal" && Scenario != "dual") { Complete(false, "invalid-scenario"); return; }
    if (HoldSeconds < 12 || ObservationSeconds < HoldSeconds + 10 || ObservationSeconds > 120)
    { Complete(false, "invalid-duration"); return; }
    if (!bReady && !bCompleted) LogSetupWait();
    if (B.Human == None || B.HandInventory == None || B.HandInventory.Input == None
        || B.HandInventory.Registry == None || B.HandInventory.Input.Reloads == None
        || Demo.StarterLoadout.NextDefinition < Demo.StarterLoadout.Definitions.Length) return;
    if (!bReady)
    {
        if (bCompleted) return;
        if (WorldInfo.RealTimeSeconds - SpawnedAt > 90) { Complete(false, "setup-timeout"); return; }
        if (!PrepareCase()) { StableSince = 0; return; }
        if (StableSince == 0) StableSince = WorldInfo.RealTimeSeconds;
        if (WorldInfo.RealTimeSeconds - StableSince < 1) return;
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None)
            {
                Ownership[H] = Runtimes[H].OwnershipRevision; PreviousAmmo[H] = Guns[H].AmmoCount[0];
                PreviousFlash[H] = Runtimes[H].NativeFlashCount;
            }
        Started = WorldInfo.RealTimeSeconds; bReady = true;
        if (bTraceLifecycle) B.OnReloadAudit = ObserveProductionTransition;
        `log("KF2VR_RELOAD_OBSERVER phase=ready case=" $ Scenario
            @ "preset=Advanced nativeCapability=" $ B.NativeWorldDropVersion
            @ "worldWeapons=" $ B.bWorldWeaponDrops @ "toggleGrip=" $ B.bToggleGrip
            @ "coverage=physical-entry-hold-only");
        B.NativeReplayReady = 1;
        RecordCapture("ready");
        LastPeriodicCapture = WorldInfo.RealTimeSeconds;
    }
    if (WorldInfo.RealTimeSeconds - LastPeriodicCapture >= 5)
    { LastPeriodicCapture = WorldInfo.RealTimeSeconds; RecordCapture("periodic"); }
    if (bTraceLifecycle) { GeometryInput(); TraceLifecycle(); return; }
    Reload = B.HandInventory.Input.Reloads;
    Heartbeat = WorldInfo.RealTimeSeconds - LastHeartbeat >= 0.25;
    AllHeld = true;
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] != None && !bCompleted)
        {
            Bit = 1 << H; LowerBit = H == 0 ? 1 : 8;
            if (!AdvancedReady() || !Runtimes[H].IsCurrent() || Runtimes[H].Item != Guns[H]
                || Runtimes[H].OwnershipRevision != Ownership[H] || Runtimes[H].PrimaryHand != H
                || B.HandInventory.Registry.GetPrimary(H) != Runtimes[H])
            { Complete(false, "identity-or-config-changed"); return; }
            if (Guns[H].AmmoCount[0] > PreviousAmmo[H])
            { Complete(false, "unattended-ammo-credit"); return; }
            // Count the actual primary debit in a stock firing state, including
            // autonomous burst rounds after an ordinary trigger release.
            if (PrimaryShotObserved(H, PreviousAmmo[H]))
            {
                Rounds = PreviousAmmo[H] - Guns[H].AmmoCount[0]; Shots[H] += Rounds;
                RecordCapture("shot");
                if (Scenario == "dual" && H == 1 && SawPhysical[0] != 0 && AuthorityHeld(0)) bOtherHandShot = true;
                `log("KF2VR_RELOAD_OBSERVER phase=shot case=" $ Scenario @ "hand=" $ H
                    @ "identity=" $ Guns[H].Name @ "ammo=" $ Guns[H].AmmoCount[0] @ "otherHandShot=" $ bOtherHandShot
                    @ "flashBefore=" $ PreviousFlash[H] @ "flashAfter=" $ Runtimes[H].NativeFlashCount
                    @ "rounds=" $ Rounds @ "triggerMask=" $ B.NativeTriggerMask
                    @ "shotWitness=stock-firing-state stage=" $ Guns[H].GetStateName());
            }
            if ((B.NativeButtonMask & LowerBit) != 0) Pressed[H] = 1;
            if (Pressed[H] != 0 && (PreviousButtons & LowerBit) != 0 && (B.NativeButtonMask & LowerBit) == 0) Released[H] = 1;
            if (AuthorityHeld(H) && Pressed[H] != 0 && Released[H] != 0 && SawPhysical[H] == 0)
            {
                SawPhysical[H] = 1; PhysicalSince[H] = WorldInfo.RealTimeSeconds;
                RecordCapture("physical-accepted");
                `log("KF2VR_RELOAD_OBSERVER phase=physical-accepted case=" $ Scenario @ "hand=" $ H
                    @ "identity=" $ Guns[H].Name @ "ammo=" $ Guns[H].AmmoCount[0]);
            }
            Pair = class'VRWeaponPair'.static.ForMember(Guns[H]);
            Member = Pair != None ? Pair.PhysicalMemberIndex(Guns[H]) : -1;
            if (Member >= 0 && Pair.PhysicalStatuses[Member] == 4)
            { Complete(false, "stock-paired-fallback"); return; }
            if (SawPhysical[H] != 0 && !AuthorityHeld(H)) { Complete(false, "physical-hold-ended"); return; }
            if (SawPhysical[H] == 0 || Shots[H] == 0 || WorldInfo.RealTimeSeconds - PhysicalSince[H] < HoldSeconds) AllHeld = false;
            PreviousAmmo[H] = Guns[H].AmmoCount[0];
            PreviousFlash[H] = Runtimes[H].NativeFlashCount;
        }
        Row = StateRow(H);
        if (Heartbeat || Row != LastState[H])
        {
            `log("KF2VR_RELOAD_OBSERVER phase=state case=" $ Scenario
                @ "elapsed=" $ (WorldInfo.RealTimeSeconds - Started) @ Row);
            LastState[H] = Row;
        }
    }
    PreviousButtons = B.NativeButtonMask;
    if (Heartbeat) LastHeartbeat = WorldInfo.RealTimeSeconds;
    if (!bCompleted && AllHeld && (Scenario != "dual" || bOtherHandShot)) Complete(true, "accepted-and-held-without-credit");
    if (!bCompleted && WorldInfo.RealTimeSeconds - Started > ObservationSeconds) Complete(false, "observation-timeout");
}

defaultproperties
{
    Scenario="normal"
    DualWeaponClass=class'KFWeap_Pistol_Dual9mm'
    PairMemberClass=class'VRWeap_Paired9mm'
    bExpectedKeep=true
    bExpectedLose=true
    bExpectedRecover=true
    HoldSeconds=12
    ObservationSeconds=40
    bExitOnComplete=true
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
}
