// Local VR presentation with predicted hand selection and stock weapon RPCs.
class KF2VRNetHandsBridge extends VRHandsBridge dependsOn(VRWeaponDropState, KF2VRNetMagazineChannel, KF2VRNetTypes);

// Opt-in local motion export/import; values belong only to Human/PC.
var int MotionEnabled, MotionPlayback, MotionHasPose, MotionPumpPhase, MotionLastRequest;
var vector MotionP0, MotionP1, MotionP2, MotionP3, MotionP4, MotionP5, MotionP6, MotionP7, MotionP8, MotionP9;
var rotator MotionR0, MotionR1, MotionR2, MotionR3, MotionR4, MotionR5, MotionR6, MotionR7, MotionR8, MotionR9;
var int MotionS0, MotionS1, MotionS2, MotionS3, MotionS4, MotionS5, MotionS6, MotionS7, MotionS8, MotionS9, MotionS10, MotionS11;
var float MotionBodyYaw, MotionEyeHeight, MotionGameSeconds;
var vector MotionVelocity;
var string MotionCurrentMap, MotionMap, MotionWeapon0, MotionWeapon1;
var int MotionW00, MotionW01, MotionW02, MotionW03, MotionW04, MotionW05;
var int MotionW10, MotionW11, MotionW12, MotionW13, MotionW14, MotionW15;
var float MotionRate0, MotionRate1;
var private KF2VRMotionReplay MotionReplay;
var private KFWeapon MotionPreviousWeapon[2];
var private int MotionLastAmmo[2], MotionShot[2], MotionItemId[2];
var int MotionFixtureEnabled;
var int MotionOriginEpoch;
var int MotionNetwork, MotionPaused, MotionSampleIndex, MotionBoundary, MotionInputDown, MotionInputActive;
var float MotionClipSeconds, MotionClockSeconds, MotionLeftGrip, MotionRightGrip;
var vector MotionLeftAxes, MotionRightAxes;
var private bool bMotionNetworkStarted;
var private vector MotionSavedRoot;
var private rotator MotionSavedRotation;
var private int MotionNetworkPawnEpoch, MotionPauseSample;
var private float MotionFixtureRecordStart;
var private KFWeapon MotionFixtureSecond;
var private bool bMotionFixtureDrewSecond;
var float MotionFixtureElapsed;
var private bool bMotionFixtureSupport, bMotionFixtureReleased, bMotionSavedHoldSupport;
var private rotator MotionFixtureRoot;
var private int MotionFixtureStep;
var private float MotionFixtureAt;
var private bool bMotionFixtureIgnoreMoveBefore;
var private int NativeSamples;
var private float NextNativeLog;
var private KF2VRNetChannel InventoryFocusChannel;
// Headset-free room-scale exercise. RoomMovementRequest normally derives the
// request from the XR head pose, which a recorded-pose fixture has none of, so
// the same bridge entry point is driven from a deterministic pattern instead.
// Scripted exercise of the network weapon contract: draw a different owned
// weapon through the same path the wrist selector uses, and check that the
// stock manager, the server and the VR registry all end up agreeing.
var private int ControlStep;
var private float ControlNextAction, ControlWatchUntil, ControlNextWatch;
var private KFWeapon ControlFirst, ControlSecond, ControlRequested;
var private float RoomInjectStarted, NextRoomInjectLog;
var private int RoomInjectLeg;
var private vector RoomInjectOrigin;
// Net drift oscillates with the walk, so it cannot show that displacement kept
// being produced. Cumulative swept distance is monotonic and does.
var private float RoomInjectTravelled;
// Sampling is stroboscopic against the one-second legs, so an instantaneous
// drift reading can look identical whether the walk is working or being
// corrected away. The peak cannot.
var private float RoomInjectPeakDrift;
var private int RoomInjectBaseCorrections;
// Clamp exercise. Bursts ride on top of the walk rather than replacing it: a
// move every frame is what keeps the server's speed budget one frame wide.
var private float RoomProbeNextAction;
var private int RoomProbeRounds;
// Residual exercise, recenter half. The respawn half lives on the controller,
// which is the only thing still ticking while the pawn is gone.
var private int RoomResidualStep, RoomReferenceEpoch;
var private bool bRoomRecenterSeen;
var private float RoomResidualUntil, RoomResidualMoved, RoomResidualQueued;
var private vector RoomResidualOrigin;
var private KF2VRNetDualWeaponProbe DualWeaponProbe;
var private KF2VRNetPairedProbe PairedProbe;
var config bool bDiagnostic9mmReload;
var private KF2VRNet9mmReloadInput ReloadCaseInput;
var private KFPawn_Human DiagnosticDualPawn;
var int DiagnosticDualTriggers, DiagnosticDualButtons;
var private KF2VRNetWorldDropChannel DropChannel;
var private vector CatchControllerPosition[2];
var private quat CatchControllerRotation[2];

var private KF2VRNetChannel ReplacementChannel;
var private KFWeapon PendingReplacement;
var private VRWeaponDropState.HandlingState PendingReplacementHandling;
var private float PendingReplacementFireDelay;
var float DiagnosticDualMotionStart;

simulated function TickMotionFixture()
{
    local KF2VRNetPlayerController C;
    local KFWeapon W;
    local VRWeaponRuntime R;
    local bool bPassed;
    C = KF2VRNetPlayerController(PC);
    if (C == None || !C.bDiagnosticMotionFixture || MotionFixtureEnabled != 1
        || NativeConnection != 2 || Human == None || Human.Health <= 0) return;
    if (MotionFixtureStep >= 99) return;
    if (C.NetChannel == None) return;
    if (MotionFixtureStep == 0 && !C.NetChannel.bDiagnosticClientsReady) return;
    if (C.bDiagnosticMotionFileOnly)
    {
        if (MotionFixtureStep == 0)
        {
            // A cold join must settle before its restoration baseline is saved.
            if (C.NativeNetworkReady != 1 || !C.NetChannel.bVRTrackingEnabled
                || Human.bDeleteMe || Human.Physics != PHYS_Walking
                || Human.bIsCrouched != Human.bWantsToCrouch) return;
            if (HandInventory == None || HandInventory.Registry == None) return;
            R = HandInventory.Registry.GetPrimary(1);
            if (R == None || R.Presenter == None || !R.Presenter.bCalibrated || R.NativePoseReady != 1) return;
            bMotionFixtureIgnoreMoveBefore = C.IsMoveInputIgnored();
            C.KF2VRMotion("network", 1);
            MotionFixtureStep = 20;
            MotionFixtureAt = WorldInfo.RealTimeSeconds + FClamp(C.MotionReviewSeconds, 0.5, 240) + 1;
        }
        else if (MotionFixtureStep == 20 && WorldInfo.RealTimeSeconds >= MotionFixtureAt)
        {
            if (!C.NetChannel.bMotionResetFailed && (C.NetChannel.MotionResetId != C.MotionReplayId
                || !C.NetChannel.bMotionResetPassed || C.NetChannel.bMotionReplayEnabled))
            {
                if (WorldInfo.RealTimeSeconds < MotionFixtureAt + 2) return;
            }
            bPassed = C.MotionReplayId > 0 && C.NetChannel.MotionResetId == C.MotionReplayId
                && C.NetChannel.bMotionResetPassed && !C.NetChannel.bMotionResetFailed && !C.NetChannel.bMotionReplayEnabled
                && C.MotionStatus == 3 && MotionPlayback == 0 && !bMotionNetworkStarted && !C.bMotionNetworkActive
                && C.IsMoveInputIgnored() == bMotionFixtureIgnoreMoveBefore;
            `log("KF2VR_MOTION_FIXTURE phase=network_end passed=" $ bPassed $ " status=" $ C.MotionStatus);
            `log("KF2VR_MOTION_FIXTURE phase=network_complete passed=" $ bPassed $ " status=" $ C.MotionStatus);
            `log("KF2VRNet motion_batch_reset replay=" $ C.MotionReplayId $ " passed=" $ bPassed $ " time=" $ WorldInfo.RealTimeSeconds);
            if (!bPassed) C.KF2VRMotion("stop", 1);
            MotionFixtureStep = 99;
        }
        return;
    }
    if (MotionFixtureStep == 1 && HandInventory != None && HandInventory.Registry != None)
    {
        R = HandInventory.Registry.GetSupport(0);
        if (!bMotionFixtureSupport && R != None && R.Presenter != None && R.Presenter.SupportIsEngaged())
        {
            bMotionFixtureSupport = true;
            `log("KF2VR_MOTION_FIXTURE phase=support_attach passed=True time=" $ WorldInfo.RealTimeSeconds);
        }
        if (bMotionFixtureSupport && !bMotionFixtureReleased && MotionFixtureElapsed > 3 && R == None)
        {
            bMotionFixtureReleased = true;
            `log("KF2VR_MOTION_FIXTURE phase=support_release passed=True time=" $ WorldInfo.RealTimeSeconds);
        }
    }
    if (MotionFixtureStep == 1 && !bMotionFixtureDrewSecond
        && WorldInfo.RealTimeSeconds - MotionFixtureRecordStart >= 4 && HandInventory != None)
    {
        // Commit the same actual owned weapon draw as the wrist selector.
        foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
            if (W != Human.Weapon && Supported(W) && W.WeaponContentLoaded && HandInventory.CanDraw(W))
            {
                MotionFixtureSecond = W;
                bMotionFixtureDrewSecond = HandInventory.Draw(1, W);
                `log("KF2VR_MOTION_FIXTURE phase=recorded_draw passed=" $ bMotionFixtureDrewSecond
                    $ " weapon=" $ PathName(W.Class) $ " time=" $ WorldInfo.RealTimeSeconds);
                break;
            }
    }
    if (WorldInfo.RealTimeSeconds < MotionFixtureAt) return;
    switch (MotionFixtureStep)
    {
    case 0:
        if (HandInventory == None || HandInventory.Registry == None) return;
        R = HandInventory.Registry.GetPrimary(1);
        if (R == None || R.Presenter == None || !R.Presenter.bCalibrated || R.NativePoseReady != 1) return;
        MotionFixtureRoot = Human.Rotation; bMotionSavedHoldSupport = bHoldSupportGrip; bHoldSupportGrip = true;
        bMotionFixtureIgnoreMoveBefore = C.IsMoveInputIgnored(); ReplayCapture = 850; C.KF2VRMotion("record", 1); MotionFixtureRecordStart = WorldInfo.RealTimeSeconds; MotionFixtureAt = WorldInfo.RealTimeSeconds + 8; break;
    case 1: bHoldSupportGrip = bMotionSavedHoldSupport; C.KF2VRMotion("stop", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.1; break;
    case 2: C.KF2VRMotion("save", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.1; break;
    case 3:
        `log("KF2VR_MOTION_FIXTURE phase=saved status=" $ C.MotionStatus);
        C.KF2VRMotion("play", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.5; break;
    case 4:
        ReplayCapture = 851;
        bPassed = C.MotionStatus == 2 && MotionReplay != None && MotionReplay.bPresentationReady
            && (MotionWeapon0 == "" || MotionReplay.LeftWeapon.WeaponClass != None)
            && (MotionWeapon1 == "" || MotionReplay.RightWeapon.WeaponClass != None);
        `log("KF2VR_MOTION_FIXTURE phase=playing passed=" $ bPassed $ " status=" $ C.MotionStatus
            $ " replay=" $ MotionReplay $ " view=" $ C.GetViewTarget()
            $ " left_class=" $ MotionReplay.LeftWeapon.WeaponClass $ " right_class=" $ MotionReplay.RightWeapon.WeaponClass);
        C.KF2VRMotion("pause", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.15; break;
    case 5: C.KF2VRMotion("camera", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.1; break;
    case 6: C.KF2VRMotion("camera", 2); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.1; break;
    case 7: C.KF2VRMotion("speed", 1, 0.5); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.1; break;
    case 8: C.KF2VRMotion("loop", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.1; break;
    case 9: C.KF2VRMotion("pause", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.4; break;
    case 10: C.KF2VRMotion("stop", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.2; break;
    case 11:
        ReplayCapture = 852;
        bPassed = C.MotionStatus == 3 && MotionReplay == None && C.GetViewTarget() == Human
            && C.IsMoveInputIgnored() == bMotionFixtureIgnoreMoveBefore;
        `log("KF2VR_MOTION_FIXTURE phase=complete passed=" $ bPassed $ " status=" $ C.MotionStatus
            $ " controls_restored=" $ (C.IsMoveInputIgnored() == bMotionFixtureIgnoreMoveBefore));
        C.KF2VRMotion("network", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 1.5; break;
    case 12: C.KF2VRMotion("pause", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.2; break;
    case 13: MotionPauseSample = MotionSampleIndex; MotionFixtureAt = WorldInfo.RealTimeSeconds + 3; break;
    case 14:
        `log("KF2VR_MOTION_FIXTURE phase=network_pause passed=" $ (MotionSampleIndex == MotionPauseSample && MotionPaused != 0)
            $ " sample=" $ MotionSampleIndex);
        C.KF2VRMotion("speed", 1, 0.5); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.2; break;
    case 15: C.KF2VRMotion("pause", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 8; break;
    case 16: C.KF2VRMotion("speed", 1, 2); MotionFixtureAt = WorldInfo.RealTimeSeconds + 5; break;
    case 17:
        // The server confirms the previous root/physics/pose reset before a second case.
        if (!C.NetChannel.bMotionResetFailed && (C.NetChannel.MotionResetId != C.MotionReplayId
            || !C.NetChannel.bMotionResetPassed || C.NetChannel.bMotionReplayEnabled))
        {
            if (WorldInfo.RealTimeSeconds < MotionFixtureAt + 2) return;
        }
        bPassed = C.NetChannel.MotionResetId == C.MotionReplayId && C.NetChannel.bMotionResetPassed
            && !C.NetChannel.bMotionResetFailed && !C.NetChannel.bMotionReplayEnabled
            && C.IsMoveInputIgnored() == bMotionFixtureIgnoreMoveBefore && C.MotionStatus == 3 && MotionPlayback == 0 && !bMotionNetworkStarted && !C.bMotionNetworkActive;
        `log("KF2VR_MOTION_FIXTURE phase=network_end passed=" $ bPassed $ " status=" $ C.MotionStatus);
        `log("KF2VRNet motion_batch_reset replay=" $ C.MotionReplayId $ " passed=" $ bPassed $ " time=" $ WorldInfo.RealTimeSeconds);
        if (!bPassed) { MotionFixtureStep = 99; C.KF2VRMotion("stop", 1); return; }
        C.KF2VRMotion("network", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 2; break;
    case 18: C.KF2VRMotion("stop", 1); MotionFixtureAt = WorldInfo.RealTimeSeconds + 0.3; break;
    case 19:
        if (!C.NetChannel.bMotionResetFailed && (C.NetChannel.MotionResetId != C.MotionReplayId
            || !C.NetChannel.bMotionResetPassed || C.NetChannel.bMotionReplayEnabled))
        {
            if (WorldInfo.RealTimeSeconds < MotionFixtureAt + 2) return;
        }
        bPassed = C.NetChannel.MotionResetId == C.MotionReplayId && C.NetChannel.bMotionResetPassed
            && !C.NetChannel.bMotionResetFailed && !C.NetChannel.bMotionReplayEnabled && C.MotionStatus == 3 && !bMotionNetworkStarted && !C.bMotionNetworkActive
            && C.IsMoveInputIgnored() == bMotionFixtureIgnoreMoveBefore;
        `log("KF2VR_MOTION_FIXTURE phase=network_complete passed=" $ bPassed $ " status=" $ C.MotionStatus);
        `log("KF2VRNet motion_batch_reset replay=" $ C.MotionReplayId $ " passed=" $ bPassed $ " time=" $ WorldInfo.RealTimeSeconds);
        MotionFixtureStep = 99; return;
    }
    ++MotionFixtureStep;
}

simulated function MotionLoadNames(string Weapon0, string Weapon1, string MapName)
{
    MotionWeapon0 = Weapon0; MotionWeapon1 = Weapon1; MotionMap = MapName;
}

simulated function MotionInputEdge(int Index, float Seconds, int Pressed, int Released, int Boundary)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None) return;
    if (!bMotionNetworkStarted) PublishNetworkMotion();
    if (!bMotionNetworkStarted) return;
    C.NetChannel.ServerMotionEdge(C.MotionReplayId, Index, Seconds, Pressed, Released, Boundary);
    `log("KF2VRNet motion_edge_sent replay=" $ C.MotionReplayId $ " sample=" $ Index
        $ " clip_time=" $ Seconds $ " pressed=" $ Pressed $ " released=" $ Released $ " boundary=" $ Boundary);
}

simulated function EndNetworkMotion()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (!bMotionNetworkStarted || C == None) return;
    if (C.NetChannel != None)
        C.NetChannel.ServerSetMotionReplay(C.NetChannel.WorldEpoch, C.NetChannel.ConnectionEpoch,
            MotionNetworkPawnEpoch, C.MotionReplayId, false);
    C.bMotionNetworkActive = false;
    C.IgnoreMoveInput(false);
    if (Human != None) { Human.SetLocation(MotionSavedRoot); Human.SetRotation(MotionSavedRotation); }
    bMotionNetworkStarted = false;
    `log("KF2VRNet motion_local_end replay=" $ C.MotionReplayId $ " time=" $ WorldInfo.RealTimeSeconds);
}

simulated function PublishNetworkMotion()
{
    local KF2VRNetPlayerController C;
    local KF2VRNetTypes.NetPoseSample S;
    local KF2VRNetTypes.NetMotionFrame M;
    local rotator Root;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None || Human == None || Human.Health <= 0
        || !C.NetChannel.bMotionReplayAllowed) { EndNetworkMotion(); return; }
    if (C.NetChannel.bMotionResetFailed) { C.KF2VRMotion("stop", 1); EndNetworkMotion(); return; }
    if (!bMotionNetworkStarted)
    {
        MotionSavedRoot = Human.Location; MotionSavedRotation = Human.Rotation;
        MotionNetworkPawnEpoch = C.NetChannel.PawnEpoch;
        ++C.MotionReplayId; C.bMotionNetworkActive = true; C.IgnoreMoveInput(true);
        C.NetChannel.ServerSetMotionReplay(C.NetChannel.WorldEpoch, C.NetChannel.ConnectionEpoch,
            MotionNetworkPawnEpoch, C.MotionReplayId, true);
        bMotionNetworkStarted = true;
    }
    if (C.NetChannel.PawnEpoch != MotionNetworkPawnEpoch) { C.KF2VRMotion("stop"); EndNetworkMotion(); return; }
    if (MotionHasPose == 0) return;
    Root.Yaw = MotionR0.Yaw;
    Human.SetLocation(MotionP0); Human.SetRotation(Root);
    S.TrackingFlags = MotionS0 & 7;
    S.PresentationFlags = MotionS1 & 63;
    S.ReferenceEpoch = Max(0, MotionS7 + MotionOriginEpoch);
    if ((S.TrackingFlags & 1) != 0) { S.HeadPosition = (MotionP1 - MotionP0) << Root; S.HeadRotation = Normalize(MotionR1 - Root); }
    if ((S.TrackingFlags & 2) != 0)
    {
        S.LeftPosition = (MotionP2 - MotionP0) << Root; S.LeftRotation = Normalize(MotionR2 - Root);
        S.LeftGripRotation = Normalize(MotionR4 - Root); S.LeftHandPose = MotionS2;
    }
    if ((S.TrackingFlags & 4) != 0)
    {
        S.RightPosition = (MotionP3 - MotionP0) << Root; S.RightRotation = Normalize(MotionR3 - Root);
        S.RightGripRotation = Normalize(MotionR5 - Root); S.RightHandPose = MotionS3;
    }
    if ((S.PresentationFlags & 1) != 0) { S.MuzzlePosition = (MotionP6 - MotionP0) << Root; S.MuzzleRotation = Normalize(MotionR6 - Root); }
    if ((S.PresentationFlags & 2) != 0) { S.LeftMuzzlePosition = (MotionP7 - MotionP0) << Root; S.LeftMuzzleRotation = Normalize(MotionR7 - Root); }
    if ((S.PresentationFlags & 4) != 0) { S.LeftWristPosition = (MotionP8 - MotionP0) << Root; S.LeftWristRotation = Normalize(MotionR8 - Root); }
    if ((S.PresentationFlags & 8) != 0) { S.RightWristPosition = (MotionP9 - MotionP0) << Root; S.RightWristRotation = Normalize(MotionR9 - Root); }
    M.bEnabled = true; M.bPaused = MotionPaused != 0;
    M.ClipId = C.MotionClipId; M.SampleIndex = MotionSampleIndex; M.ClipSeconds = MotionClipSeconds;
    M.ClockSeconds = MotionClockSeconds; M.Boundary = MotionBoundary;
    M.RootPosition = MotionP0; M.RootRotation = Root; M.BodyYaw = MotionBodyYaw;
    M.EyeHeight = MotionEyeHeight; M.Velocity = MotionVelocity; M.bCrouched = MotionS8 != 0;
    M.InteractionState = MotionS9;
    M.InputDown = MotionInputDown; M.InputActive = MotionInputActive;
    M.LeftAxes = MotionLeftAxes; M.RightAxes = MotionRightAxes;
    M.LeftGrip = MotionLeftGrip; M.RightGrip = MotionRightGrip;
    if (MotionWeapon0 != "") M.LeftWeapon.WeaponClass = class<KFWeapon>(DynamicLoadObject(MotionWeapon0, class'Class'));
    if (MotionWeapon1 != "") M.RightWeapon.WeaponClass = class<KFWeapon>(DynamicLoadObject(MotionWeapon1, class'Class'));
    M.LeftWeapon.ItemId = MotionW00; M.LeftWeapon.ShotSequence = MotionW01; M.LeftWeapon.Ammo = MotionW02;
    M.LeftWeapon.WeaponState = MotionW03; M.LeftWeapon.ReloadStage = MotionW04;
    M.LeftWeapon.FireMode = MotionW05; M.LeftWeapon.AnimRate = MotionRate0;
    M.RightWeapon.ItemId = MotionW10; M.RightWeapon.ShotSequence = MotionW11; M.RightWeapon.Ammo = MotionW12;
    M.RightWeapon.WeaponState = MotionW13; M.RightWeapon.ReloadStage = MotionW14;
    M.RightWeapon.FireMode = MotionW15; M.RightWeapon.AnimRate = MotionRate1;
    C.PublishMotionPose(S, M);
}

simulated function NativeMotionUpdate()
{
    if (MotionPlayback == 0)
    {
        EndNetworkMotion();
        if (MotionReplay != None) MotionReplay.Destroy();
        MotionReplay = None;
        return;
    }
    if (MotionNetwork != 0)
    {
        if (MotionReplay != None) MotionReplay.Destroy(); MotionReplay = None;
        PublishNetworkMotion(); return;
    }
    EndNetworkMotion();
    if (Human == None || MotionHasPose == 0) return;
    if (MotionReplay == None) MotionReplay = Spawn(class'KF2VRMotionReplay', PC);
    if (MotionReplay != None) MotionReplay.ApplyBridge(self);
}

simulated function ExportMotionWeapon(int Hand)
{
    local VRWeaponRuntime Runtime;
    local KFWeapon W;
    local KF2VRNetTypes.NetWeaponVisual Visual;
    if (HandInventory != None) Runtime = HandInventory.GetHeldForHand(Hand);
    if (Runtime != None) W = Runtime.Item;
    else if (!bIndependentHands && Hand == WeaponHand) W = ActiveWeapon;
    if (W != None)
    {
        Visual.WeaponClass = W.Class;
        if (MotionPreviousWeapon[Hand] != W)
        {
            ++MotionItemId[Hand]; MotionShot[Hand] = 0;
        }
        else if (W.AmmoCount[0] < MotionLastAmmo[Hand]) MotionShot[Hand] = (MotionShot[Hand] + 1) & 65535;
        MotionPreviousWeapon[Hand] = W; MotionLastAmmo[Hand] = W.AmmoCount[0];
        Visual.ItemId = MotionItemId[Hand]; Visual.ShotSequence = MotionShot[Hand];
        Visual.Ammo = W.AmmoCount[0];
        Visual.SkinId = class'VRWeaponPair'.static.VisibleSkin(W);
        Visual.WeaponState = W.GetWeaponStateId();
        Visual.ReloadStage = W.ReloadStatus;
        Visual.FireMode = W.CurrentFireMode;
        Visual.AnimRate = W.GetThirdPersonAnimRate();
    }
    if (Hand == 0)
    {
        MotionWeapon0 = W == None ? "" : PathName(W.Class);
        MotionW00 = Visual.ItemId; MotionW01 = Visual.ShotSequence; MotionW02 = Visual.Ammo;
        MotionW03 = Visual.WeaponState; MotionW04 = Visual.ReloadStage; MotionW05 = Visual.FireMode;
        MotionRate0 = Visual.AnimRate;
    }
    else
    {
        MotionWeapon1 = W == None ? "" : PathName(W.Class);
        MotionW10 = Visual.ItemId; MotionW11 = Visual.ShotSequence; MotionW12 = Visual.Ammo;
        MotionW13 = Visual.WeaponState; MotionW14 = Visual.ReloadStage; MotionW15 = Visual.FireMode;
        MotionRate1 = Visual.AnimRate;
    }
}


simulated function bool MultiplayerGrabHostAllowed()
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    return NetPC != None && NetPC.NetChannel != None && NetPC.NetChannel.bHandshakeAccepted
        && NetPC.NetChannel.bMultiplayerZedGrabAllowed;
}

// The local Zed preference and host permission are independent of the parked
// experimental interaction group. bGrabOptIn acknowledges eligible tracked input.
simulated function bool ZedGrabAllowed()
{
    return class'VRExperimentalPolicy'.static.ZedGrabbingEnabled() && bZedGrabEnabled
        && MultiplayerGrabHostAllowed() && KF2VRNetPlayerController(PC).NetChannel.bGrabOptIn;
}

simulated function bool RequestNetworkGrabDamage(Pawn Victim, float Amount, vector HitLocation, vector Momentum, name BoneName)
{
    if (!ZedGrabAllowed()) return false;
    KF2VRNetPlayerController(PC).ServerGrabDamage(Victim, Amount, HitLocation, Momentum, BoneName,
        KF2VRNetPlayerController(PC).NetChannel.PawnEpoch, KF2VRNetPlayerController(PC).NetChannel.GrabPolicyEpoch);
    return true;
}

simulated function bool RequestNetworkGrabImpact(Actor Source, name Bone, Actor Target,
    vector Point, vector Direction, float Speed, float BaseDamage)
{
    if (!ZedGrabAllowed()) return false;
    KF2VRNetPlayerController(PC).ServerGrabImpact(Source,Bone,Target,Point,Direction,Speed,BaseDamage,
        KF2VRNetPlayerController(PC).NetChannel.PawnEpoch,KF2VRNetPlayerController(PC).NetChannel.GrabPolicyEpoch);
    return true;
}

simulated function bool UsesNetworkDualWeapons()
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    return NetPC != None && NetPC.NetChannel != None && NetPC.NetChannel.CanRequestHeldWeapons()
        && NetPC.NetChannel.HeldState.bIndependentWeapons;
}

simulated function bool RequestNetworkHands(KFWeapon Left, KFWeapon Right, optional int CarryMask, optional int ShieldHandToken)
{
    return UsesNetworkDualWeapons() && KF2VRNetPlayerController(PC).NetChannel.RequestHeldWeapons(Left, Right, CarryMask, ShieldHandToken);
}

simulated function bool NetworkHandsPending()
{
    return UsesNetworkDualWeapons() && KF2VRNetPlayerController(PC).NetChannel.HeldRequestPending();
}

simulated function bool ReadNetworkHands(out KFWeapon Left, out KFWeapon Right, out int CarryMask, optional out int ShieldHandToken)
{
    UpdateTransferredReplacement();
    if (PendingReplacement != None || (KF2VRNetPlayerController(PC) != None
        && KF2VRNetPlayerController(PC).NetChannel != None
        && KF2VRNetPlayerController(PC).NetChannel.WorldReplacementPending())) return false;
    return UsesNetworkDualWeapons() && KF2VRNetPlayerController(PC).NetChannel.GetDesiredHeldWeapons(Left, Right, CarryMask, ShieldHandToken);
}

// A pair extraction can replace the donor's retained wrapper too. Import its
// receipt before held reconciliation exposes the newly owned stock single.
simulated function UpdateTransferredReplacement()
{
    local KF2VRNetPlayerController C;
    local KF2VRNetChannel Channel;
    local VRWeaponRuntime R;
    C = KF2VRNetPlayerController(PC);
    if (C != None) Channel = C.NetChannel;
    if (ReplacementChannel != Channel || Human == None || Human.bDeleteMe || Human.Health <= 0)
    {
        PendingReplacement = None;
        ReplacementChannel = Channel;
    }
    if (Channel == None || HeldInventory == None || HeldInventory.Human != Human) return;
    if (PendingReplacement == None)
        if (!Channel.ReadWorldReplacement(HeldInventory, PendingReplacement, PendingReplacementHandling, PendingReplacementFireDelay)) return;
    if (PendingReplacement == None || PendingReplacement.bDeleteMe || PendingReplacement.Owner != Human)
    { PendingReplacement = None; return; }
    R = HeldInventory.RegisterItem(PendingReplacement);
    if (R == None || !class'VRWeaponDropState'.static.ApplyToRuntime(R, PendingReplacementHandling,
        bInteractiveReloads, bInteractiveReloads || bFreeWeaponCycling)) return;
    R.WorldDropFireReadyAt = FMax(R.WorldDropFireReadyAt, WorldInfo.TimeSeconds + FMax(PendingReplacementFireDelay, 0.0));
    PendingReplacement = None;
}

simulated function bool WorldDropNetworkAvailable()
{
    local KF2VRNetPlayerController C;
    UpdateTransferredReplacement();
    C = KF2VRNetPlayerController(PC);
    if (DropChannel != None && (DropChannel.bDeleteMe || C == None || C.NetChannel == None
        || DropChannel != C.NetChannel.WorldDrops)) RetireDropLifetime(DropChannel);
    if (C == None || C.NetChannel == None || !UsesNetworkDualWeapons()) return false;
    if (C.NetChannel.WorldDrops == None || C.NetChannel.WorldDrops.bDeleteMe) return false;
    DropChannel = C.NetChannel.WorldDrops;
    DropChannel.Returned = WorldWeaponReturned;
    return NativeWorldDropVersion == 9 && DropChannel.Ready();
}

simulated function bool WorldDropNetworkBusy()
{
    return DropChannel != None && !DropChannel.bDeleteMe && DropChannel.Busy();
}

simulated function RetireDropLifetime(Object Lifetime)
{
    local int I;
    local VRWeaponRuntime R;
    if (Lifetime == None || HeldInventory == None) return;
    for (I = 0; I < HeldInventory.Items.Length; ++I)
    {
        R = HeldInventory.Items[I];
        if (R != None && R.WorldDropLifetime == Lifetime)
        { R.WorldDropped = 0; R.WorldDropLifetime = None; }
    }
}

simulated function WorldWeaponReturned(KFWeapon W, Object Lifetime)
{
    local VRWeaponRuntime R;
    if (HeldInventory != None)
    {
        R = HeldInventory.FindItem(W);
        if (R != None && R.WorldDropLifetime == Lifetime)
        { R.WorldDropped = 0; R.WorldDropLifetime = None; }
    }
}

simulated function bool IsWorldDropRegistered(KFWeapon W)
{
    return DropChannel != None && !DropChannel.bDeleteMe && DropChannel.IsDropped(W);
}

simulated function int SendWorldDropRelease(KFWeapon W, int Hand, vector At, rotator Facing, vector Linear, vector Angular)
{
    local int Request;
    local bool RootPose;
    local VRWeaponRuntime R;
    local VRWeaponDropState.HandlingState Snapshot;
    if (!WorldDropNetworkAvailable() || HeldInventory == None) return 0;
    R = HeldInventory.FindItem(W);
    if (R == None || R.WorldDropped != 0) return 0;
    if (!class'VRWeaponDropState'.static.Capture(R, Snapshot)) return 0;
    RootPose = class'VRWorldDropGun'.static.HasRigFrame(W.Class);
    if (!RootPose)
    {
        At = PalmPosition(Hand); Facing = W.Rotation;
        if (HandInventory != None && HandInventory.WorldDrops != None && HandInventory.WorldDrops.Input.Actions[Hand].QueuedWeapon == W)
            At = HandInventory.WorldDrops.Input.Actions[Hand].QueuedPalm;
    }
    R.WorldDropFireReadyAt = FMax(R.WorldDropFireReadyAt,
        WorldInfo.TimeSeconds + class'VRWorldDropGun'.static.RemainingFireDelay(W));
    Request = DropChannel.RequestRelease(W, Hand, At, Facing, Linear, Angular, RootPose, Snapshot);
    // The marker was sent before this local fence; earlier server handlers
    // remain admitted until authority observes that marker and stock readiness.
    if (Request > 0)
    {
        R.WorldDropped = 1; R.WorldDropLifetime = DropChannel;
        DropChannel.TrickClient().RegisterIntent(self, W, Request, Hand, 0);
    }
    return Request;
}

simulated function int SendWorldDropCatch(Actor Prop, int Hand)
{
    local int Request;
    local VRWorldDropGun Gun;
    if (!WorldDropNetworkAvailable() || Hand < 0 || Hand > 1) return 0;
    CatchControllerPosition[Hand] = Hand == 0 ? LeftPosition : RightPosition;
    CatchControllerRotation[Hand] = QuatFromRotator(Hand == 0 ? LeftRotation : RightRotation);
    Request = DropChannel.RequestCatch(Prop, Hand, HeldInventory);
    Gun = VRWorldDropGun(Prop);
    if (Request > 0 && Gun != None && Gun.DropOwner == Human)
        DropChannel.TrickClient().RegisterIntent(self, Gun.OwnedWeapon, Request, Hand, 1);
    return Request;
}

simulated function int ReserveWorldDropContact(VRWorldDropPrediction Prediction, int Hand)
{
    if (!WorldDropNetworkAvailable() || Hand < 0 || Hand > 1) return 0;
    return DropChannel.TrickClient().Send(Prediction, 1);
}

simulated function RegisterWorldTrick(VRWorldDropPrediction Prediction, byte EntryAction)
{
    if (WorldDropNetworkAvailable()) DropChannel.TrickClient().Register(Prediction, EntryAction);
}

simulated function bool ResolveWorldTrickEntry(KFWeapon W, int Request, bool bAccepted)
{
    return DropChannel != None && !DropChannel.bDeleteMe
        && DropChannel.TrickClient().EntryResolved(W, Request, bAccepted);
}

simulated function int RecordWorldDropRethrow(VRWorldDropPrediction Prediction)
{
    return WorldDropNetworkAvailable() ? DropChannel.TrickClient().Send(Prediction, 0) : 0;
}

simulated function UpdateWorldTricks()
{
    if (DropChannel != None && !DropChannel.bDeleteMe && DropChannel.LocalTricks != None)
        DropChannel.LocalTricks.Update();
}

simulated function byte ReadWorldDropResult(int Request, out byte Action, out byte Accepted,
    out KFWeapon W, out byte GripRole, out vector RootPosition, out quat RootRotation)
{
    local VRWeaponRuntime R;
    local int Hand;
    local byte Status;
    local vector Offset;
    local quat RelativeQ, ControllerQ;
    if (DropChannel == None || DropChannel.bDeleteMe)
    { RetireDropLifetime(DropChannel); return 2; }
    Hand = DropChannel.PendingHand(Request);
    if (Hand < 0) return 2;
    if (HeldInventory != None) R = HeldInventory.FindItem(DropChannel.PendingItem(Request));
    Status = DropChannel.ReadResult(Request, R, Action, Accepted, W, GripRole, RootPosition, RootRotation,
        bInteractiveReloads, bInteractiveReloads || bFreeWeaponCycling);
    if (Status == 1 && Action == 1 && Accepted != 0 && GripRole == 1)
    {
        // Keep the verified catch frame relative to the controller at contact,
        // rather than freezing it at a stale server-world position during RTT.
        Offset = QuatRotateVector(QuatInvert(CatchControllerRotation[Hand]), RootPosition - CatchControllerPosition[Hand]);
        RelativeQ = QuatProduct(QuatInvert(CatchControllerRotation[Hand]), RootRotation);
        ControllerQ = QuatFromRotator(Hand == 0 ? LeftRotation : RightRotation);
        RootPosition = (Hand == 0 ? LeftPosition : RightPosition) + QuatRotateVector(ControllerQ, Offset);
        RootRotation = QuatProduct(ControllerQ, RelativeQ);
    }
    if (Status != 0 && R != None)
    {
        R.WorldDropped = int(IsWorldDropRegistered(R.Item));
        if (R.WorldDropped == 0) R.WorldDropLifetime = None;
    }
    return Status;
}

simulated function bool ConfigureWorldDrops(bool Enabled, float Delay, bool Support, bool Others, bool Recall)
{
    return WorldDropNetworkAvailable() && DropChannel.RequestConfigure(Enabled, Delay, Support, Others, Recall) > 0;
}

simulated function bool RecallWorldDrop(KFWeapon W)
{
    return WorldDropNetworkAvailable() && DropChannel.RequestRecall(W) > 0;
}

simulated function AbandonWorldDrops()
{
    if (DropChannel != None && !DropChannel.bDeleteMe) DropChannel.Abandon();
}

simulated function bool SupportCarryAvailable()
{
    return UsesNetworkDualWeapons() && KF2VRNetPlayerController(PC).NetChannel.HeldState.NativeCarryVersion == 1;
}

simulated function bool PairedReloadAvailable()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None && C.NetChannel.PairedReloadAvailable();
}

simulated function int PairedReloadBegin(KFWeapon W, int Hand, optional bool bStock, optional bool bRealistic,
    optional bool bSwingOut, optional bool bLoseAmmo)
{
    if (!PairedReloadAvailable() || PairedReloadMailboxBusy(Hand) || CylinderEjectionPending(Hand)) return 0;
    return KF2VRNetPlayerController(PC).NetChannel.PairedReloadBegin(W, Hand, bStock, bRealistic, bSwingOut, bLoseAmmo);
}

simulated function Object PairedReloadLifetime()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None ? C.NetChannel : None;
}

simulated function int PairedReloadEpoch(int Kind)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None) return -1;
    if (Kind == 0) return C.NetChannel.WorldEpoch;
    if (Kind == 1) return C.NetChannel.ConnectionEpoch;
    return C.NetChannel.PawnEpoch;
}

simulated function bool PairedReloadRead(KFWeapon W, int BeginRequest, out int Session,
    out byte Status, out int Ammo, out int Reserve, optional out byte Ejected)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None
        && C.NetChannel.PairedReloadRead(W, BeginRequest, Session, Status, Ammo, Reserve, Ejected);
}

simulated function bool PairedReloadEject(KFWeapon W, int BeginRequest, int Session)
{
    return PairedReloadAvailable()
        && KF2VRNetPlayerController(PC).NetChannel.PairedReloadEject(W, BeginRequest, Session);
}

simulated function bool PairedReloadCommit(KFWeapon W, int BeginRequest, int Session, optional bool bNoLoad, optional int Maximum)
{
    return PairedReloadAvailable()
        && KF2VRNetPlayerController(PC).NetChannel.PairedReloadCommit(W, BeginRequest, Session, bNoLoad, Maximum);
}

simulated function int SendCycleEject(KFWeapon W, int Hand, int Count)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None || NativeWorldDropVersion != 9) return 0;
    return C.NetChannel.BeginCycleEject(W, Hand, Count);
}

simulated function int PouchDosh(KFWeapon W)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None) return 0;
    return C.NetChannel.GetPouchAmmo().Dosh();
}

simulated function bool DiscardPouchAmmo(KFWeapon W, int Count, optional byte Slot,
    optional vector At, optional rotator Facing, optional vector Velocity, optional float Scale=1)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C != None && C.NetChannel != None && C.NetChannel.DiscardPouchAmmo(W, Count, Slot, At, Facing, Velocity, Scale)) return true;
    return false;
}

simulated function bool PouchAmmoPending()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None && C.NetChannel.PouchAmmoPending();
}

simulated function int PendingPouchRounds(KFWeapon W, optional byte Slot)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None || C.NetChannel.PouchAmmo == None) return 0;
    return C.NetChannel.PouchAmmo.Reserved(W, Slot);
}

simulated function byte ReadCycleEject(KFWeapon W, int Serial, out int Ammo, out int Reserve)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    Ammo = -1; Reserve = 0;
    if (C == None || C.NetChannel == None) return 3;
    return C.NetChannel.ReadCycleEject(W, Serial, Ammo, Reserve);
}

simulated function AbandonCycleEject(int Serial)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C != None && C.NetChannel != None) C.NetChannel.AbandonCycleEject(Serial);
}

simulated function AcknowledgeCycleEject(int Serial)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C != None && C.NetChannel != None) C.NetChannel.AcknowledgeCycleEject(Serial);
}

simulated function KF2VRNetMagazineChannel MagazineTransport()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return (C != None && C.NetChannel != None) ? C.NetChannel.MagazineActions : None;
}

simulated function bool MagazineActionBusy()
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    return C != None && C.Ready() && C.Busy();
}

// Mirrors every local refusal of the channel's Start. Without a transport the
// request itself fails terminally, so there is nothing to wait for.
simulated function bool MagazineActionAdmissible(byte Action, KFWeapon W, optional int PairSession)
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    return C == None || C.CanStart(Action, W, PairSession);
}

simulated function int BeginMagazineRemoval(KFWeapon W, int Kept, bool bLose, optional int PairSession)
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    return C != None ? C.BeginRemoval(W, Kept, bLose, PairSession) : 0;
}

simulated function int SecondaryMagazineAction(byte Action, KFWeapon W, int Kept, bool Lose)
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    return C != None ? C.BeginSecondary(Action, W, Kept, Lose) : 0;
}

simulated function int RequestMagazineAction(byte Action, int Hand, KFWeapon SourceW,
    int Token, KFWeapon TargetW, byte Side, int ExpectedRemaining, optional VRWorldDropMagazine WorldProp)
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    if (C == None) return 0;
    if (Action == 1) return C.BeginClaim(Token, SourceW, Hand, WorldProp);
    if (Action == 2) return C.BeginPouch(Token, TargetW, Hand, Side, SourceW, WorldProp);
    if (Action == 3) return C.BeginInsert(Token, TargetW, Hand, SourceW, WorldProp);
    if (Action == 4) return C.BeginRelease(Token, SourceW, Hand, WorldProp);
    return 0;
}

simulated function byte ReadMagazineAction(int Request, out byte Action, out byte Accepted,
    out KFWeapon TargetW, out int Actual, out int Remaining, out byte Retired)
{
    local KF2VRNetMagazineChannel C;
    local KF2VRNetMagazineChannel.MagazineResult Reply;
    local byte Status;
    local VRWeaponRuntime R;
    C = MagazineTransport();
    if (C == None) return 2;
    Status = C.ReadResult(Request, None, Reply);
    if (Status != 1) return Status;
    // Both ammo pools were corrected on the weapon channel before the marker.
    // Only mechanism flags belong to this reply; replaying its counts would
    // erase a newer pickup that arrived while the owner receipt was in flight.
    if (Reply.bHaveAmmo && Reply.AmmoSlot == 1 && Reply.MarkerSerial > 0 && Reply.Weapon != None
        && !Reply.Weapon.bDeleteMe && Reply.Weapon.Owner == Human)
    {
        if (Reply.AmmoSlot == 1 && HeldInventory != None)
        {
            R = HeldInventory.FindItem(Reply.Weapon);
            if (R != None) R.SecondaryMagazineFlags = Reply.SecondaryFlags;
        }
    }
    Action = Reply.Action; Accepted = byte(Reply.bAccepted); TargetW = Reply.Weapon;
    Actual = Reply.Actual; Remaining = Reply.Remaining; Retired = byte(Reply.bRetired);
    return 1;
}

simulated function PublishMagazinePresentation(int Token, vector At, rotator Facing,
    vector Velocity, float Scale, optional VRWorldDropMagazine WorldProp,
    optional vector ExitAxis, optional float ExitDistance, optional int ExitHand=-1)
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    if (C != None) C.PublishPresentation(Token, At, Facing, Velocity, Scale, WorldProp, ExitAxis, ExitDistance, ExitHand);
}

simulated function AbandonMagazineActions()
{
    local KF2VRNetMagazineChannel C;
    C = MagazineTransport();
    if (C != None) C.Abandon();
}

simulated function ReportMagazineRemoved(KFWeapon W, int Kept, int Lost)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C == None || C.NetChannel == None)
    {
        // No VR channel: stock client ammo tracking still states the count.
        if (W != None && W.Role < ROLE_Authority) W.SyncCurrentAmmoCount(0, Kept);
        else Super.ReportMagazineRemoved(W, Kept, Lost);
        return;
    }
    C.NetChannel.MagazineRemoved(W, Kept, Lost);
}

simulated function NotifyPhysicalReloadEnded(KFWeapon W)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C != None && C.NetChannel != None) C.NetChannel.NotifyPhysicalReloadEnded(W);
}

simulated function PairedReloadCancel(KFWeapon W, int BeginRequest, int Session)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C != None && C.NetChannel != None) C.NetChannel.PairedReloadCancel(W, BeginRequest, Session);
}

simulated function bool VampireAvailable()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None && C.NetChannel.VampireAvailable();
}

simulated function bool BowReleaseAvailable(KFWeapon W)
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None && BowClientAvailable()
        && C.NetChannel.BowReleaseAvailable(W);
}

simulated function bool BowCaptureRelease(KFWeapon W, int Hand, out VRCompoundBowAuthority.VRBowReleaseIdentity Identity)
{
    if (RootBridge != None) return RootBridge.BowCaptureRelease(W, Hand, Identity);
    return BowReleaseAvailable(W) && BowLocalContext(W, Hand)
        && KF2VRNetPlayerController(PC).NetChannel.BowCaptureRelease(W, Hand, NativeCalibrationEpoch, Identity);
}

simulated function int BowRelease(KFWeapon W, int Hand, byte Mode, VRCompoundBowAuthority.VRBowReleaseIdentity Identity,
    vector Origin, rotator Aim, float Tension)
{
    if (RootBridge != None) return RootBridge.BowRelease(W, Hand, Mode, Identity, Origin, Aim, Tension);
    if (!BowReleaseAvailable(W) || !BowLocalContext(W, Hand)
        || Identity.ReferenceEpoch != NativeCalibrationEpoch) return 0;
    return KF2VRNetPlayerController(PC).NetChannel.BowRelease(W, Hand, Mode, Identity, Origin, Aim, Tension);
}

simulated function bool BowReleaseRead(KFWeapon W, int Request, out byte Status, out int Ammo)
{
    local KF2VRNetPlayerController C;
    if (RootBridge != None) return RootBridge.BowReleaseRead(W, Request, Status, Ammo);
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None && C.NetChannel.BowReleaseRead(W, Request, Status, Ammo);
}

simulated function bool VampireManaged()
{
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    return C != None && C.NetChannel != None && C.NetChannel.VampireManaged();
}

simulated function int VampireBegin(KFWeapon W, int Hand, bool bStock, optional bool bLoseAmmo)
{
    if (!VampireAvailable()) return 0;
    return KF2VRNetPlayerController(PC).NetChannel.VampireBegin(W, Hand, bStock, bLoseAmmo);
}

simulated function bool VampireRead(KFWeapon W, int BeginRequest, out int Session,
    out byte Status, out int Ammo, out int Reserve)
{
    if (!VampireAvailable()) return false;
    return KF2VRNetPlayerController(PC).NetChannel.VampireRead(W, BeginRequest, Session, Status, Ammo, Reserve);
}

simulated function bool VampireRemoveMagazine(KFWeapon W, int BeginRequest, int Session)
{
    return VampireAvailable() && KF2VRNetPlayerController(PC).NetChannel.VampireRemoveMagazine(W, BeginRequest, Session);
}

simulated function bool VampireCommit(KFWeapon W, int BeginRequest, int Session, optional int Maximum)
{
    return VampireAvailable() && KF2VRNetPlayerController(PC).NetChannel.VampireCommit(W, BeginRequest, Session, Maximum);
}

simulated function VampireCancel(KFWeapon W, int BeginRequest, int Session)
{
    if (VampireAvailable()) KF2VRNetPlayerController(PC).NetChannel.VampireCancel(W, BeginRequest, Session);
}

simulated function int RequestNetworkGrenade(KFWeapon ProjectileOwner, class<KFProj_Grenade> GrenadeClass,
    int Hand, vector Position, vector ReleaseVelocity)
{
    if (!UsesNetworkDualWeapons()) return 0;
    return KF2VRNetPlayerController(PC).NetChannel.RequestGrenade(
        ProjectileOwner, GrenadeClass, Hand, Position, ReleaseVelocity, NativeCalibrationEpoch);
}

simulated function byte ReadNetworkGrenadeResult(int Request, KFPawn_Human Pawn)
{
    if (!UsesNetworkDualWeapons()) return 3;
    return KF2VRNetPlayerController(PC).NetChannel.ReadGrenadeResult(Request, Pawn);
}

// A listen host or solo game tosses directly; only a remote client asks.
simulated function bool RequestNetworkDosh(vector Position, vector ReleaseVelocity)
{
    if (WorldInfo.NetMode != NM_Client || KF2VRNetPlayerController(PC) == None) return false;
    KF2VRNetPlayerController(PC).ServerThrowDosh(Position, ReleaseVelocity, HeadPosition);
    return true;
}

simulated function bool RequestNetworkDeployable(KFWeapon W, int Hand, vector Position, vector ReleaseVelocity)
{
    if (WorldInfo.NetMode != NM_Client || KF2VRNetPlayerController(PC) == None) return false;
    KF2VRNetPlayerController(PC).ServerThrowDeployable(W, Hand, Position, ReleaseVelocity, HeadPosition);
    return true;
}

simulated function bool RequestNetworkGrip(KFWeapon W, int Policy)
{
    if (WorldInfo.NetMode != NM_Client || KF2VRNetPlayerController(PC) == None) return false;
    KF2VRNetPlayerController(PC).ServerVRGrip(W, Policy);
    return true;
}

simulated function bool RequestNetworkSeekerSights(KFWeapon W, bool bSighted)
{
    if (WorldInfo.NetMode != NM_Client || KF2VRNetPlayerController(PC) == None) return false;
    KF2VRNetPlayerController(PC).ServerVRSeekerSights(W, bSighted);
    return true;
}

simulated function bool NetworkGrenadePending()
{
    return UsesNetworkDualWeapons() && KF2VRNetPlayerController(PC).NetChannel.GrenadePending();
}

simulated function int NetworkGrenadeCount()
{
    if (!UsesNetworkDualWeapons()) return 0;
    return KF2VRNetPlayerController(PC).NetChannel.AvailableGrenades();
}

simulated function bool RequestNetworkThrownContact(KFWeapon W, int Hand, int Token,
    vector Position, vector ReleaseVelocity, optional bool bStop)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || NetPC.NetChannel == None) return false;
    NetPC.NetChannel.ServerThrownWeaponContact(W, byte(Hand), Token, Position, ReleaseVelocity, bStop);
    return true;
}

simulated function RequestThrownFlinch(vector Position, vector ReleaseVelocity)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || NetPC.NetChannel == None) { Super.RequestThrownFlinch(Position, ReleaseVelocity); return; }
    NetPC.NetChannel.ServerThrownItemFlinch(Position, ReleaseVelocity);
}

simulated function KF2VRNetTypes.NetPhysicalStrike PhysicalStrike(int Hand, int Serial, optional KFWeapon W)
{
    local KF2VRNetTypes.NetPhysicalStrike Strike;
    local KF2VRNetPlayerController C;
    C = KF2VRNetPlayerController(PC);
    if (C != None && C.NetChannel != None)
    {
        Strike.WorldEpoch = C.NetChannel.WorldEpoch;
        Strike.ConnectionEpoch = C.NetChannel.ConnectionEpoch;
        Strike.PawnEpoch = C.NetChannel.PawnEpoch;
        Strike.HandGeneration = Hand == 0 ? C.NetChannel.HeldState.LeftGeneration : C.NetChannel.HeldState.RightGeneration;
        if (W != None) Strike.WeaponGeneration = C.NetChannel.HeldState.LeftWeapon == W
            ? C.NetChannel.HeldState.LeftGeneration : C.NetChannel.HeldState.RightGeneration;
    }
    Strike.Hand = Hand; Strike.Serial = Serial;
    return Strike;
}

simulated function bool RequestNetworkMeleeHit(byte FiringMode, Actor Victim, vector HitLocation, vector RayDir, name BoneName, KFWeapon SourceWeapon, int Hand, int SwingSerial, optional float DamageScale = 1.0, optional bool bShieldContact, optional bool bNoDismember, optional bool bExplosiveContact, optional bool bBluntContact)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC != None)
    {
        NetPC.ServerMeleeHit(Victim, FiringMode, HitLocation, RayDir, BoneName, SourceWeapon, PhysicalStrike(Hand, SwingSerial, SourceWeapon), DamageScale, bShieldContact, bNoDismember, bExplosiveContact, bBluntContact);
        return true;
    }
    return false;
}

simulated function bool RequestNetworkBrawlerBlast(KFWeapon W, int Hand, vector Origin, vector Dir)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None) return false;
    NetPC.ServerVRBrawlerBlast(W, byte(Hand), Origin, Dir);
    return true;
}

simulated function bool RequestNetworkPhysicalDamage(Actor Victim, float DamageAmount, vector HitLocation, vector Momentum, class<DamageType> DamageType, name BoneName, int Hand, int SwingSerial)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC != None)
    {
        NetPC.ServerPhysicalDamage(Victim, DamageAmount, HitLocation, Momentum, DamageType, BoneName, PhysicalStrike(Hand, SwingSerial));
        return true;
    }
    return false;
}

simulated function bool RequestNetworkMeleeParry(Pawn Victim, KFWeapon SourceWeapon)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || SourceWeapon == None) return false;
    NetPC.ServerMeleeParry(Victim, SourceWeapon);
    return true;
}

simulated function bool RequestNetworkMeleePommel(Pawn Victim, float DamageAmount, vector HitLocation, vector Momentum, name BoneName, KFWeapon SourceWeapon, int Hand, int SwingSerial)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || SourceWeapon == None) return false;
    NetPC.ServerMeleePommel(Victim, DamageAmount, HitLocation, Momentum, BoneName, SourceWeapon, PhysicalStrike(Hand, SwingSerial, SourceWeapon));
    return true;
}

simulated function bool RequestNetworkFistParry(Pawn Victim, int Hand)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || Hand < 0 || Hand > 1) return false;
    NetPC.ServerFistParry(Victim, byte(Hand));
    return true;
}

simulated function bool NetworkPracticeAvailable()
{
    return WorldInfo.NetMode == NM_Client && KF2VRNetPlayerController(PC) != None;
}

simulated function bool NetworkPracticeActive()
{
    return NetworkPracticeAvailable() && KF2VRNetPlayerController(PC).bVRPracticeActive;
}
simulated function bool NetworkSandboxActive()
{
    return NetworkPracticeAvailable() && KF2VRNetPlayerController(PC).bVRSandboxActive;
}

simulated function bool NetworkPracticeInvulnerable()
{
    return NetworkPracticeAvailable() && KF2VRNetPlayerController(PC).bVRPracticeInvulnerable;
}

simulated function bool RequestNetworkPractice(string Command)
{
    if (!NetworkPracticeAvailable()) return false;
    KF2VRNetPlayerController(PC).ServerVRPractice(Command);
    return true;
}

simulated function bool NetworkGodMode()
{
    return NetworkPracticeAvailable() && KF2VRNetPlayerController(PC).bVRGodMode;
}

simulated function bool RequestNetworkGodMode(bool bOn)
{
    if (!NetworkPracticeAvailable()) return false;
    KF2VRNetPlayerController(PC).ServerVRGodMode(bOn);
    return true;
}

simulated function bool RequestNetworkKnockdown(KFPawn_Monster M, vector Nudge)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC != None)
    {
        if (!ZedGrabAllowed()) return false;
        NetPC.ServerRequestKnockdown(M, Nudge, NetPC.NetChannel.PawnEpoch, NetPC.NetChannel.GrabPolicyEpoch);
        return true;
    }
    return false;
}

simulated function bool RequestNetworkReleaseGrab(KFPawn_Monster M, int Hand, optional vector Throw)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC != None)
    {
        NetPC.ServerReleaseGrab(M, byte(Hand), Throw);
        return true;
    }
    return false;
}

simulated function bool RequestNetworkGrabHold(KFPawn_Monster M, name BoneName, int Hand, vector Palm, rotator HandRotation, optional bool bStanding)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC != None)
    {
        if (!ZedGrabAllowed() || (bStanding && !ExperimentalInteractionsEnabled())) return false;
        // Capture the calibrated wrist-to-palm offset once. Subsequent frames
        // use the existing accepted tracked hand stream, including both hands.
        NetPC.ServerGrabHold(M, BoneName, byte(Hand), Palm, HandRotation, NetPC.NetChannel.PawnEpoch,
            NetPC.NetChannel.GrabPolicyEpoch, bStanding,
            (Palm - (Hand == 0 ? LeftPosition : RightPosition)) << HandRotation);
        return true;
    }
    return false;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    PC = KF2VRNetPlayerController(Owner);
    AuditedSubclasses.Add(1);
    AuditedSubclasses[AuditedSubclasses.Length - 1].SubclassName = 'KF2VRNet9mm';
    AuditedSubclasses[AuditedSubclasses.Length - 1].ProfileClassName = 'KFWeap_Pistol_9mm';
}

simulated function bool IsLocalVRContext()
{
    return PC != None && KF2VRNetPlayerController(PC) != None
        && LocalPlayer(PC.Player) != None && WorldInfo.NetMode == NM_Client
        && KF2VRNetPlayerController(PC).NativeNetworkReady == 1;
}

simulated function NativeHandsUpdate()
{
    local KF2VRNetPlayerController NetPC;
    local float Phase;
    local rotator LookOffset, HandOffset;
    local VRWeaponRuntime MotionHeld;
    local vector MotionSupportPosition;
    local quat MotionSupportRotation;
    if (DiagnosticDualPawn != Human)
    {
        DiagnosticDualPawn = Human;
        DualWeaponProbe = None;
        PairedProbe = None;
        DiagnosticDualTriggers = 0;
        DiagnosticDualButtons = 0;
        DiagnosticDualMotionStart = 0;
    }
    if (KF2VRNetPlayerController(PC) != None && KF2VRNetPlayerController(PC).NetChannel != None)
        KF2VRNetPlayerController(PC).NetChannel.UpdateGrabIntent(Human != None && Human.Health > 0 && NativeConnection > 0 && NativeControlsEnabled != 0
            && NativeValidMask == 3 && NativeMenuActive == 0, ExperimentalInteractionsEnabled(),
            class'VRExperimentalPolicy'.static.ZedGrabbingEnabled() && bZedGrabEnabled);
    bNativeEnabled = NativeConnection > 0;
    // Controls parity is not a user preference here: the legacy single-weapon
    // path has no selector, body grip, utilities or independent locomotion.
    // NativeConnection 2 is the recorded no-headset fixture, whose accepted
    // firing/damage/movement evidence was gathered on that legacy path; it
    // keeps it so the regression harness keeps measuring the same thing.
    // The recorded fixture stays on the legacy path so its existing firing,
    // damage and movement evidence keeps measuring the same thing -- unless it
    // is explicitly asked to exercise the modern stack instead.
    // Scripted replays on a dedicated server (control version 3, set by
    // KF2VRReplay.NetScriptRunner) drive the modern stack like a headset.
    bIndependentHands = NativeConnection != 2 || bDiagnostic9mmReload || ReloadCaseControlVersion == 3
        || (KF2VRNetPlayerController(PC) != None
            && (KF2VRNetPlayerController(PC).bDiagnosticVRControls
                || KF2VRNetPlayerController(PC).bDiagnosticLocomotionReplay
                || KF2VRNetPlayerController(PC).bDiagnosticDualWeapons
                || KF2VRNetPlayerController(PC).bDiagnosticMotionFixture
                || (KF2VRNetPlayerController(PC).bDiagnosticSharingReplay
                    && KF2VRNetPlayerController(PC).NetChannel != None
                    && KF2VRNetPlayerController(PC).NetChannel.bSyntheticAllowed)));
    NetPC = KF2VRNetPlayerController(PC);
    if (NativeConnection == 2 && NetPC != None && NetPC.bDiagnosticMotionFixture)
    {
        MotionFixtureElapsed = MotionFixtureStep == 1 ? WorldInfo.RealTimeSeconds - MotionFixtureRecordStart : 0.0;
        // The fixture moves controller input into the real authored support contact.
        // The production input/registry/presenter performs acquisition and release.
        if (MotionFixtureStep == 1 && MotionFixtureElapsed > 0.8 && MotionFixtureElapsed < 3
            && HandInventory != None && HandInventory.Registry != None)
        {
            MotionHeld = HandInventory.Registry.GetPrimary(1);
            if (MotionHeld != None && MotionHeld.Presenter != None
                && MotionHeld.Presenter.GetSupportGripWorld(MotionHeld.Item, MotionSupportPosition, MotionSupportRotation))
            {
                LeftPosition = MotionSupportPosition; LeftRotation = QuatToRotator(MotionSupportRotation);
                NativeLeftGripRotation = LeftRotation;
            }
        }
        NativeTriggerMask = 0; NativeButtonMask = 0; NativePhysicalButtonMask = 0;
        if (MotionFixtureStep == 1)
        {
            HandOffset = MotionFixtureRoot;
            HandOffset.Yaw += int(Sin(MotionFixtureElapsed * 0.8) * 1800);
            Human.SetRotation(HandOffset);
        }
    }
    // Only the explicit no-headset diagnostic supplies recorded button input.
    // Live XR never receives these overrides, even with a diagnostic config.
    if (NativeConnection == 2 && NetPC != None && NetPC.bDiagnosticDualWeapons)
    {
        NativeTriggerActiveMask = 3;
        NativeGripActiveMask = 3;
        NativeTriggerMask = DiagnosticDualTriggers;
        LeftTriggerValue = (DiagnosticDualTriggers & 1) != 0 ? 1 : 0;
        RightTriggerValue = (DiagnosticDualTriggers & 2) != 0 ? 1 : 0;
        NativePhysicalButtonActiveMask = 15;
        NativePhysicalButtonMask = DiagnosticDualButtons;
        HandOffset.Yaw = -4500;
        LeftRotation = Normalize(BodyRotation + HandOffset);
        HandOffset.Yaw = 4500;
        RightRotation = Normalize(BodyRotation + HandOffset);
        // Each pawn supplies its own world origin. Keep the same separated
        // hand rays for both owners: the old extra 38-degree second-owner
        // turn aimed the long gun into geometry beside the stock spawn.
        if (DiagnosticDualMotionStart > 0)
        {
            Phase = WorldInfo.RealTimeSeconds - DiagnosticDualMotionStart;
            LeftPosition += vect(0,0,1) * Sin(Phase * 1.2) * 5;
            RightPosition += (vect(0,1,0) * Sin(Phase) * 5) >> BodyRotation;
            LeftRotation.Roll += int(Sin(Phase) * 2200);
            RightRotation.Roll += int(Cos(Phase) * 2200);
            LookOffset.Yaw = int(Sin(Phase * 0.7) * 4000);
            NativeHeadRotation = Normalize(BodyRotation + LookOffset);
        }
        NativeLeftGripRotation = LeftRotation;
        NativeRightGripRotation = RightRotation;
    }
    if (NativeConnection == 2 && NetPC != None && NetPC.bDiagnosticAutoFire9mm)
    {
        NativeTriggerActiveMask = 3;
        NativeButtonActiveMask = 15;
        NativeTriggerMask = NetPC.bDiagnosticNativeTrigger ? 2 : 0;
        NativeButtonMask = NetPC.bDiagnosticNativeReload ? 1 : 0;
        if (NetPC.bDiagnosticDamage && !NetPC.bDiagnosticAvatarReplay && NetPC.DiagnosticTarget != None)
            RightRotation = rotator(NetPC.DiagnosticTarget.Location - RightPosition);
    }
    // Recorded INPUT poses are changed before Super.Tick places the real gun.
    // The observer subsequently receives that real solved optical muzzle. No
    // target auto-aim or publication-only fake muzzle is used in this fixture.
    if (NativeConnection == 2 && NetPC != None && NetPC.bDiagnosticAvatarReplay
        && NetPC.NetChannel != None && NetPC.NetChannel.bSyntheticAllowed)
    {
        Phase = WorldInfo.RealTimeSeconds * 0.55;
        LookOffset.Yaw = int(Sin(Phase) * 6500);
        LookOffset.Pitch = int(Cos(Phase * 0.7) * 1800);
        LookOffset.Roll = int(Sin(Phase * 0.8) * 1400);
        NativeHeadRotation = Normalize(BodyRotation + LookOffset);
        // Independent look and aim, a reachable free-hand wave, and wrist roll.
        LeftPosition += (vect(0,0,1) * (8 + Sin(Phase * 1.3) * 12)
            + vect(-20,0,0)) >> BodyRotation;
        RightPosition += (vect(1,0,0) * (5 + Cos(Phase) * 5)
            + vect(0,0,1) * Sin(Phase) * 6) >> BodyRotation;
        HandOffset.Yaw = int(-Sin(Phase) * 4200);
        HandOffset.Pitch = int(Sin(Phase * 0.9) * 1600);
        HandOffset.Roll = int(Cos(Phase * 0.8) * 2600);
        RightRotation = Normalize(BodyRotation + HandOffset);
        NativeRightGripRotation = RightRotation;
        HandOffset.Yaw = int(Cos(Phase) * 2600);
        HandOffset.Roll = int(Sin(Phase) * 4200);
        LeftRotation = Normalize(BodyRotation + HandOffset);
        NativeLeftGripRotation = LeftRotation;
    }
}

// The pawn is not moved here. ProcessMove applies the request as part of the
// move that replicates it, and reports back what its swept MoveSmooth achieved
// so the tracking reference still follows the real result.
simulated function bool DeferRoomMovement(vector Requested)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None) return false;
    NetPC.RequestRoomMove(Requested);
    RoomMoveAccepted = NetPC.AppliedRoomMove;
    return true;
}

// A teleport is a discrete event, not a stream, so it does not ride the room
// move's saved-move channel: that packs a 15 unit step into half an int and
// could not carry 650 units if it wanted to. The server owns the relocation,
// the client does not predict it, and the fade covers the round trip -- which
// is cheaper than predicting and being corrected, because a rejected predict
// would rubber-band the player back through a view that had already faded in.
simulated function bool DeferTeleport(vector Spot)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None) return false;
    // A queued physical step was measured against the body about to be
    // replaced. It is a sub-15 unit displacement and would be applied at the
    // destination, in a direction that no longer means anything.
    NetPC.ClearRoomState("teleport");
    NetPC.RequestTeleport(Spot);
    return true;
}

// Walks 1.5 m/s sideways in alternating one-second legs with no stick input.
// Zero acceleration and zero velocity is deliberately the hostile case: it is
// what SavedMove.CanCombineWith folds together and what the server's
// one-second idle rule force-corrects. Legs are short so the pawn oscillates
// about its spawn instead of walking 6 m into the nearest wall, where a
// blocked MoveSmooth would stop producing displacement to test.
simulated function UpdateRoomInjection(float DeltaTime)
{
    local KF2VRNetPlayerController NetPC;
    local float Now, Step;
    local vector Direction;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || !(NetPC.bDiagnosticRoomMovement || NetPC.bDiagnosticLocomotionReplay) || !IsLocalVRContext()
        || Human == None || Human.Health <= 0 || Human.Physics != PHYS_Walking
        || DeltaTime <= 0 || DeltaTime > 0.1) return;
    if (NetPC.bDiagnosticLocomotionReplay && (NativeConnection != 2 || NetPC.DiagnosticLocomotionPhase != 1)) return;
    Now = WorldInfo.RealTimeSeconds;
    if (RoomInjectStarted == 0)
    {
        RoomInjectStarted = Now;
        RoomInjectOrigin = Human.Location;
        RoomInjectBaseCorrections = NetPC.NativeRoomCorrections;
        LogRoomInjection("begin");
    }
    RoomInjectLeg = int((Now - RoomInjectStarted) / 1.0) % 2;
    Direction = vect(0,1,0) >> BodyRotation;
    if (RoomInjectLeg == 1) Direction = -Direction;
    // The clamp exercise replaces this frame's ordinary step with one the
    // server must refuse, then lets the walk resume. Running it inside the
    // walk is the point: with a room move every frame the server's
    // CurrentTimeStamp is always one frame old, so the speed budget is one
    // frame of travel rather than an idle client's accumulated gap. The lead-in
    // leaves the walk's own acceptance evidence established first.
    if (NetPC.bDiagnosticRoomClamp && Now - RoomInjectStarted >= 6.0
        && Now >= RoomProbeNextAction)
    {
        RoomProbeNextAction = Now + 1.5;
        ++RoomProbeRounds;
        // Past the 15 UU limit and well inside the +/-32.7 UU the packed field
        // carries, so the server judges the displacement rather than a
        // truncated one. The refusal is what pulls the pawn back; the gap
        // before the next burst is what lets that correction settle.
        if ((RoomProbeRounds % 2) == 1)
            NetPC.DiagnosticRoomProbe("over_distance", Direction * 20.0, DeltaTime);
        // Deliberately under the distance limit, so the only limit left to
        // refuse it is the speed one. Sized from the frame the move will span.
        // The two clamps only both bite above about 20 fps: below that, 300
        // UU/s of frame budget already exceeds the 15 UU distance limit and
        // nothing under that limit can be over speed.
        else
            NetPC.DiagnosticRoomProbe("over_speed",
                Direction * FClamp(300.0 * DeltaTime * 2.5, 8.0, 14.0), DeltaTime);
        return;
    }
    // 150 UU/s is half the 300 UU/s ceiling the server enforces.
    Step = FMin(DeltaTime, 0.05) * 150.0;
    RoomMoveRequested = Direction * Step;
    ApplyRoomMovement();
    RoomInjectTravelled += VSize(RoomMoveAccepted);
    RoomInjectPeakDrift = FMax(RoomInjectPeakDrift, VSize(Human.Location - RoomInjectOrigin));
    RoomMoveRequested = vect(0,0,0);
    if (Now >= NextRoomInjectLog)
    {
        NextRoomInjectLog = Now + 2.0;
        LogRoomInjection("walking");
    }
}

// Pick two distinct supported weapons the pawn actually owns.
simulated function bool ResolveControlWeapons()
{
    local KFWeapon W;
    if (Human == None || Human.InvManager == None) return false;
    ControlFirst = None; ControlSecond = None;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (!Supported(W) || !W.WeaponContentLoaded) continue;
        if (ControlFirst == None) ControlFirst = W;
        else if (ControlSecond == None && W != ControlFirst) { ControlSecond = W; break; }
    }
    return ControlFirst != None && ControlSecond != None;
}

// The stock switch is a sequence, not an instant. Seeing PendingWeapon set and
// the outgoing weapon enter WeaponPuttingDown is what proves the request was
// accepted; neither appearing means it was refused before it started.
simulated function LogSwitchProgress()
{
    local KFInventoryManager Inv;
    Inv = KFInventoryManager(Human.InvManager);
    `log("KF2VRNet vr_switch current=" $ (Human.Weapon != None ? string(Human.Weapon.Class.Name) : "none")
        $ " state=" $ (Human.Weapon != None ? string(Human.Weapon.GetStateName()) : "none")
        $ " pending=" $ ((Inv != None && Inv.PendingWeapon != None) ? string(Inv.PendingWeapon.Class.Name) : "none")
        $ " wanted=" $ (ControlRequested != None ? string(ControlRequested.Class.Name) : "none")
        $ " wantedstate=" $ (ControlRequested != None ? string(ControlRequested.GetStateName()) : "none")
        $ " netmode=" $ WorldInfo.NetMode);
}

simulated function LogControl(string Phase, KFWeapon Wanted)
{
    local KF2VRNetPlayerController NetPC;
    local VRWeaponRuntime R;
    local KFWeapon Held;
    NetPC = KF2VRNetPlayerController(PC);
    if (HandInventory != None && HandInventory.Registry != None)
    {
        R = HandInventory.Registry.GetPrimary(Clamp(PreferredWeaponHand, 0, 1));
        if (R != None) Held = R.Item;
    }
    `log("KF2VRNet vr_controls phase=" $ Phase
        $ " wanted=" $ (Wanted != None ? string(Wanted.Class.Name) : "none")
        $ " equipped=" $ (Human.Weapon != None ? string(Human.Weapon.Class.Name) : "none")
        $ " held=" $ (Held != None ? string(Held.Class.Name) : "none")
        $ " agrees=" $ (Held != None && Held == Human.Weapon)
        $ " switches=" $ NetPC.NativeControlSwitches
        $ " failures=" $ NetPC.NativeControlFailures
        $ " independent=" $ bIndependentHands
        $ " netmode=" $ WorldInfo.NetMode);
}

// One switch, then back, so a pass needs the contract to work in both
// directions rather than once from the spawn state.
simulated function UpdateControlDiagnostic()
{
    local KF2VRNetPlayerController NetPC;
    local KFWeapon Target;
    local VRWeaponRuntime R;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || !NetPC.bDiagnosticVRControls || !IsLocalVRContext()
        || Human == None || Human.Health <= 0 || HandInventory == None
        || HandInventory.Registry == None) return;
    if (WorldInfo.RealTimeSeconds < ControlNextAction) return;
    if (ControlStep == 0)
    {
        if (Human.Weapon == None || !ResolveControlWeapons())
        { ControlNextAction = WorldInfo.RealTimeSeconds + 1.0; return; }
        LogControl("begin", None);
        ControlStep = 1;
        ControlNextAction = WorldInfo.RealTimeSeconds + 1.0;
        return;
    }
    if (ControlStep == 1 || ControlStep == 3)
    {
        Target = (ControlStep == 1) ? ControlSecond : ControlFirst;
        if (Target == Human.Weapon) Target = (ControlStep == 1) ? ControlFirst : ControlSecond;
        ControlRequested = Target;
        // Exactly the call VRHandSelector.CommitSelection makes.
        if (!HandInventory.Draw(Clamp(PreferredWeaponHand, 0, 1), Target))
        {
            ++NetPC.NativeControlFailures;
            LogControl("draw_refused", Target);
        }
        else LogControl("draw_requested", Target);
        ControlStep += 1;
        ControlWatchUntil = WorldInfo.RealTimeSeconds + 4.0;
        ControlNextWatch = 0;
        return;
    }
    if ((ControlStep == 2 || ControlStep == 4) && WorldInfo.RealTimeSeconds < ControlWatchUntil)
    {
        if (WorldInfo.RealTimeSeconds >= ControlNextWatch)
        {
            ControlNextWatch = WorldInfo.RealTimeSeconds + 0.5;
            LogSwitchProgress();
        }
        return;
    }
    if (ControlStep == 2 || ControlStep == 4)
    {
        LogSwitchProgress();
        R = HandInventory.Registry.GetPrimary(Clamp(PreferredWeaponHand, 0, 1));
        if (ControlRequested != None && Human.Weapon == ControlRequested
            && R != None && R.Item == ControlRequested)
        {
            ++NetPC.NativeControlSwitches;
            LogControl("switch_complete", ControlRequested);
        }
        else
        {
            ++NetPC.NativeControlFailures;
            LogControl("switch_failed", ControlRequested);
        }
        ControlStep = (ControlStep == 2) ? 3 : 5;
        ControlNextAction = WorldInfo.RealTimeSeconds + 1.0;
        return;
    }
    if (ControlStep == 5)
    {
        LogControl("done", None);
        ControlStep = 6;
    }
}

// A recenter replaces the reference the queued request was measured against, so
// anything no move has carried yet describes a step in a frame that no longer
// exists. Native clears NativeRecenterRequested once it has handled the event
// and raises NativeCalibrationEpoch when the new reference is established;
// watching an edge on each catches the request either way, and consuming
// neither leaves the native handler's own reads alone.
simulated function ObserveRecenter()
{
    local KF2VRNetPlayerController NetPC;
    local bool bChanged;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None) return;
    if (NativeCalibrationEpoch != RoomReferenceEpoch)
    {
        RoomReferenceEpoch = NativeCalibrationEpoch;
        bChanged = true;
    }
    if (NativeRecenterRequested == 0) bRoomRecenterSeen = false;
    else if (!bRoomRecenterSeen)
    {
        bRoomRecenterSeen = true;
        bChanged = true;
    }
    if (bChanged) NetPC.ClearRoomState("recenter");
}

// Residual exercise, recenter half. Queueing and recentering inside one call
// is what makes this deterministic: no engine tick falls between them, so the
// move pipeline cannot consume the request first and turn a pass into luck.
simulated function UpdateRoomResidual()
{
    local KF2VRNetPlayerController NetPC;
    local vector Requested, Moved;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None || !NetPC.bDiagnosticRoomResidual || !IsLocalVRContext()
        || Human == None || Human.Health <= 0 || Human.Physics != PHYS_Walking) return;
    if (RoomResidualStep == 0)
    {
        // Let the connection settle rather than racing the first pawn.
        RoomResidualStep = 1;
        RoomResidualUntil = WorldInfo.RealTimeSeconds + 3.0;
    }
    else if (RoomResidualStep == 1 && WorldInfo.RealTimeSeconds >= RoomResidualUntil)
    {
        Requested = vect(0,8,0) >> BodyRotation;
        Requested.Z = 0;
        NetPC.RequestRoomMove(Requested);
        RoomResidualQueued = VSize(NetPC.PendingRoomRequest);
        NativeRecenterRequested = 1;
        ObserveRecenter();
        RoomResidualStep = 2;
        RoomResidualOrigin = Human.Location;
        RoomResidualMoved = 0;
        RoomResidualUntil = WorldInfo.RealTimeSeconds + 0.75;
        NetPC.LogRoomResidual("recenter", RoomResidualQueued, 0.0);
    }
    else if (RoomResidualStep == 2)
    {
        // Horizontal only: a room offset is never vertical.
        Moved = Human.Location - RoomResidualOrigin;
        Moved.Z = 0;
        RoomResidualMoved = FMax(RoomResidualMoved, VSize(Moved));
        if (WorldInfo.RealTimeSeconds >= RoomResidualUntil)
        {
            RoomResidualStep = 3;
            NativeRecenterRequested = 0;
            NetPC.LogRoomResidual("recenter_settled", RoomResidualQueued, RoomResidualMoved);
        }
    }
}

simulated function LogRoomInjection(string Phase)
{
    local KF2VRNetPlayerController NetPC;
    local vector Where;
    NetPC = KF2VRNetPlayerController(PC);
    Where = Human.Location;
    `log("KF2VRNet room_client phase=" $ Phase $ " leg=" $ RoomInjectLeg
        $ " travelled=" $ RoomInjectTravelled
        $ " peak=" $ RoomInjectPeakDrift
        $ " drift=" $ VSize(Where - RoomInjectOrigin)
        $ " sent=" $ NetPC.NativeRoomSent
        $ " corrections=" $ (NetPC.NativeRoomCorrections - RoomInjectBaseCorrections)
        $ " x=" $ Where.X $ " y=" $ Where.Y $ " z=" $ Where.Z
        $ " netmode=" $ WorldInfo.NetMode);
}

simulated function UpdateInventoryFocusIntent()
{
    local KF2VRNetPlayerController NetPC;
    local KF2VRNetChannel Channel;
    local bool bOpen;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC != None) Channel = NetPC.NetChannel;
    if (InventoryFocusChannel != None && InventoryFocusChannel != Channel)
        InventoryFocusChannel.UpdateInventoryFocusIntent(false);
    InventoryFocusChannel = Channel;
    if (Channel == None) return;
    bOpen = HandInventory != None && HandInventory.Input != None
        && (HandInventory.Input.IsSelectorOpen(0) || HandInventory.Input.IsSelectorOpen(1));
    Channel.UpdateInventoryFocusIntent(bOpen && IsLocalVRContext() && Human != None
        && Human.Health > 0 && !Human.bDeleteMe && NativeConnection > 0
        && NativeHeadTracked != 0 && NativeMenuActive == 0);
}

simulated event Tick(float DeltaTime)
{
    local int Tracking, GrenadeWristMask;
    local VRWeaponRuntime HeldRuntime;
    local vector OpticalMuzzle, LeftOpticalMuzzle;
    local rotator OpticalRotation, LeftOpticalRotation;
    local bool bOpticalValid, bLeftOpticalValid, bFrameCalibrated;
    local vector LeftWrist, RightWrist;
    local rotator LeftWristAim, RightWristAim;
    local bool bLeftWristValid, bRightWristValid;
    local NetPoseSample WeaponRoots;
    Super.Tick(DeltaTime);
    MotionPumpPhase = 0;
    if (KF2VRNetPlayerController(PC) != None &&
        (KF2VRNetPlayerController(PC).MotionRequest != MotionLastRequest || MotionEnabled != 0 || MotionPlayback != 0 || KF2VRNetPlayerController(PC).bDiagnosticMotionFixture))
    {
        MotionCurrentMap = WorldInfo.GetMapName(true);
        NativeMotionUpdate();
        MotionLastRequest = KF2VRNetPlayerController(PC).MotionRequest;
    }

    TickMotionFixture();
    if (MotionPlayback != 0 && MotionNetwork != 0) return;
    UpdateInventoryFocusIntent();
    ObserveRecenter();
    UpdateRoomInjection(DeltaTime);
    UpdateRoomResidual();
    UpdateControlDiagnostic();
    if (bDiagnostic9mmReload && NativeConnection == 2 && HandInventory != None)
    {
        if (ReloadCaseInput == None)
        { ReloadCaseInput = new(self) class'KF2VRNet9mmReloadInput'; ReloadCaseInput.Bridge = self; }
        ReloadCaseInput.Tick();
    }
    if (KF2VRNetPlayerController(PC) != None && KF2VRNetPlayerController(PC).bDiagnosticPairedWeapons
        && UsesNetworkDualWeapons() && HandInventory != None)
    {
        if (PairedProbe == None) { PairedProbe = new(self) class'KF2VRNetPairedProbe'; PairedProbe.Bridge = self; }
        PairedProbe.Tick();
    }
    else if (KF2VRNetPlayerController(PC) != None && KF2VRNetPlayerController(PC).bDiagnosticDualWeapons
        && UsesNetworkDualWeapons() && HandInventory != None)
    {
        if (DualWeaponProbe == None)
        {
            DualWeaponProbe = new(self) class'KF2VRNetDualWeaponProbe';
            DualWeaponProbe.Bridge = self;
        }
        DualWeaponProbe.Tick();
    }
    if (KF2VRNetPlayerController(PC) != None)
        KF2VRNetPlayerController(PC).UpdateSelfInspectionView(self, HeadPosition, BodyRotation,
            IsLocalVRContext() && Human != None && Human.Health > 0
                && NativeConnection > 0 && NativeHeadTracked != 0, NativeMenuActive != 0,
            NativeCalibrationEpoch);
    if (!IsLocalVRContext() || Human == None || Human.Health <= 0 || NativeConnection == 0)
    {
        if (MotionEnabled != 0)
        {
            MotionS0 = 0; MotionS1 = 0; MotionS2 = 0; MotionS3 = 0;
            MotionS10 = Human == None ? 0 : Human.Health;
            MotionHasPose = 0; MotionPumpPhase = 1; NativeMotionUpdate();
        }
        return;
    }
    bFrameCalibrated = bCalibrated;
    if (bIndependentHands)
    {
        // The modern stack calibrates the held item's presenter, not this root.
        bFrameCalibrated = false;
        if (HandInventory != None && HandInventory.Registry != None)
            HeldRuntime = HandInventory.Registry.GetPrimary(Clamp(PreferredWeaponHand, 0, 1));
        if (HeldRuntime != None && HeldRuntime.Item == Human.Weapon
            && HeldRuntime.Presenter != None && HeldRuntime.Presenter.ActiveWeapon == Human.Weapon)
            bFrameCalibrated = HeldRuntime.Presenter.bCalibrated;
    }
    if (NativeConnection > 0 && NativeValidMask == 3) ++NativeSamples;
    if (WorldInfo.RealTimeSeconds >= NextNativeLog)
    {
        NextNativeLog = WorldInfo.RealTimeSeconds + 5.0;
        `log("KF2VRNet native_frame samples=" $ NativeSamples $ " valid=" $ NativeValidMask
            $ " calibrated=" $ bFrameCalibrated $ " connection=" $ NativeConnection
            $ " weapon=" $ Human.Weapon $ " netmode=" $ WorldInfo.NetMode
            $ " trace_calls=" $ KF2VRNetPlayerController(PC).NativeTraceCalls
            $ " aim_calls=" $ KF2VRNetPlayerController(PC).NativeAimCalls
            $ " origin=" $ FireLocation $ " aim=" $ FireRotation);
    }
    Tracking = (NativeValidMask & 3) << 1;
    if (NativeHeadTracked != 0) Tracking = Tracking | 1;
    if (bIndependentHands && HandInventory != None && HandInventory.Registry != None)
    {
        HeldRuntime = HandInventory.GetHeldForHand(0);
        PublishWeaponRoot(HeldRuntime,0,WeaponRoots);
        bLeftOpticalValid = ReadOpticalMuzzle(HeldRuntime, LeftOpticalMuzzle, LeftOpticalRotation)
            && (Tracking & 2) != 0;
        if (ReadShieldRoot(0,LeftOpticalMuzzle,LeftOpticalRotation)) bLeftOpticalValid=true;
        if (HeldRuntime == None) HeldRuntime = HandInventory.Registry.GetSupport(0);
        bLeftWristValid = ReadVisualWrist(HeldRuntime, 0, LeftWrist, LeftWristAim) && (Tracking & 2) != 0;
        HeldRuntime = HandInventory.GetHeldForHand(1);
        PublishWeaponRoot(HeldRuntime,1,WeaponRoots);
        bOpticalValid = ReadOpticalMuzzle(HeldRuntime, OpticalMuzzle, OpticalRotation)
            && (Tracking & 4) != 0;
        if (ReadShieldRoot(1,OpticalMuzzle,OpticalRotation)) bOpticalValid=true;
        if (HeldRuntime == None) HeldRuntime = HandInventory.Registry.GetSupport(1);
        bRightWristValid = ReadVisualWrist(HeldRuntime, 1, RightWrist, RightWristAim) && (Tracking & 4) != 0;
        GrenadeWristMask = PublishHeldGrenade(WeaponRoots, LeftWrist, LeftWristAim,
            RightWrist, RightWristAim);
        bLeftWristValid = bLeftWristValid || (GrenadeWristMask & 1) != 0;
        bRightWristValid = bRightWristValid || (GrenadeWristMask & 2) != 0;
    }
    else if (bCalibrated && ActiveWeapon != None && ActiveWeapon == Human.Weapon
        && ActiveWeapon.MySkelMesh != None && ActiveProfile >= 0
        && ActiveProfile < WeaponProfiles.Length && WeaponHand == 1
        && (Tracking & 4) != 0)
        bOpticalValid = ActiveWeapon.MySkelMesh.GetSocketWorldLocationAndRotation(
            WeaponProfiles[ActiveProfile].MuzzleSocket, OpticalMuzzle, OpticalRotation);
    if (MotionEnabled != 0)
    {
        MotionHasPose = 1; MotionPumpPhase = 1;
        MotionP0 = Human.Location; MotionR0 = Human.Rotation;
        MotionP1 = HeadPosition; MotionR1 = NativeHeadRotation;
        MotionP2 = LeftPosition; MotionR2 = LeftRotation;
        MotionP3 = RightPosition; MotionR3 = RightRotation;
        MotionP4 = LeftPosition; MotionR4 = NativeLeftGripRotation;
        MotionP5 = RightPosition; MotionR5 = NativeRightGripRotation;
        MotionP6 = OpticalMuzzle; MotionR6 = OpticalRotation;
        MotionP7 = LeftOpticalMuzzle; MotionR7 = LeftOpticalRotation;
        MotionP8 = LeftWrist; MotionR8 = LeftWristAim;
        MotionP9 = RightWrist; MotionR9 = RightWristAim;
        MotionS0 = Tracking;
        MotionS1 = 0;
        if (bOpticalValid) MotionS1 = MotionS1 | 1;
        if (bLeftOpticalValid) MotionS1 = MotionS1 | 2;
        if (bLeftWristValid) MotionS1 = MotionS1 | 4;
        if (bRightWristValid) MotionS1 = MotionS1 | 8;
        MotionS1 = MotionS1 | ((ChargedFists() & 3) << 4);
        MotionS2 = HandPose(0); MotionS3 = HandPose(1);
        if (KF2VRNetPlayerController(PC).NetChannel != None)
        {
            MotionS4 = KF2VRNetPlayerController(PC).NetChannel.WorldEpoch;
            MotionS5 = KF2VRNetPlayerController(PC).NetChannel.ConnectionEpoch;
            MotionS6 = KF2VRNetPlayerController(PC).NetChannel.PawnEpoch;
        }
        MotionS7 = NativeCalibrationEpoch;
        MotionS8 = Human.bIsCrouched ? 1 : 0;
        // Existing scalar field: menu bit 0, support ownership bits 1/2,
        // engaged/braced support bits 3/4. Old clips have only menu 0/1.
        MotionS9 = NativeMenuActive & 1;
        if (HandInventory != None && HandInventory.Registry != None)
        {
            HeldRuntime = HandInventory.Registry.GetSupport(0);
            if (HeldRuntime != None) { MotionS9 = MotionS9 | 2; if (HeldRuntime.Presenter.SupportIsEngaged()) MotionS9 = MotionS9 | 8; }
            HeldRuntime = HandInventory.Registry.GetSupport(1);
            if (HeldRuntime != None) { MotionS9 = MotionS9 | 4; if (HeldRuntime.Presenter.SupportIsEngaged()) MotionS9 = MotionS9 | 16; }
        }
        MotionS10 = Human.Health;
        MotionBodyYaw = BodyRotation.Yaw; MotionEyeHeight = Human.BaseEyeHeight;
        MotionVelocity = Human.Velocity; MotionGameSeconds = WorldInfo.TimeSeconds;
        MotionMap = WorldInfo.GetMapName(true);
        ExportMotionWeapon(0); ExportMotionWeapon(1);
        NativeMotionUpdate();
    }
    PublishReloadProps(WeaponRoots);
    PublishMechanisms(WeaponRoots);
    PublishPhysicalOwnership(WeaponRoots);
    KF2VRNetPlayerController(PC).PublishTrackedPose(HeadPosition, NativeHeadRotation,
        LeftPosition, LeftRotation, RightPosition, RightRotation, Tracking,
        NativeLeftGripRotation, NativeRightGripRotation, NativeCalibrationEpoch,
        OpticalMuzzle, OpticalRotation, bOpticalValid,
        LeftOpticalMuzzle, LeftOpticalRotation, bLeftOpticalValid,
        LeftWrist, LeftWristAim, bLeftWristValid, RightWrist, RightWristAim, bRightWristValid,
        ChargedFists(), HandPose(0) | (HandPose(1) << 8), CarryPumpCode(0), CarryPumpCode(1),WeaponRoots);
}

simulated function AddReloadProp(out NetPoseSample Sample, StaticMeshComponent Component, KFWeapon W,
    int Hand, byte Slot, byte PropSlot, int CarrySerial, optional bool bSeated)
{
    local NetReloadProp Prop;
    local KF2VRNetChannel Channel;
    local rotator Basis;
    if (Component == None || Component.HiddenGame || Component.StaticMesh == None || W == None
        || Hand < 0 || Hand > 1 || Sample.ReloadProps.Length >= 5 || Human == None) return;
    Channel = KF2VRNetPlayerController(PC).NetChannel;
    if (Channel == None) return;
    Prop.SourceHand = 1 - Hand;
    if ((Prop.SourceHand == 0 ? Channel.HeldState.LeftWeapon : Channel.HeldState.RightWeapon) != W) return;
    Prop.Generation = Prop.SourceHand == 0 ? Channel.HeldState.LeftGeneration : Channel.HeldState.RightGeneration;
    Prop.bSeated = bSeated;
    Prop.Hand = bSeated ? int(Prop.SourceHand) : Hand; Prop.AmmoSlot = Slot; Prop.PropSlot = PropSlot; Prop.CarrySerial = CarrySerial;
    Prop.Family = class'VRReloadCatalog'.static.ProfileClass(W.Class);
    Prop.SkinId = class'VRWeaponPair'.static.VisibleSkin(W);
    Basis.Yaw = NormalizeRotAxis(Human.Rotation.Yaw);
    Prop.Position = (Component.Translation - Human.Location) << Basis;
    Prop.Rotation = Normalize(Component.Rotation - Basis);
    Prop.Scale = Component.Scale3D * Component.Scale;
    if (class'KF2VRNetTypes'.static.ValidReloadProp(Prop)) Sample.ReloadProps.AddItem(Prop);
}

simulated function PublishReloadProps(out NetPoseSample Sample)
{
    local VRInteractiveReload R;
    local int I;
    if (HandInventory == None || HandInventory.Input == None) return;
    R = HandInventory.Input.Reloads;
    if (R == None) return;
    if (R.bActive && (R.HandMode == 1 || R.HandMode == 4) && !R.bRecoveredMagazineSession)
    {
        AddReloadProp(Sample, R.HandAmmo, R.Gun, R.OffHand(), 0, 0, R.CarriedAmmoSerial);
        if (R.ShellBundle != None && R.ShellBundle.bPlaced)
            for (I = 0; I < 3; ++I) AddReloadProp(Sample, R.ShellBundle.Props[I], R.Gun, R.OffHand(), 0, I + 1, R.CarriedAmmoSerial);
    }
    // The seated mesh replaces the hidden magazine until the physical session
    // releases the gun. It must follow the gun, not the now-free loading hand.
    if (R.bActive && (R.HandAmmo == None || R.HandAmmo.HiddenGame))
        AddReloadProp(Sample, R.SeatedAmmo, R.Gun, R.OffHand(), 0, 0, R.CarriedAmmoSerial, true);
    if (R.Secondary != None && R.Secondary.bActive && R.Secondary.bCarryingAmmo && !R.Secondary.bRecoveredMagazine)
        AddReloadProp(Sample, R.Secondary.SecondaryAmmo, R.Secondary.Gun, R.Secondary.OffHand(), 1, 4, R.Secondary.CarriedAmmoSerial);
}

simulated function AddMechanism(out NetPoseSample Sample, KFWeapon W, int Hand, name Bone,
    SkelControlSingleBone Control, vector RestPosition, quat RestRotation)
{
    local KF2VRNetChannel Channel;
    local NetMechanismPart Part;
    local int I;
    if (W == None || Hand < 0 || Hand > 1 || Bone == '' || Control == None || Control.ControlStrength <= 0
        || Control.BoneTranslationSpace != BCS_WorldSpace || Control.BoneRotationSpace != BCS_WorldSpace) return;
    Channel = KF2VRNetPlayerController(PC).NetChannel;
    if (Channel == None || (Hand == 0 ? Channel.HeldState.LeftWeapon : Channel.HeldState.RightWeapon) != W) return;
    Part.Hand = Hand; Part.Bone = Bone;
    Part.Flags = 1 | 4;
    if (class'VRBoneVisibility'.static.IsHidden(W.MySkelMesh, Bone)) Part.Flags = Part.Flags | 2;
    Part.Generation = Hand == 0 ? Channel.HeldState.LeftGeneration : Channel.HeldState.RightGeneration;
    Part.Translation = QuatRotateVector(QuatInvert(RestRotation), Control.BoneTranslation - RestPosition);
    Part.Rotation = Normalize(QuatToRotator(QuatProduct(QuatInvert(RestRotation), QuatFromRotator(Control.BoneRotation))));
    if (!class'KF2VRNetTypes'.static.ValidMechanism(Part)) return;
    for (I = 0; I < Sample.Mechanisms.Length; ++I)
        if (Sample.Mechanisms[I].Hand == Hand && Sample.Mechanisms[I].Bone == Bone)
        { Sample.Mechanisms[I] = Part; return; }
    if (Sample.Mechanisms.Length < 32) Sample.Mechanisms.AddItem(Part);
}

simulated function ExportMechanism(out NetPoseSample Sample, VRManualPump Action)
{
    local int I;
    local quat Root;
    local vector RestOrigin;
    if (Action == None || Action.Gun == None || Action.Gun.MySkelMesh == None || Action.Tree == None) return;
    Root = Action.RootQ(); RestOrigin = Action.RootPos();
    for (I = 0; I < Action.Parts.Length; ++I)
        AddMechanism(Sample, Action.Gun, Action.GunHand, Action.Parts[I].Bone, Action.Parts[I].Control,
            RestOrigin + QuatRotateVector(Root, Action.Parts[I].IdleLocal * Action.GunScale()),
            QuatProduct(Root, Action.Parts[I].IdleLocalQ));
}

simulated function PublishMechanisms(out NetPoseSample Sample)
{
    local VRInteractiveReload R;
    local int I, Hand, Profile;
    local KFWeapon W;
    local array<name> Bones;
    local KF2VRNetChannel Channel;
    if (HandInventory == None || HandInventory.Input == None) return;
    R = HandInventory.Input.Reloads;
    if (R == None) return;
    ExportMechanism(Sample, R.Pump);
    ExportMechanism(Sample, R.ManualAction);
    ExportMechanism(Sample, R.BreakAction);
    ExportMechanism(Sample, R.M32Action);
    ExportMechanism(Sample, R.FinishAction);
    ExportMechanism(Sample, R.DualCylinders[0]);
    ExportMechanism(Sample, R.DualCylinders[1]);
    ExportMechanism(Sample, R.Mechanism);
    ExportMechanism(Sample, R.Vampire);
    ExportMechanism(Sample, R.Secondary);
    Channel = KF2VRNetPlayerController(PC).NetChannel;
    if (Channel != None)
        for (Hand = 0; Hand < 2; ++Hand)
        {
            W = Hand == 0 ? Channel.HeldState.LeftWeapon : Channel.HeldState.RightWeapon;
            if (W == None || W.MySkelMesh == None) continue;
            Profile = class'VRReloadCatalog'.static.FindClass(W.Class);
            if (Profile >= 0)
            {
                PublishMechanismVisibility(Sample, W, Hand, class'VRReloadCatalog'.static.MagazineBone(Profile, false));
                PublishMechanismVisibility(Sample, W, Hand, class'VRReloadCatalog'.static.MagazineBone(Profile, true));
            }
            Profile = class'VRBreakCatalog'.static.FindClass(W.Class);
            if (Profile >= 0)
            {
                for (I = 0; I < 4; ++I) PublishMechanismVisibility(Sample, W, Hand, class'VRBreakCatalog'.default.Profiles[Profile].ShellBones[I]);
                PublishMechanismVisibility(Sample, W, Hand, class'VRBreakCatalog'.default.Profiles[Profile].ClipBone);
            }
            if (class'VRSecondaryReloadCatalog'.static.Supported(W))
            {
                class'VRSecondaryReloadCatalog'.static.ControlBones(W, Bones);
                for (I = 0; I < Bones.Length; ++I) PublishMechanismVisibility(Sample, W, Hand, Bones[I]);
            }
        }
    if (R.Gun == None || R.Gun.MySkelMesh == None) return;
    if (R.MagazineProfileIndex >= 0 && R.RigSample != None)
    {
        AddMechanism(Sample, R.Gun, R.GunHand, R.RackBone, R.RackControl,
            R.RootLocation(R.RigSample.RackRestLocal), R.RootQuat(R.RigSample.RackRestLocalQ));
        AddMechanism(Sample, R.Gun, R.GunHand, R.FollowBone, R.FollowControl,
            R.RootLocation(R.RigSample.FollowRestLocal), R.RootQuat(R.RigSample.FollowRestLocalQ));
    }
    if (R.LeverPath != None && R.LeverPath.Path.Length > 0)
        for (I = 0; I < R.LeverControls.Length && I < 3; ++I)
            AddMechanism(Sample, R.Gun, R.GunHand, R.LeverPath.Bones[I], R.LeverControls[I],
                R.RootLocation(R.LeverPath.Path[0].P[I]), R.RootQuat(R.LeverPath.Path[0].Q[I]));
}

// Playback ownership uses the same generation-checked 120 Hz part stream.
// Visibility alone is not ownership: ordinary button reloads also publish it.
simulated function PublishPhysicalOwnership(out NetPoseSample Sample)
{
    local VRInteractiveReload R;
    local KF2VRNetChannel Channel;
    local KFWeapon W;
    local array<name> Bones;
    local int Hand, I;
    if (HandInventory == None || HandInventory.Input == None) return;
    R = HandInventory.Input.Reloads;
    Channel = KF2VRNetPlayerController(PC).NetChannel;
    if (R == None || Channel == None) return;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        W = Hand == 0 ? Channel.HeldState.LeftWeapon : Channel.HeldState.RightWeapon;
        if (W == None || W.MySkelMesh == None) continue;
        if (R.Automatic(HandInventory.Registry.FindItem(W)))
        {
            for (I = 0; I < Sample.Mechanisms.Length; ++I)
                if (Sample.Mechanisms[I].Hand == Hand) Sample.Mechanisms[I].Flags = Sample.Mechanisms[I].Flags & 3;
            continue;
        }
        if (!R.EnabledFor(W) || !R.SessionHolds(W)) continue;
        class'KF2VRNetMechanismCatalog'.static.Collect(W.Class, Bones);
        for (I = 0; I < Bones.Length; ++I) PublishMechanismVisibility(Sample, W, Hand, Bones[I]);
        for (I = 0; I < Sample.Mechanisms.Length; ++I)
            if (Sample.Mechanisms[I].Hand == Hand) Sample.Mechanisms[I].Flags = Sample.Mechanisms[I].Flags | 4;
    }
}

simulated function PublishMechanismVisibility(out NetPoseSample Sample, KFWeapon W, int Hand, name Bone)
{
    local int I;
    local NetMechanismPart Part;
    local KF2VRNetChannel Channel;
    if (Bone == '' || Bone == 'RW_Weapon' || W.MySkelMesh.MatchRefBone(Bone) < 0) return;
    for (I = 0; I < Sample.Mechanisms.Length; ++I)
        if (Sample.Mechanisms[I].Hand == Hand && Sample.Mechanisms[I].Bone == Bone) return;
    Channel = KF2VRNetPlayerController(PC).NetChannel;
    Part.Hand = Hand; Part.Bone = Bone;
    Part.Generation = Hand == 0 ? Channel.HeldState.LeftGeneration : Channel.HeldState.RightGeneration;
    if (class'VRBoneVisibility'.static.IsHidden(W.MySkelMesh, Bone)) Part.Flags = 2;
    if (Sample.Mechanisms.Length < 32) Sample.Mechanisms.AddItem(Part);
}

simulated function int CarryPumpCode(int Hand)
{
    if (HandInventory == None || HandInventory.Input == None || HandInventory.Input.Reloads == None
        || HandInventory.Input.Reloads.Pump == None) return 0;
    return HandInventory.Input.Reloads.Pump.CarryVisualCode(Hand);
}

// Copy the already placed local preview: authored offsets, EMP fit and both
// hands use exactly the same presentation as solo. No second throw estimator.
simulated function int PublishHeldGrenade(out NetPoseSample Sample,
    out vector LeftWrist, out rotator LeftAim, out vector RightWrist, out rotator RightAim)
{
    local VRChestGrenade G;
    local rotator Root, Aim;
    local vector Wrist;
    if (HandInventory.Input == None) return 0;
    G = HandInventory.Input.Grenade;
    if (G == None || G.HoldingHand < 0 || G.HoldingHand > 1
        || !G.IsHeld(G.HoldingHand) || G.Preview == None || !G.HeldContextValid()) return 0;
    Root.Yaw = NormalizeRotAxis(Human.Rotation.Yaw);
    Sample.GrenadeHand = G.HoldingHand + 1;
    Sample.GrenadePosition = (G.Preview.Translation - Human.Location) << Root;
    Sample.GrenadeRotation = Normalize(G.Preview.Rotation - Root);
    // Retarget the empty hand's rendered anatomy too, just as for held guns,
    // so the prop and the observer's wrist agree on the authored hand frame.
    if (FreeHandPose == None || !FreeHandPose.bReady) return 0;
    Wrist = RenderedHandPosition(G.HoldingHand);
    Aim = QuatToRotator(QuatProduct(RenderedHandRotation(G.HoldingHand),
        QuatInvert(FreeHandPose.WristBasis[G.HoldingHand])));
    if (G.HoldingHand == 0) { LeftWrist = Wrist; LeftAim = Aim; return 1; }
    RightWrist = Wrist; RightAim = Aim; return 2;
}

// Teammates see the curl the local hand shows (KF2VRNetTypes.NetPoseSample
// hand pose): the free hand's grip curl (VRFreeHandPose.Amount, from the grip
// analog), or a full grip around a held or supported weapon. The local hands
// have no pointing or thumb pose and the adapter exposes no touch or finger
// tracking, so index and thumb are extended only on the fully open hand.
// Curl at or below this (of 15) is an open hand; KF2VRNetHandContact.IsOpen agrees.
const OpenCurl = 2;

simulated function int HandPose(int Hand)
{
    local int Curl;
    local bool bWeapon;
    if (FreeHandPose == None) return 0;
    if (bIndependentHands)
        bWeapon = HandInventory != None && HandInventory.Registry != None
            && (HandInventory.Registry.GetPrimary(Hand) != None || HandInventory.Registry.GetSupport(Hand) != None);
    else bWeapon = ActiveWeapon != None && ActiveWeapon == Human.Weapon && Hand == WeaponHand;
    if (bWeapon) return 64 | 15;
    Curl = Clamp(Round(FreeHandPose.Amount[Hand] * 15), 0, 15);
    // A hand resting on the controller is still open: flag the index and thumb
    // extended up to OpenCurl so a relaxed high five reads as one on the server.
    return Curl <= OpenCurl ? (48 | Curl) : Curl;
}

// Teammates see a fully charged fist glow; the rising charge stays local.
simulated function int ChargedFists()
{
    local int Mask;
    if (HandInventory == None || HandInventory.FistCharge == None) return 0;
    if (HandInventory.FistCharge.IsCharged(0)) Mask = Mask | 1;
    if (HandInventory.FistCharge.IsCharged(1)) Mask = Mask | 2;
    return Mask;
}

simulated function bool ReadVisualWrist(VRWeaponRuntime Runtime, int Hand, out vector Position, out rotator Aim)
{
    if (Runtime == None || Runtime.Presenter == None || Runtime.Presenter.Arms == None
        || Runtime.Presenter.FreeHandPose == None || !Runtime.Presenter.FreeHandPose.bReady
        || !Runtime.Presenter.bCalibrated
        || (Runtime.NativePoseReady != 1 && !Runtime.Presenter.FreshCarryVisual(Hand))) return false;
    Position = Runtime.Presenter.RenderedHandPosition(Hand);
    Aim = QuatToRotator(QuatProduct(Runtime.Presenter.RenderedHandRotation(Hand),
        QuatInvert(Runtime.Presenter.FreeHandPose.WristBasis[Hand])));
    return true;
}

simulated function PublishWeaponRoot(VRWeaponRuntime Runtime,int Hand,out NetPoseSample Sample)
{
    local vector At;
    local rotator Facing,Root;
    local VRWeaponPresenter Presenter;
    local KF2VRNetChannel Channel;
    local int Generation;
    if(Runtime==None || Runtime.Item==None || Runtime.Item.MySkelMesh==None || Runtime.NativePoseReady!=1
        || (NativeValidMask & (1<<Hand))==0) return;
    Presenter=Runtime.Presenter;
    if(Presenter==None || !Presenter.bCalibrated || Presenter.ActiveProfile<0
        || Presenter.ActiveProfile>=Presenter.WeaponProfiles.Length) return;
    Channel=KF2VRNetPlayerController(PC).NetChannel;
    if(Channel==None || !Channel.HeldState.bAvailable
        || (Hand==0 ? Channel.HeldState.LeftWeapon : Channel.HeldState.RightWeapon)!=Runtime.Item) return;
    Generation=Hand==0 ? Channel.HeldState.LeftGeneration : Channel.HeldState.RightGeneration;
    if(Generation<=0) return;
    if(VRWeap_Tomahawk(Runtime.Item)!=None && VRWeap_Tomahawk(Runtime.Item).bAxeAway) return;
    Sample.WeaponRootFlags=Sample.WeaponRootFlags | (Hand==0 ? 2 : 1);
    if(Hand==0) Sample.LeftWeaponRootGeneration=Generation;
    else Sample.RightWeaponRootGeneration=Generation;
    if(class'VRWeaponBlockShapes'.static.PublishesRoot(Presenter.ActiveProfile)) return;
    At=Runtime.Item.MySkelMesh.GetBoneLocation(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    Facing=QuatToRotator(Runtime.Item.MySkelMesh.GetBoneQuaternion(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone));
    Root.Yaw=NormalizeRotAxis(Human.Rotation.Yaw);
    At=(At-Human.Location)<<Root; Facing=Normalize(Facing-Root);
    if(Hand==0) { Sample.LeftWeaponRootPosition=At; Sample.LeftWeaponRootRotation=Facing; }
    else { Sample.RightWeaponRootPosition=At; Sample.RightWeaponRootRotation=Facing; }
}

simulated function bool ReadShieldRoot(int Hand, out vector Position, out rotator Aim)
{
    local VRWeaponRuntime R;
    R=HandInventory.Registry.GetSupport(Hand);
    if (R==None || R.Item.Class!=class'KFWeap_SMG_G18' || R.NativeShieldReady!=1
        || R.ShieldPoseSequence!=HandInventory.Registry.PoseSequence || R.Item.MySkelMesh==None) return false;
    Position=R.Item.MySkelMesh.GetBoneLocation('LW_Weapon');
    Aim=QuatToRotator(R.Item.MySkelMesh.GetBoneQuaternion('LW_Weapon'));
    return true;
}

simulated function bool ReadOpticalMuzzle(VRWeaponRuntime Runtime, out vector Position, out rotator Aim)
{
    local VRWeaponPresenter Presenter;
    if (Runtime == None || Runtime.Item == None || Runtime.Item.MySkelMesh == None) return false;
    if (Runtime.Item.Class==class'KFWeap_SMG_G18' && Runtime.PrimaryHand<0) return false;
    // A thrown RAVEN-7 is the projectile others see; its hand is empty.
    if (VRWeap_Tomahawk(Runtime.Item) != None && VRWeap_Tomahawk(Runtime.Item).bAxeAway) return false;
    Presenter = Runtime.Presenter;
    // Pure melee has no optical socket. Its otherwise unused presentation
    // slot carries the exact held root for contact authority and measured 3P
    // alignment. Firearm and projectile/muzzle paths keep their stock frame.
    if(Presenter!=None && Presenter.bCalibrated && Runtime.NativePoseReady==1
        && class'VRWeaponBlockShapes'.static.PublishesRoot(Presenter.ActiveProfile))
    {
        Position=Runtime.Item.MySkelMesh.GetBoneLocation(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
        Aim=QuatToRotator(Runtime.Item.MySkelMesh.GetBoneQuaternion(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone));
        return true;
    }
    // Remote bow art keeps its fixed riser/rest anchor. Its direction is the
    // final arrow bore, rather than the perpendicular raw 1P muzzle frame.
    if (class'VRCompoundBowAuthority'.static.Supports(Runtime.Item))
    {
        if (Presenter == None || !Presenter.bCalibrated || Runtime.NativePoseReady != 1) return false;
        if (!Runtime.Item.MySkelMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', Position, Aim)) return false;
        Aim = Presenter.LaserMuzzleRotation;
        return true;
    }
    return Presenter != None && Presenter.bCalibrated && Presenter.ActiveProfile >= 0
        && Presenter.ActiveProfile < Presenter.WeaponProfiles.Length
        && Runtime.Item.MySkelMesh.GetSocketWorldLocationAndRotation(
            Presenter.WeaponProfiles[Presenter.ActiveProfile].MuzzleSocket, Position, Aim);
}

simulated event Destroyed()
{
    EndNetworkMotion();
    if (MotionReplay != None) MotionReplay.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
}
