// Tests the actual pose acquisition reset used at secondary guide capture.
// Mesh placement and hand/cartridge alignment remain rendered acceptance.
class VRSecondaryPoseStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL secondary-pose " $ Label); }
}

function RunCases()
{
    local VRReloadHandPose Pose;
    local SkelControlSingleBone Finger;
    local quat VisibleQ, FingerQ;
    Checks = 0; Failures = 0;
    Pose = new(self) class'VRReloadHandPose';
    Finger = new(self) class'SkelControlSingleBone';
    Finger.BoneRotation = rot(1000,2000,3000);
    FingerQ = QuatFromRotator(Finger.BoneRotation);
    Pose.Controls.AddItem(Finger);
    VisibleQ = QuatFromRotator(rot(4000,5000,6000));
    Pose.LastWrist = vect(13,27,41); Pose.LastWristQ = VisibleQ;
    Pose.bVisible = true; Pose.bWasHeld = true; Pose.TransitionTime = 1;
    Pose.ReleaseFingers.AddItem(VisibleQ);
    Pose.Start(10);
    Check(Pose.TransitionTime == 10, "already-held carry restarts acquisition time");
    Check(Pose.bWasHeld && Pose.bVisible, "guide acquisition retains visible ownership state");
    Check(Pose.bAcquireSnapshot, "visible carry schedules previous wrist snapshot");
    Check(Pose.LastWrist == vect(13,27,41)
        && Abs(Pose.LastWristQ.W - VisibleQ.W) < 0.0001,
        "restart preserves previous wrist instead of snapping it");
    Check(Pose.AcquireFingers.Length == 1, "visible finger control is captured");
    Check(Abs(Pose.AcquireFingers[0].W - FingerQ.W) < 0.0001,
        "capture uses rendered finger rotation");
    Check(Pose.ReleaseFingers.Length == 0, "new capture retires release blend");
    Finger.BoneRotation = rot(9000,8000,7000);
    FingerQ = QuatFromRotator(Finger.BoneRotation);
    Pose.Start(11);
    Check(Pose.TransitionTime == 11 && Pose.AcquireFingers.Length == 1,
        "repeated capture replaces rather than appends snapshot");
    Check(Abs(Pose.AcquireFingers[0].W - FingerQ.W) < 0.0001,
        "repeated capture follows current rendered fingers");
    Pose.Cancel();
    Check(!Pose.bVisible && !Pose.bWasHeld && !Pose.bAcquireSnapshot
        && Pose.AcquireFingers.Length == 0 && Pose.ReleaseFingers.Length == 0,
        "cancel releases transient presentation state");
    Pose.Start(12);
    Check(!Pose.bAcquireSnapshot && Pose.AcquireFingers.Length == 0,
        "invisible reentry cannot inherit a stale visible pose");
    `log("KF2VR_RELOAD_STATE secondary-pose checks=" $ Checks @ "failures=" $ Failures);
}
