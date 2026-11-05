// Authority-only target eligibility; physical containment is the map's native
// KFPawnBlockingVolumes. Keep every zed's original specialized controller.
class KF2VRRangeArena extends Actor;

struct ProtectedHuman
{
    var KFPawn_Human Human;
    var bool PreviousIgnore;
};
var array<ProtectedHuman> ProtectedHumans;

function bool InsideArena(vector At)
{
    return At.X >= -300 && At.X <= 2600 && At.Y >= 700 && At.Y <= 2300;
}

function UpdateEligibility()
{
    local KFPawn_Human Human;
    local KFAIController AI;
    local ProtectedHuman Entry;
    local int I;
    local bool Changed;
    if(Role != ROLE_Authority) return;

    for(I=ProtectedHumans.Length-1;I>=0;--I)
    {
        Human=ProtectedHumans[I].Human;
        if(Human == None || Human.bDeleteMe || Human.Health <= 0 || InsideArena(Human.Location))
        {
            if(Human != None) Human.bAIZedsIgnoreMe=ProtectedHumans[I].PreviousIgnore;
            ProtectedHumans.Remove(I,1);
            Changed=true;
        }
    }
    foreach WorldInfo.AllPawns(class'KFPawn_Human',Human)
    {
        if(Human.Health <= 0 || Human.bDeleteMe || InsideArena(Human.Location)) continue;
        for(I=0;I<ProtectedHumans.Length;++I)
            if(ProtectedHumans[I].Human == Human) break;
        if(I < ProtectedHumans.Length) continue;
        Entry.Human=Human;
        Entry.PreviousIgnore=Human.bAIZedsIgnoreMe;
        ProtectedHumans.AddItem(Entry);
        Human.bAIZedsIgnoreMe=true;
        Changed=true;
    }
    if(!Changed) return;

    // A boundary crossing invalidates an existing pursuit once. Subsequent
    // stock acquisition calls reject protected pawns via CanAITargetThisPawn.
    foreach WorldInfo.AllControllers(class'KFAIController',AI)
    {
        Human=KFPawn_Human(AI.Enemy);
        if(Human != None && !InsideArena(Human.Location))
        {
            if(AI.MyKFPawn != None) AI.MyKFPawn.ClearHeadTrackTarget(Human);
            AI.Enemy=None;
            AI.Focus=None;
            AI.AbortMovementCommands();
            AI.AbortMovementPlugIns();
            AI.MoveTarget=None;
            if(AI.Pawn != None) AI.Pawn.Acceleration=vect(0,0,0);
        }
        if(AI.Enemy == None && AI.Pawn != None && AI.Pawn.Health > 0) AI.FindNewEnemy();
    }
}

event Destroyed()
{
    local int I;
    for(I=0;I<ProtectedHumans.Length;++I)
        if(ProtectedHumans[I].Human != None)
            ProtectedHumans[I].Human.bAIZedsIgnoreMe=ProtectedHumans[I].PreviousIgnore;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
