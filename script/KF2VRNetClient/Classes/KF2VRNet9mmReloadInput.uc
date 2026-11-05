// One opt-in controller choreography, with read-only production observations.
// Native turns these wrist goals into tracking samples before the normal ingress.
class KF2VRNet9mmReloadInput extends Object;

var KF2VRNetHandsBridge Bridge;
var private KF2VRNetChannel Channel;
var private KF2VRNetReloadCase CaseOwner;
var private KFWeapon Gun;
var private VRWeaponRuntime Runtime;
var private VRInteractiveReload Reload;
var private int Step;
var private float Started, At, StableAt;
var private bool bDone, bRequested;
var private vector From, Pouch, Path[17];
var private rotator FromRotation, PathRotation[17];
var private Pawn InitialSetupPawn;
var private bool bInitialDrawDone, bInitialShellClosed;
var private float NextInitialWaitLog;

// Initial fixture setup uses ordinary draw/menu ownership APIs. Once the
// measured reload begins, this helper cannot close or alter any live UI.
function PrepareInitialUI()
{
    local KF2VRNetPlayerController C;
    local VRSessionUI Session;
    local bool BeforeInput, BeforeLeft, BeforeRight, Changed;
    local int BeforeMenu, BeforeShell;
    if (Step != 0 || !bInitialDrawDone || Bridge == None || Bridge.NativeConnection != 2
        || !Bridge.bDiagnostic9mmReload || Bridge.HandInventory == None || Bridge.HandInventory.Input == None) return;
    C = KF2VRNetPlayerController(Bridge.PC);
    if (C == None || !C.IsLocalPlayerController() || C.NetChannel != Channel || Channel == None
        || !Channel.bSyntheticAllowed || !Channel.bHandshakeAccepted
        || Bridge.Human == None || Bridge.Human != C.Pawn || Bridge.Human.Health <= 0
        || Runtime == None || Runtime.Item != Gun || Bridge.HandInventory.Registry.GetPrimary(1) != Runtime) return;
    if (InitialSetupPawn == None) InitialSetupPawn = Bridge.Human;
    if (InitialSetupPawn != Bridge.Human) return;
    Bridge.RefreshMenuState();
    Session = Bridge.MenuSession();
    BeforeInput = Bridge.HandInventory.Input.ContextValid();
    BeforeMenu = Bridge.NativeMenuActive;
    BeforeShell = Session != None ? Session.NativeShellActive : -1;
    BeforeLeft = Bridge.HandInventory.Input.IsSelectorOpen(0);
    BeforeRight = Bridge.HandInventory.Input.IsSelectorOpen(1);
    if (!bInitialShellClosed && Session != None && Session.PC == C
        && Session.NativeShellActive != 0 && Session.LivingView())
    {
        Session.ToggleMenu(); bInitialShellClosed = true; Changed = true;
        Bridge.RefreshMenuState();
    }
    if (Bridge.HandInventory.Input.ContextValid())
    {
        if (BeforeLeft) { Bridge.HandInventory.Input.CloseSelector(0); Changed = true; }
        if (BeforeRight) { Bridge.HandInventory.Input.CloseSelector(1); Changed = true; }
    }
    Bridge.RefreshMenuState();
    if (Changed)
        `log("KF2VRNet reload_initial_ui input_before=" $ BeforeInput
            $ " input_after=" $ Bridge.HandInventory.Input.ContextValid()
            $ " menu_before=" $ BeforeMenu $ " menu_after=" $ Bridge.NativeMenuActive
            $ " shell_before=" $ BeforeShell $ " shell_after=" $ (Session != None ? Session.NativeShellActive : -1)
            $ " left_before=" $ BeforeLeft $ " left_after=" $ Bridge.HandInventory.Input.IsSelectorOpen(0)
            $ " right_before=" $ BeforeRight $ " right_after=" $ Bridge.HandInventory.Input.IsSelectorOpen(1)
            $ " inputWrites=False ammoWrites=False");
}

function LogInitialWait()
{
    local KF2VRNetPlayerController C;
    local VRSessionUI Session;
    if (Bridge.WorldInfo.RealTimeSeconds < NextInitialWaitLog) return;
    NextInitialWaitLog = Bridge.WorldInfo.RealTimeSeconds + 3;
    C = KF2VRNetPlayerController(Bridge.PC);
    Session = Bridge.MenuSession();
    `log("KF2VRNet reload_wait_pose input_context=" $ (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.ContextValid())
        $ " native_menu=" $ Bridge.NativeMenuActive $ " native_connection=" $ Bridge.NativeConnection
        $ " native_shell=" $ (Session != None ? Session.NativeShellActive : -1)
        $ " selector_left=" $ (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.IsSelectorOpen(0))
        $ " selector_right=" $ (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.IsSelectorOpen(1))
        $ " first_person=" $ (C != None && C.UsingFirstPersonCamera())
        $ " stock_active=" $ (C != None && C.MyGFxManager != None && C.MyGFxManager.bMenusActive)
        $ " stock_open=" $ (C != None && C.MyGFxManager != None && C.MyGFxManager.bMenusOpen)
        $ " stock_popup=" $ (C != None && C.MyGFxManager != None && C.MyGFxManager.CurrentPopup != None)
        $ " calibrated=" $ (Runtime.Presenter != None && Runtime.Presenter.bCalibrated)
        $ " presenter_ready=" $ (Runtime.Presenter != None ? Runtime.Presenter.NativeWeaponReady : -1)
        $ " pose_ready=" $ Runtime.NativePoseReady $ " native_ready=" $ Runtime.NativeReady);
}

function Report(name Phase, optional name Reason)
{
    local int ItemId, Ammo, Reserve, Capacity, Damage;
    local string TargetId;
    Ammo = -1; Reserve = -1;
    if (Gun != None) { Ammo = Gun.AmmoCount[0]; Reserve = Gun.SpareAmmoCount[0]; Capacity = Gun.MagazineCapacity[0]; }
    if (CaseOwner != None)
    {
        ItemId = CaseOwner.ItemId;
        if (CaseOwner.Target != None) { TargetId = CaseOwner.Target.DiagnosticId; Damage = CaseOwner.Target.DamageReceipts; }
    }
    `log("KF2VRNet reload_case role=owner phase=" $ Phase $ " reason=" $ Reason $ " step=" $ Step
        $ " world=" $ Channel.WorldEpoch $ " connection=" $ Channel.ConnectionEpoch
        $ " pawn=" $ Channel.PawnEpoch $ " item=" $ ItemId
        $ " hand=1 ammo=" $ Ammo $ " reserve=" $ Reserve
        $ " capacity=" $ Capacity $ " target=" $ TargetId
        $ " damage=" $ Damage $ " netmode=" $ Bridge.WorldInfo.NetMode);
}

function Fail(name Reason)
{
    Bridge.ReloadCaseTrigger = 0; Bridge.ReloadCaseButton = 0; Bridge.ReloadCaseGrip = 0;
    Bridge.ReloadCaseEnabled = -1;
    Report('failed', Reason); bDone = true;
}

function Checkpoint(int Stage, name Phase)
{
    Report(Phase); CaseOwner.ServerCheckpoint(Stage);
}

function bool CacheInsert()
{
    local int I;
    local quat Q;
    if (Reload.InsertPath.Length != 17 || !Reload.bInsertSampled || Reload.MagazineProfileIndex < 0) return false;
    // Follow the gun's authored stock part path using its measured wrist contact.
    // These are input goals only; no guide progress or reload state is assigned.
    for (I = 0; I < 17; ++I)
    {
        Q = QuatProduct(Reload.InsertQuat(Reload.InsertPath[I].Rotation), QuatInvert(Reload.CarriedAmmoInHandQ));
        Path[I] = Reload.InsertLocation(Reload.InsertPath[I].Position)
            - QuatRotateVector(Q, Reload.CarriedAmmoInHand * Reload.GunScale());
        PathRotation[I] = QuatToRotator(Q);
    }
    return true;
}

function Tick()
{
    local KF2VRNetPlayerController C;
    local KFWeapon W;
    local float Now, Alpha, Fraction;
    local int I;
    local vector Offset, HitLocation, HitNormal;
    local TraceHitInfo HitInfo;
    local Actor Hit;
    if (bDone) return;
    ++Bridge.ReloadCaseSample;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    C = KF2VRNetPlayerController(Bridge.PC);
    if (C == None || C.NetChannel == None) return;
    Channel = C.NetChannel;
    if (Started > 0 && Now - Started > 100) { Fail('timeout'); return; }
    if (Bridge.Human == None || Bridge.Human.Health <= 0)
    { if (Started > 0) Fail('pawn-unavailable'); return; }
    if (!Channel.bHandshakeAccepted || !Channel.bSyntheticAllowed || !Channel.bDiagnosticClientsReady
        || !Bridge.UsesNetworkDualWeapons() || Bridge.NativeWorldDropVersion != 9) return;
    if (Started == 0) Started = Now;
    if (Step == 0)
    {
        foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
            if (W.Class == class'KFWeap_Pistol_9mm') Gun = W;
        if (Gun == None || !Bridge.HandInventory.CanDraw(Gun)) return;
        if (Bridge.HandInventory.Registry.GetPrimary(0) != None) Bridge.HandInventory.ReleaseHand(0);
        Runtime = Bridge.HandInventory.Registry.GetPrimary(1);
        if (Runtime == None || Runtime.Item != Gun)
        { bInitialDrawDone = Bridge.HandInventory.Draw(1, Gun); return; }
        if (!bInitialDrawDone)
        { bInitialDrawDone = Bridge.HandInventory.Draw(1, Gun); return; }
        PrepareInitialUI();
        if (Runtime.Presenter == None || !Runtime.Presenter.bCalibrated || Runtime.Presenter.bReadyPoseSettling
            || Runtime.NativePoseReady != 1 || !Gun.IsInState('Active') || Channel.HeldState.RightWeapon != Gun)
        { LogInitialWait(); return; }
        if (StableAt == 0) StableAt = Now;
        if (Now - StableAt < 2) return;
        Bridge.ReloadCaseRightPosition = Bridge.RightPosition; Bridge.ReloadCaseRightRotation = Bridge.RightRotation;
        Bridge.ReloadCaseLeftPosition = Bridge.LeftPosition; Bridge.ReloadCaseLeftRotation = Bridge.LeftRotation;
        Bridge.ReloadCaseEnabled = 1;
        if (!bRequested)
        { Channel.ServerBegin9mmReloadCase(Runtime.FireLocation, Runtime.AimBaseRotation + Runtime.RecoilBuffer); bRequested = true; }
        CaseOwner = Channel.ReloadCase;
        if (CaseOwner == None || CaseOwner.Target == None || CaseOwner.Target.DiagnosticId == "" || CaseOwner.InitialAmmo <= 0) return;
        if (CaseOwner.InitialAmmo != Gun.AmmoCount[0] || CaseOwner.InitialReserve != Gun.SpareAmmoCount[0]
            || Gun.AmmoCount[0] != Gun.MagazineCapacity[0] || Gun.SpareAmmoCount[0] < Gun.MagazineCapacity[0])
        { Fail('initial-ammo'); return; }
        Hit = Gun.GetTraceOwner().Trace(HitLocation, HitNormal,
            Runtime.FireLocation + vector(Runtime.AimBaseRotation + Runtime.RecoilBuffer) * Gun.GetTraceRange(),
            Runtime.FireLocation, true, vect(0,0,0), HitInfo, Gun.TRACEFLAG_Bullet);
        if (Hit != CaseOwner.Target) return;
        Reload = Bridge.HandInventory.Input.Reloads;
        if (Reload == None || !Bridge.bInteractiveReloads || !Bridge.bKeepChamberedRound || !Bridge.bLoseReloadAmmo)
        { Fail('physical-settings'); return; }
        Report('ready'); At = Now; Step = 1;
        return;
    }
    if (CaseOwner.bFailed) { Fail('authority-failed'); return; }
    if (Channel.WorldEpoch != CaseOwner.WorldEpoch || Channel.ConnectionEpoch != CaseOwner.ConnectionEpoch
        || Channel.PawnEpoch != CaseOwner.PawnEpoch || Bridge.HandInventory.Registry.GetPrimary(1) != Runtime)
    { Fail('identity-changed'); return; }
    if (Step == 1 && Now - At >= 2)
    { Bridge.ReloadCaseTrigger = 1; At = Now; Step = 2; }
    else if (Step == 2 && Now - At >= 0.15)
    { Bridge.ReloadCaseTrigger = 0; Step = 3; }
    else if (Step == 3 && Gun.AmmoCount[0] == CaseOwner.InitialAmmo - 1 && CaseOwner.Target.DamageReceipts == 1)
    { Checkpoint(1, 'shot_before'); At = Now; Step = 4; }
    else if (Step == 4 && CaseOwner.Stage == 1 && Now - At >= 2)
    { Bridge.ReloadCaseButton = 1; At = Now; Step = 5; }
    else if (Step == 5 && Now - At >= 0.15)
    { Bridge.ReloadCaseButton = 0; Step = 6; }
    else if (Step == 6 && Reload.bActive && Reload.Gun == Gun && Reload.bAwaitAmmo
        && Runtime.MagazineOut() && Gun.AmmoCount[0] == 1)
    { Checkpoint(2, 'physical'); Step = 7; }
    else if (Step == 7 && CaseOwner.Stage == 2)
    { At = Now; Step = 8; }
    else if (Step == 8)
    {
        if (!Reload.bActive || Gun.AmmoCount[0] != 1 || Gun.SpareAmmoCount[0] != CaseOwner.InitialReserve)
        { Fail('unseated-ammo-credit'); return; }
        if (Now - At < 4) return;
        Checkpoint(3, 'held'); Step = 9;
    }
    else if (Step == 9 && CaseOwner.Stage == 3)
    {
        From = Bridge.ReloadCaseLeftPosition; FromRotation = Bridge.ReloadCaseLeftRotation;
        Offset = Bridge.NativeWristOffset; Offset.Y = -Offset.Y;
        Pouch = Reload.BeltPosition() + QuatRotateVector(QuatFromRotator(FromRotation), Offset);
        At = Now; Step = 10;
    }
    else if (Step == 10)
    {
        Bridge.ReloadCaseLeftPosition = VLerp(From, Pouch, FClamp(Now - At, 0, 1));
        if (Now - At < 1.2) return;
        Bridge.ReloadCaseGrip = 1; At = Now; Step = 11;
    }
    else if (Step == 11 && Reload.HandMode == 1)
    {
        if (!CacheInsert()) { Fail('insert-path-unavailable'); return; }
        Report('carried'); From = Bridge.ReloadCaseLeftPosition; FromRotation = Bridge.ReloadCaseLeftRotation;
        At = Now; Step = 12;
    }
    else if (Step == 12)
    {
        Alpha = FClamp(Now - At, 0, 1);
        Bridge.ReloadCaseLeftPosition = VLerp(From, Path[0], Alpha);
        Bridge.ReloadCaseLeftRotation = RLerp(FromRotation, PathRotation[0], Alpha, true);
        if (Alpha < 1) return;
        At = Now; Step = 13;
    }
    else if (Step == 13)
    {
        Fraction = FClamp((Now - At) / 0.8, 0, 1) * 16;
        I = Min(int(Fraction), 15); Alpha = Fraction - I;
        Bridge.ReloadCaseLeftPosition = VLerp(Path[I], Path[I + 1], Alpha);
        Bridge.ReloadCaseLeftRotation = RLerp(PathRotation[I], PathRotation[I + 1], Alpha, true);
        if (Fraction < 16) return;
        Bridge.ReloadCaseGrip = 0; Step = 14;
    }
    else if (Step == 14 && !Reload.bActive && Gun.IsInState('Active') && !Runtime.MagazineOut()
        && Gun.AmmoCount[0] == Gun.MagazineCapacity[0] + 1
        && Gun.SpareAmmoCount[0] == CaseOwner.InitialReserve - Gun.MagazineCapacity[0])
    { Checkpoint(4, 'reloaded'); Step = 15; }
    else if (Step == 15 && CaseOwner.Stage == 4)
    { At = Now; Step = 16; }
    else if (Step == 16 && Now - At >= 2)
    { Bridge.ReloadCaseTrigger = 1; At = Now; Step = 17; }
    else if (Step == 17 && Now - At >= 0.15)
    { Bridge.ReloadCaseTrigger = 0; Step = 18; }
    else if (Step == 18 && Gun.AmmoCount[0] == Gun.MagazineCapacity[0] && CaseOwner.Target.DamageReceipts == 2)
    { Checkpoint(5, 'shot_after'); Step = 19; }
    else if (Step == 19 && CaseOwner.Stage == 5)
    { Report('complete'); At = Now; Step = 20; }
    // Leave a neutral, valid tracked item visible for the observer's existing
    // once-per-second presentation log before withdrawing synthetic tracking.
    else if (Step == 20 && Now - At >= 3)
    { Bridge.ReloadCaseEnabled = -1; bDone = true; }
}
