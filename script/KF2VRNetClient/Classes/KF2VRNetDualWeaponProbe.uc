// Drives the existing hand input code with recorded buttons, using two actual
// owned weapons. It does not grant ammo or replace firing/reload behavior.
class KF2VRNetDualWeaponProbe extends Object;

var KF2VRNetHandsBridge Bridge;
var private KFWeapon Left, Right;
var private int Step, LeftAmmo, RightAmmo;
var private float NextAction, Deadline;
var private bool bFinished;
var private KFWeapon TradeWeapon;
var private int TradeIndex;
var private float TradeDosh;

function bool TargetRayValid(VRWeaponRuntime Item, KF2VRNetDiagnosticClot Target)
{
    local vector HitLocation, HitNormal;
    local TraceHitInfo HitInfo;
    local Actor Hit;
    Target.ForceUpdateComponents(true, false);
    Hit = Item.Item.GetTraceOwner().Trace(HitLocation, HitNormal,
        Item.FireLocation + vector(Item.AimBaseRotation + Item.RecoilBuffer) * Item.Item.GetTraceRange(),
        Item.FireLocation, true, vect(0,0,0), HitInfo, Item.Item.TRACEFLAG_Bullet);
    `log("KF2VRNet dual_target_ray target=" $ Target.DiagnosticId $ " hit=" $ Hit
        $ " origin=" $ Item.FireLocation $ " aim=" $ (Item.AimBaseRotation + Item.RecoilBuffer)
        $ " location=" $ Target.Location $ " netmode=" $ Bridge.WorldInfo.NetMode);
    return Hit == Target;
}

function Report(string Phase, bool Passed)
{
    local KF2VRNetChannel Channel;
    Channel = KF2VRNetPlayerController(Bridge.PC).NetChannel;
    `log("KF2VRNet dual_weapon phase=" $ Phase $ " passed=" $ Passed
        $ " world=" $ Channel.WorldEpoch $ " connection=" $ Channel.ConnectionEpoch
        $ " pawn=" $ Channel.PawnEpoch $ " left_ammo=" $ Left.AmmoCount[0]
        $ " right_ammo=" $ Right.AmmoCount[0] $ " left_state=" $ Left.GetStateName()
        $ " right_state=" $ Right.GetStateName() $ " netmode=" $ Bridge.WorldInfo.NetMode);
    if (Phase != "draw") Channel.ServerObserveDualWeapons(Phase, Left.AmmoCount[0], Right.AmmoCount[0]);
}

function Tick()
{
    local KFWeapon W;
    local VRWeaponRuntime L, R;
    local KF2VRNetChannel Channel;
    local float Now;
    local KF2VRNetDiagnosticClot Target, LeftTarget, RightTarget;
    local string TargetPrefix;
    if (bFinished || Bridge.Human == None || Bridge.Human.Health <= 0) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Channel = KF2VRNetPlayerController(Bridge.PC).NetChannel;
    if (Deadline == 0) Deadline = Now + 50;
    if (Now > Deadline)
    {
        Bridge.DiagnosticDualTriggers = 0;
        Bridge.DiagnosticDualButtons = 0;
        Report("timeout_" $ Step, false);
        bFinished = true;
        return;
    }
    if (Step >= 18) { TickTrader(Now); return; }
    if (Step == 0)
    {
        Bridge.DiagnosticDualTriggers = 0;
        foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        {
            if (W.IsA('KFWeap_Pistol_9mm')) Left = W;
            if (W.IsA('KFWeap_Shotgun_MB500')) Right = W;
        }
        if (Left == None || Right == None) return;
        if (!Left.WeaponContentLoaded) Left.Class.static.TriggerAsyncContentLoad(Left.Class);
        if (!Right.WeaponContentLoaded) Right.Class.static.TriggerAsyncContentLoad(Right.Class);
        if (!Bridge.HandInventory.CanDraw(Left) || !Bridge.HandInventory.CanDraw(Right)) return;
        // Exercise normal spawn adoption before the explicit second draw; a
        // scripted draw of both guns used to hide an empty-hands startup race.
        R = Bridge.HandInventory.Registry.GetPrimary(Clamp(Bridge.PreferredWeaponHand, 0, 1));
        if (!Bridge.HandInventory.bPredictNetworkHands || R == None) return;
        if (!Bridge.HandInventory.Draw(1, Right) || !Bridge.HandInventory.Draw(0, Left)) return;
        Report("draw", Bridge.HandInventory.Registry.GetPrimary(0).Item == Left
            && Bridge.HandInventory.Registry.GetPrimary(1).Item == Right);
        Step = 1;
        return;
    }
    if (Step == 1)
    {
        Bridge.DiagnosticDualTriggers = 0;
        L = Bridge.HandInventory.Registry.GetPrimary(0);
        R = Bridge.HandInventory.Registry.GetPrimary(1);
        if (L == None || R == None || L.Presenter == None || R.Presenter == None
            || !L.Presenter.bCalibrated || !R.Presenter.bCalibrated
            || L.Presenter.bReadyPoseSettling || R.Presenter.bReadyPoseSettling
            || L.Presenter.NativeWeaponReady == 0 || R.Presenter.NativeWeaponReady == 0
            || !Left.IsInState('Active') || !Right.IsInState('Active')
            || Channel.HeldState.LeftWeapon != Left || Channel.HeldState.RightWeapon != Right) return;
        Report("rapid_replace", Left.IsInState('Active') && Right.IsInState('Active')
            && Channel.HeldState.LeftWeapon == Left && Channel.HeldState.RightWeapon == Right);
        // Targets follow the fixed, separated test rays once. Subsequent input
        // never tracks a target, so a wrong hand's origin/aim misses its target.
        Channel.ServerSpawnDualTargets(L.FireLocation, L.AimBaseRotation + L.RecoilBuffer,
            R.FireLocation, R.AimBaseRotation + R.RecoilBuffer);
        NextAction = Now + 0.5;
        Step = 2;
        return;
    }
    if (Step == 2)
    {
        Bridge.DiagnosticDualTriggers = 0;
        if (Now < NextAction) return;
        TargetPrefix = "w" $ Channel.WorldEpoch $ "-c" $ Channel.ConnectionEpoch $ "-p" $ Channel.PawnEpoch;
        foreach Bridge.WorldInfo.AllPawns(class'KF2VRNetDiagnosticClot', Target)
        {
            if (Target.DiagnosticId == (TargetPrefix $ "-left")) LeftTarget = Target;
            if (Target.DiagnosticId == (TargetPrefix $ "-right")) RightTarget = Target;
        }
        // A target RPC is not proof that either replicated target exists yet.
        if (LeftTarget == None || RightTarget == None) return;
        L = Bridge.HandInventory.Registry.GetPrimary(0);
        R = Bridge.HandInventory.Registry.GetPrimary(1);
        if (L == None || R == None) return;
        if (!TargetRayValid(L, LeftTarget) || !TargetRayValid(R, RightTarget))
        {
            // Replicated identity may precede the stock mesh/physics asset's
            // readiness. Keep input released until both real traces hit;
            // the existing fixture deadline still rejects a blocked ray.
            NextAction = Now + 0.25;
            return;
        }
        Report("ready", !Left.bHidden && !Right.bHidden && L.NativePoseReady == 1 && R.NativePoseReady == 1
            && VSize(L.FireLocation - R.FireLocation) > 10);
        Bridge.ReplayCapture = 862;
        LeftAmmo = Left.AmmoCount[0]; RightAmmo = Right.AmmoCount[0];
        // Input stayed released throughout drawing; press on this ready frame.
        Bridge.DiagnosticDualTriggers = 1;
        NextAction = Now + 0.15;
        Step = 3;
        return;
    }
    if (Now < NextAction) return;
    if (Step == 3) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 4)
    {
        Report("fresh_trigger", Left.AmmoCount[0] < LeftAmmo && Right.AmmoCount[0] == RightAmmo);
        LeftAmmo = Left.AmmoCount[0]; RightAmmo = Right.AmmoCount[0];
        Bridge.DiagnosticDualTriggers = 2; NextAction = Now + 0.15;
    }
    else if (Step == 5) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 6)
    {
        Report("right_fire", Right.AmmoCount[0] < RightAmmo && Left.AmmoCount[0] == LeftAmmo);
        LeftAmmo = Left.AmmoCount[0]; RightAmmo = Right.AmmoCount[0];
        Bridge.DiagnosticDualTriggers = 3; NextAction = Now + 0.15;
    }
    else if (Step == 7) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 8)
    {
        Report("both_fire", Left.AmmoCount[0] < LeftAmmo && Right.AmmoCount[0] < RightAmmo);
        Bridge.ReplayCapture = 863;
        LeftAmmo = Left.AmmoCount[0]; RightAmmo = Right.AmmoCount[0];
        Bridge.DiagnosticDualButtons = 1;
        Bridge.DiagnosticDualTriggers = 2;
        NextAction = Now + 0.15;
    }
    else if (Step == 9)
    {
        Bridge.DiagnosticDualButtons = 0;
        Bridge.DiagnosticDualTriggers = 0;
        NextAction = Now + 5;
    }
    else if (Step == 10)
    {
        Report("left_reload_right_fire", Left.AmmoCount[0] > LeftAmmo && Right.AmmoCount[0] < RightAmmo
            && Left.IsInState('Active'));
        LeftAmmo = Left.AmmoCount[0]; RightAmmo = Right.AmmoCount[0];
        Bridge.DiagnosticDualButtons = 8; NextAction = Now + 0.15;
    }
    else if (Step == 11) { Bridge.DiagnosticDualButtons = 0; NextAction = Now + 5; }
    else if (Step == 12)
    {
        Report("right_reload", Right.AmmoCount[0] > RightAmmo && Left.AmmoCount[0] == LeftAmmo
            && Right.IsInState('Active'));
        Bridge.ReplayCapture = 864;
        NextAction = Now + 0.5;
    }
    else if (Step == 13)
    {
        Bridge.NativeMenuActive = 1;
        Bridge.HandInventory.Input.Update(0);
        Bridge.NativeMenuActive = 0;
        Report("menu_cancel", !Bridge.Hands[0].bTrigger && !Bridge.Hands[1].bTrigger
            && !Bridge.Hands[0].bTriggerArmed && !Bridge.Hands[1].bTriggerArmed
            && Bridge.PC.bRun == 0);
        Report("complete", Bridge.HandInventory.Registry.NativeFault == 0
            && Bridge.HandInventory.Registry.NativeAimFault == 0 && Bridge.HandInventory.Registry.NativeRuntimeFault == 0);
        Bridge.DiagnosticDualMotionStart = Now;
        if (!KF2VRNetPlayerController(Bridge.PC).bDiagnosticLifecycle) bFinished = true;
        if (KF2VRNetPlayerController(Bridge.PC).bDiagnosticDualTradePending)
        {
            // Keep both guns held during the existing respawn trader visit.
            // Resume the stock drop sequence after the purchase/sale exercise.
            KF2VRNetPlayerController(Bridge.PC).CompleteDiagnosticDualPass();
            Step = 18;
            Deadline = Now + 90;
            return;
        }
        NextAction = Now + 5;
    }
    else if (Step == 14)
    {
        Bridge.DiagnosticDualMotionStart = 0;
        Bridge.PC.ThrowWeapon();
        NextAction = Now + 1;
    }
    else if (Step == 15)
    {
        L = Bridge.HandInventory.Registry.GetPrimary(0);
        if (Bridge.HandInventory.Registry.IsOwned(Right) || L == None || L.Item != Left
            || Channel.HeldState.RightWeapon != None || Channel.HeldState.LeftWeapon != Left) return;
        LeftAmmo = Left.AmmoCount[0];
        Bridge.DiagnosticDualTriggers = 1;
        NextAction = Now + 0.15;
    }
    else if (Step == 16) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 17)
    {
        `log("KF2VRNet dual_drop passed=" $ (Left.AmmoCount[0] < LeftAmmo
            && Bridge.HandInventory.Registry.GetPrimary(1) == None
            && !Bridge.HandInventory.Registry.IsOwned(Right))
            $ " world=" $ Channel.WorldEpoch $ " connection=" $ Channel.ConnectionEpoch
            $ " pawn=" $ Channel.PawnEpoch $ " left_ammo=" $ Left.AmmoCount[0]
            $ " netmode=" $ Bridge.WorldInfo.NetMode);
        Channel.ServerObserveDualDrop(Left.AmmoCount[0]);
        KF2VRNetPlayerController(Bridge.PC).bDiagnosticDualTradePending = false;
        KF2VRNetPlayerController(Bridge.PC).CompleteDiagnosticDualPass();
        bFinished = true;
    }
    ++Step;
}

function ReportTrade(string Phase, bool Passed)
{
    local KF2VRNetChannel Channel;
    Channel = KF2VRNetPlayerController(Bridge.PC).NetChannel;
    `log("KF2VRNet dual_trade phase=" $ Phase $ " passed=" $ Passed
        $ " world=" $ Channel.WorldEpoch $ " connection=" $ Channel.ConnectionEpoch
        $ " pawn=" $ Channel.PawnEpoch $ " dosh=" $ Bridge.PC.PlayerReplicationInfo.Score
        $ " weapon=" $ TradeWeapon $ " left_ammo=" $ Left.AmmoCount[0]
        $ " netmode=" $ Bridge.WorldInfo.NetMode);
}

function TickTrader(float Now)
{
    local KF2VRNetPlayerController PC;
    local KFInventoryManager IM;
    local KFGameReplicationInfo GRI;
    local KFWeapon W;
    local bool bMenuOpen;
    local int I;
    if (Now < NextAction) return;
    PC = KF2VRNetPlayerController(Bridge.PC);
    IM = KFInventoryManager(Bridge.Human.InvManager);
    GRI = KFGameReplicationInfo(Bridge.WorldInfo.GRI);
    if (IM == None || GRI == None || GRI.TraderItems == None || PC.MyGFxManager == None) return;
    bMenuOpen = PC.MyGFxManager.TraderMenu != None && PC.MyGFxManager.CurrentMenu == PC.MyGFxManager.TraderMenu;
    if (Step == 18)
    {
        if (!PC.bDiagnosticDualTradeReady || bMenuOpen) return;
        TradeIndex = -1;
        for (I = 0; I < GRI.TraderItems.SaleItems.Length; ++I)
            if (GRI.TraderItems.SaleItems[I].ClassName == 'KFWeap_AssaultRifle_AR15') TradeIndex = I;
        if (TradeIndex < 0 || TradeIndex > 255) return;
        Bridge.DiagnosticDualMotionStart = 0;
        TradeDosh = PC.PlayerReplicationInfo.Score;
        PC.ServerAdvanceLifecycle(4);
        NextAction = Now + 1;
    }
    else if (Step == 19)
    {
        if (!bMenuOpen) return;
        IM.ServerBuyWeapon(byte(TradeIndex));
        NextAction = Now + 1;
    }
    else if (Step == 20)
    {
        if (PC.PlayerReplicationInfo.Score >= TradeDosh) return;
        PC.CloseTraderMenu();
        PC.ServerSetEnablePurchases(false);
        NextAction = Now + 1;
    }
    else if (Step == 21)
    {
        foreach IM.InventoryActors(class'KFWeapon', W)
            if (W.IsA('KFWeap_AssaultRifle_AR15')) TradeWeapon = W;
        if (TradeWeapon == None || bMenuOpen) return;
        if (!TradeWeapon.WeaponContentLoaded) TradeWeapon.Class.static.TriggerAsyncContentLoad(TradeWeapon.Class);
        if (!Bridge.HandInventory.CanDraw(TradeWeapon)) return;
        ReportTrade("purchase", Bridge.HandInventory.GetHeldForHand(0).Item == Left
            && Bridge.HandInventory.GetHeldForHand(1).Item == Right
            && PC.NetChannel.HeldState.LeftWeapon == Left && PC.NetChannel.HeldState.RightWeapon == Right);
        if (!Bridge.HandInventory.Draw(1, TradeWeapon)) return;
        NextAction = Now + 1;
    }
    else if (Step == 22)
    {
        if (PC.NetChannel.HeldState.RightWeapon != TradeWeapon || !TradeWeapon.IsInState('Active')) return;
        ReportTrade("draw", Bridge.HandInventory.GetHeldForHand(1).Item == TradeWeapon
            && Bridge.HandInventory.GetHeldForHand(0).Item == Left && PC.NetChannel.HeldState.LeftWeapon == Left);
        TradeDosh = PC.PlayerReplicationInfo.Score;
        PC.ServerAdvanceLifecycle(4);
        NextAction = Now + 1;
    }
    else if (Step == 23)
    {
        if (!bMenuOpen) return;
        IM.ServerSellWeapon(byte(TradeIndex));
        NextAction = Now + 1;
    }
    else if (Step == 24)
    {
        if (Bridge.HandInventory.Registry.IsOwned(TradeWeapon) || PC.NetChannel.HeldState.RightWeapon != None
            || PC.PlayerReplicationInfo.Score <= TradeDosh) return;
        ReportTrade("sale", Bridge.HandInventory.GetHeldForHand(1) == None
            && Bridge.HandInventory.GetHeldForHand(0).Item == Left && PC.NetChannel.HeldState.LeftWeapon == Left);
        PC.CloseTraderMenu();
        PC.ServerSetEnablePurchases(false);
        NextAction = Now + 1;
    }
    else if (Step == 25)
    {
        if (bMenuOpen) return;
        LeftAmmo = Left.AmmoCount[0];
        Bridge.DiagnosticDualTriggers = 1;
        NextAction = Now + 0.15;
    }
    else if (Step == 26) { Bridge.DiagnosticDualTriggers = 0; NextAction = Now + 1.5; }
    else if (Step == 27)
    {
        ReportTrade("survivor_fire", Left.AmmoCount[0] < LeftAmmo && PC.NetChannel.HeldState.LeftWeapon == Left);
        if (!Bridge.HandInventory.Draw(1, Right)) return;
        Step = 14;
        NextAction = Now + 2;
        return;
    }
    ++Step;
}
