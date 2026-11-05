// Real Solo authority and production pouch guide. The hand's prop pose/time
// are supplied at 120 Hz; native grip edges and headset handling are not tested.
class VRPouchMagazineStateCases extends VRMagazineStateCases;

var VRMagazinePouchReload PouchReload;
var VRWeaponRuntime TestRuntime, SavedLeft, SavedRight, SavedLeftSupport, SavedRightSupport;
var VRInteractiveReload SavedReload;
var Weapon SavedPawnWeapon;
var KFWeapon SavedMyKFWeapon;
var bool SavedRecovery, SavedInteractive, SavedLoseAmmo, bContextEntered, bFinished;
var int SavedWeaponHand, SavedLeftRevision, SavedRightRevision;
var float PreparationStarted;

function EnterFixtureContext()
{
    SavedLeft = B.HeldInventory.LeftItem; SavedRight = B.HeldInventory.RightItem;
    SavedLeftSupport = B.HeldInventory.LeftSupport; SavedRightSupport = B.HeldInventory.RightSupport;
    SavedLeftRevision = B.HeldInventory.HandRevision[0]; SavedRightRevision = B.HeldInventory.HandRevision[1];
    SavedPawnWeapon = B.Human.Weapon; SavedMyKFWeapon = B.Human.MyKFWeapon;
    SavedWeaponHand = B.WeaponHand;
    SavedReload = B.HandInventory.Input.Reloads;
    SavedRecovery = B.bRecoverMagazineAmmo; B.bRecoverMagazineAmmo = true;
    SavedInteractive = B.bInteractiveReloads; B.bInteractiveReloads = true;
    SavedLoseAmmo = B.bLoseReloadAmmo; B.bLoseReloadAmmo = true;
    if (PouchReload != None) B.HandInventory.Input.Reloads = PouchReload;
    bContextEntered = true;
}

function RestoreLiveContext()
{
    if (!bContextEntered) return;
    B.HandInventory.Input.Reloads = SavedReload;
    B.HeldInventory.LeftItem = SavedLeft; B.HeldInventory.RightItem = SavedRight;
    B.HeldInventory.LeftSupport = SavedLeftSupport; B.HeldInventory.RightSupport = SavedRightSupport;
    B.HeldInventory.HandRevision[0] = SavedLeftRevision; B.HeldInventory.HandRevision[1] = SavedRightRevision;
    B.Human.Weapon = SavedPawnWeapon; B.Human.MyKFWeapon = SavedMyKFWeapon;
    B.WeaponHand = SavedWeaponHand;
    B.HandInventory.SyncHands();
    B.bRecoverMagazineAmmo = SavedRecovery;
    B.bInteractiveReloads = SavedInteractive; B.bLoseReloadAmmo = SavedLoseAmmo;
    bContextEntered = false;
}

function bool PreparePouchWeapon(VRWeaponRuntime R)
{
    local bool Prepared;
    local KFWeapon W;
    W = R.Item;
    W.AmmoCount[0] = W.MagazineCapacity[0];
    W.SpareAmmoCount[0] = 3 * W.MagazineCapacity[0];
    B.HeldInventory.LeftItem = None; B.HeldInventory.RightItem = None;
    B.HeldInventory.LeftSupport = None; B.HeldInventory.RightSupport = None;
    Prepared = FixtureInventory.Draw(1, W);
    if (Prepared && W.IsInState('WeaponEquipping'))
    {
        W.ClearTimer('WeaponEquipped');
        W.WeaponEquipped();
    }
    Prepared = Prepared && R.bActivated && W.IsInState('Active')
        && R.Presenter != None && W.MySkelMesh != None && W.MySkelMesh.bAttached;
    Check(Prepared, "tommy-pouch-real-draw-attached");
    // Park only our runtime while the component receives a real engine frame.
    // Suspend may hide it, but does not detach it or bypass TryCapture.Ready.
    R.PrimaryHand = -1; R.SupportHand = -1;
    return Prepared;
}

function int WorldRounds(KFWeapon W)
{
    local VRWorldDropMagazine Prop;
    local int Total;
    foreach WorldInfo.AllActors(class'VRWorldDropMagazine', Prop)
        if (!Prop.bDeleteMe && Prop.SourceWeapon == W) Total += Prop.Rounds;
    return Total;
}

function TestPouchCycles(VRWeaponRuntime R)
{
    local int Cycle, Hand, Frame, BeforeReserve, BeforeAmmo, InitialTotal, BeforeWorld;
    local int PriorRequest;
    local bool Admitted, Returned;
    local KFWeapon W;
    W = R.Item;
    InitialTotal = W.AmmoCount[0] + W.SpareAmmoCount[0];
    PriorRequest = 0;
    for (Cycle = 0; Cycle < 3; ++Cycle)
    {
        Hand = Cycle == 1 ? 0 : 1;
        B.HeldInventory.LeftItem = None; B.HeldInventory.RightItem = None;
        B.HeldInventory.LeftSupport = None; B.HeldInventory.RightSupport = None;
        R.PrimaryHand = Cycle == 1 ? -1 : Hand;
        R.SupportHand = Cycle == 1 ? Hand : -1;
        if (Cycle == 1) B.HeldInventory.LeftSupport = R;
        else B.HeldInventory.RightItem = R;
        ++R.OwnershipRevision;
        R.Presenter.BindRoles();
        Check(!PouchReload.CanStartPouchReload(R), "tommy-pouch-full-noop-" $ Cycle);
        BeforeReserve = W.SpareAmmoCount[0]; BeforeAmmo = W.AmmoCount[0];
        BeforeWorld = WorldRounds(W);
        // The same production one-shot ejection ends its presentation while
        // leaving the exact removal owner alive. Do not wait stock tail timers.
        PouchReload.Begin(R, Hand, true);
        `log("KF2VR_POUCH_DIAGNOSTIC cycle=" $ Cycle @ "phase=eject" @ "state=" $ W.GetStateName()
            @ "request=" $ PouchReload.MagazineRemovals[Hand].Request
            @ "status=" $ PouchReload.MagazineRemovals[Hand].Status
            @ "ammo=" $ W.AmmoCount[0] @ "reserve=" $ W.SpareAmmoCount[0]);
        Check(PouchReload.MagazineRemovals[Hand].Request > PriorRequest,
            "tommy-pouch-unique-real-removal-" $ Cycle);
        if (PouchReload.MagazineRemovals[Hand].Request <= PriorRequest) break;
        PriorRequest = PouchReload.MagazineRemovals[Hand].Request;
        PouchReload.MagazineRemovals[Hand].Poll();
        Check(PouchReload.MagazineRemovals[Hand].Status == 2 && R.MagazineOut()
            && W.AmmoCount[0] == 0 && W.SpareAmmoCount[0] == BeforeReserve
            && WorldRounds(W) == BeforeWorld + BeforeAmmo,
            "tommy-pouch-removal-paid-world-conservation-" $ Cycle);
        if (PouchReload.MagazineRemovals[Hand].Status != 2) break;
        Admitted = PouchReload.CanStartPouchReload(R);
        Check(Admitted, "tommy-pouch-immediate-post-eject-admission-" $ Cycle);
        if (!Admitted) break;
        R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
        W.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        PouchReload.Begin(R, Hand);
        Check(PouchReload.bActive && PouchReload.Gun == W && PouchReload.NeedsAmmo(),
            "tommy-pouch-real-begin-needs-ammo-" $ Cycle);
        if (!PouchReload.bActive || !PouchReload.NeedsAmmo()) break;
        PouchReload.TakeAmmo(1 - Hand);
        Check(PouchReload.HandMode == 1 && PouchReload.CarriedPouchRounds() == W.MagazineCapacity[0]
            && W.AmmoCount[0] == 0 && W.SpareAmmoCount[0] == BeforeReserve,
            "tommy-pouch-reservation-not-debit-" $ Cycle);
        // Starting at the final seat must not acquire through the receiver.
        PouchReload.SamplePath(1);
        PouchReload.UpdateInsertion();
        Check(PouchReload.HandMode == 1 && !PouchReload.bSeated && !PouchReload.bAmmoStepPaid
            && W.SpareAmmoCount[0] == BeforeReserve,
            "tommy-pouch-seat-without-entry-noop-" $ Cycle);
        PouchReload.SamplePath(0);
        PouchReload.UpdateInsertion();
        Check(PouchReload.bGuidedInsert && PouchReload.InsertGuide.bCaptured,
            "tommy-pouch-authored-entry-captured-" $ Cycle);
        // Supply an explicit overlapping belt-contact observation. The real
        // TryReturnPouchAmmo admission still must prefer the authored well.
        PouchReload.bSampleBeltContact = true;
        Check(!PouchReload.TryReturnPouchAmmo() && PouchReload.HandMode == 1,
            "tommy-pouch-synthetic-belt-overlap-retains-entry-" $ Cycle);
        Returned = false;
        for (Frame = 1; Frame <= 120 && PouchReload.HandMode == 1; ++Frame)
        {
            PouchReload.SamplePath(float(Frame) / 120.0);
            if (PouchReload.TryReturnPouchAmmo()) { Returned = true; break; }
            PouchReload.UpdateInsertion();
        }
        PouchReload.bSampleBeltContact = false;
        Check(!Returned, "tommy-pouch-synthetic-belt-overlap-entire-authored-path-" $ Cycle);
        `log("KF2VR_POUCH_DIAGNOSTIC cycle=" $ Cycle @ "phase=insert" @ "frames=" $ Frame
            @ "state=" $ W.GetStateName() @ "hand_mode=" $ PouchReload.HandMode
            @ "seated=" $ PouchReload.bSeated @ "paid=" $ PouchReload.bAmmoStepPaid
            @ "ammo=" $ W.AmmoCount[0] @ "reserve=" $ W.SpareAmmoCount[0]);
        Check(PouchReload.bSeated && PouchReload.bAmmoStepPaid
            && W.AmmoCount[0] == W.MagazineCapacity[0]
            && W.SpareAmmoCount[0] == BeforeReserve - W.MagazineCapacity[0],
            "tommy-pouch-guide-seat-real-stock-payment-" $ Cycle);
        PouchReload.TryCompleteWithHands();
        Check(!PouchReload.bActive && W.IsInState('Active') && !R.MagazineOut()
            && !R.MagazineNeedsRack() && W.AmmoCount[0] == W.MagazineCapacity[0],
            "tommy-pouch-finishes-without-invented-chamber-or-recock-" $ Cycle);
        Check(W.AmmoCount[0] + W.SpareAmmoCount[0] + WorldRounds(W) == InitialTotal,
            "tommy-pouch-total-including-paid-world-magazines-" $ Cycle);
        if (PouchReload.bActive) break;
    }
    Check(Cycle == 3, "tommy-pouch-three-cycles-same-helper-hand-transfer");
}

function RunCases(VRHandsBridge InBridge)
{
    local bool Prepared;
    B = InBridge;
    Check(B != None && WorldInfo.NetMode == NM_Standalone && B.Human != None
        && B.HeldInventory != None && B.HandInventory != None && B.HandInventory.Input != None
        && !B.PouchAmmoPending() && !B.MagazineActionBusy(), "tommy-pouch-live-solo-context");
    if (Failures != 0) { FinishCases(); return; }
    // Isolate Draw's selection history from the player's real inventory
    // helper while retaining the actual live ownership registry/stock actor.
    FixtureInventory = new(self) class'VRHandInventory';
    FixtureInventory.Bridge = B; FixtureInventory.Registry = B.HeldInventory;
    EnterFixtureContext();
    TestRuntime = MakeWeapon(class'KFWeap_AssaultRifle_Thompson');
    if (TestRuntime != None) Prepared = PreparePouchWeapon(TestRuntime);
    RestoreLiveContext();
    if (!Prepared) { FinishCases(); return; }
    PreparationStarted = WorldInfo.RealTimeSeconds;
    SetTimer(0.05, true, 'AwaitPresentation');
}

function bool ResumeContextIdle()
{
    local VRInteractiveReload Live;
    local VRLocalTestControl Control;
    local bool Authorized;
    local int Hand;
    if (B == None || B.bDeleteMe || B.Human == None || B.Human.Health <= 0
        || B.HeldInventory == None || B.HandInventory == None || B.HandInventory.Input == None
        || !B.HandInventory.ContextValid() || TestRuntime == None || !TestRuntime.IsCurrent()
        || TestRuntime.Inventory != B.HeldInventory || TestRuntime.Item.Instigator != B.Human
        || B.NativeGripMask != 0 || B.NativeTriggerMask != 0
        || B.PouchAmmoPending() || B.MagazineActionBusy()
        || B.HandInventory.Input.HandCarrying(0) || B.HandInventory.Input.HandCarrying(1)
        || (B.HandInventory.ZedGrab != None && B.HandInventory.ZedGrab.IsHoldingAny())) return false;
    foreach WorldInfo.AllActors(class'VRLocalTestControl', Control)
        if (Control.Authorized()) { Authorized = true; break; }
    if (!Authorized) return false;
    Live = B.HandInventory.Input.Reloads;
    if (Live == None) return true;
    if (Live.bActive || Live.bIdleBound || Live.DedicatedReloadBusy()) return false;
    for (Hand = 0; Hand < 2; ++Hand)
        if ((Live.MagazineRemovals[Hand] != None && Live.MagazineRemovals[Hand].Status == 1)
            || (Live.DualCylinders[Hand] != None && Live.DualCylinders[Hand].Active())) return false;
    return true;
}

function AwaitPresentation()
{
    local VRReloadMeshPresentation P;
    local name Spare;
    local bool Ready;
    if (!ResumeContextIdle())
    { Check(false, "tommy-pouch-resume-context-idle"); FinishCases(); return; }
    P = TestRuntime.Presenter != None ? TestRuntime.Presenter.ReloadMeshPresentation : None;
    if (P != None)
    {
        // Ready's strict world-time gate is production's crash protection.
        // Never write ArmedTime/Captured/HiddenBones or invoke Capture directly.
        P.Update(TestRuntime.Presenter, TestRuntime.Item);
        Spare = class'VRReloadCatalog'.static.MagazineBone(
            class'VRReloadCatalog'.static.FindClass(TestRuntime.Item.Class), true);
        Ready = P.Captured == TestRuntime.Item && P.HiddenBones.Find(Spare) >= 0
            && TestRuntime.Item.MySkelMesh != None && TestRuntime.Item.MySkelMesh.bAttached;
    }
    if (!Ready && WorldInfo.RealTimeSeconds - PreparationStarted < 3) return;
    ClearTimer('AwaitPresentation');
    `log("KF2VR_POUCH_PREPARATION ready=" $ Ready @ "elapsed=" $ (WorldInfo.RealTimeSeconds - PreparationStarted)
        @ "presentation=" $ (P != None) @ "captured=" $ (P != None ? P.Captured : None)
        @ "spare=" $ Spare @ "hidden=" $ (P != None ? P.HiddenBones.Length : -1));
    Check(Ready, "tommy-pouch-presentation-after-real-engine-frame");
    if (Ready)
    {
        PouchReload = new(self) class'VRMagazinePouchReload';
        PouchReload.Initialize(B.HandInventory.Input);
        PouchReload.SampleTime = WorldInfo.RealTimeSeconds;
        EnterFixtureContext();
        TestPouchCycles(TestRuntime);
    }
    FinishCases();
}

function FinishCases()
{
    local VRWorldDropMagazine Prop;
    local int I;
    if (bFinished) return;
    ClearTimer('AwaitPresentation');
    // No helper exists during the asynchronous wait. Therefore a timeout or
    // new live action cannot globally abandon someone else's magazine receipt.
    // Once created, this helper runs and shuts down in one admitted call stack.
    if (PouchReload != None) { PouchReload.Shutdown(); PouchReload = None; }
    RestoreLiveContext();
    for (I = 0; I < Created.Length; ++I)
    {
        foreach WorldInfo.AllActors(class'VRWorldDropMagazine', Prop)
            if (Prop.SourceWeapon == Created[I]) Prop.Destroy();
        if (B != None && B.HeldInventory != None) B.HeldInventory.NotifyRemoved(Created[I]);
        Created[I].Destroy();
    }
    Created.Length = 0;
    bFinished = true;
    `log("KF2VR_RELOAD_POUCH_STATE checks=" $ Checks @ "failures=" $ Failures
        @ "pose=authored_120hz" @ "belt_contact=synthetic" @ "authority=real_solo"
        @ "equip_timer=controlled_stock_callback" @ "grip_edges=not_tested");
}

event Destroyed()
{
    if (!bFinished) { Check(false, "tommy-pouch-probe-destroyed-before-completion"); FinishCases(); }
    super.Destroyed();
}
