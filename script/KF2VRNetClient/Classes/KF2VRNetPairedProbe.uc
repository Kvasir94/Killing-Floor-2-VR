// Short, real owning-client regression: 1858 and 9mm only. Production conversion,
// selector draws, trigger edges, reload buttons and server ammunition stay intact.
class KF2VRNetPairedProbe extends Object;

var KF2VRNetHandsBridge Bridge;
var int Step, Index, LeftAmmo, RightAmmo, Rounds;
var float NextAction, Deadline, NextStallLog;
var bool bFinished;
var VRWeaponPair Pair;
var KF2VRNetPlayerController PC;

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
        $ ":pose=" $ R.NativePoseReady
        $ ":active=" $ (R.Item != None && R.Item.IsInState('Active'));
}

function LogStall(string Reason)
{
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
        `log("KF2VRNet paired_wait_pose index=" $ Index
            $ " left=" $ RuntimeReadiness(Bridge.HandInventory.Registry.GetPrimary(0))
            $ " right=" $ RuntimeReadiness(Bridge.HandInventory.Registry.GetPrimary(1))
            $ " held_left=" $ PC.NetChannel.HeldState.LeftWeapon
            $ " held_right=" $ PC.NetChannel.HeldState.RightWeapon);
}

// Exercise real camera registration/removal without causing gameplay damage.
// Each case has a fresh capture object so one lens cannot satisfy the other.
function bool CheckLensSignals(VRSessionUI S, class<EmitterCameraLensEffectBase> BloodClass,
    class<EmitterCameraLensEffectBase> PukeClass)
{
    local VRComfortEffects E;
    local bool bPassed, bWasVisible;
    if (PC.PlayerCamera == None) return false;
    if (PC.GameplayPostProcessEffects != None) bWasVisible = PC.GameplayPostProcessEffects.bShowInGame;
    PC.PlayerCamera.AddCameraLensEffect(BloodClass);
    PC.PlayerCamera.AddCameraLensEffect(PukeClass);
    E = new(self) class'VRComfortEffects';
    E.BeginFrame(S);
    bPassed = S.NativeBloodFX == 0 && S.NativePukeFX == 0 && S.NativeDamageFX == 0
        && PC.PainEffectTimeRemaining == 0 && PC.BloatPukeEffectTimeRemaining == 0
        && PC.PlayerCamera.FindCameraLensEffect(BloodClass) == None
        && PC.PlayerCamera.FindCameraLensEffect(PukeClass) == None;
    E.EndFrame();
    return bPassed && (PC.GameplayPostProcessEffects == None || PC.GameplayPostProcessEffects.bShowInGame == bWasVisible);
}

function CheckSharedPresentation()
{
    local VRGameViewportClient V;
    local VRSessionUI S;
    local VRComfortEffects E;
    local VRChestGrenade G;
    local float Pain, Puke, Heal, Flash, Siren;
    local bool bPassed, bWasVisible;
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
    PC.PlayerCamera.AddCameraLensEffect(class'KFCameraLensEmit_EMP');
    E = new(self) class'VRComfortEffects';
    E.BeginFrame(S);
    bPassed = S.NativeDamageFX == 0.5 && S.NativePukeFX == 0 && S.NativeHealFX == 0.5 && S.NativeFlashFX == 0.5
        && S.NativeBloodFX == 0 && S.NativeEnergyFX == 0
        && PC.SirenScreamEffectTimeRemaining == 0.5
        && PC.PlayerCamera.FindCameraLensEffect(class'KFCameraLensEmit_EMP') == None
        && PC.BloatPukeEffectTimeRemaining == 0.5
        && PC.PainEffectTimeRemaining == 0.5 && Bridge.Human.Health == Health && Bridge.Human.Armor == Armor;
    E.EndFrame();
    bPassed = bPassed && (PC.GameplayPostProcessEffects == None || PC.GameplayPostProcessEffects.bShowInGame == bWasVisible);
    PC.PainEffectTimeRemaining = 0; PC.BloatPukeEffectTimeRemaining = 0;
    bPassed = CheckLensSignals(S, class'KFCameraLensEmit_BloodBase', class'KFCameraLensEmit_Puke') && bPassed;
    bPassed = CheckLensSignals(S, class'KFCameraLensEmit_BloodGorge', class'KFCameraLensEmit_Puke_Light') && bPassed;
    bPassed = bPassed && Bridge.Human.Health == Health && Bridge.Human.Armor == Armor;
    PC.PainEffectTimeRemaining = Pain; PC.BloatPukeEffectTimeRemaining = Puke;
    PC.HealEffectTimeRemaining = Heal; PC.FlashBangEffectTimeRemaining = Flash;
    PC.SirenScreamEffectTimeRemaining = Siren;
    // Drop the probe's captured lens lifetimes before restoring live signals.
    E = new(self) class'VRComfortEffects';
    E.BeginFrame(S); E.EndFrame();
    `log("KF2VRNet playable_contract phase=comfort_signals passed=" $ bPassed $ " netmode=" $ Bridge.WorldInfo.NetMode);
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
    if (PC == None || !PC.NetChannel.HeldState.bIndependentWeapons) return;
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
        Step = 2; return;
    }
    if (Step == 2)
    {
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
