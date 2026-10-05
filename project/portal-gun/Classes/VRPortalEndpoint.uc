// Local portal pair and conservative collision-checked traversal prototype.
// UE3 script cannot cut an aperture in the wall's collision. Transfer therefore
// occurs at leading hull contact, not Portal 2's continuous body-plane crossing.
class VRPortalEndpoint extends Actor;

struct PortalTraveler
{
    var Actor Body;
    var vector Previous;
    var float LastSeen;
    var bool bExitLocked;
};

var byte PortalColor;
var VRWeap_PortalGun Launcher;
var VRPortalEndpoint OtherPortal;
var VRPortalSurface Surface;
var float HalfWidth, HalfHeight;
var array<PortalTraveler> Travelers;
var Actor MountActor;
var PrimitiveComponent MountComponent;
var float NextMountCheck;
var int TraversalCount, BlockedExitCount;
var Pawn NativeTraversalPawn;
var float NativeTraversalLeaseUntil;

simulated function PlayPortalCue(name CueName)
{
    local SoundCue Cue;
    Cue=SoundCue(DynamicLoadObject("KF2VRPortal." $ CueName,class'SoundCue',true));
    if (Cue != None) PlaySound(Cue);
}

// Cylinder LineCheck pulls contacts back by 0.001 of the whole ray length.
// Recover a local contact on the same first surface before testing its plane.
// Keep the original direction/range so refinement cannot shoot behind the
// shooter or discover a surface beyond the shot. See the pinned RE evidence.
static function bool RefineSurfaceHit(Actor Context, vector Start, vector End,
    Actor HitActor, out vector Hit, out vector HitNormal, out TraceHitInfo Info,
    optional int ExtraTraceFlags)
{
    local vector Direction, RefinedHit, RefinedNormal, LocalStart, LocalEnd;
    local float Length, Distance, Radius;
    local Actor RefinedActor;
    local TraceHitInfo RefinedInfo;
    if (Context == None || HitActor == None) return false;
    Length=VSize(End-Start);
    if (Length <= 0.001) return false;
    Direction=(End-Start)/Length;
    Distance=FClamp((Hit-Start) dot Direction,0,Length);
    Radius=FMax(128,Length*0.001+2);
    LocalStart=Start+Direction*FMax(0,Distance-Radius);
    LocalEnd=Start+Direction*FMin(Length,Distance+Radius);
    RefinedActor=Context.Trace(RefinedHit,RefinedNormal,LocalEnd,LocalStart,true,,RefinedInfo,ExtraTraceFlags);
    if (RefinedActor != HitActor || RefinedInfo.HitComponent != Info.HitComponent
        || (RefinedNormal dot HitNormal) <= 0.995) return false;
    Hit=RefinedHit;
    HitNormal=RefinedNormal;
    Info=RefinedInfo;
    return true;
}

static function bool SampleSurface(Actor Context, vector Center, vector N)
{
    local vector Hit, HitNormal;
    local Actor A;
    local TraceHitInfo Info;
    A = Context.Trace(Hit, HitNormal, Center - N*6, Center + N*6, true,, Info);
    return class'VRPortalRules'.static.IsPortalable(A, Info)
        && (HitNormal dot N) > 0.995 && Abs((Hit-Center) dot N) < 1.5;
}

static function bool FitsSurface(Actor Context, vector Center, rotator Basis)
{
    local int Y, Z, I;
    local float A;
    local vector XAxis, YAxis, ZAxis, P;
    GetAxes(Basis, XAxis, YAxis, ZAxis);
    // Test the interior as well as the rim: corner-only checks accept holes.
    for (Y=-4; Y<=4; ++Y)
        for (Z=-4; Z<=4; ++Z)
        {
            if (Y*Y + Z*Z > 16) continue;
            P = Center + YAxis*(default.HalfWidth*float(Y)/4)
                + ZAxis*(default.HalfHeight*float(Z)/4);
            if (!SampleSurface(Context, P, XAxis)) return false;
        }
    for (I=0; I<32; ++I)
    {
        A = float(I)*Pi/16;
        P = Center + YAxis*(Cos(A)*default.HalfWidth) + ZAxis*(Sin(A)*default.HalfHeight);
        if (!SampleSurface(Context, P, XAxis)) return false;
    }
    return true;
}

static function bool FindPlacement(Actor Context, vector Start, vector Direction,
    out vector Center, out rotator Basis)
{
    local Actor A;
    local TraceHitInfo Info;
    local vector Hit, N, X, Y, Z, Candidate;
    local int Ring, Side;
    if (Context == None || VSizeSq(Direction) < 0.9) return false;
    A = Context.Trace(Hit, N, Start + Normal(Direction)*65536, Start, true,, Info);
    if (!class'VRPortalRules'.static.IsPortalable(A, Info) || (N dot Direction) >= -0.01)
    {
        `log("KF2VR_PORTAL action=placement-rejected stage=initial-trace actor=" $ A
            @ "component=" $ Info.HitComponent @ "start=" $ Start @ "hit=" $ Hit
            @ "normal=" $ N @ "direction=" $ Direction @ "material=" $ Info.Material
            @ "physicalMaterial=" $ Info.PhysMaterial);
        return false;
    }
    if (!RefineSurfaceHit(Context,Start,Start+Normal(Direction)*65536,A,Hit,N,Info)
        || !class'VRPortalRules'.static.IsPortalable(A,Info))
    {
        `log("KF2VR_PORTAL action=placement-rejected stage=surface-refine actor=" $ A
            @ "component=" $ Info.HitComponent @ "hit=" $ Hit @ "normal=" $ N);
        return false;
    }
    Basis = class'VRPortalMath'.static.MakeBasis(N, Direction);
    if (FitsSurface(Context, Hit, Basis)) { Center=Hit; return true; }
    GetAxes(Basis, X, Y, Z);
    // Modest placement adjustment permits a shot near a wall edge to fit.
    // Every candidate receives the same full surface validation.
    for (Ring=1; Ring<=4; ++Ring)
        for (Side=0; Side<8; ++Side)
        {
            Candidate=Hit + (Y*Cos(float(Side)*Pi/4) + Z*Sin(float(Side)*Pi/4))*float(Ring)*16;
            if (FitsSurface(Context, Candidate, Basis)) { Center=Candidate; return true; }
        }
    `log("KF2VR_PORTAL action=placement-rejected stage=surface-fit actor=" $ A
        @ "component=" $ Info.HitComponent @ "hit=" $ Hit @ "normal=" $ N);
    return false;
}

static function bool OverlapsPortal(vector Center, rotator Basis, VRPortalEndpoint Peer)
{
    local vector Delta, X, Y, Z, Point;
    local int I;
    local float A;
    if (Peer == None || Peer.bDeleteMe) return false;
    if (Abs(vector(Basis) dot vector(Peer.Rotation)) < 0.99) return false;
    Delta=(Center-Peer.Location) << Peer.Rotation;
    if (Abs(Delta.X) > 4) return false;
    if (class'VRPortalMath'.static.InsideEllipse(Delta, Peer.HalfWidth, Peer.HalfHeight)) return true;
    GetAxes(Basis, X, Y, Z);
    for (I=0; I<64; ++I)
    {
        A=float(I)*Pi/32;
        Point=Center + Y*Cos(A)*default.HalfWidth + Z*Sin(A)*default.HalfHeight;
        if (class'VRPortalMath'.static.InsideEllipse((Point-Peer.Location) << Peer.Rotation,
            Peer.HalfWidth+2, Peer.HalfHeight+2)) return true;
    }
    return false;
}

function Configure(VRWeap_PortalGun Gun, byte PortalIndex, VRPortalEndpoint Peer)
{
    local vector Hit, N;
    local TraceHitInfo Info;
    Launcher=Gun;
    Instigator=Gun.Instigator;
    PortalColor=PortalIndex;
    MountActor=Trace(Hit, N, Location-vector(Rotation)*6, Location+vector(Rotation)*6, true,, Info);
    MountComponent=Info.HitComponent;
    Surface=Spawn(class'VRPortalSurface', self,, Location, Rotation);
    if (Surface != None) Surface.BindPortal(self);
    PlayPortalCue(PortalColor == 0 ? 'PortalOpenBlue' : 'PortalOpenOrange');
    LinkTo(Peer);
}

function LinkTo(VRPortalEndpoint Peer)
{
    local VRPortalEndpoint Old;
    if (Peer == self || (Peer != None && Peer.bDeleteMe)) return;
    Old=OtherPortal;
    if (Old != Peer && Launcher != None) Launcher.CloseNativePortalPair(self);
    OtherPortal=Peer;
    Travelers.Length=0;
    if (Old != None && Old != Peer && Old.OtherPortal == self) Old.LinkTo(None);
    if (Peer != None && Peer.OtherPortal != self) Peer.LinkTo(self);
    if (Surface != None) Surface.SetPortalLink(Peer);
    // The recursive peer call returns before this surface is updated. Publish
    // only once both endpoint links and both capture destinations are complete.
    if (Launcher != None) Launcher.PublishNativePortalPair(self,Peer);
}

simulated function SetVRRenderingActive(bool bActive)
{
    if (Surface != None) Surface.SetVRRenderingActive(bActive);
}

function bool CanTransport(Actor A)
{
    if (A == None || A.bDeleteMe || A.bStatic || A.bWorldGeometry || Vehicle(A) != None) return false;
    if (Pawn(A) != None) return A.bCanTeleport && Pawn(A).Health > 0 && A.Physics != PHYS_RigidBody;
    return (KActor(A) != None && A.Physics == PHYS_RigidBody) || Projectile(A) != None;
}

function vector BodyExtent(Actor A)
{
    local vector Extent;
    if (Pawn(A) != None && Pawn(A).CylinderComponent != None)
    {
        Extent.X=Pawn(A).CylinderComponent.CollisionRadius;
        Extent.Y=Extent.X;
        Extent.Z=Pawn(A).CylinderComponent.CollisionHeight;
    }
    else
    {
        if (A.CollisionComponent != None) Extent=A.CollisionComponent.Bounds.BoxExtent;
    }
    return Extent;
}

function vector BodyPosition(Actor A)
{
    if (Pawn(A) == None && A.CollisionComponent != None) return A.CollisionComponent.Bounds.Origin;
    return A.Location;
}

function vector TransformedExtent(vector Extent)
{
    local vector X,Y,Z, Result;
    X=class'VRPortalMath'.static.MapVector(vect(1,0,0),Rotation,OtherPortal.Rotation);
    Y=class'VRPortalMath'.static.MapVector(vect(0,1,0),Rotation,OtherPortal.Rotation);
    Z=class'VRPortalMath'.static.MapVector(vect(0,0,1),Rotation,OtherPortal.Rotation);
    Result.X=Abs(X.X)*Extent.X+Abs(Y.X)*Extent.Y+Abs(Z.X)*Extent.Z;
    Result.Y=Abs(X.Y)*Extent.X+Abs(Y.Y)*Extent.Y+Abs(Z.Y)*Extent.Z;
    Result.Z=Abs(X.Z)*Extent.X+Abs(Y.Z)*Extent.Y+Abs(Z.Z)*Extent.Z;
    return Result;
}

function bool ExitClear(Actor Traveler, vector Center, vector Extent, vector Axis)
{
    local Actor A;
    local vector Hit,N;
    foreach TraceActors(class'Actor',A,Hit,N,Center+Axis*0.05,Center,Extent)
        if (A != Traveler) return false;
    return true;
}

function float ExtentAlong(vector Extent, vector Axis)
{
    return Abs(Axis.X)*Extent.X + Abs(Axis.Y)*Extent.Y + Abs(Axis.Z)*Extent.Z;
}

function vector BodyVelocity(Actor A)
{
    local RB_BodyInstance Body;
    if (A.Physics == PHYS_RigidBody && A.CollisionComponent != None)
    {
        Body=A.CollisionComponent.GetRootBodyInstance();
        if (Body != None) return Body.GetUnrealWorldVelocity();
    }
    return A.Velocity;
}

function LockExit(Actor A)
{
    local PortalTraveler Record;
    local int I;
    I=Travelers.Find('Body', A);
    if (I < 0) { Record.Body=A; I=Travelers.Length; Travelers.AddItem(Record); }
    Travelers[I].Previous=BodyPosition(A);
    Travelers[I].LastSeen=WorldInfo.TimeSeconds;
    Travelers[I].bExitLocked=true;
}

function bool Transfer(Actor A, vector CrossPoint)
{
    local vector Destination, LocalPoint, NewVelocity, NewAcceleration, Extent, X,Y,Z;
    local vector NewAngularVelocity, BodyOffset, RBOffset;
    local rotator NewRotation, ViewRotation, NewRBRotation;
    local Pawn P;
    local RB_BodyInstance Body;
    local float Depth;
    if (OtherPortal == None || OtherPortal.bDeleteMe || !CanTransport(A)) return false;
    Extent=BodyExtent(A);
    BodyOffset=BodyPosition(A)-A.Location;
    if (Pawn(A) == None)
    {
        Extent=TransformedExtent(Extent);
        BodyOffset=class'VRPortalMath'.static.MapVector(BodyOffset,Rotation,OtherPortal.Rotation);
    }
    if (A.Physics == PHYS_RigidBody && A.CollisionComponent != None)
    {
        RBOffset=class'VRPortalMath'.static.MapVector(A.CollisionComponent.GetPosition()-A.Location,Rotation,OtherPortal.Rotation);
        NewRBRotation=class'VRPortalMath'.static.MapRotation(A.CollisionComponent.GetRotation(),Rotation,OtherPortal.Rotation);
    }
    LocalPoint=(CrossPoint-Location) << Rotation;
    LocalPoint.X=0;
    Destination=class'VRPortalMath'.static.MapPoint(Location+(LocalPoint >> Rotation),
        Location, Rotation, OtherPortal.Location, OtherPortal.Rotation);
    GetAxes(OtherPortal.Rotation,X,Y,Z);
    // Pawns stay gravity-upright in KF2, so recompute their exit footprint.
    if (!class'VRPortalMath'.static.InsideEllipse((Destination-OtherPortal.Location) << OtherPortal.Rotation,
        OtherPortal.HalfWidth,OtherPortal.HalfHeight,ExtentAlong(Extent,Y),ExtentAlong(Extent,Z))) return false;
    Depth=ExtentAlong(Extent,X)+3;
    Destination += X*Depth;
    // A zero length extent query validates destination occupancy before any
    // state changes. Keep world/actor collision enabled throughout SetLocation.
    if (!ExitClear(A,Destination,Extent,X)) { ++BlockedExitCount; return false; }
    Destination-=BodyOffset;
    NewVelocity=class'VRPortalMath'.static.MapVector(BodyVelocity(A), Rotation, OtherPortal.Rotation);
    NewAcceleration=class'VRPortalMath'.static.MapVector(A.Acceleration, Rotation, OtherPortal.Rotation);
    NewRotation=class'VRPortalMath'.static.MapRotation(A.Rotation, Rotation, OtherPortal.Rotation);
    NewAngularVelocity=class'VRPortalMath'.static.MapVector(A.AngularVelocity,Rotation,OtherPortal.Rotation);
    if (A.Physics == PHYS_RigidBody && A.CollisionComponent != None)
    {
        Body=A.CollisionComponent.GetRootBodyInstance();
        if (Body != None) NewAngularVelocity=class'VRPortalMath'.static.MapVector(
            Body.GetUnrealWorldAngularVelocity(),Rotation,OtherPortal.Rotation);
    }
    P=Pawn(A);
    if (P != None && P.Controller != None)
        ViewRotation=class'VRPortalMath'.static.MapRotation(P.Controller.Rotation, Rotation, OtherPortal.Rotation);
    if (!A.SetLocation(Destination)) { ++BlockedExitCount; return false; }
    class'VRPortalCarry'.static.ReleaseForPortalTravel(A);
    if (P != None)
    {
        NewRotation.Pitch=0;
        NewRotation.Roll=0;
        ViewRotation.Roll=0;
        if (P.Controller != None)
        {
            P.SetViewRotation(ViewRotation);
            P.ClientSetRotation(ViewRotation);
            P.Controller.MoveTimer=-1;
        }
        P.SetBase(None);
        P.SetPhysics(PHYS_Falling);
    }
    A.SetRotation(NewRotation);
    A.Velocity=NewVelocity;
    A.Acceleration=NewAcceleration;
    if (A.Physics == PHYS_RigidBody && A.CollisionComponent != None)
    {
        A.CollisionComponent.SetRBPosition(Destination+RBOffset);
        A.CollisionComponent.SetRBRotation(NewRBRotation);
        A.CollisionComponent.SetRBLinearVelocity(NewVelocity);
        A.CollisionComponent.SetRBAngularVelocity(NewAngularVelocity);
        A.CollisionComponent.WakeRigidBody();
    }
    OtherPortal.LockExit(A);
    PlayPortalCue('PortalEnter');
    OtherPortal.PlayPortalCue('PortalExit');
    ++TraversalCount;
    `log("KF2VR_PORTAL action=traverse color=" $ PortalColor @ "actor=" $ A.Class
        @ "speed=" $ VSize(NewVelocity));
    return true;
}

function ObserveTraveler(Actor A, float DeltaTime)
{
    local PortalTraveler Record;
    local int I;
    local vector Extent, X,Y,Z, Previous, Predicted, CrossPoint, Hit, N, Current, Motion;
    local float Depth, Distance;
    local Actor Obstacle;
    if (!CanTransport(A)) return;
    if (A == NativeTraversalPawn && WorldInfo.TimeSeconds <= NativeTraversalLeaseUntil) return;
    Current=BodyPosition(A);
    Motion=BodyVelocity(A);
    I=Travelers.Find('Body',A);
    if (I<0)
    {
        Record.Body=A;
        Record.Previous=Current-Motion*FMin(DeltaTime,0.1);
        I=Travelers.Length;
        Travelers.AddItem(Record);
    }
    Previous=Travelers[I].Previous;
    Travelers[I].Previous=Current;
    Travelers[I].LastSeen=WorldInfo.TimeSeconds;
    GetAxes(Rotation,X,Y,Z);
    Extent=BodyExtent(A);
    Depth=ExtentAlong(Extent,X)+2;
    Distance=(Current-Location) dot X;
    if (Travelers[I].bExitLocked)
    {
        if (Distance > Depth+8) Travelers[I].bExitLocked=false;
        return;
    }
    // Check swept motion, plus at most one frame of approach to the collision
    // wall. Never globally disable collision in order to get through it.
    Predicted=Current;
    if ((Motion dot X) < -1 && Distance > 0)
        Predicted += Motion*FMin(DeltaTime,0.05);
    if (Pawn(A) != None && Distance > Depth-4 && Distance <= Depth+1
        && (A.Acceleration dot X) < -1)
    {
        // Walking collision can zero velocity before this tick. An actual
        // inward movement request permits transfer while pressed to the rim.
        Previous=Current+X*8;
        Predicted=Current-X*4;
    }
    if (!class'VRPortalMath'.static.SweptCrossing(Previous,Predicted,Location,Rotation,Depth,CrossPoint)) return;
    if (!class'VRPortalMath'.static.InsideEllipse((CrossPoint-Location) << Rotation,
        HalfWidth,HalfHeight,ExtentAlong(Extent,Y),ExtentAlong(Extent,Z))) return;
    // A high speed actor cannot teleport through an intervening obstacle.
    foreach TraceActors(class'Actor',Obstacle,Hit,N,CrossPoint,Previous)
        if (Obstacle != A) return;
    Transfer(A,CrossPoint);
}

// Native movement calls this only AFTER a collision-checked relocation. This
// completes pawn/gameplay bookkeeping without a second location change.
function NativeCommitTraversal(Pawn A, vector MappedVelocity, vector MappedAcceleration,
    rotator MappedBodyRotation, rotator MappedViewRotation)
{
    if (Role != ROLE_Authority || WorldInfo.NetMode != NM_Standalone
        || A == None || A != NativeTraversalPawn || A.Health <= 0
        || OtherPortal == None || OtherPortal.bDeleteMe) return;
    class'VRPortalCarry'.static.ReleaseForPortalTravel(A);
    A.SetBase(None);
    A.SetPhysics(PHYS_Falling);
    A.SetRotation(MappedBodyRotation);
    if (A.Controller != None)
    {
        A.SetViewRotation(MappedViewRotation);
        A.ClientSetRotation(MappedViewRotation);
        A.Controller.MoveTimer=-1;
    }
    A.Velocity=MappedVelocity;
    A.Acceleration=MappedAcceleration;
    OtherPortal.LockExit(A);
    PlayPortalCue('PortalEnter');
    OtherPortal.PlayPortalCue('PortalExit');
    ++TraversalCount;
    `log("KF2VR_PORTAL action=native-traverse color=" $ PortalColor @ "actor=" $ A.Class
        @ "speed=" $ VSize(MappedVelocity));
}

event Tick(float DeltaTime)
{
    local Actor A;
    local int I;
    if (Role != ROLE_Authority || WorldInfo.NetMode != NM_Standalone) return;
    if (Launcher == None || Launcher.bDeleteMe || Instigator == None || Instigator.Health <= 0
        || Launcher.Instigator != Instigator)
    { Destroy(); return; }
    if (WorldInfo.TimeSeconds >= NextMountCheck)
    {
        NextMountCheck=WorldInfo.TimeSeconds+0.25;
        if (MountActor == None || MountActor.bDeleteMe || !SampleSurface(self,Location,vector(Rotation)))
        { Destroy(); return; }
    }
    if (OtherPortal == None || OtherPortal.bDeleteMe) return;
    foreach CollidingActors(class'Actor',A,1600,Location) ObserveTraveler(A,DeltaTime);
    for (I=Travelers.Length-1; I>=0; --I)
        if (Travelers[I].Body == None || Travelers[I].Body.bDeleteMe
            || WorldInfo.TimeSeconds-Travelers[I].LastSeen > 1) Travelers.Remove(I,1);
}

event Destroyed()
{
    PlayPortalCue(PortalColor == 0 ? 'PortalClose' : 'PortalCloseOrange');
    LinkTo(None);
    if (Surface != None) { Surface.ShutdownPortal(); Surface.Destroy(); Surface=None; }
    Launcher=None;
    NativeTraversalPawn=None;
    Travelers.Length=0;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bStatic=false
    bMovable=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    HalfWidth=81.28
    HalfHeight=142.24
    TickGroup=TG_PreAsyncWork
}
