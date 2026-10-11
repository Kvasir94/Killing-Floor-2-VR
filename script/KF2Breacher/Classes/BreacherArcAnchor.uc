// Replicated accepted attachment, not a kinematic handle. Never fixes bodies or
// takes ownership from a player's grab. A missing attachment expires locally.
class BreacherArcAnchor extends Actor;

var BreacherArcGroup Group;
var repnotify Actor Target;
var PrimitiveComponent TargetComponent;
var repnotify name AttachBone;
var vector LocalOffset;
var rotator LocalPinRotation;
var float MissingSince;
var bool bAttachmentReady, bMissingBody;
var repnotify bool bWorldAnchor, bOccupant, bDestination;
var bool bReachable;
var int Serial;
var float Resistance, LastActivity;
// Independent of ambient motion: a severed/isolated attachment has a bounded
// cleanup deadline. Only authoring a fresh accepted edge clears this latch.
var float DisconnectedAt;
var bool bDisconnected;
var vector ActivityPosition;
var array<vector> LastZones;
var array<float> ZoneCooldown;
var vector PreviousContactPoint;
var bool bHaveContactPoint;
var repnotify byte PresentationPhase;
var StaticMeshComponent Marker, Hardware;
var MaterialInstanceConstant Glow;

replication
{
    if (bNetDirty) Target, AttachBone, bWorldAnchor, bOccupant, bDestination, PresentationPhase;
}

function bool Initialize(BreacherArcGroup G, Actor A, PrimitiveComponent C, name Bone, vector Point, bool Occupant,
    optional vector SurfaceNormal)
{
    local Pawn P;
    Group = G; Target = A; TargetComponent = C; AttachBone = Bone;
    if (IsZero(SurfaceNormal)) SurfaceNormal=Normal(G.Shooter.Location-Point);
    SetRotation(rotator(-SurfaceNormal)); // driven hardware points into contact
    LocalPinRotation=Rotation;
    bOccupant = Occupant;
    P = Pawn(A);
    bWorldAnchor = A == None || A.bWorldGeometry || A.bStatic;
    // A temporarily kinematic prop remains a moving endpoint. Fixed physics
    // alone never promotes it into the static fence hull or world destination.
    if (!bWorldAnchor && A == None) return false;
    if (P != None && P.Mesh != None)
    {
        TargetComponent = P.Mesh;
        if (Bone != '' && P.Mesh.MatchRefBone(Bone) == INDEX_NONE) return false;
        if (Bone != '') P.Mesh.TransformToBoneSpace(Bone,Point,Rotation,LocalOffset,LocalPinRotation);
        else LocalOffset = Point - P.Location;
    }
    else if (A != None)
    {
        LocalOffset = (Point - A.Location) << A.Rotation;
        LocalPinRotation=QuatToRotator(QuatProduct(QuatInvert(QuatFromRotator(A.Rotation)),QuatFromRotator(Rotation)));
    }
    SetLocation(Point);
    ActivityPosition = Point;
    if (P!=None && P.Health>0 && P.Physics!=PHYS_RigidBody) ActivityPosition=P.Location;
    LastActivity = WorldInfo.TimeSeconds;
    DisconnectedAt=WorldInfo.TimeSeconds;
    bDisconnected=true;
    Resistance = EffectiveResistance();
    bAttachmentReady=true;
    return true;
}

function float EffectiveResistance()
{
    local RB_BodyInstance B;
    local KFPawn_Monster M;
    if (bWorldAnchor) return 1000000;
    M = KFPawn_Monster(Target);
    if (M != None)
    {
        if (M.Health <= 0) return 80;
        if (M.IsABoss()) return 2000;
        if (M.IsLargeZed()) return 500;
        return 110;
    }
    if (Pawn(Target) != None) return 160;
    if (TargetComponent != None)
    {
        B = TargetComponent.GetRootBodyInstance();
        if (B != None && B.IsValidBodyInstance())
        {
            if (B.IsFixed()) return 5000;
            return FClamp(B.GetBodyMass(), 10, 5000);
        }
    }
    return 1000; // constrained/non-physical prop: retains endpoint, no teleport
}

function bool Refresh()
{
    local Pawn P;
    local vector Point, ActivityPoint;
    local rotator IgnoredRotation;
    local RB_BodyInstance Body;
    local int BoneIndex;
    bAttachmentReady=true;
    if (bWorldAnchor) return Target == None || !Target.bDeleteMe;
    if (Target == None || Target.bDeleteMe) return false;
    P = Pawn(Target);
    if (P != None)
    {
        if (P.Mesh == None) return false;
        TargetComponent = P.Mesh; // death can rebuild the component
        if (AttachBone != '')
        {
            BoneIndex=P.Mesh.MatchRefBone(AttachBone);
            if (BoneIndex == INDEX_NONE || P.Mesh.IsBoneHidden(BoneIndex)) return false;
            P.Mesh.TransformFromBoneSpace(AttachBone,LocalOffset,LocalPinRotation,Point,IgnoredRotation);
            SetRotation(IgnoredRotation);
            if (P.Physics==PHYS_RigidBody || P.Health<=0)
            {
                Body=P.Mesh.FindBodyInstanceNamed(AttachBone);
                if (Body==None || !Body.IsValidBodyInstance())
                {
                    bAttachmentReady=false;
                    if (!bMissingBody) { bMissingBody=true; MissingSince=WorldInfo.TimeSeconds; }
                    // Retain exact named ownership over stock gore/death rebuild,
                    // but never jump to a nearby surviving sibling/root body.
                    return WorldInfo.TimeSeconds-MissingSince<=1.5;
                }
            }
        }
        else Point = P.Location + LocalOffset;
    }
    else
    {
        Point = Target.Location + (LocalOffset >> Target.Rotation);
        SetRotation(QuatToRotator(QuatProduct(QuatFromRotator(Target.Rotation),QuatFromRotator(LocalPinRotation))));
    }
    SetLocation(Point);
    bMissingBody=false;
    ActivityPoint=Point;
    if (P!=None && P.Health>0 && P.Physics!=PHYS_RigidBody) ActivityPoint=P.Location;
    if (VSizeSq(ActivityPoint - ActivityPosition) > 64)
    {
        ActivityPosition = ActivityPoint;
        LastActivity = WorldInfo.TimeSeconds;
    }
    Resistance = EffectiveResistance();
    return true;
}

function vector PointVelocity()
{
    local RB_BodyInstance B;
    if (bWorldAnchor || Target == None) return vect(0,0,0);
    if (TargetComponent != None)
    {
        B = AttachmentBody();
        if (B != None && B.IsValidBodyInstance() && !B.IsFixed())
            return B.GetUnrealWorldVelocityAtPoint(Location);
    }
    return Target.Velocity;
}

function RB_BodyInstance AttachmentBody()
{
    if (TargetComponent==None) return None;
    if (AttachBone!='' && SkeletalMeshComponent(TargetComponent)!=None)
        return SkeletalMeshComponent(TargetComponent).FindBodyInstanceNamed(AttachBone);
    return TargetComponent.GetRootBodyInstance();
}

function bool DetachedPiece()
{
    local SkeletalMeshComponent S;
    S=SkeletalMeshComponent(TargetComponent);
    return S!=None && BoneDetached(S,AttachBone);
}

static function bool BoneDetached(SkeletalMeshComponent S,name Bone)
{
    local name ParentBone;
    local int Steps;
    if (S==None || S.PhysicsAssetInstance==None || Bone=='') return false;
    for (Steps=0; Steps<256; ++Steps)
    {
        if (S.IsBrokenConstraint(Bone)) return true;
        ParentBone=S.GetParentBone(Bone);
        if (ParentBone=='' || ParentBone==Bone) return false;
        Bone=ParentBone;
    }
    return true; // unknown topology must never move/consume the whole pawn
}

// Short, collision-resolved pressure after arrival, never a visual shrink or a
// kinematic pose. Only connected corpse bodies participate; a new grab aborts
// the whole corpse immediately, and already detached branches stay untouched.
function Compress(vector Center,float Delta)
{
    local SkeletalMeshComponent S;
    local KFPawn_Monster M;
    local RB_BodyInstance B;
    local name Bone;
    local vector Point,Direction,Change;
    local float Distance,Along;
    local int I;
    M=KFPawn_Monster(Target);
    S=SkeletalMeshComponent(TargetComponent);
    if (M==None || M.Health>0 || !M.bPlayedDeath || M.bDeleteMe || S==None || S.PhysicsAsset==None
        || !CorpseArrived(Center,100)) return;
    for (I=0; I<S.PhysicsAsset.BodySetup.Length; ++I)
    {
        Bone=S.PhysicsAsset.BodySetup[I].BoneName;
        if (BoneDetached(S,Bone) || S.IsBoneHidden(S.MatchRefBone(Bone))
            || class'BreacherConsumedPiece'.static.IsConsumed(M,Bone)) continue;
        B=S.FindBodyInstanceNamed(Bone);
        if (B==None || !B.IsValidBodyInstance() || B.IsFixed()) continue;
        Point=MatrixGetOrigin(B.GetUnrealWorldTM());
        Direction=Center-Point; Distance=VSize(Direction);
        if (Distance<12) continue;
        Direction/=Distance;
        Along=B.GetUnrealWorldVelocityAtPoint(Point) dot Direction;
        Change=Direction*FClamp(180-Along,0,900*Delta);
        S.AddImpulse(Change*B.GetBodyMass(),Point,Bone);
    }
}

function bool CorpseArrived(vector Destination,float Radius)
{
    local RB_BodyInstance Root;
    local KFPawn_Monster M;
    M=KFPawn_Monster(Target);
    if (M!=None && M.Mesh!=None && class'BreacherConsumedPiece'.static.IsConsumed(M,M.Mesh.GetBoneName(0))) return false;
    if (DetachedPiece() || HasHeldBody() || TargetComponent==None) return false;
    Root=TargetComponent.GetRootBodyInstance();
    // Actor.Location can stay at the death location after ragdoll travel. Only
    // the actual connected root body establishes whole-corpse arrival.
    return Root!=None && Root.IsValidBodyInstance() && !Root.IsFixed()
        && VSizeSq(MatrixGetOrigin(Root.GetUnrealWorldTM())-Destination)<=Square(Radius);
}

// Conservative corpse finish guard: no consuming a mesh containing a hand-owned
// fixed body. This preserves both retained Rend pieces during a nearby collapse.
function bool HasHeldBody()
{
    local SkeletalMeshComponent S;
    local RB_BodyInstance B;
    local int I;
    S=SkeletalMeshComponent(TargetComponent);
    if (S==None || S.PhysicsAsset==None || S.bUpdateKinematicBonesFromAnimation) return false;
    for (I=0; I<S.PhysicsAsset.BodySetup.Length; ++I)
    {
        B=S.FindBodyInstanceNamed(S.PhysicsAsset.BodySetup[I].BoneName);
        if (B!=None && B.IsValidBodyInstance() && B.IsFixed()) return true;
    }
    return false;
}

function Pull(vector Direction, float PullRate, float Delta)
{
    local Pawn P;
    local RB_BodyInstance B;
    local vector Change;
    local bool Detached;
    if (bWorldAnchor || !bAttachmentReady || Target == None || Target.bDeleteMe) return;
    if (KFPawn_Monster(Target)!=None && class'BreacherConsumedPiece'.static.IsConsumed(KFPawn_Monster(Target),
        AttachBone!='' ? AttachBone : Pawn(Target).Mesh.GetBoneName(0))) return;
    P = Pawn(Target);
    Detached=DetachedPiece();
    Change = Direction * PullRate * Delta * FClamp(110 / Resistance, 0.05, 2);
    if (TargetComponent != None)
    {
        B = AttachmentBody();
        if (B!=None && B.IsValidBodyInstance() && B.IsFixed()
            && (Detached || Target.Physics==PHYS_RigidBody || (P!=None && P.Health<=0))) return;
        if ((Detached || Target.Physics == PHYS_RigidBody || (P != None && P.Health <= 0))
            && B != None && B.IsValidBodyInstance() && !B.IsFixed())
        {
            // Impulse at the attachment introduces torque and keeps collisions.
            TargetComponent.AddImpulse(Change * Resistance, Location, AttachBone);
            return;
        }
    }
    if (!Detached && P != None && P.Health > 0)
    {
        // Native Pawn movement owns sweeps and server correction. No SetLocation
        // or camera displacement. Player prediction/comfort needs online testing.
        P.AddVelocity(Change, Location, class'BreacherArcImpact');
    }
}

simulated event PostBeginPlay()
{
    local StaticMesh PinMesh;
    local MaterialInstanceConstant PinSurface;
    Super.PostBeginPlay();
    if (WorldInfo.NetMode == NM_DedicatedServer) return;
    // Existing adapted rigging hardware, not a new mandatory collar assembly.
    PinMesh=StaticMesh(DynamicLoadObject("KF2VRHands.VRRipcordHook",class'StaticMesh',true));
    PinSurface=class'BreacherArcVisuals'.static.Surface(self,"VRRipcordHook");
    if (PinMesh!=None && PinSurface!=None)
    {
        Hardware=class'BreacherArcVisuals'.static.Part(self,PinMesh);
        Hardware.SetMaterial(0,PinSurface);
        Hardware.SetScale(0.45);
        Hardware.SetTranslation(vect(-4,0,0));
    }
    Marker=class'BreacherArcVisuals'.static.Part(self,StaticMesh'EngineMeshes.Sphere');
    Marker.SetScale(0.012);
    Marker.SetTranslation(vect(-4.5,0,0));
    Glow = new(self) class'MaterialInstanceConstant';
    Glow.SetParent(Material'EngineDebugMaterials.LevelColorationUnlitMaterial');
    Marker.SetMaterial(0, Glow);
}

simulated event Tick(float Delta)
{
    local LinearColor C;
    local float Brightness;
    if (Glow == None) return;
    if (Hardware!=None) Hardware.SetHidden(bOccupant);
    Brightness=PresentationPhase==3 ? 0.15 : 0.75;
    if (bDestination && PresentationPhase!=3)
        Brightness=1.25+0.45*Sin(WorldInfo.TimeSeconds*(PresentationPhase>0 ? 14 : 5));
    if (PresentationPhase==2) Brightness*=1.5;
    C.R = bDestination ? 1.0 : 0.1;
    C.G = bDestination ? 0.7 : 0.5;
    C.B = bDestination ? 0.1 : 1.0;
    C.A = 1;
    C.R*=Brightness; C.G*=Brightness; C.B*=Brightness;
    Glow.SetVectorParameterValue('Color', C);
    Marker.SetScale(bDestination ? 0.019 : (bOccupant ? 0.006 : 0.012));
}

simulated event Destroyed()
{
    if (Hardware!=None) DetachComponent(Hardware);
    if (Marker!=None) DetachComponent(Marker);
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=15
}
