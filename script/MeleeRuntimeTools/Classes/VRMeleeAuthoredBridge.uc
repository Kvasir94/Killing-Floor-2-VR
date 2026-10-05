// Explicit script-authored controller poses; only the synthetic LAN fixture creates this bridge.
// Draw, rig placement, sampler, stock damage helper and network RPC remain production.
class VRMeleeAuthoredBridge extends KF2VRNetHandsBridge;
var VRMeleeFixtureCoordinator Coordinator;
var KFWeapon CaseWeapon;
var KF2VRNetDiagnosticClot Target;
var int CaseIndex, Step;
var float At, NextLog, CaseStarted;
var bool bPositionSent, bFirstMarked, bGapMarked;
var int StartRejected;

simulated function UpdateControlDiagnostic() {}
simulated function AdoptFreeHandCalibration(KF2VRNetHandsBridge Previous)
{
    if (Previous == None || Previous.FreeHandPose == None || !Previous.FreeHandPose.bReady) return;
    Arms = Previous.Arms; ArmsTree = Previous.ArmsTree;
    FreeHandPose = Previous.FreeHandPose; IdlePose = Previous.IdlePose;
    WristIK[0] = Previous.WristIK[0]; WristIK[1] = Previous.WristIK[1];
    // Detach from the retiring actor before its destruction can detach its components.
    if (Arms != None) { Arms.DetachFromAny(); AttachComponent(Arms); }
    `log("KF2VR_MELEE_FIXTURE phase=bridge_handoff free_ready=" $ FreeHandPose.bReady);
}

simulated function TargetPlaced(int Index)
{
    if (Index != CaseIndex || !bPositionSent || Step != 1) return;
    At = WorldInfo.RealTimeSeconds + 0.5; Step = 2;
    `log("KF2VR_MELEE_FIXTURE phase=authored case=" $ CaseIndex $ " start=" $ At $ " speed=600");
}

simulated function BeginCase(int Index, KFWeapon W, KF2VRNetDiagnosticClot T)
{
    if (W == CaseWeapon && T == Target) return;
    CaseStarted = WorldInfo.RealTimeSeconds;
    CaseIndex = Index; CaseWeapon = W; Target = T; Step = 0; At = 0; bPositionSent = false; bFirstMarked = false; bGapMarked = false;
    `log("KF2VR_MELEE_FIXTURE phase=client case=" $ Index $ " weapon=" $ W.Class $ " target=" $ T.DiagnosticId);
}

simulated function NativeHandsUpdate()
{
    local float T, Offset, SecondAt;
    Super.NativeHandsUpdate();
    if (NativeConnection != 2 || Human == None || CaseWeapon == None) return;
    bIndependentHands = true;
    NativeGripActiveMask = 3; NativeTriggerActiveMask = 3; NativeGripMask = CaseIndex == 1 ? 3 : 2;
    NativeTriggerMask = 0; NativeButtonMask = 0; NativePhysicalButtonMask = 0;
    LeftGripValue = CaseIndex == 1 ? 1 : 0; RightGripValue = 1; LeftTriggerValue = 0; RightTriggerValue = 0;
    Offset = -40; SecondAt = CaseIndex == 3 ? 0.81 : 0.9;
    if (At > 0 && WorldInfo.RealTimeSeconds > At)
    {
        T = WorldInfo.RealTimeSeconds - At;
        // Two outward strokes; case 3 resumes before a quiet reset after a rejected gap.
        if (T < 0.14) Offset = -40 + T * 600;
        else if (T < 0.74) Offset = 44 - (T - 0.14) * 140;
        else if (CaseIndex == 3 && T >= 0.75 && T < 0.80) Offset = 140;
        else if (T < SecondAt) Offset = -40;
        else if (T < SecondAt + 0.14) Offset = -40 + (T - SecondAt) * 600;
        else Offset = 44;
    }
    LeftPosition = Human.Location + ((CaseIndex == 1 ? vect(140,-40,35) : vect(20,-90,35)) >> BodyRotation);
    RightPosition = Human.Location + (vect(120,-40,35) >> BodyRotation);
    if (CaseIndex == 1) LeftPosition += (vect(0,1,0) * (Offset + 40)) >> BodyRotation;
    else RightPosition += (vect(0,1,0) * (Offset + 40)) >> BodyRotation;
    LeftRotation = BodyRotation; RightRotation = BodyRotation;
    NativeLeftGripRotation = LeftRotation; NativeRightGripRotation = RightRotation;
}

simulated event Tick(float Delta)
{
    local VRWeaponRuntime R;
    local VRPhysicalMelee M;
    local vector Center;
    local quat BodyQ;
    Super.Tick(Delta);
    if (CaseWeapon == None || Target == None || Coordinator == None || Human == None || HandInventory == None) return;
    if (Step == 0)
    {
        HandInventory.Draw(0, None);
        if (HandInventory.Draw(1, CaseWeapon)) Step = 1;
        return;
    }
    R = HandInventory.GetHeldForHand(1);
    if (R == None || R.Item != CaseWeapon || R.Presenter == None) return;
    M = CaseIndex == 1 ? R.Presenter.OffhandGauntletMelee : R.Presenter.PhysicalMelee;
    if (M == None) return;
    if (WorldInfo.RealTimeSeconds >= NextLog)
    {
        NextLog = WorldInfo.RealTimeSeconds + 0.5;
        `log("KF2VR_MELEE_FIXTURE phase=sampling case=" $ CaseIndex $ " eligible=" $ M.Eligible()
            $ " ready=" $ M.bReady $ " swings=" $ M.Swings $ " hits=" $ M.Hits $ " rejected=" $ M.RejectedSamples $ " peak=" $ M.PeakSpeed $ " supported=" $ M.bSupported
            $ " palm=" $ (CaseIndex == 1 ? LeftPosition : RightPosition) $ " target=" $ Target.Location);
        if (CaseIndex == 1)
            `log("KF2VR_MELEE_FIXTURE phase=shield_gates case=" $ CaseIndex $ " state=" $ CaseWeapon.GetStateName()
                $ " free_ready=" $ (R.Presenter.FreeHandPose != None && R.Presenter.FreeHandPose.bReady)
                $ " shield_exists=" $ (R.Presenter.RiotShield != None)
                $ " shield_calibrated=" $ (R.Presenter.RiotShield != None && R.Presenter.RiotShield.bCalibrated)
                $ " control_exists=" $ (R.Presenter.RiotShield != None && R.Presenter.RiotShield.Control != None)
                $ " control_strength=" $ ((R.Presenter.RiotShield != None && R.Presenter.RiotShield.Control != None) ? R.Presenter.RiotShield.Control.ControlStrength : -1.0)
                $ " can_strike=" $ HandInventory.CanStrikeShield(R, 0) $ " pose_ready=" $ R.NativePoseReady
                $ " primary=" $ R.PrimaryHand $ " support=" $ R.SupportHand
                $ " calibrated=" $ R.Presenter.bCalibrated $ " weapon_ready=" $ R.Presenter.NativeWeaponReady);

    }
    if (Step == 1 && WorldInfo.RealTimeSeconds - CaseStarted > 10)
    {
        Step = 3; Coordinator.ServerFixtureFailed(CaseIndex, CaseIndex == 1 ? "shield_eligibility" : "melee_eligibility");
        return;
    }
    if (Step == 1 && M.Eligible() && M.bReady && !bPositionSent)
    {
        BodyQ = QuatFromRotator(BodyRotation);
        Center = Human.Location + QuatRotateVector(BodyQ, M.CurrentHead[1]);
        StartRejected = M.RejectedSamples;
        bPositionSent = true; Coordinator.ServerPlaceTarget(CaseIndex, Center);
        `log("KF2VR_MELEE_FIXTURE phase=placement_request case=" $ CaseIndex $ " head=" $ Center);
    }
    if (Step == 2 && WorldInfo.RealTimeSeconds > At + 0.25 && !bFirstMarked)
    {
        bFirstMarked = true; Coordinator.ServerMarkPhase(CaseIndex, 1);
    }
    if (Step == 2 && WorldInfo.RealTimeSeconds > At + 0.805 && !bGapMarked)
    {
        bGapMarked = true; Coordinator.ServerMarkPhase(CaseIndex, 2);
        `log("KF2VR_MELEE_FIXTURE phase=gap case=" $ CaseIndex $ " rejected_before=" $ StartRejected
            $ " rejected_after=" $ M.RejectedSamples $ " gap_authored=" $ (CaseIndex == 3));
    }
    if (Step == 2 && WorldInfo.RealTimeSeconds > At + 2)
    {
        Step = 3;
        Coordinator.ServerCaseComplete(CaseIndex);
        `log("KF2VR_MELEE_FIXTURE phase=finished case=" $ CaseIndex $ " swings=" $ M.Swings $ " hits=" $ M.Hits $ " rejected=" $ M.RejectedSamples);
    }
}
