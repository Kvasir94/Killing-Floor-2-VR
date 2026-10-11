// Eligibility for tracked strikes and player-owned body grabs, not stock fire.
// Never changes a special move, its locks, damage rules or release conditions.
class VRPhysicalInteraction extends Object;

struct InteractionState
{
    var bool bAlive, bIncapacitated, bNoWeaponFiring;
    var bool bHasMove, bOwnedMove, bZedRestraint, bMoveBlocksWeapons;
};

static function bool IsRestraintClass(class<KFSpecialMove> MoveClass)
{
    // Includes disabled, Hans/Patriarch/tentacle, DAR EMP and gorge variants,
    // and subclasses. No enemy-class or enum-handle allowlist.
    return MoveClass != None && ClassIsChildOf(MoveClass, class'KFSM_GrappleVictim');
}

static function ReadState(KFPawn_Human Human, out InteractionState S)
{
    local KFSpecialMove Move;
    local KFSM_GrappleVictim Restraint;
    local KFPawn_Monster Leader;
    local InteractionState Empty;
    S = Empty;
    if (Human == None) return;
    S.bAlive = !Human.bDeleteMe && Human.Health > 0 && !Human.bPlayedDeath;
    S.bIncapacitated = Human.Physics == PHYS_RigidBody
        || Human.IsDoingSpecialMove(SM_Knockdown) || Human.IsDoingSpecialMove(SM_RecoverFromRagdoll)
        || Human.IsDoingSpecialMove(SM_DeathAnim) || Human.IsDoingSpecialMove(SM_Stunned)
        || Human.IsDoingSpecialMove(SM_Frozen);
    S.bNoWeaponFiring = Human.bNoWeaponFiring;
    S.bHasMove = Human.IsDoingSpecialMove();
    if (!S.bHasMove || int(Human.SpecialMove) >= Human.SpecialMoves.Length) return;
    Move = Human.SpecialMoves[Human.SpecialMove];
    S.bOwnedMove = Move != None && Move.KFPOwner == Human && Move.PawnOwner == Human;
    if (!S.bOwnedMove) return;
    S.bMoveBlocksWeapons = Move.bDisableWeaponInteraction || Move.bDisablesWeaponFiring;
    if (!IsRestraintClass(Move.Class)) return;
    Restraint = KFSM_GrappleVictim(Move);
    Leader = KFPawn_Monster(Restraint.Leader);
    S.bZedRestraint = Leader != None && Leader == Human.InteractionPawn
        && !Leader.bDeleteMe && Leader.Health > 0 && !Leader.bPlayedDeath;
    if (!S.bZedRestraint) S.bOwnedMove = false;
}

static function bool AllowsState(InteractionState S)
{
    if (!S.bAlive || S.bIncapacitated) return false;
    if (S.bHasMove)
    {
        if (!S.bOwnedMove) return false;
        if (S.bZedRestraint) return true;
        if (S.bMoveBlocksWeapons) return false;
    }
    return !S.bNoWeaponFiring;
}

static function bool Allowed(KFPawn_Human Human)
{
    local InteractionState S;
    ReadState(Human, S);
    return AllowsState(S);
}

static function bool Restrained(KFPawn_Human Human)
{
    local InteractionState S;
    ReadState(Human, S);
    return AllowsState(S) && S.bHasMove && S.bOwnedMove && S.bZedRestraint;
}

static function bool BashStateAllowed(name State, bool bRestrained)
{
    return State != 'Inactive' && State != 'WeaponEquipping' && State != 'WeaponPuttingDown'
        && State != 'WeaponAbortEquip' && State != 'WeaponThrowing'
        && (State != 'WeaponDownSimple' || bRestrained);
}
