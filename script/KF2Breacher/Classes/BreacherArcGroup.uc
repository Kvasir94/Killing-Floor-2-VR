// Authority-only graph/physics policy. Clients receive accepted anchors, edges
// and phase; they never infer damage from a visual line. All numbers are tuning
// defaults, not balance or in-game acceptance. Static hull, explicit membership
// and optional collected occupants are deliberately separate concepts.
class BreacherArcGroup extends Actor;

var array<BreacherArcAnchor> Anchors;
var array<BreacherArcAnchor> Hull;
var array<BreacherArcLink> Links;
var repnotify BreacherArcAnchor Destination;
var repnotify bool bCollapsing, bCompacting, bFinished;
var Pawn Shooter;
var Actor Tool;
var int PlacementSerial, MaxPins, MaxOccupants;
var float MaxSpan, PlacementRange, RestSeconds, GatherSeconds, CollapseSeconds;
var float PullAcceleration, MaxPullSpeed, NextUpdate, LastUpdate, NextExposure, NextCollection;
var float FirstLinkedTime, CollapseTime, MinimumArea, ZoneHalfHeight;
var float ImpactThreshold, ImpactScale, ImpactCap;
var float CompactionTime, CompactionSeconds, NextImpactEvent;
var bool bHaveLinked, bClosing;
var array<KFPawn_Monster> Mulched;
struct ArcCompression
{
    var BreacherArcAnchor Anchor;
    var float Started;
};
var array<ArcCompression> Compression;
struct ArcContact
{
    var Actor A,B;
    var float Until;
};
var array<ArcContact> Contacts;
struct ArcExposure
{
    var KFPawn_Monster Target;
    var float HealthRemainder, LastSeen;
};
var array<ArcExposure> Exposures;

replication
{
    if (bNetDirty) Destination, bCollapsing, bCompacting, bFinished;
}

static function BreacherArcGroup CreateFor(Pawn P, Actor OwningTool)
{
    local BreacherArcGroup G;
    if (P == None || P.Health <= 0 || P.WorldInfo.NetMode == NM_Client) return None;
    foreach P.DynamicActors(class'BreacherArcGroup', G)
        if (G.Shooter == P && !G.bDeleteMe) return None;
    G = P.Spawn(class'BreacherArcGroup', OwningTool,, P.Location);
    if (G != None) { G.Shooter=P; G.Instigator=P; G.Tool=OwningTool; }
    return G;
}

function bool AddEndpoint(Actor Target, PrimitiveComponent Component, name Bone, vector Point, optional vector SurfaceNormal)
{
    local int I, Pins;
    local BreacherArcAnchor A;
    if (Role != ROLE_Authority || bCollapsing || bFinished || Shooter == None || Shooter.Health <= 0) return false;
    if (VSizeSq(Point - Shooter.Location) > Square(PlacementRange)) return false;
    for (I=0; I<Anchors.Length; ++I)
    {
        if (!Anchors[I].bOccupant) ++Pins;
        // One explicit attachment per actor; an occupant can be promoted.
        if (Target != None && !Target.bWorldGeometry && !Target.bStatic && Anchors[I].Target == Target)
        {
            if (!Anchors[I].bOccupant) return false;
            Anchors[I].bOccupant=false;
            Anchors[I].Serial=++PlacementSerial;
            Anchors[I].bNetDirty=true;
            RebuildTopology();
            return true;
        }
        if (Anchors[I].bWorldAnchor && VSizeSq(Anchors[I].Location - Point)<64) return false;
    }
    if (Pins >= MaxPins) return false;
    A=Spawn(class'BreacherArcAnchor', self,, Point);
    if (A == None) return false;
    if (!A.Initialize(self,Target,Component,Bone,Point,false,SurfaceNormal)) { A.Destroy(); return false; }
    A.Serial=++PlacementSerial;
    Anchors.AddItem(A);
    RebuildTopology();
    TouchActivity();
    return true;
}

function TouchActivity()
{
    local int I;
    for (I=0; I<Anchors.Length; ++I) Anchors[I].LastActivity=WorldInfo.TimeSeconds;
}

// Newest surviving WORLD placement wins, as chosen by Justin. Dynamic ties
// use first placement; resistance stays meaningful without immobilizing it.
function BreacherArcAnchor ChooseDestination()
{
    local int I;
    local BreacherArcAnchor Best, A;
    for (I=0; I<Anchors.Length; ++I)
    {
        A=Anchors[I];
        if (A.bOccupant || A.bDeleteMe) continue;
        if (Best == None || (A.bWorldAnchor && (!Best.bWorldAnchor || A.Serial>Best.Serial))
            || (!A.bWorldAnchor && !Best.bWorldAnchor && (A.Resistance>Best.Resistance
                || (A.Resistance==Best.Resistance && A.Serial<Best.Serial)))) Best=A;
    }
    return Best;
}

function UpdateDestination()
{
    local int I;
    if (!bCollapsing || Destination == None || Destination.bDeleteMe || Anchors.Find(Destination)==INDEX_NONE)
        Destination=ChooseDestination();
    for (I=0; I<Anchors.Length; ++I)
    {
        Anchors[I].bDestination=Anchors[I]==Destination;
        Anchors[I].PresentationPhase=0;
        if (bFinished) Anchors[I].PresentationPhase=3;
        else if (bCompacting) Anchors[I].PresentationPhase=2;
        else if (bCollapsing) Anchors[I].PresentationPhase=1;
        Anchors[I].bNetDirty=true;
    }
    bNetDirty=true;
}

static function float Cross2(vector A, vector B, vector C)
{
    return (B.X-A.X)*(C.Y-A.Y)-(B.Y-A.Y)*(C.X-A.X);
}

// Jarvis hull in XY from STATIC world pins only. Moving explicit members never
// become corners. Collinear/vertical layouts retain graph pulls without a zone.
function BuildHull()
{
    local array<BreacherArcAnchor> WorldPins;
    local int I, Start, Current, Next, Guard;
    local float Turn;
    Hull.Length=0;
    for (I=0; I<Anchors.Length; ++I)
        if (Anchors[I].bWorldAnchor && !Anchors[I].bOccupant) WorldPins.AddItem(Anchors[I]);
    if (WorldPins.Length<3) { Hull=WorldPins; return; }
    for (I=1; I<WorldPins.Length; ++I)
        if (WorldPins[I].Location.X<WorldPins[Start].Location.X
            || (WorldPins[I].Location.X==WorldPins[Start].Location.X && WorldPins[I].Location.Y<WorldPins[Start].Location.Y)) Start=I;
    Current=Start;
    for (Guard=0; Guard<WorldPins.Length; ++Guard)
    {
        Hull.AddItem(WorldPins[Current]);
        Next=(Current+1)%WorldPins.Length;
        for (I=0; I<WorldPins.Length; ++I)
        {
            if (I==Current) continue;
            Turn=Cross2(WorldPins[Current].Location,WorldPins[Next].Location,WorldPins[I].Location);
            if (Turn<0 || (Abs(Turn)<0.01 && VSizeSq(WorldPins[I].Location-WorldPins[Current].Location)
                > VSizeSq(WorldPins[Next].Location-WorldPins[Current].Location))) Next=I;
        }
        Current=Next;
        if (Current==Start) break;
    }
}

function BreacherArcLink FindLink(BreacherArcAnchor A, BreacherArcAnchor B)
{
    local int I;
    for (I=0; I<Links.Length; ++I)
        if ((Links[I].A==A && Links[I].B==B) || (Links[I].A==B && Links[I].B==A)) return Links[I];
    return None;
}

function bool LinkClear(BreacherArcAnchor A, BreacherArcAnchor B)
{
    local Actor Hit;
    local vector Pos, Norm;
    local TraceHitInfo Info;
    if (A==None || B==None) return false;
    // World geometry plus closed movable doors/props block; crossing pawns do
    // not cut power. Endpoint surfaces themselves are valid terminal contacts.
    foreach TraceActors(class'Actor',Hit,Pos,Norm,B.Location,A.Location,vect(0,0,0),Info)
    {
        if (Hit==A.Target || Hit==B.Target || Pawn(Hit)!=None || Hit==self
            || BreacherArcAnchor(Hit)!=None || BreacherArcLink(Hit)!=None) continue;
        if (Hit.bWorldGeometry || Hit.bBlockActors)
        {
            if (VSizeSq(Pos-A.Location)>16 && VSizeSq(Pos-B.Location)>16) return false;
        }
    }
    return FastTrace(B.Location+Normal(A.Location-B.Location)*2,A.Location+Normal(B.Location-A.Location)*2);
}

function AddLink(BreacherArcAnchor A, BreacherArcAnchor B)
{
    local BreacherArcLink L;
    if (A==None || B==None || A==B || FindLink(A,B)!=None || VSizeSq(A.Location-B.Location)>Square(MaxSpan)) return;
    L=Spawn(class'BreacherArcLink',self,, A.Location);
    if (L==None) return;
    L.Group=self; L.A=A; L.B=B;
    Links.AddItem(L);
    // New accepted topology (placement or first collection), never a periodic
    // refresh, is what grants a disconnected participant a new lifetime.
    A.bDisconnected=false; B.bDisconnected=false;
    L.Refresh();
}

function RebuildTopology()
{
    local int I,J;
    local float Distance, BestDistance;
    local BreacherArcAnchor Best;
    // Re-authoring topology is deliberate only on placement/promotion. An
    // obstructed edge is never silently resurrected by the periodic update.
    for (I=0; I<Links.Length; ++I) Links[I].Destroy();
    Links.Length=0;
    BuildHull();
    for (I=1; I<Hull.Length; ++I) AddLink(Hull[I-1],Hull[I]);
    if (Hull.Length>2) AddLink(Hull[Hull.Length-1],Hull[0]);
    for (I=0; I<Anchors.Length; ++I)
    {
        if (Hull.Find(Anchors[I])!=INDEX_NONE) continue;
        Best=None; BestDistance=1000000000;
        for (J=0; J<Anchors.Length; ++J)
        {
            if (I==J || Anchors[J].bOccupant) continue;
            // Static hull anchors root every branch. Two nearby moving members
            // must never select each other and form an isolated two-node cycle.
            if (Hull.Length>0 && Hull.Find(Anchors[J])==INDEX_NONE) continue;
            // Without world pins, earlier explicit pins define a bounded tree.
            if (Hull.Length==0 && Anchors[J].Serial>=Anchors[I].Serial) continue;
            Distance=VSizeSq(Anchors[I].Location-Anchors[J].Location);
            if (Distance<BestDistance && LinkClear(Anchors[I],Anchors[J]))
            { Best=Anchors[J]; BestDistance=Distance; }
        }
        AddLink(Anchors[I],Best);
    }
    UpdateDestination();
    if (Links.Length>0 && !bHaveLinked) { bHaveLinked=true; FirstLinkedTime=WorldInfo.TimeSeconds; }
}

function bool Collapse()
{
    if (Role!=ROLE_Authority || bFinished || bCollapsing || Anchors.Length<2 || Links.Length==0) return false;
    UpdateDestination();
    if (Destination==None) return false;
    bCollapsing=true;
    CollapseTime=WorldInfo.TimeSeconds;
    bNetDirty=true;
    TouchActivity();
    PreparePhysicalCollapse();
    PresentationEvent(2);
    // Next authority update applies the ramp, with no charge/animation wait.
    NextUpdate=0;
    return true;
}

function PresentationEvent(byte Kind)
{
    if (BreacherArcFence(Tool)!=None) BreacherArcFence(Tool).EmitPresentationEvent(Kind);
}

function PreparePhysicalCollapse()
{
    local int I;
    local KFPawn_Monster M;
    local BreacherArcAnchor A;
    local vector Toward;
    // Request stock eligibility, not a blanket class immunity. Eligible living
    // Zeds become collision-resolved ragdolls so a leg pin can apply torque;
    // refusing/heavy targets retain the resistant locomotion adapter.
    MarkConnected();
    for (I=0; I<Anchors.Length; ++I)
    {
        A=Anchors[I]; M=KFPawn_Monster(A.Target);
        if (!A.bReachable || M==None || M.Health<=0 || M.bDeleteMe || M.Physics==PHYS_RigidBody
            || A.DetachedPiece() || A.HasHeldBody() || !M.CanDoSpecialMove(SM_Knockdown)) continue;
        if (A!=Destination && !LinkClear(A,Destination)) continue;
        Toward=Normal(Destination.Location-A.Location);
        // A nonzero velocity is mandatory for stock knockdown replication.
        M.Knockdown(Toward*100+vect(0,0,30),vect(0,0,0),M.Location,0,0,Toward*30,A.Location);
    }
}

function Cancel()
{
    if (Role==ROLE_Authority) Destroy();
}

function DetachPlayer(Pawn P)
{
    local int I;
    if (Role!=ROLE_Authority) return;
    for (I=Anchors.Length-1; I>=0; --I)
        if (Anchors[I].Target==P) RemoveAnchor(I);
}

function RemoveAnchor(int Index)
{
    local int I;
    local BreacherArcAnchor A;
    A=Anchors[Index];
    for (I=Links.Length-1; I>=0; --I)
        if (Links[I].A==A || Links[I].B==A) { Links[I].Destroy(); Links.Remove(I,1); }
    Hull.RemoveItem(A);
    Anchors.Remove(Index,1);
    A.Destroy();
    BuildHull(); // area stays disabled unless all new boundary edges exist;
                 // removal cannot resurrect a severed edge behind an obstacle.
    UpdateDestination();
}

function MarkConnected()
{
    local int I,Pass;
    local bool Changed;
    for (I=0; I<Anchors.Length; ++I) Anchors[I].bReachable=Anchors[I]==Destination;
    for (Pass=0; Pass<Anchors.Length; ++Pass)
    {
        Changed=false;
        for (I=0; I<Links.Length; ++I)
        {
            if (!Links[I].bConducting) continue;
            if (Links[I].A.bReachable && !Links[I].B.bReachable) { Links[I].B.bReachable=true; Changed=true; }
            if (Links[I].B.bReachable && !Links[I].A.bReachable) { Links[I].A.bReachable=true; Changed=true; }
        }
        if (!Changed) break;
    }
}

function ExpireRestingComponents(float Now)
{
    local array<int> Component,Count;
    local array<float> LatestActivity,DisconnectDeadline;
    local array<bool> Expire;
    local int I,J,Pass,ComponentCount,RootComponent,IA,IB,ID;
    local bool Changed;
    Component.Length=Anchors.Length;
    for (I=0; I<Component.Length; ++I) Component[I]=INDEX_NONE;
    // Surviving edges include the half-second obstruction grace. Their force
    // and exposure already stop immediately, but they have not broken yet.
    for (I=0; I<Anchors.Length; ++I)
    {
        if (Component[I]!=INDEX_NONE) continue;
        ID=ComponentCount++;
        Component[I]=ID;
        for (Pass=0; Pass<Anchors.Length; ++Pass)
        {
            Changed=false;
            for (J=0; J<Links.Length; ++J)
            {
                IA=Anchors.Find(Links[J].A); IB=Anchors.Find(Links[J].B);
                if (IA==INDEX_NONE || IB==INDEX_NONE) continue;
                if (Component[IA]==ID && Component[IB]==INDEX_NONE) { Component[IB]=ID; Changed=true; }
                if (Component[IB]==ID && Component[IA]==INDEX_NONE) { Component[IA]=ID; Changed=true; }
            }
            if (!Changed) break;
        }
    }
    Count.Length=ComponentCount; LatestActivity.Length=ComponentCount;
    DisconnectDeadline.Length=ComponentCount; Expire.Length=ComponentCount;
    for (I=0; I<ComponentCount; ++I) DisconnectDeadline[I]=1000000000;
    RootComponent=INDEX_NONE;
    for (I=0; I<Anchors.Length; ++I)
    {
        ID=Component[I]; ++Count[ID];
        LatestActivity[ID]=FMax(LatestActivity[ID],Anchors[I].LastActivity);
        if (Anchors[I]==Destination) RootComponent=ID;
    }
    for (I=0; I<Anchors.Length; ++I)
    {
        ID=Component[I];
        if ((ID!=RootComponent || Count[ID]<2) && !Anchors[I].bDisconnected)
        {
            Anchors[I].bDisconnected=true;
            Anchors[I].DisconnectedAt=Now;
        }
        if (Anchors[I].bDisconnected)
            DisconnectDeadline[ID]=FMin(DisconnectDeadline[ID],Anchors[I].DisconnectedAt+RestSeconds);
    }
    for (I=0; I<ComponentCount; ++I)
        Expire[I]=Now-LatestActivity[I]>=RestSeconds || Now>=DisconnectDeadline[I];
    // Decide against the complete snapshot, then remove whole components.
    // Removing one post cannot grant the remainder an accidental new timer.
    for (I=Anchors.Length-1; I>=0; --I)
        if (Expire[Component[I]]) RemoveAnchor(I);
}

function bool ZoneContains(vector Point)
{
    local int I;
    local float Area,Low,High,Side,LastSide;
    local BreacherArcLink L;
    if (Hull.Length<3) return false;
    Low=Hull[0].Location.Z; High=Low;
    for (I=0; I<Hull.Length; ++I)
    {
        L=FindLink(Hull[I],Hull[(I+1)%Hull.Length]);
        if (L==None || !L.bConducting) return false;
        Area+=Hull[I].Location.X*Hull[(I+1)%Hull.Length].Location.Y-Hull[(I+1)%Hull.Length].Location.X*Hull[I].Location.Y;
        Low=FMin(Low,Hull[I].Location.Z); High=FMax(High,Hull[I].Location.Z);
        Side=Cross2(Hull[I].Location,Hull[(I+1)%Hull.Length].Location,Point);
        if (Abs(Side)>0.1)
        {
            if (LastSide!=0 && Side*LastSide<0) return false;
            LastSide=Side;
        }
    }
    return Abs(Area)*0.5>=MinimumArea && High-Low<=ZoneHalfHeight
        && Point.Z>=Low-ZoneHalfHeight && Point.Z<=High+ZoneHalfHeight;
}

function bool HasTarget(Actor Target)
{
    local int I;
    for (I=0; I<Anchors.Length; ++I) if (Anchors[I].Target==Target) return true;
    return false;
}

function Collect()
{
    local KFPawn_Monster M;
    local BreacherArcAnchor A,Best;
    local float BestDistance,Distance;
    local int I,Count;
    if (bCollapsing || Hull.Length<3) return;
    for (I=0; I<Anchors.Length; ++I) if (Anchors[I].bOccupant) ++Count;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster',M)
    {
        if (Count>=MaxOccupants) break;
        if (M.Health<=0 || M.bDeleteMe || HasTarget(M) || !ZoneContains(M.Location)) continue;
        Best=None; BestDistance=Square(MaxSpan);
        for (I=0; I<Hull.Length; ++I)
        {
            Distance=VSizeSq(M.Location-Hull[I].Location);
            // FastTrace excludes cross-floor/world collection; full link check
            // below additionally handles closed movable blockers.
            if (Distance<BestDistance && FastTrace(Hull[I].Location,M.Location))
            { Best=Hull[I]; BestDistance=Distance; }
        }
        if (Best==None) continue;
        A=Spawn(class'BreacherArcAnchor',self,,M.Location);
        if (A==None) break;
        if (!A.Initialize(self,M,M.Mesh,'',M.Location,true) || !LinkClear(A,Best)) { A.Destroy(); continue; }
        A.Serial=++PlacementSerial;
        Anchors.AddItem(A); AddLink(A,Best); ++Count;
        // Membership persists outside the polygon, while its edge must still
        // obey the same range and line-of-sight rules as an explicit pin.
        TouchActivity();
    }
}

static function float SegmentDistanceSq(vector Point,vector A,vector B)
{
    local vector D;
    local float T;
    D=B-A;
    T=FClamp(((Point-A) dot D)/FMax(VSizeSq(D),0.01),0,1);
    return VSizeSq(Point-(A+D*T));
}

function bool Exposed(KFPawn_Monster M)
{
    local int I;
    for (I=0; I<Links.Length; ++I)
    {
        if (!Links[I].bConducting) continue;
        if (Links[I].A.Target==M || Links[I].B.Target==M) return true;
        if (SegmentDistanceSq(M.Location,Links[I].A.Location,Links[I].B.Location)
            <=Square(FMax(M.CylinderComponent.CollisionRadius,20)+10)
            && FastTrace(M.Location, (Links[I].A.Location+Links[I].B.Location)*0.5)) return true;
    }
    return false;
}

function Shock()
{
    local KFPawn_Monster M;
    local TraceHitInfo Info;
    local BreacherArcGroup Other;
    local bool Earlier;
    local BreacherPerk Perk;
    local class<BreacherArcShock> ShockType;
    local int I,ExposureIndex,HealthDamage;
    local float HealthPerTick;
    ShockType=class'BreacherArcShock';
    HealthPerTick=2;
    if (KFPlayerController(Shooter.Controller)!=None)
        Perk=BreacherPerk(KFPlayerController(Shooter.Controller).CurrentPerk);
    if (Perk!=None && Perk.SkillActive(3))
    {
        ShockType=class'BreacherArcLiveWireShock';
        HealthPerTick=1.5;
    }
    // Keep fractional accounting by pawn lifetime, bounded to live recent
    // exposure targets. This stores no damage or EMP on an unexposed pawn.
    for (I=Exposures.Length-1; I>=0; --I)
        if (Exposures[I].Target==None || Exposures[I].Target.bDeleteMe || Exposures[I].Target.Health<=0
            || WorldInfo.TimeSeconds-Exposures[I].LastSeen>8) Exposures.Remove(I,1);
    foreach WorldInfo.AllPawns(class'KFPawn_Monster',M)
    {
        if (M.Health<=0 || M.bDeleteMe || !Exposed(M)) continue;
        // Global overlap cap: the oldest extant exposing group owns this tick.
        // No per-link, per-pin or zone multiplication of EMP/health damage.
        Earlier=false;
        foreach DynamicActors(class'BreacherArcGroup',Other)
            if (Other!=self && !Other.bFinished && string(Other.Name)<string(Name) && Other.Exposed(M)) { Earlier=true; break; }
        if (Earlier) continue;
        ExposureIndex=Exposures.Find('Target',M);
        if (ExposureIndex==INDEX_NONE)
        {
            // Do not evict identities and accidentally farm an extra round-up.
            if (Exposures.Length>=256) continue;
            ExposureIndex=Exposures.Length;
            Exposures.Length=ExposureIndex+1;
            Exposures[ExposureIndex].Target=M;
        }
        Exposures[ExposureIndex].LastSeen=WorldInfo.TimeSeconds;
        Exposures[ExposureIndex].HealthRemainder+=HealthPerTick;
        HealthDamage=int(Exposures[ExposureIndex].HealthRemainder);
        Exposures[ExposureIndex].HealthRemainder-=HealthDamage;
        M.TakeDamage(HealthDamage,Shooter.Controller,M.Location,vect(0,0,0),ShockType,Info,self);
    }
}

// Resolve stock ZoneName by actual physics-asset intersection; never substitute
// the anchor bone or nearest head/root. Samples can miss contacts, which is safer
// than inventing a body-part hit. Full surface/manifold coverage remains a gate.
function bool ContactZone(KFPawn_Monster M,vector Point,vector Direction,out ImpactInfo Impact)
{
    local array<ImpactInfo> Hits;
    local int I;
    local float Distance,Best;
    if (M==None || M.Mesh==None) return false;
    if (!TraceAllPhysicsAssetInteractions(M.Mesh,Point+Direction*24,Point-Direction*24,Hits,vect(0,0,0),true)) return false;
    Best=100000000;
    for (I=0; I<Hits.Length; ++I)
    {
        if (M.GetHitZoneIndex(Hits[I].HitInfo.BoneName)==INDEX_NONE) continue;
        if (class'BreacherConsumedPiece'.static.IsConsumed(M,
            M.HitZones[M.GetHitZoneIndex(Hits[I].HitInfo.BoneName)].BoneName)) continue;
        Distance=VSizeSq(Hits[I].HitLocation-Point);
        if (Distance<Best) { Best=Distance; Impact=Hits[I]; }
    }
    return Best<100000000;
}

function DamageContact(KFPawn_Monster M,vector Point,vector NormalToOther,float Closing)
{
    local ImpactInfo Hit;
    local int Damage;
    if (M==None || M.Health<=0 || Closing<ImpactThreshold) return;
    if (!ContactZone(M,Point,NormalToOther,Hit)) return;
    Damage=int(FClamp((Closing-ImpactThreshold)*ImpactScale,1,ImpactCap));
    M.TakeDamage(Damage,Shooter.Controller,Hit.HitLocation,vect(0,0,0),class'BreacherArcImpact',Hit.HitInfo,self);
    if (WorldInfo.TimeSeconds>=NextImpactEvent)
    {
        PresentationEvent(4);
        NextImpactEvent=WorldInfo.TimeSeconds+0.12;
    }
}

function bool NewContact(Actor A,Actor B)
{
    local int I;
    local ArcContact C;
    for (I=Contacts.Length-1; I>=0; --I)
    {
        if (Contacts[I].Until<WorldInfo.TimeSeconds || Contacts[I].A==None || Contacts[I].A.bDeleteMe
            || Contacts[I].B==None || Contacts[I].B.bDeleteMe) Contacts.Remove(I,1);
        else if ((Contacts[I].A==A && Contacts[I].B==B) || (Contacts[I].A==B && Contacts[I].B==A)) return false;
    }
    if (Contacts.Length>=128) return false;
    C.A=A; C.B=B; C.Until=WorldInfo.TimeSeconds+0.35; Contacts.AddItem(C);
    return true;
}

function vector ContactVelocity(Actor A,TraceHitInfo Info,vector Point)
{
    local Pawn P;
    local KFPawn K;
    local RB_BodyInstance B;
    local name Bone;
    local int Zone;
    if (A==None) return vect(0,0,0);
    P=Pawn(A); K=KFPawn(A); Bone=Info.BoneName;
    if (P!=None && P.Mesh!=None && (P.Physics==PHYS_RigidBody || P.Health<=0))
    {
        if (K!=None)
        {
            Zone=K.GetHitZoneIndex(Bone);
            if (Zone!=INDEX_NONE) Bone=K.HitZones[Zone].BoneName;
            Bone=K.GetRBBoneFromBoneName(Bone);
        }
        if (Bone!='') B=P.Mesh.FindBodyInstanceNamed(Bone);
        if (B==None) B=P.Mesh.GetRootBodyInstance();
    }
    else if (Info.HitComponent!=None) B=Info.HitComponent.GetRootBodyInstance();
    if (B!=None && B.IsValidBodyInstance() && !B.IsFixed()) return B.GetUnrealWorldVelocityAtPoint(Point);
    return A.Velocity;
}

function SweepContacts(BreacherArcAnchor A,float Delta)
{
    local KFPawn_Monster M,Other;
    local vector Point,Previous,Travel,HitPoint,HitNormal,OtherVelocity;
    local Actor Hit;
    local TraceHitInfo Info;
    local int I;
    local float Closing;
    M=KFPawn_Monster(A.Target);
    if (M==None) { SweepPropContacts(A,Delta); return; }
    if (M.Mesh==None) return;
    if (A.LastZones.Length!=M.HitZones.Length)
    {
        A.LastZones.Length=M.HitZones.Length; A.ZoneCooldown.Length=M.HitZones.Length;
        for (I=0; I<M.HitZones.Length; ++I) A.LastZones[I]=M.Mesh.GetBoneLocation(M.HitZones[I].BoneName);
        return;
    }
    for (I=0; I<M.HitZones.Length; ++I)
    {
        Point=M.Mesh.GetBoneLocation(M.HitZones[I].BoneName);
        Previous=A.LastZones[I]; A.LastZones[I]=Point;
        if (class'BreacherConsumedPiece'.static.IsConsumed(M,M.HitZones[I].BoneName)) continue;
        if (WorldInfo.TimeSeconds<A.ZoneCooldown[I] || Delta<=0) continue;
        Travel=Point-Previous;
        if (VSizeSq(Travel)<Square(ImpactThreshold*Delta)) continue;
        // Sweep each authored anatomical region through real collision. Small
        // extents sample regions; this is not a full rigid-body manifold API.
        foreach TraceActors(class'Actor',Hit,HitPoint,HitNormal,Point,Previous,vect(3,3,3),Info)
        {
            if (Hit==M || Hit==Shooter || Hit==self || BreacherArcAnchor(Hit)!=None || BreacherArcLink(Hit)!=None) continue;
            if (!Hit.bBlockActors && !Hit.bWorldGeometry && KFPawn_Monster(Hit)==None) continue;
            OtherVelocity=ContactVelocity(Hit,Info,HitPoint);
            Closing=FMax(0,-((Travel/Delta-OtherVelocity) dot HitNormal));
            if (Closing<ImpactThreshold) break;
            if (!NewContact(M,Hit)) break;
            DamageContact(M,HitPoint,-HitNormal,Closing);
            Other=KFPawn_Monster(Hit);
            if (Other!=None) DamageContact(Other,HitPoint,HitNormal,Closing);
            A.ZoneCooldown[I]=WorldInfo.TimeSeconds+0.35;
            A.LastActivity=WorldInfo.TimeSeconds;
            break;
        }
    }
}

function SweepPropContacts(BreacherArcAnchor A,float Delta)
{
    local Actor Hit;
    local KFPawn_Monster M;
    local vector HitPoint,HitNormal,Travel;
    local TraceHitInfo Info;
    local float Closing;
    // Players have their own damage rules; being an endpoint doesn't turn the
    // player capsule into an offensive prop or enable friendly shock damage.
    if (A.Target==None || Pawn(A.Target)!=None || A.bWorldAnchor) return;
    Travel=A.Location-A.PreviousContactPoint;
    if (A.bHaveContactPoint && Delta>0 && VSizeSq(Travel)>Square(ImpactThreshold*Delta))
    {
        foreach TraceActors(class'Actor',Hit,HitPoint,HitNormal,A.Location,A.PreviousContactPoint,vect(6,6,6),Info)
        {
            if (Hit==A.Target || Hit==self || BreacherArcAnchor(Hit)!=None || BreacherArcLink(Hit)!=None) continue;
            M=KFPawn_Monster(Hit);
            if (M!=None)
            {
                Closing=FMax(0,-((Travel/Delta-ContactVelocity(M,Info,HitPoint)) dot HitNormal));
                if (Closing>=ImpactThreshold && NewContact(A.Target,M))
                {
                    DamageContact(M,HitPoint,HitNormal,Closing);
                    A.LastActivity=WorldInfo.TimeSeconds;
                }
                break;
            }
            if (Hit.bBlockActors || Hit.bWorldGeometry) break;
        }
    }
    A.PreviousContactPoint=A.Location; A.bHaveContactPoint=true;
}

function ApplyPull(float Delta)
{
    local int I;
    local vector Toward;
    local float Distance,PullRate,Along;
    local BreacherArcAnchor A;
    if (Destination==None) return;
    PullRate=PullAcceleration*FClamp((WorldInfo.TimeSeconds-CollapseTime+0.05)/0.25,0.2,1);
    for (I=0; I<Anchors.Length; ++I)
    {
        A=Anchors[I];
        if (A==Destination || A.bWorldAnchor || !A.bReachable || !LinkClear(A,Destination)) continue;
        Toward=Destination.Location-A.Location;
        Distance=VSize(Toward);
        if (Distance<32) continue;
        Toward/=Distance;
        Along=(A.PointVelocity()-Destination.PointVelocity()) dot Toward;
        if (Along>=MaxPullSpeed) continue;
        A.Pull(Toward,FMin(PullRate,(MaxPullSpeed-Along)/FMax(Delta,0.001)),Delta);
        // Equal opposing load: choosing a heavy object doesn't freeze it.
        if (!Destination.bWorldAnchor) Destination.Pull(-Toward,PullRate*FClamp(A.Resistance/Destination.Resistance,0.02,1),Delta);
    }
}

function bool CanCompact(BreacherArcAnchor A)
{
    local KFPawn_Monster M;
    if (A==None || A.bDeleteMe || Destination==None || !A.bReachable || !A.bAttachmentReady) return false;
    M=KFPawn_Monster(A.Target);
    return M!=None && M.Health<=0 && M.bPlayedDeath && !M.bDeleteMe
        && A.CorpseArrived(Destination.Location,100)
        && (A==Destination || LinkClear(A,Destination));
}

function BeginCompaction()
{
    bCompacting=true;
    CompactionTime=WorldInfo.TimeSeconds;
    bNetDirty=true;
    PresentationEvent(5);
    UpdateDestination();
}

function ApplyCompaction(float Delta)
{
    local int I,Index;
    local ArcCompression C;
    // A bounded arrival window admits staggered corpses, while preserving at
    // least 0.15 s of visible physical pressure for every credited identity.
    for (I=0; I<Anchors.Length; ++I)
    {
        if (!CanCompact(Anchors[I])) continue;
        Index=Compression.Find('Anchor',Anchors[I]);
        if (Index==INDEX_NONE)
        {
            if (WorldInfo.TimeSeconds-CompactionTime>CompactionSeconds-0.15) continue;
            C.Anchor=Anchors[I]; C.Started=WorldInfo.TimeSeconds;
            Compression.AddItem(C);
        }
        Anchors[I].Compress(Destination.Location,Delta);
    }
    // A held/severed/obstructed corpse loses eligibility immediately, including
    // a grab made after entry. No stale reservation can award it at phase end.
    for (I=Compression.Length-1; I>=0; --I)
        if (!CanCompact(Compression[I].Anchor)) Compression.Remove(I,1);
}

function FinishCompaction()
{
    local int I;
    local KFPawn_Monster M;
    local BreacherArcConsumed C;
    local BreacherConsumedPiece Consumed;
    local BreacherArcBurst Burst;
    local bool Seen;
    if (bFinished || Destination==None) return;
    bFinished=true; bNetDirty=true;
    for (I=0; I<Compression.Length; ++I)
    {
        if (!CanCompact(Compression[I].Anchor) || WorldInfo.TimeSeconds-Compression[I].Started<0.15) continue;
        M=KFPawn_Monster(Compression[I].Anchor.Target);
        if (Mulched.Find(M)!=INDEX_NONE) continue;
        Seen=false;
        foreach DynamicActors(class'BreacherArcConsumed',C) if (C.Target==M) { Seen=true; break; }
        if (Seen) continue;
        // Consume before gore callbacks. A corpse and all of its pins count once.
        C=Spawn(class'BreacherArcConsumed',self,,M.Location);
        if (C==None) continue;
        Consumed=class'BreacherConsumedPiece'.static.Consume(M,M.Mesh.GetBoneName(0));
        if (Consumed==None || !Consumed.bSnapshot) { C.Destroy(); continue; }
        C.Target=M;
        Mulched.AddItem(M);
    }
    if (Mulched.Length>0)
    {
        Burst=Spawn(class'BreacherArcBurst',self,,Destination.Location);
        if (Burst!=None)
        {
            Burst.MulchCount=Mulched.Length;
            Burst.Outward=Destination.bWorldAnchor ? -vector(Destination.Rotation) : vect(0,0,1);
            Burst.bAroundObject=!Destination.bWorldAnchor;
            if (WorldInfo.GRI!=None) Burst.EventSecond=WorldInfo.GRI.ElapsedTime;
            for (I=0; I<Mulched.Length && I<32; ++I)
            {
                Burst.Payload[I]=Mulched[I];
                Burst.BodyIdentity[I]=class'BreacherBodyIdentity'.static.Find(Mulched[I]);
                Burst.PayloadRoot[I]=Mulched[I].Mesh.GetBoneName(0);
            }
            Burst.bReady=true;
            Burst.bNetDirty=true;
        }
        PresentationEvent(6);
    }
    Compression.Length=0;
    // The reward is consumed. Retained hardware is visibly unpowered, and
    // ambient AI/physics motion cannot retain this finished field indefinitely.
    for (I=0; I<Links.Length; ++I)
    {
        Links[I].bConducting=false; Links[I].bLoaded=false;
        Links[I].bNetDirty=true; Links[I].bForceNetUpdate=true;
    }
    for (I=0; I<Anchors.Length; ++I)
    {
        Anchors[I].bDisconnected=true;
        Anchors[I].DisconnectedAt=WorldInfo.TimeSeconds;
    }
    TouchActivity(); // at most eight seconds of unpowered aftermath
    UpdateDestination();
}

event Tick(float DeltaTime)
{
    local int I;
    local float Now,Delta;
    if (Role!=ROLE_Authority) return;
    if (Shooter==None || Shooter.bDeleteMe || Shooter.Health<=0 || Shooter.Controller==None
        || Tool==None || Tool.bDeleteMe) { Destroy(); return; }
    Now=WorldInfo.TimeSeconds;
    if (Now<NextUpdate) return;
    // Contact velocity uses real elapsed time; capping it would turn a hitch
    // into invented impact energy. Only force integration is timestep-capped.
    Delta=LastUpdate>0 ? FMax(Now-LastUpdate,0.001) : 0.05;
    LastUpdate=Now; NextUpdate=Now+0.05;
    SetLocation(Shooter.Location);
    for (I=Anchors.Length-1; I>=0; --I)
    {
        if (!Anchors[I].Refresh()) RemoveAnchor(I);
    }
    if (Anchors.Length==0) { Destroy(); return; }
    UpdateDestination();
    for (I=Links.Length-1; I>=0; --I)
        if (!Links[I].Refresh()) { Links[I].Destroy(); Links.Remove(I,1); }
    ExpireRestingComponents(Now);
    if (Anchors.Length==0) { Destroy(); return; }
    MarkConnected();
    if (!bCollapsing && Now>=NextCollection) { Collect(); NextCollection=Now+0.25; }
    if (!bCollapsing && bHaveLinked && Now-FirstLinkedTime>=GatherSeconds) Collapse();
    if (bCollapsing && !bFinished)
    {
        for (I=0; I<Anchors.Length; ++I) if (Anchors[I].bReachable) SweepContacts(Anchors[I],Delta);
        if (!bCompacting)
        {
            ApplyPull(FMin(Delta,0.1));
            if (Now-CollapseTime>=CollapseSeconds) BeginCompaction();
        }
        if (bCompacting)
        {
            ApplyCompaction(FMin(Delta,0.1));
            if (Now-CompactionTime>=CompactionSeconds) FinishCompaction();
        }
    }
    if (!bFinished && Now>=NextExposure) { Shock(); NextExposure=Now+0.25; }
}

event Destroyed()
{
    local int I;
    if (Role==ROLE_Authority)
    {
        for (I=0; I<Links.Length; ++I) if (Links[I]!=None) Links[I].Destroy();
        for (I=0; I<Anchors.Length; ++I) if (Anchors[I]!=None) Anchors[I].Destroy();
    }
    Super.Destroyed();
}

defaultproperties
{
    MaxPins=16
    MaxOccupants=16
    MaxSpan=1500
    PlacementRange=2000
    RestSeconds=8
    GatherSeconds=6
    CollapseSeconds=3
    CompactionSeconds=0.5
    PullAcceleration=2200
    MaxPullSpeed=1000
    MinimumArea=2500
    ZoneHalfHeight=100
    ImpactThreshold=180
    ImpactScale=0.22
    ImpactCap=180
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=10
}
