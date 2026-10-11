// Optional SDK-only fixture. Calls production recovery; no gameplay grants.
class VRMeleeStateCommandlet extends Commandlet dependson(VRPhysicalInteraction);

var int Checks, Failures;

function CheckInteraction()
{
    local VRPhysicalInteraction.InteractionState S, T;
    local class<KFSpecialMove> Moves[5];
    local int I;
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
