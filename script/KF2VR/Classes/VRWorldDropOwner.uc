// Local binder for the physical-drop input and the existing authority ledger.
// Multiplayer never creates a local authority registry or falls back to solo.
class VRWorldDropOwner extends Object dependsOn(VRWeaponDropState);

var VRHandsBridge Bridge;
var VRHandInventory Inventory;
var VRWorldDropInput Input;
var VRWorldDropRegistry Registry;
var array<VRWorldDropPrediction> Predictions;
var private array<int> PredictedCueRequests;


var KFPawn_Human Human;
var bool bNetwork, bShutDown, bDispatching, bConfigured;
var bool ConfigEnabled, ConfigSupport, ConfigOthers, ConfigRecall;
var float ConfigDelay, LastUpdate, NextPairScan, NextReturnRetry;
var int DispatchSerial, DispatchHand;
var byte DispatchAction;
var KFWeapon DispatchWeapon, StopWeapon;
var int StopRevision;
// A release that just ended an idle reload session waits for its receipts.
var KFWeapon YieldedWeapon;
var float YieldedAt;
var KFWeapon MenuDropWeapon;
var int MenuDropHand, MenuDropCalibration, MenuDropRoom;
var float MenuDropUntil;
var KFWeapon ReplacementOld;
var int ReplacementHand;
var byte ReplacementRole;
var float ReplacementFireReadyAt;
var VRWeaponDropState.HandlingState ReplacementHandling;

struct LocalResult
{
    var int Request;
    var bool bReady, bAbandoned;
    var byte Action, Accepted, GripRole;
    var KFWeapon Weapon;
    var vector RootPosition;
    var quat RootRotation;
};
var LocalResult Results[2];

struct DropLease
{
    var KFWeapon Weapon;
    var VRWeaponPair Pair;
    var int Token;
    var bool bRetired;
};
var array<DropLease> Leases;

function VRWorldDropPrediction PredictionFor(KFWeapon W)
{
    local int I;
    for (I = 0; I < Predictions.Length; ++I)
        if (Predictions[I] != None && !Predictions[I].bDeleteMe && Predictions[I].OwnedWeapon == W) return Predictions[I];
    return None;
}

function bool PredictionOwnsHand(int Hand)
{
    local int I;
    for (I = 0; I < Predictions.Length; ++I)
        if (Predictions[I] != None && !Predictions[I].bDeleteMe && Predictions[I].bVisualHeld
            && !Predictions[I].bConfirmedAcquire && Predictions[I].VisualHand == Hand) return true;
    return false;
}

function bool SuppressesPresentation(KFWeapon W)
{
    local VRWorldDropPrediction P;
    local VRWeaponRuntime R;
    P = PredictionFor(W);
    if (P != None && !P.bConfirmedAcquire) return true;
    R = Inventory.Registry.FindItem(W);
    return R != None && R.WorldTrickPending != 0;
}

function AdjustConfirmedCatchRoot(KFWeapon W, out vector Position, out quat Q)
{
    local VRWorldDropPrediction P;
    P = PredictionFor(W);
    if (P != None && P.bConfirmedAcquire) P.AdjustConfirmedRoot(Position, Q);
}

function AbandonPrediction(KFWeapon W, int Request)
{
    local VRWorldDropPrediction P;
    PredictedCueRequests.RemoveItem(Request);
    P = PredictionFor(W);
    if (P != None && (P.ReleaseRequest == Request || P.LeaseToken == Request)) P.Destroy();
}

function ClearPredictions()
{
    local int I;
    for (I = 0; I < Predictions.Length; ++I)
        if (Predictions[I] != None && !Predictions[I].bDeleteMe) Predictions[I].Destroy();
    Predictions.Length = 0; PredictedCueRequests.Length = 0;
}

function PredictRelease(KFWeapon W, int Request, int Hand, vector At, rotator Facing, vector Linear, vector Angular)
{
    local VRWorldDropPrediction P;
    local bool RootPose;
    if (!bNetwork || Request <= 0) return;
    P = PredictionFor(W);
    if (P != None)
    {
        // A confirmed acquire may be rethrown from the stock mesh's currently
        // shown root. The queued release already captured that root exactly.
        P.Destroy();
    }
    RootPose = class'VRWorldDropGun'.static.HasRigFrame(W.Class);
    if (!RootPose) { At = Input.Actions[Hand].QueuedPalm; Facing = W.Rotation; }
    P = Bridge.Spawn(class'VRWorldDropPrediction', Bridge,, At, Facing,, true);
    if (P == None) return;
    if (!P.InitializePrediction(Bridge, W, Request, Hand, Linear, Angular, RootPose, At, QuatFromRotator(Facing))
        || !Inventory.PredictWorldRelease(W, Hand))
    { P.Destroy(); return; }
    PredictedCueRequests.AddItem(Request);
    class'VRWorldHandlingAudio'.static.Play(Bridge, W.Class, false, At, Bridge);
    Predictions.AddItem(P);
    Bridge.RegisterWorldTrick(P, 0);
}

function ObservePredictions(float Now)
{
    local VRWorldDropPrediction P;
    local int I, H;
    local vector Linear, Angular;
    if (!Input.ValidContext()) { ClearPredictions(); return; }
    for (I = Predictions.Length - 1; I >= 0; --I)
    {
        P = Predictions[I];
        if (P == None || P.bDeleteMe) { Predictions.Remove(I, 1); continue; }
        if (!Input.ValidContext()) { P.Destroy(); Predictions.Remove(I, 1); continue; }
        if (P.bConfirmedAcquire || !bNetwork) continue;
        if (P.bVisualHeld)
        {
            H = P.VisualHand;
            if (Input.Open(H) && !Input.LatchedRole(P.VisualGripRole))
            {
                Linear = QuatRotateVector(Input.Motion[H].ToWorld, Input.Motion[H].Linear);
                Angular = QuatRotateVector(Input.Motion[H].ToWorld, Input.Motion[H].Angular);
                P.ReleaseLocally(Linear, Angular);
                if (Bridge.RecordWorldDropRethrow(P) > 0)
                    class'VRWorldHandlingAudio'.static.Play(Bridge, P.OwnedWeapon.Class, false, P.RethrowPalm, Bridge);
            }
            continue;
        }
        for (H = 0; H < 2; ++H)
        {
            if (!Input.EmptyHand(H) || PredictionOwnsHand(H) || !Input.Down(H)
                || !Input.CatchWindowOpen(H, !P.bGrounded, Now)) continue;
            if (!P.CatchLocally(H)) continue;
            P.ContactRequest = Bridge.ReserveWorldDropContact(P, H);
            class'VRWorldHandlingAudio'.static.Play(Bridge, P.OwnedWeapon.Class, true, P.ContactPalm, Bridge);
            P.bCatchSoundPlayed = true;
            Input.CatchUntil[H] = 0; Input.AirCatchUntil[H] = 0;
            Input.ClaimMask = Input.ClaimMask | (1 << H);
            Bridge.QueueHandHaptic(1 << H, 0.25, 0.035);
            break;
        }
    }
}

function AdvancePredictions()
{
    // Receipt draining also runs after local pose context is lost. A paid
    // authority catch then follows the existing deferred cancellation path.
    if (bNetwork) Bridge.UpdateWorldTricks();
}

function bool Initialize(VRHandsBridge B, VRHandInventory OwnerInventory)
{
    if (B == None || B.RootBridge != None || OwnerInventory == None
        || OwnerInventory.Registry == None || B.Human == None || B.PC == None
        || OwnerInventory.Bridge != B || OwnerInventory.Registry.Human != B.Human) return false;
    Bridge = B; Inventory = OwnerInventory; Human = B.Human;
    bNetwork = B.WorldInfo.NetMode != NM_Standalone;
    if (!bNetwork)
    {
        if (B.Role != ROLE_Authority) return false;
        Registry = new(self) class'VRWorldDropRegistry';
        Registry.Initialize(B, Human);
        Registry.ReleaseHeldWeapon = ReleaseHeld;
        Registry.CatchHeldWeapon = CatchHeld;
        Registry.OnRetired = Retired;
        Registry.Handoff.PrepareReplacement = PrepareWorldReplacement;
        Registry.Handoff.FinishReplacement = FinishWorldReplacement;
    }
    Input = new(self) class'VRWorldDropInput';
    Input.Initialize(B, OwnerInventory);
    Input.RequestRelease = RequestRelease;
    Input.RequestCatch = RequestCatch;
    Input.ReadResult = ReadResult;
    Input.ApplyResult = ApplyResult;
    LastUpdate = B.WorldInfo.RealTimeSeconds;
    BindPairs();
    Configure();
    return true;
}

function bool LocalContext()
{
    return !bShutDown && Bridge != None && Inventory != None && Inventory.ContextValid()
        && Bridge.Human == Human && Inventory.Registry.Human == Human
        && Input != None && Input.ValidContext();
}

function bool Busy()
{
    return bDispatching || Results[0].bReady || Results[1].bReady || (Input != None && Input.Busy())
        || (bNetwork && Bridge != None && Bridge.WorldDropNetworkBusy());
}

function bool OwnsHand(int Hand)
{
    return (bDispatching && Hand == DispatchHand) || PredictionOwnsHand(Hand) || (Input != None && Input.OwnsHand(Hand));
}

function Configure()
{
    local bool Enabled, Support, Others, Recall;
    local float Delay;
    if (Bridge == None) return;
    Enabled = class'VRWorldWeaponPolicy'.static.Enabled()
        && !bShutDown && Bridge.bWorldWeaponDrops && Bridge.NativeWorldDropVersion == 9;
    Support = Bridge.bSupportHandCarry;
    Others = Bridge.bAllowOtherWeaponPickup;
    Recall = Bridge.bWorldDropRadialRecall;
    Delay = Bridge.WorldDropReturnPolicy == 0 ? Bridge.WorldDropReturnSeconds : -1.0;
    if (Delay != Delay) Delay = 5;
    if (Delay >= 0) Delay = FClamp(Delay, 1, 300);
    if (bNetwork && !Bridge.WorldDropNetworkAvailable()) { bConfigured = false; return; }
    if (bConfigured && ConfigEnabled == Enabled && ConfigSupport == Support
        && ConfigOthers == Others && ConfigRecall == Recall && ConfigDelay == Delay) return;
    if (bNetwork)
    {
        if (!Bridge.ConfigureWorldDrops(Enabled, Delay, Support, Others, Recall)) return;
    }
    else if (Registry != None) Registry.Configure(Enabled, Delay, Support, Others, Recall);
    else return;
    ConfigEnabled = Enabled; ConfigSupport = Support; ConfigOthers = Others;
    ConfigRecall = Recall; ConfigDelay = Delay; bConfigured = true;
}

function BindPairs()
{
    local VRWeaponPair P;
    if (bNetwork || Bridge == None || Human == None) return;
    foreach Bridge.WorldInfo.AllActors(class'VRWeaponPair', P)
        if (!P.bDeleteMe && P.Role == ROLE_Authority && P.Human == Human && P.PairState == 2)
            P.RetireWorldDrops = RetirePair;
}

function Update()
{
    local float Now, Delta;
    if (Bridge == None || Input == None) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Delta = FClamp(Now - LastUpdate, 0, 0.15); LastUpdate = Now;
    if (!bShutDown)
    {
        Configure();
        if (!bNetwork && Registry != None)
        {
            Registry.Compact();
            if (Now >= NextPairScan) { BindPairs(); NextPairScan = Now + 0.25; }
        }
    }
    else if (bNetwork) Configure();
    if (!bNetwork && Now >= NextReturnRetry)
    {
        RetryReturns();
        NextReturnRetry = Now + 0.1;
    }
    if (Input.Actions[0].QueuedWeapon != StopWeapon && Input.Actions[1].QueuedWeapon != StopWeapon)
    { StopWeapon = None; StopRevision = 0; }
    if (MenuDropWeapon != None)
    {
        if (Now > MenuDropUntil || Bridge.NativeHeadTracked == 0
            || Bridge.NativeCalibrationEpoch != MenuDropCalibration || Bridge.NativeRoomSpaceEpoch != MenuDropRoom)
            MenuDropWeapon = None;
        else if (LocalContext() && !Busy())
        {
            if (Inventory.GetHeldForHand(MenuDropHand) != None
                && Inventory.GetHeldForHand(MenuDropHand).Item == MenuDropWeapon
                && Input.QueueRelease(Inventory.GetHeldForHand(MenuDropHand), MenuDropHand, Now))
            {
                Input.Actions[MenuDropHand].bQueuedExplicit = true;
                // A menu drop falls from the held frame; pointing at the UI
                // is not a physical throwing gesture.
                Input.Actions[MenuDropHand].QueuedLinear = vect(0,0,0); Input.Actions[MenuDropHand].QueuedAngular = vect(0,0,0);
            }
            MenuDropWeapon = None;
        }
    }
    // Shutdown still drains submitted authority replies. It cannot grant a
    // new input action because VRWorldDropInput.Shutdown invalidates context.
    Input.Update(Delta);
    AdvancePredictions();
}

function bool ActionSessionBusy(KFWeapon W)
{
    local VRDualHandInput Controls;
    Controls = Inventory.Input;
    if (Controls == None) return true;
    if (Controls.Reloads != None)
    {
        if (Controls.Reloads.RevolverRounds != None
            && Controls.Reloads.RevolverRounds.PendingWeapon(W)) return true;
        if ((Controls.Reloads.bActive && Controls.Reloads.Gun == W)
            || Controls.Reloads.CylinderAuthorityGun == W || Controls.Reloads.DualCylinderOwns(W)) return true;
        if (Controls.Reloads.Mechanism != None && Controls.Reloads.Mechanism.BlocksFire(W)) return true;
        if (Controls.Reloads.Vampire != None && Controls.Reloads.Vampire.BlocksFire(W)) return true;
        if (Controls.Reloads.ServerMagazine != None && Controls.Reloads.ServerMagazine.BlocksFire(W)) return true;
        if (Controls.Reloads.Brawlers != None && Controls.Reloads.Brawlers.BlocksFire(W)) return true;
        if (Controls.Reloads.Secondary != None && Controls.Reloads.Secondary.BlocksFire(W)) return true;
    }
    if (Controls.Bow != None && ((Controls.Bow.Gun == W && Controls.Bow.Phase != 0
            && Controls.Bow.Phase != class'VRCompoundBowInput'.const.Nocked) || Controls.Bow.PendingGun == W
        || Controls.Bow.AwaitEmptyGun == W)) return true;
    return (Controls.InputState[0].StockReloadWeapon == W || Controls.InputState[1].StockReloadWeapon == W);
}

// Ordinary StopFire allows charged/refiring stock states to settle themselves.
// Never PutDownWeapon, AbortReload or force a state exit to make a drop ready.
function bool PrepareRelease(KFWeapon W, int Hand)
{
    local VRWeaponRuntime R;
    if (!LocalContext() || W == None || W.bDeleteMe || Hand < 0 || Hand > 1) return false;
    R = Inventory.Registry.FindItem(W);
    if (R == None || !R.IsCurrent() || R.WorldDropped != 0 || R.MechanismPending != 0
        || Inventory.GetHeldForHand(Hand) != R) return false;
    // Letting go ends a reload that is only waiting for ammunition, as a stow
    // does; the magazine-out state stays on the runtime (spec 3.8).
    if (Inventory.Input != None && Inventory.Input.Reloads != None
        && Inventory.Input.Reloads.YieldIdleSession(W, "world-release"))
    { YieldedWeapon = W; YieldedAt = Bridge.WorldInfo.RealTimeSeconds; }
    if (ActionSessionBusy(W)) return false;
    if (StopWeapon != W || StopRevision != R.OwnershipRevision)
    {
        Inventory.Input.CancelSprint();
        W.StopFire(0); W.StopFire(1);
        StopWeapon = W; StopRevision = R.OwnershipRevision;
    }
    R.FlushMagazineShot();
    if (Inventory.Input.Reloads != None)
    {
        if (Inventory.Input.Reloads.Pump != None && Inventory.Input.Reloads.Pump.Gun == W)
            Inventory.Input.Reloads.Pump.SavePersistentState();
        if (Inventory.Input.Reloads.ManualAction != None && Inventory.Input.Reloads.ManualAction.Gun == W)
            Inventory.Input.Reloads.ManualAction.SavePersistentState();
    }
    return R.PendingFireMask == 0 && class'VRWorldDropGun'.static.ReleaseActionReady(W);
}

// The yielded reload's cancel receipt may still be settling; its release
// keeps retrying instead of falling back to a stow.
function bool ReleaseSettling(KFWeapon W)
{
    return W != None && W == YieldedWeapon && Bridge != None
        && Bridge.WorldInfo.RealTimeSeconds - YieldedAt < 2.0;
}

function int RequestRelease(KFWeapon W, int Hand, vector At, rotator Facing, vector Linear, vector Angular)
{
    local int Token;
    local VRWorldDropGun Prop;
    local bool bWeaponRootPose;
    local vector ReleasePalm;
    local VRWeaponDropState.HandlingState Snapshot;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()
        || bDispatching || Input.HandPending(Hand) || !PrepareRelease(W, Hand)) return 0;
    if (!class'VRWeaponDropState'.static.Capture(Inventory.Registry.FindItem(W), Snapshot)) return 0;
    if (bNetwork)
    {
        Token = Bridge.WorldDropNetworkAvailable() ? Bridge.SendWorldDropRelease(W, Hand, At, Facing, Linear, Angular) : 0;
        if (Token > 0) PredictRelease(W, Token, Hand, At, Facing, Linear, Angular);
        return Token;
    }
    if (Registry == None || !Registry.bEnabled) return 0;
    ReleasePalm = Bridge.PalmPosition(Hand);
    if (Input.Actions[Hand].QueuedWeapon == W && Input.Actions[Hand].QueuedHand == Hand) ReleasePalm = Input.Actions[Hand].QueuedPalm;
    bWeaponRootPose = class'VRWorldDropGun'.static.HasRigFrame(W.Class);
    if (!bWeaponRootPose)
    {
        // Stock DropFrom spawns with the weapon actor's rotation. Other
        // first-person-to-pickup mesh transforms have not been audited.
        At = ReleasePalm; Facing = W.Rotation;
    }
    Token = Bridge.AllocateWeaponActionSerial();
    if (Token <= 0) return 0;
    bDispatching = true; DispatchSerial = Token; DispatchWeapon = W; DispatchHand = Hand; DispatchAction = 0;
    Prop = Registry.Release(W, Hand, At, Facing, Linear, Angular, bWeaponRootPose, ReleasePalm, Snapshot);
    if (Prop != None && PredictionFor(W) != None) PredictionFor(W).Destroy();
    StoreResult(Hand, Token, 0, byte(Prop != None), W, 0, At, QuatFromRotator(Facing));
    bDispatching = false; DispatchWeapon = None; DispatchSerial = 0;
    return Token;
}

function bool ReleaseHeld(KFWeapon W, int Hand)
{
    local DropLease Lease;
    if (bNetwork || !bDispatching || DispatchAction != 0 || W != DispatchWeapon
        || Hand != DispatchHand || DispatchSerial <= 0 || !PrepareRelease(W, Hand)) return false;
    if (!Inventory.ReleaseForWorld(W, Hand, DispatchSerial)) return false;
    Lease.Weapon = W; Lease.Token = DispatchSerial;
    Lease.Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Lease.Pair != None && Lease.Pair.Human == Human) Lease.Pair.RetireWorldDrops = RetirePair;
    Leases.AddItem(Lease);
    return true;
}

function bool IncomingCatchActionsReady(Actor Target)
{
    local KFWeapon W;
    if (Inventory == None || Inventory.Input == None || Human == None || Human.InvManager == None) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (ActionSessionBusy(W) && class'VRWorldPickupFootprint'.static.TouchesWeapon(Target, W)) return false;
    return true;
}

function int RequestCatch(Actor Target, int Hand)
{
    local int Token;
    local byte Role;
    local bool Accepted;
    local KFWeapon W, Caught;
    local vector Position;
    local quat Q;
    local VRWeaponDropState.HandlingState Handling;
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    local VRWorldDropGun Prop;
    local VRStockWorldPickup Stock;
    local VRVampireReload Vampire;
    local VRWorldDropPrediction Prediction;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()
        || bDispatching || !LocalContext() || Hand < 0 || Hand > 1 || Target == None
        || Input.HandPending(Hand) || Inventory.DeferredCatch[Hand].Weapon != None || !Input.EmptyHand(Hand)) return 0;
    if (Inventory.Input != None && Inventory.Input.Reloads != None) Vampire = Inventory.Input.Reloads.Vampire;
    // A physical Vampire reload reserves its opposite hand even between strokes.
    if (Vampire != None && Vampire.bRequested && !Vampire.bStockRequested) return 0;
    Prop = VRWorldDropGun(Target);
    if ((Prop != None && !Prop.CanPickupBy(Human))
        || (Prop == None && !class'VRStockWorldPickup'.static.IsPickup(Target))) return 0;
    if ((Prop == None || Prop.DropOwner != Human) && !IncomingCatchActionsReady(Target)) return 0;
    if (bNetwork)
    {
        Token = Bridge.WorldDropNetworkAvailable() ? Bridge.SendWorldDropCatch(Target, Hand) : 0;
        if (Token > 0 && Prop != None && !Prop.bDeleteMe && Prop.DropOwner == Human && PredictionFor(Prop.OwnedWeapon) == None)
        {
            Prediction = Bridge.Spawn(class'VRWorldDropPrediction', Bridge,, Prop.Location, Prop.Rotation,, true);
            if (Prediction != None)
            {
                if (Prediction.InitializeCatch(Bridge, Prop, Hand, Token))
                {
                    Predictions.AddItem(Prediction); PredictedCueRequests.AddItem(Token);
                    Bridge.RegisterWorldTrick(Prediction, 1);
                    class'VRWorldHandlingAudio'.static.Play(Bridge, Prop.OwnedWeapon.Class, true, Bridge.PalmPosition(Hand), Bridge);
                    Prediction.bCatchSoundPlayed = true;
                    Bridge.QueueHandHaptic(1 << Hand, 0.25, 0.035);
                }
                else Prediction.Destroy();
            }
        }
        return Token;
    }
    if (Registry == None || !Registry.bEnabled) return 0;
    Token = Bridge.AllocateWeaponActionSerial();
    if (Token <= 0) return 0;
    if (Prop != None) { W = Prop.OwnedWeapon; Handling = Prop.Handling; }
    if (Prop != None && Prop.DropOwner == Human && PredictionFor(W) == None)
    {
        Prediction = Bridge.Spawn(class'VRWorldDropPrediction', Bridge,, Prop.Location, Prop.Rotation,, true);
        if (Prediction != None)
        {
            if (Prediction.InitializeCatch(Bridge, Prop, Hand, Token)) Predictions.AddItem(Prediction);
            else { Prediction.Destroy(); Prediction = None; }
        }
    }
    bDispatching = true; DispatchSerial = Token; DispatchWeapon = W; DispatchHand = Hand; DispatchAction = 1;
    if (Prop != None)
        Accepted = Registry.Catch(Prop, Human, Hand, Bridge.PalmPosition(Hand), Role, Position, Q, Caught);
    else
    {
        Stock = new(self) class'VRStockWorldPickup';
        Caught = Stock.Catch(Target, Human, Bridge.PalmPosition(Hand), Hand);
        Accepted = Caught != None;
        Q = QuatFromRotator(rot(0,0,0));
        if (Accepted) Handling.Family = class'VRWeaponDropState'.static.FamilyFor(Caught.Class);
    }
    if (Accepted)
    {
        W = Caught;
        class'VRWeaponDropState'.static.MatchTransferredFamily(W, Handling);
        R = Inventory.Registry.RegisterItem(W);
        if (R != None) class'VRWeaponDropState'.static.ApplyToRuntime(R, Handling,
            Bridge.bInteractiveReloads, Bridge.bInteractiveReloads || Bridge.bFreeWeaponCycling);
        Pair = class'VRWeaponPair'.static.ForMember(W);
        if (Pair != None && ((Handling.FeedFlags & 2) != 0 || (Handling.EmptyMagazineFlags & 1) != 0))
            Pair.AdoptPhysicalMagazineWell(W, W.AmmoCount[0]);
    }
    StoreResult(Hand, Token, 1, byte(Accepted), W, Role, Position, Q);
    bDispatching = false; DispatchWeapon = None; DispatchSerial = 0;
    return Token;
}

function bool CatchHeld(KFPawn_Human Catcher, KFWeapon W, int Hand, byte Role, vector Position, quat Q)
{
    return !bNetwork && bDispatching && DispatchAction == 1 && W == DispatchWeapon
        && Hand == DispatchHand && Catcher == Human && LocalContext()
        && Inventory.CatchFromWorld(W, Hand, Role, Position, Q);
}

function bool PrepareWorldReplacement(KFWeapon W)
{
    local VRWeaponRuntime R;
    ReplacementOld = None;
    ReplacementHand = -1;
    if (!LocalContext() || W == None
        || (Busy() && !(bDispatching && DispatchAction == 1 && DispatchWeapon != W))) return false;
    R = Inventory.Registry.FindItem(W);
    if (R == None || ActionSessionBusy(W) || !class'VRWeaponDropState'.static.Capture(R, ReplacementHandling)) return false;
    ReplacementOld = W;
    ReplacementHand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    ReplacementRole = byte(R.CarryPrimaryHand >= 0);
    ReplacementFireReadyAt = R.WorldDropFireReadyAt;
    return true;
}

function FinishWorldReplacement(KFWeapon OldWeapon, KFWeapon NewWeapon)
{
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    if (OldWeapon != ReplacementOld) return;
    ReplacementOld = None;
    if (NewWeapon == None || Inventory == None || Inventory.Registry == None) return;
    R = Inventory.Registry.RegisterItem(NewWeapon);
    if (R == None) return;
    class'VRWeaponDropState'.static.ApplyToRuntime(R, ReplacementHandling,
        Bridge.bInteractiveReloads, Bridge.bInteractiveReloads || Bridge.bFreeWeaponCycling);
    Pair = class'VRWeaponPair'.static.ForMember(NewWeapon);
    if (Pair != None && ((ReplacementHandling.FeedFlags & 2) != 0 || (ReplacementHandling.EmptyMagazineFlags & 1) != 0))
        Pair.AdoptPhysicalMagazineWell(NewWeapon, NewWeapon.AmmoCount[0]);
    R.WorldDropFireReadyAt = ReplacementFireReadyAt;
    R.WorldDropped = int(Registry != None && Registry.IsDropped(NewWeapon));
    if (ReplacementHand >= 0)
        Inventory.ApplyWorldDropResult(NewWeapon, ReplacementHand, 1, 1, ReplacementRole, vect(0,0,0), QuatFromRotator(rot(0,0,0)));
}

function StoreResult(int Hand, int Token, byte Action, byte Accepted, KFWeapon W, byte Role, vector Position, quat Q)
{
    Results[Hand].Request = Token; Results[Hand].Action = Action; Results[Hand].Accepted = Accepted; Results[Hand].Weapon = W;
    Results[Hand].GripRole = Role; Results[Hand].RootPosition = Position; Results[Hand].RootRotation = Q;
    Results[Hand].bReady = true; Results[Hand].bAbandoned = false;
}

function byte ReadResult(int Request, out byte Action, out byte Accepted,
    out KFWeapon W, out byte Role, out vector Position, out quat Q)
{
    local int Hand;
    if (bNetwork) return Bridge.ReadWorldDropResult(Request, Action, Accepted, W, Role, Position, Q);
    Hand = Results[0].Request == Request ? 0 : 1;
    if (!Results[Hand].bReady || Request != Results[Hand].Request) return 2;
    Results[Hand].bReady = false;
    if (Results[Hand].bAbandoned || Results[Hand].Weapon == None || Results[Hand].Weapon.bDeleteMe
        || Bridge.Human != Human) return 2;
    Action = Results[Hand].Action; Accepted = Results[Hand].Accepted; W = Results[Hand].Weapon;
    Role = Results[Hand].GripRole; Position = Results[Hand].RootPosition; Q = Results[Hand].RootRotation;
    return 1;
}

function ApplyResult(KFWeapon W, int Hand, byte Action, byte Accepted, byte Role, vector Position, quat Q)
{
    local int Request;
    local VRWorldDropPrediction P;
    local VRWeaponRuntime Held;
    local bool bCue;
    // This bookkeeping is mandatory even with lost tracking/menu context.
    // The inventory method reads context before binding/activating catch poses.
    // Network ReadWorldDropResult has already adopted the authority snapshot.
    Request = Input != None ? Input.Actions[Hand].PendingRequest : 0;
    bCue = Accepted != 0 && W != None && Input != None && Input.bResultContextValid
        && PredictedCueRequests.Find(Request) == INDEX_NONE;
    PredictedCueRequests.RemoveItem(Request);
    P = PredictionFor(W);
    if (Action == 1 && P != None && P.bCatchSoundPlayed) bCue = false;
    if (bNetwork && Bridge.ResolveWorldTrickEntry(W, Request, Accepted != 0))
    {
        // Authority progress may already describe a later catch/release. The
        // entry receipt retires its lane only; final settlement binds the hand.
        if (Action == 0 && Accepted == 0 && Inventory != None)
            Inventory.ReconcileNetworkHands(true);
        return;
    }
    if (!bNetwork && P != None && Action == 1 && Accepted != 0)
    {
        if (P.GetVisualRoot(Position, Q)) P.BeginConfirmedAcquire();
    }
    if (Inventory != None) Inventory.ApplyWorldDropResult(W, Hand, Action, Accepted, Role, Position, Q);
    if (bCue && Inventory != None)
    {
        Held = Inventory.GetHeldForHand(Hand);
        if (Action == 0 || (Action == 1 && Held != None && Held.Item == W
            && Inventory.DeferredCatch[Hand].Weapon != W))
        {
            class'VRWorldHandlingAudio'.static.Play(Bridge, W.Class, Action == 1, Bridge.PalmPosition(Hand), Bridge);
            if (Action == 1 && P != None) P.bCatchSoundPlayed = true;
        }
    }
    if (P != None && !P.bConfirmedAcquire) P.Destroy();
}

// Called only after the exact settlement weapon marker and matching event.
// The cosmetic acquire shares the real presenter's root, so firing can resume
// on receipt while muzzle, sights and the shown gun follow the same motion.
function bool ApplyTrickSettlement(VRWorldDropPrediction P, KFWeapon W, int Hand, byte Role,
    vector Position, quat Q, int Token, bool bRecovery)
{
    local VRWeaponRuntime R;
    local bool Hold, Valid;
    if (Inventory == None || Input == None || Hand > 1) return false;
    R = Inventory.Registry.FindItem(W);
    if (R == None || R.WorldTrickPending != Token) return false;
    if (Hand < 0)
    {
        if (!bRecovery) return false;
        R.WorldTrickPending = 0; R.WorldDropped = 0;
        if (P != None && !P.bDeleteMe) { P.RememberCaughtRelease(); P.Destroy(); }
        Inventory.ReconcileNetworkHands(true);
        return true;
    }
    Valid = LocalContext() && Inventory.CatchPoseContextValid(Hand);
    Hold = Valid && (Input.Down(Hand) || Input.LatchedRole(Role))
        && (P == None || (!P.bDeleteMe && P.bVisualHeld && P.VisualHand == Hand));
    if (Hold && P != None)
    {
        P.GetVisualRoot(Position, Q);
        if (!P.BeginConfirmedAcquire()) { P.RememberCaughtRelease(); P.Destroy(); P = None; }
    }
    Input.bApplying = true; Input.ApplyingHand = Hand;
    Input.bResultContextValid = Valid; Input.bResultGripHeld = Hold;
    R.WorldDropped = 0;
    Inventory.ApplyWorldDropResult(W, Hand, 1, 1, Role, Position, Q);
    Input.bApplying = false; Input.ApplyingHand = -1;
    Bridge.Hands[Hand].bTriggerArmed = false; Bridge.Hands[Hand].bTrigger = false;
    if (Inventory.DeferredCatch[Hand].Weapon == W)
    {
        // Context loss retires the paid held reservation through its ordinary
        // acknowledgement path, instead of inventing a catch pose later.
        Inventory.DeferredCatch[Hand].bCancel = !Valid;
        Inventory.DeferredCatch[Hand].bRelease = Valid && !Hold;
        R.WorldTrickPending = 0;
        if (P != None && !P.bDeleteMe) P.Destroy();
        return true;
    }
    if (Inventory.GetHeldForHand(Hand) != R) return false;
    if (Hold)
    {
        R.WorldTrickPending = 0;
        Input.ArmCaughtWeapon(W, Hand);
        if (P != None) P.RememberCaughtRelease();
        return true;
    }
    // Recovery can arrive after an open/rethrow. Keep its gate and invisible
    // stock copy until a fresh explicit release has entered the normal lane.
    if (!Valid) return false;
    if (!Input.QueueRecoveredRelease(R, Hand, P)) return false;
    Input.SubmitQueue(Hand, Bridge.WorldInfo.RealTimeSeconds);
    return Input.HandPending(Hand);
}

function ClearFence(KFWeapon W)
{
    local int I;
    local VRWeaponRuntime R;
    if (Inventory == None || Inventory.Registry == None) return;
    // FindItem deliberately requires live input ownership. Retirement also
    // runs during death/removal, before those references are torn down.
    for (I = 0; I < Inventory.Registry.Items.Length; ++I)
    {
        R = Inventory.Registry.Items[I];
        if (R != None && R.Inventory == Inventory.Registry && R.Item == W) R.WorldDropped = 0;
    }
}

function bool ReturnLease(int I)
{
    local VRWeaponPair P;
    local KFWeapon W;
    local int Member;
    if (I < 0 || I >= Leases.Length) return true;
    P = Leases[I].Pair; W = Leases[I].Weapon;
    if (P == None || P.bDeleteMe || P.PairState != 2) return true;
    if (P.Human != Human || W == None) return false;
    Member = P.Members[0] == W ? 0 : (P.Members[1] == W ? 1 : -1);
    if (Member < 0 || P.WorldDropToken[Member] != Leases[I].Token) return true;
    return P.ReturnWorldRelease(W, Leases[I].Token);
}

function RetryReturns()
{
    local int I;
    for (I = Leases.Length - 1; I >= 0; --I)
        if (Leases[I].bRetired && ReturnLease(I)) Leases.Remove(I, 1);
}

function Retired(KFWeapon W, byte Reason)
{
    local int I;
    if (bNetwork) return;
    ClearFence(W);
    for (I = Leases.Length - 1; I >= 0; --I)
        if (Leases[I].Weapon == W)
        {
            Leases[I].bRetired = true;
            if (ReturnLease(I)) Leases.Remove(I, 1);
        }
}

function bool RetirePair(VRWeaponPair P)
{
    local int I, Token;
    local KFWeapon W;
    if (bNetwork || P == None || P.bDeleteMe || P.Human != Human || P.Role != ROLE_Authority) return false;
    for (I = 0; I < 2; ++I)
    {
        W = P.Members[I];
        if (Registry != None)
        {
            Registry.InvalidateWeapon(W);
            // An in-flight catch may defer invalidation. Do not restore a
            // pair while its physical identity remains registered.
            if (Registry.GunIdentities.Find(W) >= 0) return false;
        }
        ClearFence(W);
        Token = P.WorldDropToken[I];
        // The prop may already have vanished/retired. The pair's outstanding
        // exact member token still authorizes returning that escrow once.
        if (Token > 0 && !P.ReturnWorldRelease(W, Token)) return false;
    }
    RetryReturns();
    return P.WorldDropToken[0] == 0 && P.WorldDropToken[1] == 0;
}

function InvalidateWeapon(KFWeapon W)
{
    local int I;
    if (W == None) return;
    if (PredictionFor(W) != None) PredictionFor(W).Destroy();
    if (Input != None)
    {
        for (I = 0; I < 2; ++I)
        {
            if (Input.Actions[I].QueuedWeapon == W) Input.ClearQueue(I);
            if (Input.Actions[I].PendingWeapon == W) Input.Actions[I].bPendingContextLost = true;
            if (Input.Held[I].Runtime != None && Input.Held[I].Runtime.Item == W)
            { Input.Held[I].Runtime = None; Input.Held[I].ArmedHands = 0; }
        }
    }
    if (StopWeapon == W) StopWeapon = None;
    if (!bNetwork)
    {
        if (Registry != None) Registry.InvalidateWeapon(W);
        for (I = 0; I < 2; ++I) if (Results[I].bReady && Results[I].Weapon == W) Results[I].bAbandoned = true;
    }
    // Network fence retirement and terminal pending replies belong to root's
    // authority/result path; never clear a predicted fence from this callback.
}

function bool QueueMenuDrop(KFWeapon W, int Hand)
{
    if (!class'VRWorldWeaponPolicy'.static.Enabled()
        || bShutDown || Busy() || Bridge == None || !Bridge.bWorldWeaponDrops
        || Inventory == None || !Inventory.ContextValid() || Hand < 0 || Hand > 1
        || Inventory.GetHeldForHand(Hand) == None || Inventory.GetHeldForHand(Hand).Item != W) return false;
    MenuDropWeapon = W; MenuDropHand = Hand;
    MenuDropCalibration = Bridge.NativeCalibrationEpoch; MenuDropRoom = Bridge.NativeRoomSpaceEpoch;
    MenuDropUntil = Bridge.WorldInfo.RealTimeSeconds + 0.75;
    return true;
}

function bool TryRecall(KFWeapon W)
{
    if (!class'VRWorldWeaponPolicy'.static.Enabled()
        || Busy() || !LocalContext() || W == None || !Bridge.bWorldDropRadialRecall) return false;
    Configure();
    if (bNetwork) return Bridge.WorldDropNetworkAvailable() && Bridge.IsWorldDropRegistered(W)
        && Bridge.RecallWorldDrop(W);
    return Registry != None && Registry.TryRecall(W);
}

function Shutdown()
{
    if (bShutDown) return;
    bShutDown = true;
    ClearPredictions();
    if (Input != None) Input.Shutdown();
    if (!bNetwork && Registry != None) { Registry.Shutdown(); RetryReturns(); }
    else Configure();
    // Caller must retain/drain this owner until Busy becomes false (or its
    // network lifecycle explicitly abandons the transport before destruction).
}
