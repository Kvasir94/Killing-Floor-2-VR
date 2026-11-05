// Separate a held trigger grip from a deliberate lever stroke. While waiting,
// the ordinary two-hand aim solve remains the sole weapon-root owner.
class VRLeverIntent extends Object;

var bool bReady;
var VRActionPath Path;
var int Revision, Calibration, RoomEpoch, PrimaryHand;
var float StartAmount;
var vector RootOffset;
var quat RootRotation, RelativeWrist;
var VRReloadMotionGuard Motion;

function Reset()
{
    bReady = false;
    Path = None;
    if (Motion != None) Motion.Reset();
}

function bool Step(VRHandsBridge B, VRWeaponRuntime R, VRActionPath InPath,
    int Hand, float CurrentAmount, int Direction, float StopAmount,
    float Scale, float Time, out float Proposed, optional float Tolerance, optional bool bReloadStage)
{
    local quat SupportQ, RootQ, Wrist, PosedQ;
    local vector RootAt, WristLocal, Posed, Closest;
    local float Travel, Remaining, Turn;
    if (B == None || R == None || !R.IsCurrent() || InPath == None || Hand < 0 || Hand > 1
        || R.PrimaryHand != Hand || R.SupportHand != 1 - Hand || R.Item.MySkelMesh == None
        || (B.NativeValidMask & B.NativeGripActiveMask & 3) != 3
        || (B.NativeGripMask & (1 << Hand)) == 0
        || !(Scale > 0.01 && Scale < 100))
    { Reset(); return false; }
    SupportQ = QuatFromRotator(Hand == 0 ? B.RightRotation : B.LeftRotation);
    Wrist = QuatProduct(QuatInvert(SupportQ),
        QuatFromRotator(Hand == 0 ? B.LeftRotation : B.RightRotation));
    if (!bReady || Path != InPath || Revision != R.OwnershipRevision || PrimaryHand != Hand
        || Calibration != B.NativeCalibrationEpoch || RoomEpoch != B.NativeRoomSpaceEpoch
        || Abs(StartAmount - CurrentAmount) > 0.001)
    {
        Reset();
        Path = InPath; Revision = R.OwnershipRevision; PrimaryHand = Hand;
        Calibration = B.NativeCalibrationEpoch; RoomEpoch = B.NativeRoomSpaceEpoch;
        StartAmount = CurrentAmount; RelativeWrist = Wrist;
        RootAt = R.Item.MySkelMesh.GetBoneLocation(InPath.RefRoot);
        RootQ = R.Item.MySkelMesh.GetBoneQuaternion(InPath.RefRoot);
        RootOffset = QuatRotateVector(QuatInvert(SupportQ), RootAt - B.Hands[1 - Hand].Position);
        RootRotation = QuatProduct(QuatInvert(SupportQ), RootQ);
        WristLocal = QuatRotateVector(QuatInvert(RootQ), B.Hands[Hand].Position - RootAt);
        Path.Grab(WristLocal / Scale, CurrentAmount);
        if (Motion == None) Motion = new(self) class'VRReloadMotionGuard';
        Motion.SpeedLimit = 1500;
        bReady = Motion.Begin(WristLocal, Time);
        // A retained rear stop can be waiting for a refused/delayed live-round
        // receipt; a retained front stop can be waiting for that same fence.
        // Reacquiring an already reached, owed endpoint requires no extra
        // impossible travel beyond it. The normal stop owner retries payment.
        Proposed = CurrentAmount;
        return bReady && (StopAmount - CurrentAmount) * Direction <= 0.0001;
    }
    RootAt = B.Hands[1 - Hand].Position + QuatRotateVector(SupportQ, RootOffset);
    RootQ = QuatProduct(SupportQ, RootRotation);
    WristLocal = QuatRotateVector(QuatInvert(RootQ), B.Hands[Hand].Position - RootAt);
    if (!Motion.Check(WristLocal, Time)) { Reset(); return false; }
    Proposed = Path.ProjectGrab(WristLocal / Scale);
    Path.PoseAt(Proposed, 0, Posed, PosedQ);
    Closest = Path.ContactLocal(Proposed) + QuatRotateVector(PosedQ, Path.GrabLocal);
    // Reaching elsewhere or changing the hold is not a lever stroke. Rebase
    // the candidate without moving the mechanism or taking over aiming.
    if (VSize(WristLocal / Scale - Closest) > (Tolerance > 0 ? Tolerance : 4.0))
    { Reset(); return false; }
    Travel = (Proposed - StartAmount) * Direction;
    Remaining = FMax(0, (StopAmount - StartAmount) * Direction);
    Turn = 6.0 * FMin(1, Remaining / 0.10) * Pi / 360.0;
    // A common rigid aiming turn changes neither relative wrist nor path
    // position. Require both directed original-path travel and a wrist turn;
    // merely squeezing/holding either controller never captures the root.
    // An owed reload stage cannot fire, so it needs no wrist-turn proof.
    return Travel >= FMin(0.10, Remaining)
        && Travel * Path.Length >= FMin(1.0, Remaining * Path.Length)
        && (bReloadStage || Abs(QuatDot(RelativeWrist, Wrist)) <= Cos(Turn));
}
