// Optional SDK-only fixture. Calls production recovery; no gameplay grants.
class VRMeleeStateCommandlet extends Commandlet dependson(VRPhysicalInteraction);

var int Checks, Failures;

function CheckBashContactSpeed()
{
    local VRPhysicalBash B;
    local int I;
    B = new(self) class'VRPhysicalBash';
    // A pivot at the butt must not borrow the moving muzzle's speed.
    B.CurrentLocal[2] = vect(4,0,0);
    Check(Abs(B.PointContactSpeed(2, 0.01) - 400) < 0.01, "moving muzzle retains its own contact speed");
    Check(!B.AdmitsContactSpeed(B.PointContactSpeed(0, 0.01)), "stationary butt cannot borrow muzzle speed");
    B.CurrentLocal[2] = vect(0,0,0);
    B.CurrentLocal[0] = vect(4,0,0);
    Check(Abs(B.PointContactSpeed(0, 0.01) - 400) < 0.01, "moving butt retains its own contact speed");
    Check(!B.AdmitsContactSpeed(B.PointContactSpeed(2, 0.01)), "stationary muzzle cannot borrow butt speed");
    for (I = 0; I < 3; ++I)
    {
        B.CurrentLocal[I] = vect(3,0,0);
        Check(Abs(B.PointContactSpeed(I, 0.01) - 300) < 0.01, "translation speed preserved at point " $ I);
    }
    B.CandidateLocal[0] = vect(-100,0,0);
    Check(Abs(B.PointContactSpeed(0, 0.01) - 300) < 0.01, "windup path cannot inflate contact speed");
    B.CurrentLocal[0] = vect(0.5,0,0);
    Check(!B.AdmitsContactSpeed(B.PointContactSpeed(0, 0.01)), "slow contact rejected despite armed swing");
    Check(B.AdmitsContactSpeed(B.StopSpeed), "contact threshold remains inclusive");
    Check(!B.AdmitsContactSpeed(B.MaximumSpeed + 1), "impossible point speed rejected");
    Check(B.PointContactSpeed(0, 0) == 0 && B.PointContactSpeed(0, -1) == 0,
        "nonpositive sample interval cannot produce contact speed");
    Check(B.PointContactSpeed(0, B.MaximumSampleTime + 0.01) == 0,
        "hitch interval cannot produce contact speed");
    Check(B.PointContactSpeed(-1, 0.01) == 0 && B.PointContactSpeed(3, 0.01) == 0,
        "invalid sample point cannot produce contact speed");
    Check(class'VRPhysicalFist'.static.OrdinaryDamage(100) == 15,
        "ordinary fist bonus cannot exceed stock base bash");
    Check(class'VRPhysicalFist'.static.OrdinaryDamage(12) == 10,
        "ordinary fist reduction preserves weaker hits");
}

function CheckInteraction()
{
    local VRPhysicalInteraction.InteractionState S, T;
    local class<KFSpecialMove> Moves[5];
    local int I;
    local byte Attempt;
    Attempt = class'KFSM_GrappleCombined'.static.PackFlagsBase(None);
    Check(class'VRSM_HeldKnockdown'.static.UnattachedAttempt(Attempt, false, false),
        "ordinary missed grapple attempt can yield before animation ends");
    Check(!class'VRSM_HeldKnockdown'.static.UnattachedAttempt(Attempt, true, false),
        "partial follower attachment cannot use empty-attempt admission");
    Check(!class'VRSM_HeldKnockdown'.static.UnattachedAttempt(Attempt, false, true),
        "partial owner interaction cannot use empty-attempt admission");
    Check(!class'VRSM_HeldKnockdown'.static.UnattachedAttempt(Attempt, true, true),
        "connected grapple still requires reciprocal victim validation");
    Check(!class'VRSM_HeldKnockdown'.static.UnattachedAttempt(byte(Attempt + 1), false, false),
        "success without a victim is not an unattached attempt");
    Check(!class'VRSM_HeldKnockdown'.static.UnattachedAttempt(byte(Attempt + 2), false, false),
        "derived miss state is not an ordinary attempt");
    Check(!class'VRSM_HeldKnockdown'.static.UnattachedAttempt(255, false, false),
        "unknown grapple flags remain rejected");
    Moves[0] = class'KFSM_GrappleVictim';
    Moves[1] = class'KFSM_DisabledGrappleVictim';
    Moves[2] = class'KFSM_HansGrappleVictim';
    Moves[3] = class'KFSM_EvilDAR_EMPGrapple';
    Moves[4] = class'KFSM_BloatKingGorgeVictim';
    S.bAlive = true;
    Check(class'VRPhysicalInteraction'.static.AllowsState(S), "ordinary live interaction");
    S.bNoWeaponFiring = true;
    Check(!class'VRPhysicalInteraction'.static.AllowsState(S), "unowned firing lock stays locked");
    S.bHasMove = true; S.bOwnedMove = true; S.bMoveBlocksWeapons = true;
    for (I = 0; I < 5; ++I)
    {
        S.bZedRestraint = class'VRPhysicalInteraction'.static.IsRestraintClass(Moves[I]);
        Check(class'VRPhysicalInteraction'.static.AllowsState(S), "restraint family " $ Moves[I]);
    }
    Check(!class'VRPhysicalInteraction'.static.IsRestraintClass(class'KFSM_Knockdown'), "knockdown is not a restraint");
    T = S; T.bOwnedMove = false;
    Check(!class'VRPhysicalInteraction'.static.AllowsState(T), "missing or foreign move owner");
    T = S; T.bAlive = false;
    Check(!class'VRPhysicalInteraction'.static.AllowsState(T), "death wins over restraint");
    T = S; T.bIncapacitated = true;
    Check(!class'VRPhysicalInteraction'.static.AllowsState(T), "incapacitation wins over restraint");
    T = S; T.bZedRestraint = false;
    Check(!class'VRPhysicalInteraction'.static.AllowsState(T), "stale leader or unrelated locked move");
    T.bNoWeaponFiring = false;
    Check(!class'VRPhysicalInteraction'.static.AllowsState(T), "move interaction lock without firing flag");
    T.bMoveBlocksWeapons = false;
    Check(class'VRPhysicalInteraction'.static.AllowsState(T), "unlocked ordinary move");
    Check(class'VRPhysicalInteraction'.static.BashStateAllowed('WeaponDownSimple', true), "held gun during strong restraint");
    Check(!class'VRPhysicalInteraction'.static.BashStateAllowed('WeaponDownSimple', false), "ordinary lowered gun remains blocked");
    Check(!class'VRPhysicalInteraction'.static.BashStateAllowed('WeaponPuttingDown', true), "restraint cannot bash a switched-out gun");
    Check(!class'VRPhysicalInteraction'.static.BashStateAllowed('Inactive', true), "restraint cannot revive inactive gun");
    Check(!class'VRPhysicalInteraction'.static.BashStateAllowed('WeaponThrowing', true), "restraint cannot bash a thrown gun");
    Check(class'VRPhysicalInteraction'.static.BashStateAllowed('Reloading', false), "ordinary reload bash retained");
    Check(class'VRGrabTurnPreference'.static.AllowsTurn(false, true, false), "stock auto-turn enabled during ordinary grab");
    Check(!class'VRGrabTurnPreference'.static.AllowsTurn(true, true, false), "stock Disable Auto Turn suppresses grab turning");
    Check(!class'VRGrabTurnPreference'.static.AllowsTurn(false, true, true), "strong grab forced camera remains suppressed");
    Check(!class'VRGrabTurnPreference'.static.AllowsTurn(false, false, false), "setting does not enable unrelated forced look");
}

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_MELEE_STATE FAIL " $ Label); }
}

event int Main(string Params)
{
    local VRPhysicalMelee M, Other;
    local VRPhysicalFist Left, Right;
    CheckInteraction();
    CheckBashContactSpeed();
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
