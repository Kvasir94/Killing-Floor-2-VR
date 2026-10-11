// Authority owns pressure and kinetic propagation. No movement/camera changes.
// Stock callback bridge: Bump = physical impulse received/dealt, Touch = spend.
// DrawScale is synchronous spend acknowledgement; Pressure is owner-replicated.
class BreacherOverpressure extends Actor;

struct ContactStamp { var Actor Target; var float Time; };
struct MovingBody
{
    var KFPawn_Monster Body;
    var vector Previous;
    var float Until;
    var int Depth;
};
var repnotify float Pressure;
var array<ContactStamp> Contacts;
var array<ContactStamp> Suppressed;
var array<MovingBody> Moving;
var array<KFPawn_Monster> ChainTargets;
var Pawn SessionPawn;
var float NextBowl, ChainUntil, LastFeedback;
var bool bApplying;

replication { if (bNetDirty && bNetOwner) Pressure; }

static function BreacherOverpressure ForPlayer(Controller C)
{
    local BreacherOverpressure S;
    if (C == None || C.Role != ROLE_Authority) return None;
    foreach C.DynamicActors(class'BreacherOverpressure', S)
        if (S.Owner == C) return S;
    return C.Spawn(class'BreacherOverpressure', C);
}

simulated function bool Selected()
{
    local KFPlayerController PC;
    local BreacherPerk P;
    PC = KFPlayerController(Owner);
    if (PC == None || PC.Pawn == None || PC.Pawn.Health <= 0 || PC.Pawn.bDeleteMe) return false;
    P = BreacherPerk(PC.CurrentPerk);
    return P != None && P.SkillActive(9);
}

simulated function bool Active() { return Selected() && WorldInfo.TimeDilation < 1; }

static function bool Boss(KFPawn_Monster M)
{
    return M == None || M.IsABoss() || KFPawn_MonsterBoss(M) != None || KFInterface_MonsterBoss(M) != None;
}

function bool Hostile(KFPawn_Monster M)
{
    return !Boss(M) && !M.bDeleteMe && M.Health > 0 && SessionPawn != None
        && M.GetTeamNum() != SessionPawn.GetTeamNum();
}

function bool SuppressedTarget(Actor Other)
{
    local int I;
    for (I = Suppressed.Length - 1; I >= 0; --I)
    {
        if (Suppressed[I].Target == None || WorldInfo.TimeSeconds > Suppressed[I].Time) Suppressed.Remove(I,1);
        else if (Suppressed[I].Target == Other) return true;
    }
    return false;
}

function Suppress(Actor Other, float Duration)
{
    local ContactStamp S;
    S.Target=Other; S.Time=WorldInfo.TimeSeconds+Duration;
    if (Suppressed.Length >= 32) Suppressed.Remove(0,1);
    Suppressed.AddItem(S);
}

// Momentum comes from a validated physical contact, never the controller's
// animation or a velocity-difference guess. Repeat callbacks share one budget.
event Bump(Actor Other, PrimitiveComponent OtherComp, vector HitNormal)
{
    local int I;
    local float Size, Before;
    local ContactStamp S;
    if (Role != ROLE_Authority || !Active() || bApplying || Other == None || SuppressedTarget(Other)) return;
    Size=VSize(HitNormal);
    if (!(Size >= 160 && Size <= 100000)) return;
    for (I=Contacts.Length-1; I>=0; --I)
    {
        if (Contacts[I].Target == None || WorldInfo.TimeSeconds-Contacts[I].Time > 0.25) Contacts.Remove(I,1);
        else if (Contacts[I].Target == Other) return;
    }
    S.Target=Other; S.Time=WorldInfo.TimeSeconds;
    if (Contacts.Length >= 32) Contacts.Remove(0,1);
    Contacts.AddItem(S);
    Before=Pressure;
    Pressure=FMin(100, Pressure+FClamp((Size-120)/30,4,25));
    bNetDirty=true;
    if (Before < 40 && Pressure >= 40) Feedback("pressure ready: non-boss grabs and head stun");
    else if (Before < 100 && Pressure >= 100) Feedback("pressure full");
}

event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    local float Stored;
    SetDrawScale(1);
    if (Role != ROLE_Authority || !Selected() || Other == None || Pressure <= 0
        || VSizeSq(HitNormal)<Square(160) || VSizeSq(HitNormal)>Square(100000)) return;
    Stored=Pressure;
    Pressure=0; bNetDirty=true;
    SetDrawScale(1+Stored/100);
    // The outgoing boosted contact and the thrown body's subsequent impacts
    // may do work, but cannot re-fill the energy they have just spent.
    Suppress(Other,5);
    Feedback("pressure released");
}

simulated event UnTouch(Actor Other)
{
    SetDrawScale(1+FClamp(Pressure,0,100)/100);
}

function Feedback(string Text)
{
    if (PlayerController(Owner) != None) PlayerController(Owner).ClientMessage("Overpressure: " $ Text);
}

function Bowl(Actor Other, vector PlayerVelocity, rotator PlayerFacing)
{
    local KFPawn_Monster M;
    if (Role != ROLE_Authority || !Active()) return;
    SessionPawn=Controller(Owner).Pawn;
    M=KFPawn_Monster(Other);
    // Actual walking/sprinting contact, not a stationary overlap or arrival.
    if (!Hostile(M) || SessionPawn.Physics != PHYS_Walking || VSize(PlayerVelocity)<180
        || Normal(PlayerVelocity) dot vector(PlayerFacing)<0.7 || WorldInfo.TimeSeconds<NextBowl) return;
    if (WorldInfo.TimeSeconds>ChainUntil) { ChainTargets.Length=0; Moving.Length=0; }
    if (ChainTargets.Find(M)!=INDEX_NONE || ChainTargets.Length>=8) return;
    NextBowl=WorldInfo.TimeSeconds+0.12;
    ChainUntil=WorldInfo.TimeSeconds+1.25;
    Bump(M,None,PlayerVelocity);
    Launch(M,Normal(PlayerVelocity)*FMin(VSize(PlayerVelocity)*2.5,1000),0);
}

function Launch(KFPawn_Monster M, vector Motion, int Depth)
{
    local MovingBody T;
    if (!Hostile(M) || ChainTargets.Find(M)!=INDEX_NONE || ChainTargets.Length>=8) return;
    ChainTargets.AddItem(M);
    bApplying=true;
    M.TakeDamage(35,Controller(Owner),M.Location,Motion,class'BreacherOverpressureDamage',,SessionPawn);
    if (M.Health>0 && !M.IsHeadless() && !M.HasInjuredHitZones())
    {
        if (M.Physics==PHYS_RigidBody && M.Mesh!=None) M.Mesh.AddImpulse(Motion,M.Location,,true);
        else M.Knockdown(Motion,vect(0,0,0));
    }
    bApplying=false;
    T.Body=M; T.Previous=M.Location; T.Until=WorldInfo.TimeSeconds+1.25; T.Depth=Depth;
    Moving.AddItem(T);
}

event Tick(float Delta)
{
    local int I;
    local KFPawn_Monster M, Candidate;
    local vector Current, VelocityNow, Point, NormalHit;
    local Actor Hit;
    local RB_BodyInstance Root;
    if (Role!=ROLE_Authority) return;
    if (Owner==None || Owner.bDeleteMe) { Destroy(); return; }
    if (!Selected() || (SessionPawn!=None && Controller(Owner).Pawn!=SessionPawn))
    {
        if (Pressure>0) { Pressure=0; bNetDirty=true; }
        Moving.Length=0; ChainTargets.Length=0; Contacts.Length=0; Suppressed.Length=0;
        SessionPawn=Controller(Owner).Pawn;
        return;
    }
    SessionPawn=Controller(Owner).Pawn;
    if (!Active()) { Moving.Length=0; ChainTargets.Length=0; return; }
    for (I=Moving.Length-1; I>=0; --I)
    {
        M=Moving[I].Body;
        if (M==None || M.bDeleteMe || WorldInfo.TimeSeconds>Moving[I].Until || Moving[I].Depth>=3)
        { Moving.Remove(I,1); continue; }
        Current=M.Location;
        VelocityNow=M.Velocity;
        if (M.Physics==PHYS_RigidBody && M.Mesh!=None)
        {
            Root=M.Mesh.GetRootBodyInstance();
            if (Root!=None && Root.IsValidBodyInstance())
            {
                Current=MatrixGetOrigin(Root.GetUnrealWorldTM());
                VelocityNow=Root.GetUnrealWorldVelocity();
            }
        }
        if (VSize(Current-Moving[I].Previous)>200) { Moving.Remove(I,1); continue; }
        // Sweep the actual travelled segment; do not damage a cone or radius.
        if (VSizeSq(Current-Moving[I].Previous)>1 && VSize(VelocityNow)>180)
        {
            Hit=M.Trace(Point,NormalHit,Current,Moving[I].Previous,true,vect(18,18,25));
            Candidate=KFPawn_Monster(Hit);
            if (Hostile(Candidate) && ChainTargets.Find(Candidate)==INDEX_NONE
                && (Normal(VelocityNow) dot Normal(Candidate.Location-Current))>0)
            {
                Bump(Candidate,None,VelocityNow);
                Launch(Candidate,VelocityNow*0.7,Moving[I].Depth+1);
            }
        }
        Moving[I].Previous=Current;
    }
}

defaultproperties
{
    bHidden=true
    bOnlyRelevantToOwner=true
    RemoteRole=ROLE_SimulatedProxy
    NetUpdateFrequency=10
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    DrawScale=1
}
