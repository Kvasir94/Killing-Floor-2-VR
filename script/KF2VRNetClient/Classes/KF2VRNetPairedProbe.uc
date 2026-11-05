// Short, real owning-client regression: 1858 and 9mm only. Production conversion,
// selector draws, trigger edges, reload buttons and server ammunition stay intact.
class KF2VRNetPairedProbe extends Object;

var KF2VRNetHandsBridge Bridge;
var int Step, Index, LeftAmmo, RightAmmo, Rounds;
var float NextAction, Deadline, NextStallLog;
var bool bFinished;
var VRWeaponPair Pair;
var KF2VRNetPlayerController PC;
var private Pawn InitialSetupPawn;
var private bool bInitialShellClosed;

// This fixture declares a direct inventory draw, so it also owns initial UI
// dismissal normally supplied by the player's wheel/menu input. End only that
// setup reservation, before any measured trigger or reload is authored.
function PrepareInitialUI()
{
    local VRSessionUI Session;
    local bool BeforeInput, BeforeLeft, BeforeRight, Changed;
    local int BeforeMenu, BeforeShell;
    if (Step != 1 && Step != 2 || Bridge == None || Bridge.NativeConnection != 2
        || PC == None || !PC.IsLocalPlayerController() || !PC.bDiagnosticPairedWeapons
        || PC.NetChannel == None || !PC.NetChannel.bSyntheticAllowed || !PC.NetChannel.bHandshakeAccepted
        || Bridge.PC != PC || Bridge.Human == None || Bridge.Human != PC.Pawn
        || Bridge.Human.Health <= 0 || Bridge.HandInventory == None || Bridge.HandInventory.Input == None) return;
    if (InitialSetupPawn == None) InitialSetupPawn = Bridge.Human;
    if (InitialSetupPawn != Bridge.Human) return;
    Bridge.RefreshMenuState();
    Session = Bridge.MenuSession();
    BeforeInput = Bridge.HandInventory.Input.ContextValid();
    BeforeMenu = Bridge.NativeMenuActive;
    BeforeShell = Session != None ? Session.NativeShellActive : -1;
    BeforeLeft = Bridge.HandInventory.Input.IsSelectorOpen(0);
    BeforeRight = Bridge.HandInventory.Input.IsSelectorOpen(1);
    if (!bInitialShellClosed && Session != None && Session.PC == PC
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
        `log("KF2VRNet paired_initial_ui index=" $ Index $ " input_before=" $ BeforeInput
            $ " input_after=" $ Bridge.HandInventory.Input.ContextValid()
            $ " menu_before=" $ BeforeMenu $ " menu_after=" $ Bridge.NativeMenuActive
            $ " shell_before=" $ BeforeShell $ " shell_after=" $ (Session != None ? Session.NativeShellActive : -1)
            $ " left_before=" $ BeforeLeft $ " left_after=" $ Bridge.HandInventory.Input.IsSelectorOpen(0)
            $ " right_before=" $ BeforeRight $ " right_after=" $ Bridge.HandInventory.Input.IsSelectorOpen(1)
            $ " inputWrites=False ammoWrites=False");
}

function Report(string Phase, bool bPassed)
{
    `log("KF2VRNet paired_case index=" $ Index $ " phase=" $ Phase $ " passed=" $ bPassed
        $ " connection=" $ PC.NetChannel.ConnectionEpoch $ " netmode=" $ Bridge.WorldInfo.NetMode);
    if (Pair != None && Phase != "restore" && Phase != "timeout")
        PC.ServerObservePairedCase(Phase, Pair.Members[1].AmmoCount[0], Pair.Members[0].AmmoCount[0], Pair.SharedReserve());
}

function string MemberReadiness(KFWeapon W)
{
    if (W == None) return "none";
    return string(W) $ ":owned=" $ Bridge.HandInventory.Registry.IsOwned(W)
        $ ":member=" $ (Pair != None && Pair.IsMember(W))
        $ ":content=" $ W.WeaponContentLoaded $ ":mesh=" $ (W.MySkelMesh != None)
        $ ":supported=" $ Bridge.Supported(W) $ ":draw=" $ Bridge.HandInventory.CanDraw(W)
        $ ":state=" $ W.GetStateName();
}

function string RuntimeReadiness(VRWeaponRuntime R)
{
    if (R == None) return "none";
    return string(R.Item) $ ":presenter=" $ R.Presenter
        $ ":calibrated=" $ (R.Presenter != None && R.Presenter.bCalibrated)
        $ ":presenter_ready=" $ (R.Presenter != None ? R.Presenter.NativeWeaponReady : -1)
        $ ":native_ready=" $ R.NativeReady
        $ ":pose=" $ R.NativePoseReady
        $ ":active=" $ (R.Item != None && R.Item.IsInState('Active'));
}

function LogStall(string Reason)
{
    local VRSessionUI Session;
    if (Bridge.WorldInfo.RealTimeSeconds < NextStallLog) return;
    NextStallLog = Bridge.WorldInfo.RealTimeSeconds + 3;
    `log("KF2VRNet paired_wait index=" $ Index $ " step=" $ Step $ " reason=" $ Reason
        $ " server_index=" $ PC.DiagnosticPairedIndex $ " pair=" $ PC.DiagnosticPair
        $ " pair_state=" $ (Pair != None ? Pair.PairState : -1)
        $ " context=" $ Bridge.HandInventory.ContextValid()
        $ " left=" $ MemberReadiness(Pair != None ? Pair.Members[1] : None)
        $ " right=" $ MemberReadiness(Pair != None ? Pair.Members[0] : None)
        $ " connection=" $ PC.NetChannel.ConnectionEpoch $ " netmode=" $ Bridge.WorldInfo.NetMode);
    if (Step == 2)
    {
        Session = Bridge.MenuSession();
        `log("KF2VRNet paired_wait_pose index=" $ Index
            $ " left=" $ RuntimeReadiness(Bridge.HandInventory.Registry.GetPrimary(0))
            $ " right=" $ RuntimeReadiness(Bridge.HandInventory.Registry.GetPrimary(1))
            $ " held_left=" $ PC.NetChannel.HeldState.LeftWeapon
            $ " held_right=" $ PC.NetChannel.HeldState.RightWeapon
            $ " input_context=" $ (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.ContextValid())
            $ " native_menu=" $ Bridge.NativeMenuActive $ " native_connection=" $ Bridge.NativeConnection
            $ " native_shell=" $ (Session != None ? Session.NativeShellActive : -1)
            $ " selector_left=" $ (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.IsSelectorOpen(0))
            $ " selector_right=" $ (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.IsSelectorOpen(1))
            $ " first_person=" $ PC.UsingFirstPersonCamera()
            $ " stock_active=" $ (PC.MyGFxManager != None && PC.MyGFxManager.bMenusActive)
            $ " stock_open=" $ (PC.MyGFxManager != None && PC.MyGFxManager.bMenusOpen)
            $ " stock_popup=" $ (PC.MyGFxManager != None && PC.MyGFxManager.CurrentPopup != None));
    }
}

function bool CustomChannelsInert(VRSessionUI S)
{
    return S.NativeFireFX == 0 && S.NativePukeFX == 0 && S.NativeBloodFX == 0
        && S.NativeDamageFX == 0 && S.NativeHealFX == 0 && S.NativeEnergyFX == 0
        && S.NativeRageFX == 0 && S.NativeNightVision == 0 && S.NativeFlashFX == 0;
}

// Custom status overlays were retired; stock lenses must remain registered.
// Do not retrigger or destroy a preexisting effect. Clean up only our own lens.
function bool CheckLensSignal(VRSessionUI S, class<EmitterCameraLensEffectBase> LensClass)
{
    local VRComfortEffects E;
    local EmitterCameraLensEffectBase Existing, Lens;
    local bool bPreserved, bCleaned, bWasVisible, bPostProcess;
    if (PC.PlayerCamera == None) return false;
    if (PC.GameplayPostProcessEffects != None) bWasVisible = PC.GameplayPostProcessEffects.bShowInGame;
    Existing = PC.PlayerCamera.FindCameraLensEffect(LensClass);
    if (Existing == None) PC.PlayerCamera.AddCameraLensEffect(LensClass);
    Lens = PC.PlayerCamera.FindCameraLensEffect(LensClass);
    E = new(self) class'VRComfortEffects';
    E.BeginFrame(S);
    bPreserved = Lens != None && !Lens.bDeleteMe && CustomChannelsInert(S)
        && PC.PlayerCamera.FindCameraLensEffect(LensClass) == Lens;
    E.EndFrame();
    bPreserved = bPreserved && Lens != None && !Lens.bDeleteMe
        && PC.PlayerCamera.FindCameraLensEffect(LensClass) == Lens;
    bPostProcess = PC.GameplayPostProcessEffects == None || PC.GameplayPostProcessEffects.bShowInGame == bWasVisible;
    if (Existing == None && Lens != None && !Lens.bDeleteMe) Lens.Destroy();
    bCleaned = PC.PlayerCamera.FindCameraLensEffect(LensClass) == Existing;
    `log("KF2VRNet comfort_lens class=" $ LensClass @ "preserved=" $ bPreserved
        @ "postprocess=" $ bPostProcess @ "cleanup=" $ bCleaned);
    return bPreserved && bPostProcess && bCleaned;
}

function CheckSharedPresentation()
{
    local VRGameViewportClient V;
    local VRSessionUI S;
    local VRComfortEffects E;
    local VRChestGrenade G;
    local float Pain, Puke, Heal, Flash, Siren;
    local bool bPassed, bWasVisible, bChannels, bTimers, bPostProcess, bVitals;
    local bool bEMP, bBlood, bPuke, bGorge, bLightPuke;
    local int Health, Armor;
    V = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    if (V == None || V.VRSession == None || PC.PlayerCamera == None) return;
    S = V.VRSession;
    bPassed = S.LocalContext() && S.SnapTurnDegrees >= 15 && S.SmoothTurnScale >= 0.1
        && S.EyeRenderPercent >= 50 && S.EyeRenderPercent <= 100 && Bridge.bIndependentHands;
    `log("KF2VRNet playable_contract phase=settings passed=" $ bPassed $ " netmode=" $ Bridge.WorldInfo.NetMode);
    Pain = PC.PainEffectTimeRemaining; Puke = PC.BloatPukeEffectTimeRemaining;
    Heal = PC.HealEffectTimeRemaining; Flash = PC.FlashBangEffectTimeRemaining;
    Siren = PC.SirenScreamEffectTimeRemaining;
    Health = Bridge.Human.Health; Armor = Bridge.Human.Armor;
    if (PC.GameplayPostProcessEffects != None) bWasVisible = PC.GameplayPostProcessEffects.bShowInGame;
    PC.PainEffectTimeRemaining = 0.5; PC.BloatPukeEffectTimeRemaining = 0.5;
    PC.HealEffectTimeRemaining = 0.5; PC.FlashBangEffectTimeRemaining = 0.5;
    PC.SirenScreamEffectTimeRemaining = 0.5;
    // Seed every retired channel so an inert bridge must actively clear it.
    S.NativeFireFX = 0.5; S.NativePukeFX = 0.5; S.NativeBloodFX = 0.5;
    S.NativeDamageFX = 0.5; S.NativeHealFX = 0.5; S.NativeEnergyFX = 0.5;
    S.NativeRageFX = 0.5; S.NativeNightVision = 1; S.NativeFlashFX = 0.5;
    E = new(self) class'VRComfortEffects';
    E.BeginFrame(S);
    bChannels = CustomChannelsInert(S);
    E.EndFrame();
    bChannels = bChannels && CustomChannelsInert(S);
    bEMP = CheckLensSignal(S, class'KFCameraLensEmit_EMP');
    bBlood = CheckLensSignal(S, class'KFCameraLensEmit_BloodBase');
    bPuke = CheckLensSignal(S, class'KFCameraLensEmit_Puke');
    bGorge = CheckLensSignal(S, class'KFCameraLensEmit_BloodGorge');
    bLightPuke = CheckLensSignal(S, class'KFCameraLensEmit_Puke_Light');
    bTimers = PC.PainEffectTimeRemaining == 0.5 && PC.BloatPukeEffectTimeRemaining == 0.5
        && PC.HealEffectTimeRemaining == 0.5 && PC.FlashBangEffectTimeRemaining == 0.5
        && PC.SirenScreamEffectTimeRemaining == 0.5;
    bPostProcess = PC.GameplayPostProcessEffects == None || PC.GameplayPostProcessEffects.bShowInGame == bWasVisible;
    bVitals = Bridge.Human.Health == Health && Bridge.Human.Armor == Armor;
    bPassed = bChannels && bTimers && bPostProcess && bVitals && bEMP && bBlood && bPuke && bGorge && bLightPuke;
    PC.PainEffectTimeRemaining = Pain; PC.BloatPukeEffectTimeRemaining = Puke;
    PC.HealEffectTimeRemaining = Heal; PC.FlashBangEffectTimeRemaining = Flash;
    PC.SirenScreamEffectTimeRemaining = Siren;
    `log("KF2VRNet playable_contract phase=comfort_signals passed=" $ bPassed $ " netmode=" $ Bridge.WorldInfo.NetMode
        @ "channels=" $ bChannels @ "timers=" $ bTimers @ "postprocess=" $ bPostProcess @ "vitals=" $ bVitals
        @ "emp=" $ bEMP @ "blood=" $ bBlood @ "puke=" $ bPuke @ "gorge=" $ bGorge @ "light_puke=" $ bLightPuke);
    G = Bridge.HandInventory.Input.Grenade;
    bPassed = G != None && Bridge.HeadPosition.Z - G.ChestPosition().Z > 20
        && VSize(G.ChestPosition() - Bridge.HeadPosition) > 25;
    `log("KF2VRNet playable_contract phase=chest_anchor passed=" $ bPassed $ " netmode=" $ Bridge.WorldInfo.NetMode);
}

function Tick()
{
    local VRWeaponRuntime L, R;
    local float Now;
    if (bFinished || Bridge.Human == None || Bridge.HandInventory == None || Bridge.NativeConnection != 2) return;
    PC = KF2VRNetPlayerController(Bridge.PC);
    if (PC == None || PC.NetChannel == None || !PC.NetChannel.HeldState.bIndependentWeapons) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (Deadline == 0) Deadline = Now + 90;
    if (Now > Deadline)
    {
        Bridge.DiagnosticDualTriggers = 0; Bridge.DiagnosticDualButtons = 0;
        Report("timeout", false); bFinished = true; return;
    }
    if (Step == 0)
    {
        Bridge.DiagnosticDualTriggers = 0; Bridge.DiagnosticDualButtons = 0;
        if (Index == 0) CheckSharedPresentation();
        PC.ServerBeginPairedCase(Index); Step = 1; return;
    }
    if (Step == 1)
    {
        Pair = PC.DiagnosticPair;
        if (PC.DiagnosticPairedIndex != Index || Pair == None || Pair.PairState != 2
            || !Pair.IsMember(Pair.Members[0]) || !Pair.IsMember(Pair.Members[1]))
        { LogStall("pair_membership"); return; }
        if (!Bridge.HandInventory.CanDraw(Pair.Members[0]) || !Bridge.HandInventory.CanDraw(Pair.Members[1]))
        { LogStall("drawable"); return; }
        if (!Bridge.HandInventory.Draw(1, Pair.Members[0]) || !Bridge.HandInventory.Draw(0, Pair.Members[1]))
        { LogStall("draw"); return; }
        PrepareInitialUI();
        Step = 2; return;
    }
    if (Step == 2)
    {
        PrepareInitialUI();
        L = Bridge.HandInventory.Registry.GetPrimary(0); R = Bridge.HandInventory.Registry.GetPrimary(1);
        if (L == None || R == None || L.Item != Pair.Members[1] || R.Item != Pair.Members[0]
            || L.Presenter == None || R.Presenter == None || !L.Presenter.bCalibrated || !R.Presenter.bCalibrated
            || L.NativePoseReady != 1 || R.NativePoseReady != 1
            || !L.Item.IsInState('Active') || !R.Item.IsInState('Active')
            || PC.NetChannel.HeldState.LeftWeapon != L.Item || PC.NetChannel.HeldState.RightWeapon != R.Item)
        { LogStall("ready"); return; }
        Report("ready", !L.Item.bHidden && !R.Item.bHidden && L.Item.MySkelMesh.bAttached && R.Item.MySkelMesh.bAttached
            && VSize(L.FireLocation - R.FireLocation) > 10);
        LeftAmmo = Pair.Members[1].AmmoCount[0]; RightAmmo = Pair.Members[0].AmmoCount[0];
        Bridge.DiagnosticDualTriggers = 1; NextAction = Now + 0.15; Step = 3; return;
    }
    if (Now < NextAction) return;
    if (Step == 3) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 4)
    {
        Report("left_fire", Pair.Members[1].AmmoCount[0] < LeftAmmo && Pair.Members[0].AmmoCount[0] == RightAmmo);
        LeftAmmo = Pair.Members[1].AmmoCount[0]; RightAmmo = Pair.Members[0].AmmoCount[0];
        Bridge.DiagnosticDualTriggers = 2; NextAction = Now + 0.15;
    }
    else if (Step == 5) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 6)
    {
        Report("right_fire", Pair.Members[0].AmmoCount[0] < RightAmmo && Pair.Members[1].AmmoCount[0] == LeftAmmo);
        LeftAmmo = Pair.Members[1].AmmoCount[0]; RightAmmo = Pair.Members[0].AmmoCount[0]; Rounds = Pair.TotalRounds();
        Bridge.DiagnosticDualButtons = 9; NextAction = Now + 0.15;
    }
    else if (Step == 7) { Bridge.DiagnosticDualButtons = 0; NextAction = Now + 5; }
    else if (Step == 8)
    {
        Report("reload", Pair.Members[1].AmmoCount[0] > LeftAmmo && Pair.Members[0].AmmoCount[0] > RightAmmo && Pair.TotalRounds() == Rounds);
        PC.ServerFinishPairedCase(); NextAction = Now + 0.5;
    }
    else if (Step == 9)
    {
        if (PC.DiagnosticPairRestored != Index) return;
        Report("restore", Pair == None || Pair.bDeleteMe || Pair.PairState == 3);
        Pair = None; ++Index;
        if (Index == 2) { bFinished = true; return; }
        Step = 0; return;
    }
    ++Step;
}
