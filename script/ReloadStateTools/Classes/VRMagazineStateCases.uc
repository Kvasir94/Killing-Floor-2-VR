// Explicit offline fixture. Direct production-state tests, not headset input
// acceptance: real owned stock actors, native feed policy and cosmetic leases;
// external contact samples and authoritative receipt delivery are controlled.
class VRMagazineStateCases extends Actor;

var int Checks, Failures, InsertCalls, PouchCalls, GuideCalls, RequestCalls;
var VRHandsBridge B;
var VRMagazineFixtureReload Reload;
var VRMagazineFixtureRecovery Recovery;
var VRHandInventory FixtureInventory;
var VRDualHandInput FixtureInput;
var VRDroppedMagazines Dropped;
var array<KFWeapon> Created;
var bool bAllowGuide;
var byte ReplyStatus, ReplyAction, ReplyAccepted, ReplyRetired;
var int ReplyActual, ReplyRemaining;
var KFWeapon ReplyTarget;
var bool bCompleteTacticalReceipts;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) ++Failures;
    `log("KF2VR_RELOAD_STATE_CASE suite=magazine case=" $ Label @ "passed=" $ Passed);
}

function VRWeaponRuntime MakeWeapon(class<KFWeapon> Kind)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    // Use the stock inventory manager as the spawning actor, as its
    // CreateInventory does. Spawn inherits its Instigator before PostBeginPlay;
    // assigning it afterwards is too late for S12.InitializeAmmo.
    if (B.Human.InvManager == None || B.Human.InvManager.Instigator != B.Human)
    { Check(false, string(Kind.Name) $ "-spawn-instigator-context"); return None; }
    W = B.Human.InvManager.Spawn(Kind, B.Human);
    if (W == None) { Check(false, string(Kind.Name) $ "-spawn"); return None; }
    Created.AddItem(W);
    B.Human.InvManager.AddInventory(W, true);
    R = B.HeldInventory.RegisterItem(W);
    Check(R != None && R.IsCurrent(), string(Kind.Name) $ "-registered");
    return R;
}

function SetupReload(VRWeaponRuntime R)
{
    Reload = new(self) class'VRMagazineFixtureReload';
    Reload.Bridge = B; Reload.Runtime = R; Reload.Gun = R.Item;
    Reload.InputOwner = FixtureInput;
    Reload.Audio = new(self) class'VRReloadAudio';
    Reload.StepGate = new(self) class'VRReloadStepGate';
    Reload.StepGate.Initialize(Reload);
    FixtureInput.Reloads = Reload;
}

function TestS12(VRWeaponRuntime R)
{
    local int Order, BeforePrimary, BeforeSecondary;
    local KFWeapon W;
    W = R.Item;
    // 0 secondary paid first; 1 primary paid first; 2 unpaid primary
    // interrupted by secondary, then resumed. These are distinct contracts.
    for (Order = 0; Order < 3; ++Order)
    {
        SetupReload(R);
        W.AmmoCount[0] = 0; W.SpareAmmoCount[0] = 20;
        W.AmmoCount[1] = 0; W.SpareAmmoCount[1] = 4;
        Reload.bActive = true; Reload.bDetachedMagazineSession = true;
        if (Order > 0)
        {
            W.GotoState('Reloading');
            Check(Reload.StepGate.BeforeTimer(W, 0) == 1, "s12-primary-first-gated-" $ Order);
            if (Order == 1)
                Check(Reload.ResumeMagazineReload(), "s12-primary-first-adopt-before-payment");
            Reload.ResumeStock();
            if (Order == 1)
            {
                W.ReloadAmountLeft = 2; W.InitialReloadAmount = 2;
                W.PerformReload();
                Check(W.AmmoCount[0] == 2 && W.SpareAmmoCount[0] == 18 && W.AmmoCount[1] == 0,
                    "s12-primary-paid-before-secondary");
            }
        }
        W.GotoState('AltReloading');
        Check(!Reload.MagazineReloading(W), "s12-alt-is-not-primary-" $ Order);
        Check(Reload.StepGate.BeforeTimer(W, 0) == 0, "s12-alt-timer-independent-" $ Order);
        if (Order != 1)
            Check(!Reload.ResumeMagazineReload() && Reload.bDetachedMagazineSession,
                "s12-alt-cannot-adopt-primary-" $ Order);
        W.ReloadAmountLeft = 1; W.InitialReloadAmount = 1;
        BeforePrimary = W.AmmoCount[0];
        W.PerformReload();
        Check(W.AmmoCount[0] == BeforePrimary && W.AmmoCount[1] == 1 && W.SpareAmmoCount[1] == 3,
            "s12-secondary-stock-payment-isolated-" $ Order);
        if (Order == 1)
        {
            Check(W.AmmoCount[0] == 2 && W.SpareAmmoCount[0] == 18 && !Reload.bDetachedMagazineSession,
                "s12-primary-first-complete-feed-conservation");
            W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
            W.GotoState('Inactive');
            continue;
        }
        W.GotoState('Reloading');
        Check(Reload.StepGate.BeforeTimer(W, 0) == 1 && Reload.StepGate.BeforeTimer(W, 1) == 1,
            "s12-reentered-primary-both-timers-gated-" $ Order);
        Check(W.AmmoCount[0] == 0 && W.SpareAmmoCount[0] == 20, "s12-no-unseated-payment-" $ Order);
        Check(Reload.StepGate.BeforeTimer(W, 7) == 0, "s12-unrelated-timer-noop-" $ Order);
        Reload.bAwaitAmmo = true; Reload.bAwaitRack = true; Reload.bAmmoStepPaid = true;
        Check(Reload.ResumeMagazineReload() && !Reload.bDetachedMagazineSession,
            "s12-adopt-reentered-primary-" $ Order);
        Check(!Reload.bAwaitAmmo && !Reload.bAwaitRack && !Reload.bAmmoStepPaid,
            "s12-adoption-clears-stale-obligations-" $ Order);
        Reload.ResumeStock();
        BeforeSecondary = W.AmmoCount[1];
        W.ReloadAmountLeft = 2; W.InitialReloadAmount = 2;
        W.PerformReload();
        Check(W.AmmoCount[0] == 2 && W.SpareAmmoCount[0] == 18 && W.AmmoCount[1] == BeforeSecondary,
            "s12-primary-stock-payment-isolated-" $ Order);
        W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
        W.GotoState('Inactive');
    }
}

function TestBouncer(VRWeaponRuntime R)
{
    local VRServerMagazineReload Server;
    local int Loaded, Reserve;
    SetupReload(R);
    R.Item.AmmoCount[0] = 18; R.Item.SpareAmmoCount[0] = 36;
    R.EmptyMagazineFlags = 1;
    Server = new(self) class'VRServerMagazineReload';
    Server.Owner = Reload; Server.Bridge = B; Server.Runtime = R; Server.Gun = R.Item;
    Server.bRequested = true; Server.bBound = true; Server.bSeated = true; Server.bCommitSent = true;
    Loaded = R.Item.AmmoCount[0]; Reserve = R.Item.SpareAmmoCount[0];
    // Complete's precondition is an already accepted authority snapshot.
    // No presentation owner is needed to retire the persistent fire gate.
    Server.Complete();
    Check(!R.MagazineOut() && !R.MagazineNeedsRack(), "bouncer-authority-complete-clears-fire-gate");
    Check(!Server.Busy() && Server.Gun == None, "bouncer-completion-releases-transaction");
    Server.Update();
    Check(R.Item.AmmoCount[0] == Loaded && R.Item.SpareAmmoCount[0] == Reserve,
        "bouncer-completion-and-repeat-update-no-extra-payment");
}

function byte DeliverReceipt(int Request, out byte Action, out byte Accepted,
    out KFWeapon TargetW, out int Actual, out int Remaining, out byte Retired)
{
    Action = ReplyAction; Accepted = ReplyAccepted; TargetW = ReplyTarget;
    Actual = ReplyActual; Remaining = ReplyRemaining; Retired = ReplyRetired;
    return ReplyStatus;
}

function int SubmitReceipt(byte Action, int Hand, KFWeapon SourceW, int RemovalToken,
    KFWeapon TargetW, byte PouchSide, int ExpectedRemaining, optional VRWorldDropMagazine WorldProp)
{
    ++RequestCalls;
    return 122 + RequestCalls;
}

function bool AdmitGuide(VRMagazineRecovery Helper, int Hand, KFWeapon TargetW)
{
    ++GuideCalls;
    if (!bAllowGuide || !Helper.BeginInsertGuide(Hand, TargetW)) return false;
    Reload.bActive = true; Reload.bRecoveredMagazineSession = true;
    Reload.GunHand = 1 - Hand;
    return true;
}

function InsertConfirmed(VRWeaponRuntime TargetRuntime, int Actual, int Hand, int Serial, optional byte AmmoSlot)
{
    ++InsertCalls;
    // Same production runtime transition used before presentation in
    // RecoveredMagazineSeated. This fixture does not drive finishing visuals.
    if (bCompleteTacticalReceipts) TargetRuntime.CompleteTacticalMagazineSeat();
}
function PouchConfirmed(KFWeapon TargetW, int Actual, byte Side, int Serial, optional byte AmmoSlot)
{ ++PouchCalls; }

function SetupCarry(VRWeaponRuntime R, int Hand)
{
    SetupReload(R);
    Recovery = new(self) class'VRMagazineFixtureRecovery';
    Dropped = new(self) class'VRDroppedMagazines';
    Dropped.Bridge = B;
    Dropped.Props[0].Mesh = new(self) class'StaticMeshComponent';
    Dropped.Props[0].bLive = true; Dropped.Props[0].bLeased = true;
    Dropped.Props[0].Generation = 1; Dropped.Props[0].Rounds = 30;
    Recovery.Bridge = B; Recovery.Inventory = FixtureInventory; Recovery.Dropped = Dropped;
    Recovery.ReadAction = DeliverReceipt; Recovery.RequestAction = SubmitReceipt;
    Recovery.TryBeginInsertGuide = AdmitGuide;
    Recovery.ConfirmedInsert = InsertConfirmed; Recovery.ConfirmedPouch = PouchConfirmed;
    Recovery.bFixtureContext = true; Recovery.bFixtureDown = true; Recovery.FixturePouch = 0;
    Recovery.Carries[Hand].Pose = new(self) class'VRReloadHandPose';
    Recovery.Carries[Hand].bActive = true; Recovery.Carries[Hand].bClaimed = true;
    Recovery.Carries[Hand].Slot = 0; Recovery.Carries[Hand].Generation = 1;
    Recovery.Carries[Hand].Remaining = 30; Recovery.Carries[Hand].Token = 77;
    Recovery.Carries[Hand].Family = class'VRWeaponDropState'.static.FamilyFor(R.Item.Class);
    Recovery.Carries[Hand].SourceWeapon = R.Item;
    Recovery.Carries[Hand].Calibration = B.NativeCalibrationEpoch;
    Recovery.Carries[Hand].RoomEpoch = B.NativeRoomSpaceEpoch;
    R.MagazineFeedFlags = 7; R.Item.AmmoCount[0] = 1; R.Item.SpareAmmoCount[0] = 60;
    R.PrimaryHand = 1 - Hand;
    B.HeldInventory.LeftItem = Hand == 1 ? R : None;
    B.HeldInventory.RightItem = Hand == 0 ? R : None;
    B.HeldInventory.LeftSupport = None; B.HeldInventory.RightSupport = None;
    bAllowGuide = true; GuideCalls = 0; RequestCalls = 0;
    InsertCalls = 0; PouchCalls = 0;
    ReplyStatus = 0;
}

function TestBullpup(VRWeaponRuntime R)
{
    local int Hand, Variant;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        for (Variant = 0; Variant < 2; ++Variant)
        {
            SetupCarry(R, Hand);
            if (Variant == 1)
            {
                // Same exact actor, carried only by the opposite support grip.
                R.PrimaryHand = -1; R.SupportHand = 1 - Hand;
                B.HeldInventory.LeftItem = None; B.HeldInventory.RightItem = None;
                B.HeldInventory.LeftSupport = Hand == 1 ? R : None;
                B.HeldInventory.RightSupport = Hand == 0 ? R : None;
                Recovery.Carries[Hand].bReleaseQueued = true;
                Recovery.Carries[Hand].bPouchContactQueued = true;
                Recovery.Carries[Hand].QueuedAction = 2;
                Recovery.Carries[Hand].QueuedSide = 0;
            }
            Recovery.Update(1.0 / 120.0);
            Check(Recovery.Carries[Hand].bGuide && RequestCalls == 0,
                "bullpup-well-wins-pouch-hand" $ Hand $ "-queued" $ Variant);
            Recovery.Update(1.0 / 120.0);
            Check(Recovery.Carries[Hand].bGuide && RequestCalls == 0 && Dropped.Props[0].Rounds == 30,
                "bullpup-overlapping-guided-contact-keeps-payload-hand" $ Hand $ "-queued" $ Variant);
            Check(Recovery.RequestInsert(Hand), "bullpup-seat-submits-hand" $ Hand $ "-queued" $ Variant);
            Recovery.Poll(Hand);
            Check(Recovery.Carries[Hand].Request == 123 && Dropped.Props[0].Rounds == 30,
                "bullpup-pending-receipt-no-payment-hand" $ Hand $ "-queued" $ Variant);
            // The backend contract applies its exact stock snapshot before Poll.
            // Remove the hand binding before delivery to exercise interrupted ownership.
            R.Item.AmmoCount[0] = 31;
            B.HeldInventory.LeftItem = None; B.HeldInventory.RightItem = None;
            B.HeldInventory.LeftSupport = None; B.HeldInventory.RightSupport = None;
            ReplyStatus = 1; ReplyAction = 3; ReplyAccepted = 1;
            ReplyTarget = R.Item; ReplyActual = 30; ReplyRemaining = 0; ReplyRetired = 1;
            Recovery.Poll(Hand);
            Check(!Recovery.OwnsHand(Hand) && !Dropped.Props[0].bLive && InsertCalls == 1,
                "bullpup-accepted-receipt-retires-once-after-hand-loss-" $ Hand $ "-" $ Variant);
            Check(!R.MagazineOut() && R.Item.AmmoCount[0] == 31 && R.Item.SpareAmmoCount[0] == 60,
                "bullpup-accepted-native-feed-and-conservation-" $ Hand $ "-" $ Variant);
            Recovery.Poll(Hand);
            Check(InsertCalls == 1 && PouchCalls == 0, "bullpup-duplicate-poll-noop-" $ Hand $ "-" $ Variant);
        }
        SetupCarry(R, Hand);
        Recovery.Update(1.0 / 120.0); Recovery.RequestInsert(Hand);
        ReplyStatus = 1; ReplyAction = 3; ReplyAccepted = 0;
        ReplyTarget = R.Item; ReplyActual = 0; ReplyRemaining = 30; ReplyRetired = 0;
        Recovery.Poll(Hand);
        Check(Recovery.Carries[Hand].bRequireFresh && Dropped.Props[0].Rounds == 30
            && R.Item.AmmoCount[0] == 1 && R.MagazineOut() && InsertCalls == 0,
            "bullpup-rejected-receipt-keeps-paid-payload-" $ Hand);
        SetupCarry(R, Hand);
        bAllowGuide = false;
        Recovery.Carries[Hand].bReleaseQueued = true;
        Recovery.Carries[Hand].bPouchContactQueued = true;
        Recovery.Carries[Hand].QueuedAction = 2; Recovery.Carries[Hand].QueuedSide = 0;
        Recovery.Update(1.0 / 120.0);
        Check(!Recovery.Carries[Hand].bGuide && Recovery.Carries[Hand].Action == 2
            && RequestCalls == 1 && Dropped.Props[0].Rounds == 30,
            "bullpup-refused-guide-preserves-queued-pouch-" $ Hand);
        SetupCarry(R, Hand);
        Recovery.bFixtureDown = false; Recovery.bFixtureOpen = true;
        Recovery.Update(1.0 / 120.0);
        Check(GuideCalls == 0 && Recovery.Carries[Hand].Action == 2 && RequestCalls == 1,
            "bullpup-explicit-release-remains-pouch-" $ Hand);
    }
}

function TestRepeatedCarry(VRWeaponRuntime R, bool OpenBolt)
{
    local VRMagazineCarryRecipe Recipe;
    local StaticMesh Asset;
    local name Clip, Track;
    local float CarryAt;
    local int Cycle, Hand, StockHand, Slot, PreviousGeneration, ClaimRequest, InsertRequest;
    local int Payload, Kept, StartingTotal;
    local bool Passed;
    local string Label;
    SetupReload(R);
    Recovery = new(self) class'VRMagazineFixtureRecovery';
    Dropped = new(self) class'VRDroppedMagazines'; Dropped.Bridge = B;
    Recovery.Bridge = B; Recovery.Inventory = FixtureInventory; Recovery.Dropped = Dropped;
    Recovery.ReadAction = DeliverReceipt; Recovery.RequestAction = SubmitReceipt;
    Recovery.TryBeginInsertGuide = AdmitGuide;
    Recovery.ConfirmedInsert = InsertConfirmed; Recovery.ConfirmedPouch = PouchConfirmed;
    Recovery.bFixtureContext = true; Recovery.FixturePouch = 0;
    Recovery.Carries[0].Pose = new(self) class'VRReloadHandPose';
    Recovery.Carries[1].Pose = new(self) class'VRReloadHandPose';
    Recipe = new(self) class'VRMagazineCarryRecipe';
    Label = OpenBolt ? "tommy-repeat" : "bullpup-repeat";
    Passed = B.Arms != None && B.FreeHandPose != None && B.FreeHandPose.bReady
        && R.Item.MySkelMesh != None && R.Item.MySkelMesh.SkeletalMesh != None;
    Check(Passed, Label $ "-actual-authored-rig-ready");
    if (Passed)
    {
        Asset = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ R.Item.MySkelMesh.SkeletalMesh.Name,
            class'StaticMesh', true));
        Check(Asset != None, Label $ "-actual-ammo-mesh");
        Passed = Asset != None;
    }
    Payload = OpenBolt ? 50 : 30; Kept = OpenBolt ? 0 : 1;
    R.Item.AmmoCount[0] = Payload + Kept; R.Item.SpareAmmoCount[0] = 60;
    R.MagazineFeedFlags = 0; R.EmptyMagazineFlags = 0;
    if (!OpenBolt) R.MagazineFeedEvent(0);
    StartingTotal = R.Item.AmmoCount[0] + R.Item.SpareAmmoCount[0];
    GuideCalls = 0; RequestCalls = 0; InsertCalls = 0; PouchCalls = 0;
    bAllowGuide = true; bCompleteTacticalReceipts = true;
    for (Cycle = 0; Passed && Cycle < 3; ++Cycle)
    {
        Hand = Cycle == 1 ? 1 : 0;
        Check(!Recovery.OwnsHand(0) && !Recovery.OwnsHand(1), Label $ "-available-before-cycle" $ Cycle);
        // Exercise the release-edge observation on the same helper before the
        // next real TryGrab. Never reconstruct or clear its carry struct.
        Recovery.bFixtureDown = false; Recovery.bFixtureOpen = true;
        Recovery.Update(1.0 / 120.0);
        Check(!Recovery.TryGrab(Hand, false), Label $ "-no-grip-edge-no-acquire" $ Cycle);
        R.PrimaryHand = Cycle == 1 ? -1 : 1 - Hand;
        R.SupportHand = Cycle == 1 ? 1 - Hand : -1;
        B.HeldInventory.LeftItem = None; B.HeldInventory.RightItem = None;
        B.HeldInventory.LeftSupport = None; B.HeldInventory.RightSupport = None;
        if (Cycle == 1) B.HeldInventory.LeftSupport = R;
        else B.HeldInventory.RightItem = R;
        Passed = Recipe.Sample(B, R.Item, Clip, Track, CarryAt, StockHand);
        Check(Passed, Label $ "-authored-carry-recipe" $ Cycle);
        if (!Passed) break;
        // Controlled removal receipt: its stock snapshot precedes the same
        // native feed event used by VRMagazineRemoval.Poll. It supplies an
        // existing paid payload, never a reserve credit or extra chamber.
        R.bTacticalMagazineRemoval = OpenBolt && !R.MagazineNeedsRack();
        R.Item.AmmoCount[0] = Kept;
        if (OpenBolt) Passed = R.EmptyMagazineEvent(0);
        else Passed = R.MagazineFeedEvent(1);
        Check(Passed && R.MagazineOut(), Label $ "-native-removal" $ Cycle);
        if (!Passed) break;
        Passed = Dropped.Drop(Asset, R.Item.MySkelMesh.GetMaterial(0), None,
            B.PalmPosition(Hand), QuatFromRotator(rot(0,0,0)), vect(0,0,0), 1,
            vect(0,0,0), vect(1,1,1));
        if (Passed) Passed = Dropped.TagLastDetails(Payload, R.Item.Class, R.Item,
            800 + Cycle, Clip, Track, CarryAt, StockHand);
        Check(Passed, Label $ "-new-paid-payload" $ Cycle);
        if (!Passed) break;
        Slot = Dropped.LastSlot;
        Check(R.Item.AmmoCount[0] + R.Item.SpareAmmoCount[0] + Dropped.Props[Slot].Rounds == StartingTotal,
            Label $ "-removal-conserves-stock-and-payload" $ Cycle);
        Recovery.bFixtureDown = true; Recovery.bFixtureOpen = false;
        ReplyStatus = 0;
        Passed = Recovery.TryGrab(Hand, true);
        Check(Passed && Recovery.Carries[Hand].Request > 0, Label $ "-real-trygrab" $ Cycle);
        if (!Passed) break;
        ClaimRequest = Recovery.Carries[Hand].Request;
        Check(Recovery.Carries[Hand].Generation > PreviousGeneration
            && Recovery.Carries[Hand].Token == 800 + Cycle,
            Label $ "-fresh-token-and-lease-generation" $ Cycle);
        PreviousGeneration = Recovery.Carries[Hand].Generation;
        ReplyStatus = 1; ReplyAction = 1; ReplyAccepted = 1; ReplyTarget = None;
        ReplyActual = 0; ReplyRemaining = Payload; ReplyRetired = 0;
        Recovery.Poll(Hand);
        Check(Recovery.Carries[Hand].bClaimed && Recovery.Carries[Hand].Request == 0,
            Label $ "-claim-settles-without-ammo" $ Cycle);
        Reload.FixtureEntry = Recovery.Carries[Hand].Origin;
        Recovery.Update(1.0 / 120.0);
        Check(Recovery.Carries[Hand].bGuide && Recovery.Carries[Hand].Request == 0,
            Label $ "-same-helper-guide-admission" $ Cycle);
        Passed = Recovery.RequestInsert(Hand);
        InsertRequest = Recovery.Carries[Hand].Request;
        Check(Passed && InsertRequest > ClaimRequest, Label $ "-unique-insert-request" $ Cycle);
        if (!Passed) break;
        ReplyStatus = 0;
        Recovery.Poll(Hand);
        Check(Recovery.Carries[Hand].Request == InsertRequest && Dropped.Props[Slot].Rounds == Payload,
            Label $ "-pending-retains-lease" $ Cycle);
        R.Item.AmmoCount[0] = Payload + Kept;
        ReplyStatus = 1; ReplyAction = 3; ReplyAccepted = 1; ReplyTarget = R.Item;
        ReplyActual = Payload; ReplyRemaining = 0; ReplyRetired = 1;
        Recovery.Poll(Hand);
        Check(!Recovery.OwnsHand(Hand) && !Recovery.Carries[Hand].bGuide
            && Recovery.Carries[Hand].Request == 0 && !Dropped.Props[Slot].bLive
            && !Dropped.Props[Slot].bLeased && InsertCalls == Cycle + 1,
            Label $ "-same-helper-clears-completed-carry" $ Cycle);
        Check(!R.MagazineOut() && !R.MagazineNeedsRack()
            && R.Item.AmmoCount[0] == Payload + Kept
            && R.Item.AmmoCount[0] + R.Item.SpareAmmoCount[0] == StartingTotal,
            Label $ "-native-feed-ready-and-total-conserved" $ Cycle);
        Recovery.Poll(Hand);
        Check(InsertCalls == Cycle + 1 && PouchCalls == 0, Label $ "-duplicate-delivery-noop" $ Cycle);
    }
    Check(Cycle == 3, Label $ "-three-sequential-seats-same-helpers");
    bCompleteTacticalReceipts = false;
    // Dispose only this fixture's leases/components even after an early failure.
    Recovery.ClearLocal(0, false); Recovery.ClearLocal(1, false);
    Recovery.Carries[0].Pose.Destroy(); Recovery.Carries[1].Pose.Destroy();
    Dropped.Shutdown();
}

function VRAutomaticReload SeedAutomatic(VRWeaponRuntime R)
{
    local VRAutomaticReload A;
    A = new(R) class'VRAutomaticReload';
    R.AutomaticReload = A;
    A.Owner = Reload; A.Runtime = R; A.Gun = R.Item; A.Hand = 0;
    A.Revision = R.OwnershipRevision; A.Calibration = B.NativeCalibrationEpoch;
    A.RoomEpoch = B.NativeRoomSpaceEpoch; A.Stage = 2; A.BeganAt = Reload.Now();
    A.InitialAmmo = R.Item.AmmoCount[0];
    return A;
}

// Unlike isolated policy checks, these stock callbacks resolve through the
// actual native bridge and live registered actor. No fixture calls the new
// completion observer directly or substitutes an ammo/payment implementation.
function TestAutomaticStock(VRWeaponRuntime R, VRWeaponRuntime Other)
{
    local VRHandInventory SavedHands;
    local VRAutomaticReload A;
    local KFWeapon W;
    local int Outcome, Loaded, Reserve;
    SavedHands = B.HandInventory;
    B.HandInventory = FixtureInventory;
    FixtureInput.Bridge = B; FixtureInput.bInitialized = true;
    SetupReload(R);
    R.PrimaryHand = 0; R.SupportHand = -1;
    Other.PrimaryHand = 1; Other.SupportHand = -1;
    B.HeldInventory.LeftItem = R; B.HeldInventory.RightItem = Other;
    B.HeldInventory.LeftSupport = None; B.HeldInventory.RightSupport = None;
    Check(FixtureInput.ContextValid(), "auto-live-callback-context");
    if (!FixtureInput.ContextValid()) { B.HandInventory = SavedHands; return; }
    W = R.Item;
    for (Outcome = 0; Outcome < 5; ++Outcome)
    {
        R.PrimaryHand = 0; B.HeldInventory.LeftItem = R;
        W.GotoState('Active');
        W.AmmoCount[0] = 0; W.SpareAmmoCount[0] = 3;
        R.MagazineFeedFlags = 0; R.EmptyMagazineFlags = 0; R.AmmoRules = 1;
        R.bSlideLockPending = false;
        Check(R.MagazineFeedEvent(0) && R.MagazineFeedEvent(1) && R.MagazineOut(),
            "auto-native-empty-removal-" $ Outcome);
        A = SeedAutomatic(R);
        W.InitializeReload(); W.GotoState('Reloading');
        Check(W.IsInState('Reloading') && A.Owns(), "auto-real-stock-entered-" $ Outcome);
        W.PerformReload();
        Loaded = W.AmmoCount[0]; Reserve = W.SpareAmmoCount[0];
        Check(Loaded == 3 && Reserve == 0, "auto-stock-pays-once-" $ Outcome);
        if (Outcome == 0) W.AbortReload();
        else if (Outcome == 1) W.ReloadComplete();
        else if (Outcome == 3) W.TryPutDown();
        else
        {
            // ReleaseHand retires the role revision before Stow exits stock.
            // Mutate only this fixture actor's role, not the live hand clock.
            if (Outcome == 4)
            {
                ++R.OwnershipRevision; R.PrimaryHand = -1;
                B.HeldInventory.LeftItem = None;
            }
            W.GotoState('Inactive');
        }
        Check(!W.IsInState('Reloading') && W.ReloadStatus == RS_None,
            "auto-stock-end-clears-transient-status-" $ Outcome);
        if (Outcome == 0)
        {
            Check(A.bPaid && !A.bStockCompleted && R.AutomaticReload == None,
                "auto-native-abort-observes-payment-before-end");
            Check(!R.MagazineOut() && R.MagazineNeedsRack(), "auto-paid-abort-keeps-action-debt");
        }
        else if (Outcome == 1)
        {
            Check(A.bPaid && A.bStockCompleted && A.Owns(), "auto-native-complete-captured-before-end");
            A.Update();
            Check(!R.MagazineOut() && !R.MagazineNeedsRack() && R.AutomaticReload == None,
                "auto-completed-stock-retires-action-debt");
        }
        else
        {
            Check(A.bPaid && !A.bStockCompleted,
                "auto-payment-observed-before-direct-state-exit-" $ Outcome);
            A.Update();
            Check(!R.MagazineOut() && R.MagazineNeedsRack() && R.AutomaticReload == None,
                "auto-direct-state-exit-retains-paid-action-debt-" $ Outcome);
        }
        A.Update(); W.ReloadComplete(); A.Update();
        Check(W.AmmoCount[0] == Loaded && W.SpareAmmoCount[0] == Reserve,
            "auto-terminal-repeat-conserves-stock-ammo-" $ Outcome);
        A.Release();
    }
    R.PrimaryHand = 0; B.HeldInventory.LeftItem = R;
    // A previously completed reload leaves these counters behind. A new
    // button with no reserve must not treat them as a new magazine payment.
    W.GotoState('Active'); W.AmmoCount[0] = 0; W.SpareAmmoCount[0] = 0;
    W.InitialReloadAmount = 5; W.ReloadAmountLeft = 0;
    R.MagazineFeedFlags = 0; R.EmptyMagazineFlags = 0;
    Check(R.MagazineFeedEvent(0) && R.MagazineFeedEvent(1), "auto-stale-counter-empty-removal");
    Check(Reload.TryAutomaticReload(R, 0), "auto-dry-stock-button-consumed");
    A = R.AutomaticReload;
    Check(A != None && !W.IsInState('Reloading'), "auto-no-reserve-does-not-enter-stock");
    if (A != None)
    {
        A.BeganAt = Reload.Now() - 1;
        A.Update();
        Check(!A.bPaid && R.AutomaticReload == None && R.MagazineOut()
            && W.AmmoCount[0] == 0 && W.SpareAmmoCount[0] == 0,
            "auto-stale-counters-cannot-seat-absent-magazine");
        A.Release();
    }
    R.MechanismPending = 1;
    Check(Reload.TryAutomaticReload(R, 0) && R.AutomaticReload == None,
        "auto-rejected-button-does-not-leave-idle-owner");
    R.MechanismPending = 0;

    // Dispatch real stock one-shots after consuming their engine timer slots,
    // as the engine does. Handoff must restore both suppressed obligations.
    W.AmmoCount[0] = 0; W.SpareAmmoCount[0] = 3;
    A = SeedAutomatic(R);
    W.InitializeReload(); W.GotoState('Reloading');
    Reload.bActive = true; Reload.bDetachedMagazineSession = true; Reload.bSeated = false;
    Reload.bAmmoStepPaid = false; Reload.GunHand = 0;
    W.ClearTimer('ReloadAmmoTimer'); W.ReloadAmmoTimer();
    W.ClearTimer('ReloadStatusTimer'); W.ReloadStatusTimer();
    Check(Reload.StepGate.bDeferredMagazineAmmo && Reload.StepGate.bDeferredMagazineStatus
        && W.AmmoCount[0] == 0 && W.SpareAmmoCount[0] == 3,
        "auto-detached-stock-callbacks-record-unpaid-obligations");
    Reload.StepGate.HandBackToStock(); Reload.ResumeStock(); Reload.bActive = false;
    Check(W.IsTimerActive('ReloadAmmoTimer') && W.IsTimerActive('ReloadStatusTimer'),
        "auto-handback-rearms-consumed-one-shots");
    W.ClearTimer('ReloadAmmoTimer'); W.ReloadAmmoTimer();
    W.ClearTimer('ReloadStatusTimer'); W.ReloadStatusTimer();
    A.Update();
    Check(W.AmmoCount[0] == 3 && W.SpareAmmoCount[0] == 0 && !W.IsInState('Reloading')
        && !R.MagazineNeedsRack() && !R.MagazineOut(), "auto-rearmed-stock-completes-once");
    A.Release();
    W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer'); W.GotoState('Inactive');
    B.HandInventory = SavedHands;
}

function RunCases(VRHandsBridge InBridge)
{
    local VRWeaponRuntime S12, Bouncer, Bullpup, Tommy;
    local VRWeaponRuntime SavedLeft, SavedRight, SavedLeftSupport, SavedRightSupport;
    local bool SavedRecovery;
    local int I;
    B = InBridge;
    Check(B != None && WorldInfo.NetMode == NM_Standalone && B.Human != None
        && B.Human.Health > 0 && B.HeldInventory != None && B.HeldInventory.NativeRoutingEnabled == 1,
        "standalone-native-registry-precondition");
    if (Failures != 0) return;
    SavedLeft = B.HeldInventory.LeftItem; SavedRight = B.HeldInventory.RightItem;
    SavedLeftSupport = B.HeldInventory.LeftSupport; SavedRightSupport = B.HeldInventory.RightSupport;
    SavedRecovery = B.bRecoverMagazineAmmo; B.bRecoverMagazineAmmo = true;
    FixtureInventory = new(self) class'VRHandInventory';
    FixtureInput = new(self) class'VRDualHandInput';
    FixtureInventory.Bridge = B; FixtureInventory.Registry = B.HeldInventory; FixtureInventory.Input = FixtureInput;
    FixtureInput.Inventory = FixtureInventory;
    S12 = MakeWeapon(class'KFWeap_Shotgun_S12');
    Bouncer = MakeWeapon(class'KFWeap_HRG_BallisticBouncer');
    Bullpup = MakeWeapon(class'KFWeap_AssaultRifle_Bullpup');
    Tommy = MakeWeapon(class'KFWeap_AssaultRifle_Thompson');
    if (S12 != None) TestS12(S12);
    if (Bouncer != None) TestBouncer(Bouncer);
    if (Bullpup != None) TestBullpup(Bullpup);
    if (Bullpup != None) TestRepeatedCarry(Bullpup, false);
    if (Tommy != None) TestRepeatedCarry(Tommy, true);
    if (Bullpup != None && Tommy != None) TestAutomaticStock(Bullpup, Tommy);
    B.HeldInventory.LeftItem = SavedLeft; B.HeldInventory.RightItem = SavedRight;
    B.HeldInventory.LeftSupport = SavedLeftSupport; B.HeldInventory.RightSupport = SavedRightSupport;
    B.bRecoverMagazineAmmo = SavedRecovery;
    for (I = 0; I < Created.Length; ++I)
    {
        B.HeldInventory.NotifyRemoved(Created[I]);
        Created[I].Destroy();
    }
    `log("KF2VR_RELOAD_MAGAZINE_STATE checks=" $ Checks @ "failures=" $ Failures);
}

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
}
