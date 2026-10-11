// Optional, owner-routed wrist utility. No weapon swap or stock weapon ammo.
// Desktop and tracked-hand commands enter the same authority transaction.
class BreacherArcFence extends Actor;

var BreacherArcGroup ActiveGroup;
var float NextCommandTime;
var float PlacementRange;
var repnotify int EventSequence;
var repnotify int EventSecond;
var repnotify byte EventKind, EventHand;
var byte LastAcceptedHand;
var float NextImpactFeedback;
var float EventReceivedAt;

replication
{
    if (bNetDirty && bNetOwner) EventSequence, EventSecond, EventKind, EventHand;
}

// Only accepted authority transitions publish feedback. Rejected commands and
// client predictions cannot produce a success pulse.
function EmitPresentationEvent(byte Kind, optional byte Hand=254)
{
    if (Role!=ROLE_Authority || Kind<1 || Kind>6) return;
    if (Kind==4)
    {
        if (WorldInfo.TimeSeconds<NextImpactFeedback) return;
        NextImpactFeedback=WorldInfo.TimeSeconds+0.12;
    }
    EventSequence=(EventSequence+1)%1000000;
    EventKind=Kind;
    EventHand=255;
    if (Hand==254) EventHand=LastAcceptedHand;
    else if (Hand<2) EventHand=Hand;
    EventReceivedAt=WorldInfo.RealTimeSeconds;
    EventSecond=WorldInfo.GRI!=None ? WorldInfo.GRI.ElapsedTime : -1;
    bNetDirty=true;
    bForceNetUpdate=true;
}

simulated event ReplicatedEvent(name PropertyName)
{
    if (PropertyName=='EventSequence')
    {
        EventReceivedAt=WorldInfo.RealTimeSeconds;
        if (EventSecond<0 || WorldInfo.GRI==None || WorldInfo.GRI.ElapsedTime-EventSecond>1)
            EventReceivedAt=-1000;
    }
    else Super.ReplicatedEvent(PropertyName);
}

function bool Available()
{
    local KFPlayerController PC;
    local KFInventoryManager Inv;
    PC = KFPlayerController(Owner);
    if (PC == None || PC.Pawn == None || PC.Pawn.Health <= 0
        || PC.Pawn.bDeleteMe || BreacherPerk(PC.CurrentPerk) == None) return false;
    Inv = KFInventoryManager(PC.Pawn.InvManager);
    return Inv != None && !Inv.bServerTraderMenuOpen;
}

static function bool FiniteBounded(vector V, float Limit)
{
    return V.X >= -Limit && V.X <= Limit && V.Y >= -Limit && V.Y <= Limit
        && V.Z >= -Limit && V.Z <= Limit && VSizeSq(V) <= Limit * Limit;
}

function Feedback(string Message)
{
    if (PlayerController(Owner) != None) PlayerController(Owner).ClientMessage("ArcFence: " $ Message);
}

function bool Place(vector Origin, vector Direction, optional byte Hand=255)
{
    local vector Point, HitNormal;
    local Actor Target;
    local TraceHitInfo Hit;
    local KFInventoryManager Inv;
    local Pawn P;
    local KFPawn K;
    local int Zone;
    P = PlayerController(Owner).Pawn;
    Inv = KFInventoryManager(P.InvManager);
    if (Inv.GrenadeCount <= 0) { Feedback("no charges"); return false; }
    if (!FiniteBounded(Origin - P.Location, 240) || !FiniteBounded(Direction, 1.1)
        || VSizeSq(Direction) < 0.8) return false;
    // The accepted muzzle cannot reach through a nearby wall.
    if (P.Trace(Point, HitNormal, Origin, P.GetPawnViewLocation(), false, vect(2,2,2)) != None) return false;
    Target = P.Trace(Point, HitNormal, Origin + Normal(Direction) * PlacementRange,
        Origin, true, vect(0,0,0), Hit, TRACEFLAG_Bullet);
    if (Target == None || Target == P) return false;
    K=KFPawn(Target);
    if (K!=None && K.Mesh!=None && K.Mesh.PhysicsAsset!=None)
    {
        Zone=K.GetHitZoneIndex(Hit.BoneName);
        if (Zone!=INDEX_NONE) Hit.BoneName=K.HitZones[Zone].BoneName;
        if (Hit.BoneName!='') Hit.BoneName=K.GetRBBoneFromBoneName(Hit.BoneName);
        if (Hit.BoneName=='' && KFPawn_Monster(K)!=None)
            Hit.BoneName=class'BreacherPin'.static.BoneAt(KFPawn_Monster(K),Point);
    }
    if (ActiveGroup == None || ActiveGroup.bDeleteMe)
        ActiveGroup = class'BreacherArcGroup'.static.CreateFor(P, self);
    if (ActiveGroup == None || !ActiveGroup.AddEndpoint(Target, Hit.HitComponent, Hit.BoneName, Point, HitNormal))
        return false;
    Inv.ConsumeGrenades();
    LastAcceptedHand=Hand<2 ? Hand : 255;
    EmitPresentationEvent(1);
    Feedback("pin placed; " $ Inv.GrenadeCount $ " charges");
    return true;
}

reliable server function ServerCommand(byte Action, vector Origin, vector Direction, optional byte Hand=255)
{
    local Pawn P;
    local byte PreviousHand;
    if (Role != ROLE_Authority || WorldInfo.TimeSeconds < NextCommandTime) return;
    NextCommandTime = WorldInfo.TimeSeconds + 0.2;
    P = PlayerController(Owner) != None ? PlayerController(Owner).Pawn : None;
    // Escape remains available after changing perk or losing the utility.
    if (Action == 3 && P != None)
    {
        if (ActiveGroup != None) { ActiveGroup.Cancel(); ActiveGroup=None; }
        DetachPlayer(P);
        EmitPresentationEvent(3,255);
        return;
    }
    if (!Available()) return;
    if (Action == 0) { Place(Origin, Direction, Hand); return; }
    if (ActiveGroup == None || ActiveGroup.bDeleteMe) return;
    if (Action == 1)
    {
        // Collapse emits synchronously; restore attribution if it rejects.
        PreviousHand=LastAcceptedHand;
        LastAcceptedHand=Hand<2 ? Hand : 255;
        if (ActiveGroup.Collapse()) Feedback("Collapse");
        else LastAcceptedHand=PreviousHand;
    }
    else if (Action == 2)
    {
        ActiveGroup.Cancel();
        ActiveGroup = None;
        DetachPlayer(P);
        Feedback("released");
        EmitPresentationEvent(3,255);
    }
}

// Stock grenade-slot launch has already spent exactly one charge. This path
// retains the same authority/owner/range checks without charging a second time.
function bool AcceptProjectile(KFProj_Grenade Shot, Actor Target, PrimitiveComponent Component, vector Point, optional vector SurfaceNormal)
{
    local Pawn P;
    local name Bone;
    if (Role != ROLE_Authority || !Available() || Shot == None) return false;
    P=PlayerController(Owner).Pawn;
    if (Shot.Instigator!=P || Target==P || VSizeSq(Point-P.Location)>Square(PlacementRange)) return false;
    if (KFPawn_Monster(Target)!=None) Bone=class'BreacherPin'.static.BoneAt(KFPawn_Monster(Target), Point);
    if (ActiveGroup==None || ActiveGroup.bDeleteMe)
    {
        ActiveGroup=class'BreacherArcGroup'.static.CreateFor(P,self);
        LastAcceptedHand=255;
    }
    if (ActiveGroup==None || !ActiveGroup.AddEndpoint(Target,Component,Bone,Point,SurfaceNormal)) return false;
    EmitPresentationEvent(1,255);
    return true;
}

function DetachPlayer(Pawn P)
{
    local BreacherArcGroup G;
    foreach DynamicActors(class'BreacherArcGroup', G) G.DetachPlayer(P);
}

// Collision is disabled. These explicit adapter calls avoid a hard KF2VR
// package dependency; the actor owns the RPC and the server repeats all checks.
simulated function byte InputHand()
{
    if (DrawScale==1) return 0;
    if (DrawScale==2) return 1;
    return 255;
}

simulated event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    if (Other != None && Other.IsA('VRHandsBridge') && PlayerController(Owner) != None
        && Other.Owner == PlayerController(Owner).Pawn)
        ServerCommand(0, HitLocation, HitNormal, InputHand());
}

simulated event Bump(Actor Other, PrimitiveComponent OtherComp, vector HitNormal)
{
    if (Other != None && Other.IsA('VRHandsBridge') && PlayerController(Owner) != None
        && Other.Owner == PlayerController(Owner).Pawn)
        ServerCommand(1, vect(0,0,0), vect(0,0,0), InputHand());
}

simulated event UnTouch(Actor Other)
{
    local vector Reply;
    // Read-only optional-package bridge. The local owner queries the replicated
    // event through stock fields; the existing bridge-actor cancel remains below.
    if (Other==Owner && PlayerController(Other)!=None && PlayerController(Other).IsLocalPlayerController())
    {
        SetDrawScale(EventSequence+1);
        Reply.X=EventKind+1;
        Reply.Y=EventHand+1;
        Reply.Z=EventReceivedAt+1;
        SetDrawScale3D(Reply);
        return;
    }
    if (Other != None && Other.IsA('VRHandsBridge') && PlayerController(Owner) != None
        && Other.Owner == PlayerController(Owner).Pawn)
        ServerCommand(2, vect(0,0,0), vect(0,0,0));
}

simulated function bool UsedBy(Pawn User)
{
    if (PlayerController(Owner) == None || PlayerController(Owner).Pawn != User) return false;
    ServerCommand(3, vect(0,0,0), vect(0,0,0));
    return true;
}

event Tick(float Delta)
{
    if (Role != ROLE_Authority) return;
    if (Owner == None || Owner.bDeleteMe) { Destroy(); return; }
    if (!Available() && ActiveGroup != None)
    {
        ActiveGroup.Cancel();
        ActiveGroup = None;
    }
}

event Destroyed()
{
    if (Role == ROLE_Authority && ActiveGroup != None) ActiveGroup.Cancel();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    bCollideActors=false
    bBlockActors=false
    PlacementRange=1500
    NetUpdateFrequency=2
    LastAcceptedHand=255
    EventHand=255
    bHidden=true
}
