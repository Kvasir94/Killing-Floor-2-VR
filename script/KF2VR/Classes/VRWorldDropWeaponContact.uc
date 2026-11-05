// Bounded authority-only swept contact for one exact world prop. Engine pawn
// cylinders select candidates; only its real named stock hurtboxes accept hits.
class VRWorldDropWeaponContact extends Object;

struct BodySample
{
    var KFPawn_Monster Victim;
    var SkeletalMeshComponent Mesh;
    var PhysicsAsset Asset;
    var name Bone;
    var matrix Frame;
    var float At;
};
struct VictimContact
{
    var KFPawn_Monster Victim;
    var bool bLatched, bTouching;
    var float LastSeen;
};
struct WeaponImpact
{
    var name Zone, Bone;
    var vector Point, Normal, LocalPoint, Velocity, VictimVelocity;
    var vector TipAxis, EdgeAxis, EdgeTangent;
    var PhysicalMaterial BodyMaterial;
    var float Fraction;
    var int Region, Triangle, Material, SourceFace;
    var bool bHit;
};
struct HurtboxShape
{
    var int Kind;
    var name Zone;
    var matrix Frame;
    var vector Extent;
    var float Radius, HalfLength;
};
struct HurtboxBody
{
    var name Bone;
    var PhysicalMaterial BodyMaterial;
    var array<HurtboxShape> Shapes;
};
struct HurtboxAsset
{
    var PhysicsAsset Asset;
    var array<HurtboxBody> Bodies;
};
var VRWorldDropGun Prop;
var array<BodySample> Bodies;
var array<VictimContact> Victims;
var array<HurtboxAsset> Assets;
var vector PreviousRoot;
var quat PreviousQ;
var float PreviousScale, PreviousAt;
var bool bSeeded;
var bool bRepositioned;
var vector RepositionedRoot;
var quat RepositionedQ;

static function bool ReadFrame(matrix TM, out vector Position, out quat Q, out vector Scale)
{
    local vector X, Y, Z;
    Position = MatrixGetOrigin(TM);
    X = TransformNormal(TM, vect(1,0,0)); Y = TransformNormal(TM, vect(0,1,0)); Z = TransformNormal(TM, vect(0,0,1));
    Scale.X = VSize(X); Scale.Y = VSize(Y); Scale.Z = VSize(Z);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Position)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Scale)
        || Scale.X < 0.001 || Scale.Y < 0.001 || Scale.Z < 0.001
        || Scale.X > 64 || Scale.Y > 64 || Scale.Z > 64) return false;
    X /= Scale.X; Y /= Scale.Y; Z /= Scale.Z;
    if (Abs(X dot Y) > 0.001 || Abs(Y dot Z) > 0.001 || Abs(Z dot X) > 0.001 || ((X cross Y) dot Z) < 0.999) return false;
    Q = QuatFromRotator(OrthoRotation(X,Y,Z));
    return class'VRHandRolePose'.static.ValidQuaternion(Q);
}

// Root, Q and scale are the prop's contact frame (VRWorldDropGun.ContactFrame).
function Reset(VRWorldDropGun P)
{
    local float Scale;
    local int Geometry;
    Prop = P; Bodies.Length = 0; Victims.Length = 0; bSeeded = false;
    if (P == None || P.MyMeshComp == None || !P.ContactFrame(Geometry, PreviousRoot, PreviousQ, Scale)) return;
    Seed(P,PreviousRoot,PreviousQ,Scale);
}

function Seed(VRWorldDropGun P, vector Root, quat Q, float Scale)
{
    Prop = P; PreviousRoot = Root; PreviousQ = Q; PreviousScale = Scale;
    PreviousAt = P.WorldInfo.TimeSeconds; bSeeded = true;
}

function int BodyIndex(KFPawn_Monster M, name Bone, matrix Current, float Now)
{
    local int I;
    local BodySample S;
    for (I = 0; I < Bodies.Length; ++I)
        if (Bodies[I].Victim == M && Bodies[I].Bone == Bone) return I;
    if (Bodies.Length >= 512) return -1;
    S.Victim = M; S.Mesh = M.Mesh; S.Asset = M.Mesh.PhysicsAsset; S.Bone = Bone;
    S.Frame = Current; S.At = Now;
    Bodies.AddItem(S);
    return Bodies.Length - 1;
}

function int VictimIndex(KFPawn_Monster M)
{
    local int I;
    local VictimContact V;
    for (I = 0; I < Victims.Length; ++I) if (Victims[I].Victim == M) return I;
    if (Victims.Length >= 32) return -1;
    V.Victim = M; Victims.AddItem(V); return Victims.Length - 1;
}

// Asset shapes are immutable, unlike the posed mesh/body instances. Build the
// named-hurtbox descriptors once per real asset and reuse them for every pawn
// of that class; do not walk reflected AggGeom arrays on every physics tick.
function int AssetIndex(PhysicsAsset Asset)
{
    local int I, J;
    local HurtboxAsset Cache;
    local HurtboxBody Body;
    local HurtboxShape Shape;
    local RB_BodySetup Setup;
    for (I = 0; I < Assets.Length; ++I) if (Assets[I].Asset == Asset) return I;
    if (Asset == None || Assets.Length >= 32 || Asset.BodySetup.Length > 128) return -1;
    Cache.Asset = Asset;
    for (I = 0; I < Asset.BodySetup.Length; ++I)
    {
        Setup = Asset.BodySetup[I];
        if (Setup == None || !Setup.bBlockZeroExtent || Setup.BoneName == '') continue;
        Body.Bone = Setup.BoneName; Body.BodyMaterial = Setup.PhysMaterial; Body.Shapes.Length = 0;
        for (J = 0; J < Setup.AggGeom.SphereElems.Length; ++J)
            if (!Setup.AggGeom.SphereElems[J].bNoUECollision && Setup.AggGeom.SphereElems[J].HitZoneName != '')
            {
                Shape.Kind = 0; Shape.Zone = Setup.AggGeom.SphereElems[J].HitZoneName;
                Shape.Frame = Setup.AggGeom.SphereElems[J].TM; Shape.Radius = Setup.AggGeom.SphereElems[J].Radius;
                Shape.HalfLength = 0; Shape.Extent = vect(0,0,0); Body.Shapes.AddItem(Shape);
            }
        for (J = 0; J < Setup.AggGeom.SphylElems.Length; ++J)
            if (!Setup.AggGeom.SphylElems[J].bNoUECollision && Setup.AggGeom.SphylElems[J].HitZoneName != '')
            {
                Shape.Kind = 1; Shape.Zone = Setup.AggGeom.SphylElems[J].HitZoneName;
                Shape.Frame = Setup.AggGeom.SphylElems[J].TM; Shape.Radius = Setup.AggGeom.SphylElems[J].Radius;
                Shape.HalfLength = Setup.AggGeom.SphylElems[J].Length * 0.5; Shape.Extent = vect(0,0,0); Body.Shapes.AddItem(Shape);
            }
        for (J = 0; J < Setup.AggGeom.BoxElems.Length; ++J)
            if (!Setup.AggGeom.BoxElems[J].bNoUECollision && Setup.AggGeom.BoxElems[J].HitZoneName != '')
            {
                Shape.Kind = 2; Shape.Zone = Setup.AggGeom.BoxElems[J].HitZoneName;
                Shape.Frame = Setup.AggGeom.BoxElems[J].TM; Shape.Radius = 0; Shape.HalfLength = 0;
                Shape.Extent.X = Setup.AggGeom.BoxElems[J].X * 0.5;
                Shape.Extent.Y = Setup.AggGeom.BoxElems[J].Y * 0.5;
                Shape.Extent.Z = Setup.AggGeom.BoxElems[J].Z * 0.5; Body.Shapes.AddItem(Shape);
            }
        if (Body.Shapes.Length > 0 && Body.Shapes.Length <= 32) Cache.Bodies.AddItem(Body);
    }
    Assets.AddItem(Cache); return Assets.Length - 1;
}

function QueryShape(KFPawn_Monster M, int V, int Geometry, int Kind, name Zone, name Bone,
    matrix LocalFrame, matrix OldBone, matrix BoneFrame, vector Dimensions, float Radius,
    float HalfLength, PhysicalMaterial BodyMaterial, vector Root, quat Q, float Scale, float DT, out WeaponImpact Best)
{
    local vector Before, Current, OldScale, CurrentScale;
    local quat BeforeQ, CurrentQ;
    local matrix OldTM, CurrentTM;
    local float ShapeReach, WeaponReach;
    if (Zone == '' || M.GetHitZoneIndex(Zone) < 0) return;
    OldTM = LocalFrame * OldBone; CurrentTM = LocalFrame * BoneFrame;
    if (!ReadFrame(OldTM, Before, BeforeQ, OldScale) || !ReadFrame(CurrentTM, Current, CurrentQ, CurrentScale)
        || VSizeSq(OldScale - CurrentScale) > 0.0001) return;
    if (Kind != 2 && (Abs(CurrentScale.X - CurrentScale.Y) > 0.001 || Abs(CurrentScale.Y - CurrentScale.Z) > 0.001)) return;
    Dimensions.X *= CurrentScale.X; Dimensions.Y *= CurrentScale.Y; Dimensions.Z *= CurrentScale.Z;
    ShapeReach = Kind == 2 ? VSize(Dimensions) : Radius * CurrentScale.X + HalfLength * CurrentScale.Z;
    WeaponReach = VSize(Prop.MyMeshComp.Bounds.BoxExtent) + VSize(Prop.MyMeshComp.Bounds.Origin - Root);
    if (VSizeSq((Before + Current - PreviousRoot - Root) * 0.5)
        > Square(ShapeReach + WeaponReach + (VSize(Current - Before) + VSize(Root - PreviousRoot)) * 0.5 + 1.0)) return;
    Prop.SurfaceHit = 0; Prop.SurfaceCurrentOverlap = 0;
    Prop.NativeThrownSurfaceSweep(Geometry, PreviousRoot, PreviousQ, Root, Q,
        Before, BeforeQ, Current, CurrentQ, Kind, Dimensions,
        Radius * CurrentScale.X, HalfLength * CurrentScale.Z, DT, Scale);
    Victims[V].bTouching = Victims[V].bTouching || Prop.SurfaceCurrentOverlap != 0;
    // A preexisting overlap cannot manufacture a fresh impact on release.
    if (Prop.SurfaceHit == 0 || Prop.SurfaceFraction <= 0 || (Best.bHit && Prop.SurfaceFraction >= Best.Fraction)) return;
    Best.Zone = Zone; Best.Bone = Bone; Best.Point = Prop.SurfacePoint; Best.Normal = Prop.SurfaceNormal;
    Best.LocalPoint = Prop.SurfaceLocalPoint; Best.Velocity = Prop.SurfaceWeaponVelocity - Prop.SurfaceVictimVelocity;
    Best.VictimVelocity = Prop.SurfaceVictimVelocity; Best.BodyMaterial = BodyMaterial;
    Best.TipAxis = Prop.SurfaceTipAxis; Best.EdgeAxis = Prop.SurfaceEdgeAxis;
    Best.EdgeTangent = Prop.SurfaceEdgeTangent;
    Best.Fraction = Prop.SurfaceFraction; Best.Region = Prop.SurfaceRegion;
    Best.Triangle = Prop.SurfaceTriangle; Best.SourceFace = Prop.SurfaceSourceFace; Best.Material = Prop.SurfaceMaterial;
    Best.bHit = true;
}

function QueryVictim(KFPawn_Monster M, int V, int Geometry, vector Root, quat Q, float Scale, float DT, float Now, out WeaponImpact Best)
{
    local int I, J, Index, BoneIndex, Cache;
    local name Bone;
    local matrix BoneFrame, OldBone;
    local RB_BodyInstance Body;
    local PhysicalMaterial BodyMaterial;
    Cache = AssetIndex(M.Mesh.PhysicsAsset); if (Cache < 0) return;
    for (I = 0; I < Assets[Cache].Bodies.Length; ++I)
    {
        Bone = Assets[Cache].Bodies[I].Bone;
        BoneIndex = M.Mesh.MatchRefBone(Bone);
        if (BoneIndex < 0 || class'VRBoneVisibility'.static.IsHiddenIndex(M.Mesh, BoneIndex) || class'VRBodyHold'.static.Consumed(M.Mesh, Bone)) continue;
        BoneFrame = M.Mesh.GetBoneMatrix(BoneIndex);
        Index = BodyIndex(M, Bone, BoneFrame, Now);
        if (Index < 0) continue;
        OldBone = Bodies[Index].Frame;
        if (Bodies[Index].Mesh != M.Mesh || Bodies[Index].Asset != M.Mesh.PhysicsAsset || Now - Bodies[Index].At > DT + 0.001)
            OldBone = BoneFrame;
        BodyMaterial = Assets[Cache].Bodies[I].BodyMaterial;
        Body = M.Mesh.FindBodyInstanceNamed(Bone);
        if (Body != None && Body.PhysMaterialOverride != None) BodyMaterial = Body.PhysMaterialOverride;
        for (J = 0; J < Assets[Cache].Bodies[I].Shapes.Length; ++J)
            QueryShape(M,V,Geometry,Assets[Cache].Bodies[I].Shapes[J].Kind,Assets[Cache].Bodies[I].Shapes[J].Zone,Bone,
                Assets[Cache].Bodies[I].Shapes[J].Frame,OldBone,BoneFrame,Assets[Cache].Bodies[I].Shapes[J].Extent,
                Assets[Cache].Bodies[I].Shapes[J].Radius,Assets[Cache].Bodies[I].Shapes[J].HalfLength,
                BodyMaterial,Root,Q,Scale,DT,Best);
        Bodies[Index].Frame = BoneFrame; Bodies[Index].Mesh = M.Mesh;
        Bodies[Index].Asset = M.Mesh.PhysicsAsset; Bodies[Index].At = Now;
    }
}

function ApplyImpact(KFPawn_Monster M, int V, int Geometry, vector Root, quat Q, WeaponImpact Best)
{
    local vector BodyAt, HitRoot, BodyTarget;
    local quat BodyQ, HitQ, DeltaQ;
    local byte TargetSurfaceKind;
    local bool bSharp;
    // Latch BEFORE stock callbacks, which can kill, dismember or retire actors.
    Victims[V].bLatched = true;
    // Blade zones authored in the rig frame (the compound bow's spike and
    // limbs) classify a contact the pickup surface itself leaves blunt.
    if (Best.Region == 0) Best.Region = Prop.RigSharpAt(Best.LocalPoint, 0.75);
    TargetSurfaceKind = Prop.ResolveThrownTargetSurface(M,Best.Zone,Best.Point,Best.Velocity,Best.BodyMaterial);
    Prop.NotifyThrownImpact(Geometry,Best.Triangle,Best.Material,Best.SourceFace,Best.Region,
        Best.Point,Best.Normal,Best.LocalPoint,TargetSurfaceKind);
    HitQ = QuatSlerp(PreviousQ,Q,Best.Fraction,true);
    bSharp = class'VRWorldDropReactions'.static.DamageWeapon(Prop, M, Best.Zone, Best.Point,
        Best.Normal, Best.Velocity, Best.Region, Best.TipAxis, Best.EdgeAxis, Best.EdgeTangent, HitQ);
    if (TargetSurfaceKind == 2 || TargetSurfaceKind == 3)
    {
        Deflect(Best,Root,HitQ,0.28);
        return;
    }
    if (TargetSurfaceKind == 1 && bSharp && Best.Region > 0 && VSizeSq(Best.Velocity) >= Square(300.0)
        && -(Best.Velocity dot Best.Normal) >= 200.0 && Prop.Embedded.Victim == None
        && Prop.BodyFrame(BodyAt, BodyQ))
    {
        HitRoot = PreviousRoot + (Root - PreviousRoot) * Best.Fraction;
        DeltaQ = QuatProduct(HitQ,QuatInvert(Q));
        BodyTarget = HitRoot + QuatRotateVector(DeltaQ,BodyAt - Root) + Normal(Best.Velocity) * 2.0;
        if (Prop.EmbedFollower == None) Prop.EmbedFollower = new(Prop) class'VRWorldDropEmbed';
        if (Prop.EmbedFollower.Begin(Prop,M,Best.Bone,BodyTarget,QuatProduct(DeltaQ,BodyQ))) return;
    }
    // Flesh and unresolved solid hurtboxes still stop a real prop when pawn
    // RB collision is disabled. A failed/slow/flat embed gets the same exact
    // inertia response, with softer restitution and no extra hit or effect.
    Deflect(Best,Root,HitQ,0.10);
}

function Deflect(WeaponImpact Impact, vector Root, quat HitQ, float Restitution)
{
    local RB_BodyInstance Body;
    local vector HitRoot;
    if (Prop.NativeThrownSurfaceAllowed() == 0 || Prop.MyMeshComp == None) return;
    Body = Prop.MyMeshComp.BodyInstance;
    if (Body == None || !Body.IsValidBodyInstance()) return;
    // Pawn rigid-body collision may be disabled. Put this same prop at its
    // swept contact, outside the surface, before applying the stock impulse.
    HitRoot = PreviousRoot + (Root - PreviousRoot) * Impact.Fraction + Impact.Normal * 0.75;
    Prop.MyMeshComp.SetRBRotation(QuatToRotator(HitQ)); Prop.MyMeshComp.SetRBPosition(HitRoot);
    Prop.InvalidateBallisticContact();
    // The private bridge snapshots the real COM, mass and full inverse inertia
    // under the stock scene lock. One normal impulse supplies bounded energy
    // loss and the body's own torque response; there is no guessed mass or
    // angular reset, and no dependence on the stock point-velocity stub.
    Prop.BodyResponseValid = 0;
    // The snapshot rejects separating contact, so a stock collision that has
    // already deflected this body cannot receive a second collision impulse.
    Prop.NativeThrownBodyResponse(Impact.Point,Impact.Normal,Impact.VictimVelocity,Restitution);
    if (Prop.BodyResponseValid != 0) Prop.MyMeshComp.AddImpulse(Prop.BodyResponseImpulse,Impact.Point);
    Prop.MyMeshComp.WakeRigidBody();
    Prop.bGrounded = false; Prop.bHavePrevious = false; Prop.GripHistoryCount = 0;
    Prop.bForceNetUpdate = true; Prop.bNetDirty = true; bRepositioned = true;
    RepositionedRoot = HitRoot; RepositionedQ = HitQ;
}

function Update()
{
    local vector Root;
    local quat Q;
    local float Scale;
    local KFPawn_Monster M;
    local float DT, Now, SearchRadius, MotionSpeedBound;
    local int I, V, Geometry, FirstVictimIndex;
    local KFPawn_Monster FirstVictim;
    local WeaponImpact Impact, EmptyImpact, FirstImpact;
    if (Prop == None || Prop.Role != ROLE_Authority || Prop.bPublic || Prop.bReturning || Prop.bCatchPending
        || Prop.Embedded.Victim != None || Prop.MyMeshComp == None) return;
    bRepositioned = false;
    Now = Prop.WorldInfo.TimeSeconds;
    if (!Prop.ContactFrame(Geometry, Root, Q, Scale)) { Reset(Prop); return; }
    DT = Now - PreviousAt;
    if (!bSeeded || DT <= 0 || DT > 0.1 || Abs(Scale - PreviousScale) > 0.001 || VSizeSq(Root - PreviousRoot) > Square(128.0))
    { Reset(Prop); return; }
    MotionSpeedBound = VSize(Root - PreviousRoot) / DT
        + 2.0 * Acos(FClamp(Abs(QuatDot(PreviousQ,Q)),0,1)) / DT
        * (VSize(Prop.MyMeshComp.Bounds.BoxExtent) + VSize(Prop.MyMeshComp.Bounds.Origin - Root));
    if (MotionSpeedBound < 220.0) { Reset(Prop); return; }
    for (I = Victims.Length - 1; I >= 0; --I)
    {
        if (Victims[I].Victim == None || Victims[I].Victim.bDeleteMe
            || (!Victims[I].bLatched && Now - Victims[I].LastSeen > 0.5)) Victims.Remove(I,1);
        else Victims[I].bTouching = false;
    }
    SearchRadius = FMin(600.0, VSize(Prop.MyMeshComp.Bounds.BoxExtent) + VSize(Root - PreviousRoot) + 256.0);
    foreach Prop.WorldInfo.AllPawns(class'KFPawn_Monster', M, (Root + PreviousRoot) * 0.5, SearchRadius)
    {
        if (M == None || M.bDeleteMe || M.Health <= 0 || M.bPlayedDeath || !M.bCanBeDamaged || M.Mesh == None
            || M.Mesh.PhysicsAsset == None || Prop.DropOwner == None || M.GetTeamNum() == Prop.DropOwner.GetTeamNum()) continue;
        V = VictimIndex(M); if (V < 0) continue;
        Victims[V].LastSeen = Now;
        Impact = EmptyImpact;
        QueryVictim(M,V,Geometry,Root,Q,Scale,DT,Now,Impact);
        if (!Impact.bHit || Victims[V].bLatched || VSizeSq(Impact.Velocity) < Square(220.0)
            || -(Impact.Velocity dot Impact.Normal) < 120.0 || !Prop.FastTrace(Impact.Point, PreviousRoot)) continue;
        if (!FirstImpact.bHit || Impact.Fraction < FirstImpact.Fraction)
        { FirstImpact = Impact; FirstVictim = M; FirstVictimIndex = V; }
    }
    if (FirstImpact.bHit) ApplyImpact(FirstVictim,FirstVictimIndex,Geometry,Root,Q,FirstImpact);
    // Re-arm only after a complete sample with no actual shape overlap.
    for (I = 0; I < Victims.Length; ++I) if (!Victims[I].bTouching) Victims[I].bLatched = false;
    for (I = Bodies.Length - 1; I >= 0; --I)
        if (Bodies[I].Victim == None || Now - Bodies[I].At > 0.25) Bodies.Remove(I,1);
    if (bRepositioned) { Root = RepositionedRoot; Q = RepositionedQ; }
    PreviousRoot = Root; PreviousQ = Q; PreviousScale = Scale; PreviousAt = Now;
}
