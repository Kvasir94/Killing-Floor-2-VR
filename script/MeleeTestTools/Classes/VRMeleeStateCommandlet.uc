// Optional SDK-only fixture. Calls production recovery; no gameplay grants.
class VRMeleeStateCommandlet extends Commandlet;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_MELEE_STATE FAIL " $ Label); }
}

event int Main(string Params)
{
    local VRPhysicalMelee M, Other;
    local VRPhysicalFist Left, Right;
    M = new(self) class'VRPhysicalMelee';
    Other = new(self) class'VRPhysicalMelee';
    M.CurrentHead[0] = vect(-30,0,0); M.CurrentHead[1] = vect(0,0,0); M.CurrentHead[2] = vect(30,0,0);
    M.Cancel();
    Check(!M.bHavePose && !M.bReady && M.bResetOnEligible, "cancel cannot sweep old pose");
    M.SeedRecoveryPose();
    Check(!M.bRequireSettle && !M.CanRearm(10), "eligible pose seeds without granting attack");
    M.CurrentHead[0] = vect(-30,-18,0); M.CurrentHead[2] = vect(30,18,0);
    Check(M.CanRearm(10) && M.ResetDisplacement() == 18, "pivot rearms with stationary midpoint");
    Check(!Other.CanRearm(10), "second sampler state remains independent");
    M.EndSwing(10, M.CurrentHead[1]);
    M.CurrentHead[0].Y -= 20; M.CurrentHead[2].Y += 20;
    Check(!M.CanRearm(10.05) && M.CanRearm(10.2), "travel cannot bypass contact cooldown");
    M.bSwing = true; M.HitsThisSwing = 1; M.bHavePose = true; M.bCandidate = true;
    M.Interrupt(11);
    Check(!M.bHavePose && !M.bSwing && !M.bCandidate && !M.bReady, "hitch drops active sweep");
    Check(M.NextSwingTime >= 11 + M.RecoveryTime, "interrupted hit retains recovery");
    M.SeedRecoveryPose();
    Check(M.ResetDisplacement() == 0 && !M.CanRearm(12), "hitch cannot hit across rejected gap");
    M.CurrentHead[0].Y += 20; M.CurrentHead[2].Y -= 20;
    Check(!M.CanRearm(11.01) && M.CanRearm(12), "continuous valid movement recovers after hitch");
    M.Cancel(); M.SeedRecoveryPose(); M.QuietTime = M.SettleTime;
    Check(M.CanRearm(12), "quiet recovery still supported");
    Left = new(self) class'VRPhysicalFist'; Right = new(self) class'VRPhysicalFist';
    Right.bPunching = true; Right.bReady = true; Right.NextPunchTime = 7;
    Left.Cancel();
    Check(Left.bResetOnClench && !Left.bHavePose, "fist occupancy loss seeds next eligible clench");
    Check(Right.bPunching && Right.bReady && Right.NextPunchTime == 7, "one fist cancellation leaves other untouched");
    `log("KF2VR_MELEE_STATE checks=" $ Checks $ " failures=" $ Failures);
    return Failures == 0 ? 0 : 1;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
