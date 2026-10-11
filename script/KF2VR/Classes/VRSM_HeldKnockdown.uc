// Stock ragdoll knockdown with a hold gate. A physics grab keeps an ordinary
// zed down without damage by refusing every stock recovery trigger while at
// least one hand holds it; the final release hands off to the normal
// SM_RecoverFromRagdoll path exactly once. Nothing else about the move changes.
class VRSM_HeldKnockdown extends KFSM_RagdollKnockdown;

// One owning player, but that player may hold with both hands.
var int HoldCount;

// Stock grapple refuses knockdown chaining even though damage can interrupt
// it. Only the ordinary stock move with its live reciprocal human victim may
// yield to a physical hold; stronger derived grabs keep their own rules.
static function bool HasBreakableGrapple(KFPawn_Monster M)
{
    local KFSM_GrappleCombined Grapple;
    local KFSM_GrappleVictim Victim;
    local KFPawn_Human Human;
    if (M == None || M.bDeleteMe || M.Health <= 0 || M.bPlayedDeath
        || M.IsABoss() || KFPawn_MonsterBoss(M) != None || KFInterface_MonsterBoss(M) != None
        || !M.IsDoingSpecialMove(SM_GrappleAttack)
        || M.SpecialMoves.Length <= SM_GrappleAttack) return false;
    Grapple = KFSM_GrappleCombined(M.SpecialMoves[SM_GrappleAttack]);
    if (Grapple == None || Grapple.Class != class'KFSM_GrappleCombined' || !Grapple.bCanBeInterrupted
        || Grapple.KFPOwner != M || Grapple.PawnOwner != M) return false;
    Human = KFPawn_Human(Grapple.Follower);
    if (Human == None || Human.bDeleteMe || Human.Health <= 0 || Human.bPlayedDeath
        || M.InteractionPawn != Human || Human.InteractionPawn != M
        || !Human.IsDoingSpecialMove(SM_GrappleVictim)
        || Human.SpecialMoves.Length <= SM_GrappleVictim) return false;
    Victim = KFSM_GrappleVictim(Human.SpecialMoves[SM_GrappleVictim]);
    return Victim != None && Victim.KFPOwner == Human && Victim.PawnOwner == Human
        && Victim.Leader == M;
}

// Query admission without installing our move on candidates that the hand has
// not contacted. The handler instances knockdown before checking chaining, so
// its instance can still enforce the stock ragdoll cap and internal eligibility.
static function bool CanStart(KFPawn_Monster M)
{
    if (M == None || M.bDeleteMe) return false;
    if (M.CanDoSpecialMove(SM_Knockdown, true)) return true;
    if (!HasBreakableGrapple(M) || M.SpecialMoves.Length <= SM_Knockdown
        || M.SpecialMoves[SM_Knockdown] == None) return false;
    return M.SpecialMoves[SM_Knockdown].CanDoSpecialMove(true);
}

function bool CanOverrideSpecialMove(name InMove)
{
    if (InMove == class'KFSM_GrappleCombined'.default.Handle
        && HasBreakableGrapple(KFPawn_Monster(KFPOwner))) return true;
    return Super.CanOverrideSpecialMove(InMove);
}

// Stock drives recovery from a 1.5s timer and a 0.2s rest test, both of which
// call this. Returning early leaves those timers armed, so a released zed
// recovers on the next tick of the existing schedule as well as from the
// explicit release below.
protected function EndKnockdown(optional bool bForceEnd = false)
{
    if (HoldCount > 0) return;
    Super.EndKnockdown(bForceEnd);
}

function AddHold()
{
    ++HoldCount;
}

// Releasing the final hand grants immediate eligibility for stock recovery.
// There is no fabricated remaining knockdown duration to restore. A thrown
// Zed is the exception: it is left to land, and the stock rest test -- still
// running every 0.2 s -- gets it up once it stops, rather than a get-up
// starting in mid-air. Its test count restarts so the stock failsafe cap
// still applies to the flight.
function ReleaseHold(optional bool bLetFly)
{
    if (HoldCount <= 0) return;
    if (--HoldCount > 0) return;
    if (bLetFly) { CurrentKnockdownTests = 0; return; }
    EndKnockdown(true);
}

function ReleaseAllHolds()
{
    if (HoldCount <= 0) return;
    HoldCount = 0;
    EndKnockdown(true);
}

function SpecialMoveEnded(Name PrevMove, Name NextMove)
{
    HoldCount = 0;
    Super.SpecialMoveEnded(PrevMove, NextMove);
}

// Substitute this move on one pawn only. The handler may already hold a stock
// instance, so clearing SpecialMoveClasses alone is not enough; the cached
// instance is dropped too, and only while the pawn is not mid-knockdown.
static function bool Install(KFPawn_Monster M)
{
    if (M == None || M.bDeleteMe || M.SpecialMoveHandler == None) return false;
    if (M.SpecialMoveHandler.SpecialMoveClasses.Length <= SM_Knockdown) return false;
    if (M.SpecialMoveHandler.SpecialMoveClasses[SM_Knockdown] == class'VRSM_HeldKnockdown')
        return true;
    if (M.IsDoingSpecialMove(SM_Knockdown)) return false;
    M.SpecialMoveHandler.SpecialMoveClasses[SM_Knockdown] = class'VRSM_HeldKnockdown';
    if (M.SpecialMoves.Length > SM_Knockdown) M.SpecialMoves[SM_Knockdown] = None;
    return true;
}

static function VRSM_HeldKnockdown Current(KFPawn_Monster M)
{
    if (M == None || M.bDeleteMe || !M.IsDoingSpecialMove(SM_Knockdown)) return None;
    if (M.SpecialMoves.Length <= SM_Knockdown) return None;
    return VRSM_HeldKnockdown(M.SpecialMoves[SM_Knockdown]);
}

defaultproperties
{
}
