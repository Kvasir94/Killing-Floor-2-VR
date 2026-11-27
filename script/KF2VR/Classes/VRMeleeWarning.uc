// Stock melee warning for a VR swing (melee plan Q7, #227). A stock attack's
// KFMeleeHelperWeapon.BeginMeleeAttack warns every AI Zed within reach on the
// server, which is how Scrakes, Fleshpounds, the Patriarch and Hans get their
// stock chance to block (KFAIController.ReceiveMeleeWarning, KFPawn_Monster
// CanBlock: difficulty chance, cooldown, no blocks from behind). VR swings
// never play the stock attack, so the swing start calls this instead.
class VRMeleeWarning extends Object dependson(KFPawn);

// The stock attack direction for a swing moving along BodyVelocity (in the
// player's body frame: X forward, Y right, Z up). Stock maps strafing left to
// a DIR_Right attack (KFMeleeHelperWeapon.ChooseAttackDir); a sideways sweep
// toward the player's left is that attack.
static function byte SwingDirection(vector BodyVelocity)
{
    local vector V;
    V = Normal(BodyVelocity);
    if (VSizeSq(V) < 0.25) return DIR_Forward;
    if (Abs(V.Y) > 0.6) return V.Y < 0 ? DIR_Right : DIR_Left;
    if (V.X < -0.5 || V.Z > 0.6) return DIR_Backward;
    if (V.Y < -0.35) return DIR_ForwardRight;
    if (V.Y > 0.35) return DIR_ForwardLeft;
    return DIR_Forward;
}

// Authority only, exactly the stock loop.
static function Warn(Pawn Attacker, KFWeapon W, byte Dir)
{
    local Pawn P;
    local KFPawn_Monster M;
    local vector Projection;
    local float Range;
    if (Attacker == None || W == None || W.MeleeAttackHelper == None || Attacker.Role != ROLE_Authority
        || Attacker.WorldInfo.NetMode == NM_Client || Dir > DIR_None) return;
    Range = W.MeleeAttackHelper.MaxHitRange;
    foreach Attacker.WorldInfo.AllPawns(class'Pawn', P)
    {
        if (P.GetTeamNum() == Attacker.GetTeamNum() || !P.IsAliveAndWell() || P.IsHumanControlled()) continue;
        Projection = Attacker.Location - P.Location;
        if (VSizeSq(Projection) > Square(Range + P.CylinderComponent.CollisionRadius)) continue;
        M = KFPawn_Monster(P);
        if (M != None && M.MyKFAIC != None) M.MyKFAIC.ReceiveMeleeWarning(EPawnOctant(Dir), Projection, Attacker);
    }
}
