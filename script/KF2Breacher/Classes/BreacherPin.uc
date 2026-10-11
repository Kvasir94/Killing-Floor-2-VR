// A server-chosen Deadbolt attachment; ragdoll motion is local presentation.
// Never damages, changes a living pawn's physics, or accepts client pin claims.
// Stock stick helpers are owner-predicted, reapply impact damage and only carry
// one corpse to a world constraint, so Cascade deliberately does not use them.
class BreacherPin extends Actor;

struct PinState
{
    var byte Phase; // 1 carried, 2 anchored, 3 released
    var KFPawn_Monster Corpse;
    var name CorpseBone;
    var KFProjectile Carrier;
    var Actor Anchor;
    var name AnchorBone;
    var vector Point; // world point, or local to Anchor/AnchorBone
    var rotator Direction;
    var float Trail;
    var bool bHasAnchor, bHasCorpse;
};
var repnotify PinState Pin;
var StaticMeshComponent Rod;
var SkeletalMeshComponent HeldMesh;
var RB_BodyInstance HeldBody;
var vector BodyOffset;
var Quat BodyRotation;
var bool bLocalReleased, bHaveBody, bTriedRod;
var bool bChainSpent; // authority consumes a connected body group before its burst
var float BornAt;

replication
{
    if (bNetDirty) Pin;
}

// Reference-skeleton bodies exist on dedicated servers even though death
// ragdolls do not. Resolve a physical attachment bone, not a guessed hit zone.
static function name BoneAt(KFPawn_Monster M, vector Point)
{
    local int I;
    local name Bone, Best;
    local float Distance, BestDistance;
    if (M == None || M.Mesh == None || M.Mesh.PhysicsAsset == None) return '';
    BestDistance = 100000000;
    for (I = 0; I < M.Mesh.PhysicsAsset.BodySetup.Length; ++I)
    {
        Bone = M.Mesh.PhysicsAsset.BodySetup[I].BoneName;
        if (M.Mesh.MatchRefBone(Bone) == INDEX_NONE || M.Mesh.IsBoneHidden(M.Mesh.MatchRefBone(Bone))) continue;
        Distance = VSizeSq(M.Mesh.GetBoneLocation(Bone) - Point);
        if (Distance < BestDistance) { BestDistance = Distance; Best = Bone; }
    }
    return Best;
}

static function BreacherPin Create(KFProjectile Shot, KFPawn_Monster Corpse, name Bone, vector Point, float Trail)
{
    local BreacherPin P;
    local int Count;
    if (Shot == None || Shot.Role != ROLE_Authority) return None;
    foreach Shot.DynamicActors(class'BreacherPin', P)
    {
        if (P.Pin.Phase == 3 || P.bDeleteMe) continue;
        if (Corpse != None && P.Pin.Corpse == Corpse) return None;
        if (++Count >= 64) return None;
    }
    if (Corpse != None && (Corpse.Health > 0 || Corpse.bDeleteMe || !Corpse.bCanBePinned || Bone == '')) return None;
    P = Shot.Spawn(class'BreacherPin', Shot.Instigator,, Point, rotator(Shot.Velocity));
    if (P == None) return None;
    P.Pin.Phase = 1;
    P.Pin.Corpse = Corpse;
    P.Pin.bHasCorpse = Corpse != None;
    P.Pin.CorpseBone = Bone;
    P.Pin.Carrier = Shot;
    P.Pin.Direction = rotator(Shot.Velocity);
    P.Pin.Trail = Trail;
    P.bNetDirty = true;
    P.bForceNetUpdate = true;
    return P;
}

function AnchorTo(Actor Target, name Bone, vector Point, rotator Direction)
{
    local Pawn TargetPawn;
    if (Role != ROLE_Authority || Pin.Phase == 3) return;
    Pin.Phase = 2;
    Pin.Carrier = None;
    Pin.Anchor = Target;
    Pin.bHasAnchor = Target != None;
    Pin.AnchorBone = Bone;
    Pin.Point = Point;
    Pin.Direction = Direction;
    TargetPawn = Pawn(Target);
    if (TargetPawn != None && TargetPawn.Mesh != None && Bone != '')
        TargetPawn.Mesh.TransformToBoneSpace(Bone, Point, Direction, Pin.Point, Pin.Direction);
    else if (Target != None)
    {
        Pin.Point = (Point - Target.Location) << Target.Rotation;
        Pin.Direction = QuatToRotator(QuatProduct(QuatInvert(QuatFromRotator(Target.Rotation)), QuatFromRotator(Direction)));
    }
    SetLocation(Point);
    SetRotation(Direction);
    bNetDirty = true;
    bForceNetUpdate = true;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    BornAt = WorldInfo.TimeSeconds;
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'Pin')
    {
        if (Pin.Phase == 3) ReleaseLocal();
    }
    else Super.ReplicatedEvent(VarName);
}

simulated function ReleaseLocal()
{
    if (bLocalReleased) return;
    bLocalReleased = true;
    if (HeldBody != None && HeldBody.IsValidBodyInstance()) HeldBody.SetFixed(false);
    if (HeldMesh != None) HeldMesh.WakeRigidBody(Pin.CorpseBone);
    HeldBody = None;
    HeldMesh = None;
    bHaveBody = false;
    if (Rod != None) Rod.SetHidden(true);
}

function ReleasePin()
{
    if (Role != ROLE_Authority || Pin.Phase == 3) return;
    Pin.Phase = 3;
    Pin.Carrier = None;
    Pin.Anchor = None;
    bNetDirty = true;
    bForceNetUpdate = true;
    ReleaseLocal();
    LifeSpan = 0.4;
}

// Package-independent hand-off invoked by VRBodyHold BEFORE fixing a hand's
// body. Collision is disabled, so no physical UnTouch can trigger this hook.
simulated event UnTouch(Actor Other)
{
    if (Other != Pin.Corpse) return;
    ReleaseLocal();
    if (Role == ROLE_Authority) ReleasePin();
}

simulated function bool Frame(out vector Point, out rotator Direction)
{
    local Pawn P;
    Point = Location;
    Direction = Rotation;
    if (Pin.Phase == 1)
    {
        if (Pin.Carrier == None || Pin.Carrier.bDeleteMe) return false;
        Direction = Pin.Direction;
        Point = Pin.Carrier.Location - vector(Direction) * Pin.Trail;
        return true;
    }
    if (Pin.Phase != 2) return false;
    Point = Pin.Point;
    Direction = Pin.Direction;
    if (Pin.Anchor == None) return !Pin.bHasAnchor; // distinguish world from an unresolved/deleted actor
    if (Pin.Anchor.bDeleteMe || Pin.Anchor.bPendingDelete) return false;
    P = Pawn(Pin.Anchor);
    if (P != None)
    {
        if (P.Mesh == None || Pin.AnchorBone == '' || P.Mesh.MatchRefBone(Pin.AnchorBone) == INDEX_NONE
            || P.Mesh.IsBoneHidden(P.Mesh.MatchRefBone(Pin.AnchorBone))) return false;
        P.Mesh.TransformFromBoneSpace(Pin.AnchorBone, Pin.Point, Pin.Direction, Point, Direction);
    }
    else
    {
        Point = Pin.Anchor.Location + (Pin.Point >> Pin.Anchor.Rotation);
        Direction = QuatToRotator(QuatProduct(QuatFromRotator(Pin.Anchor.Rotation), QuatFromRotator(Pin.Direction)));
    }
    return true;
}

simulated function MakeRod()
{
    local StaticMesh Mesh;
    if (bTriedRod) return;
    bTriedRod = true;
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRDeadboltSpike", class'StaticMesh', true));
    if (Mesh == None) return;
    Rod = new(self) class'StaticMeshComponent';
    Rod.SetStaticMesh(Mesh);
    Rod.SetActorCollision(false, false, false);
    Rod.SetTraceBlocking(false, false);
    Rod.SetBlockRigidBody(false);
    Rod.CastShadow = false;
    // The authored 34 cm spike starts at its base and points along +X.
    Rod.SetScale(0.5);
    Rod.SetTranslation(vect(-12,0,0));
    AttachComponent(Rod);
}

simulated function bool AttachBody(vector Point, rotator Direction)
{
    local int I;
    local RB_BodyInstance Body;
    local matrix TM;
    local Quat Inverse;
    local KFPawn_Monster M;
    M = Pin.Corpse;
    if (M == None || M.bDeleteMe || M.Health > 0 || M.Mesh == None || M.Physics != PHYS_RigidBody
        || M.Mesh.PhysicsAssetInstance == None || M.Mesh.PhysicsAsset == None) return false;
    // A late-replicated pin must never take a body already controlled by a hand
    // (including a different bone in this corpse), or another physics owner.
    for (I = 0; I < M.Mesh.PhysicsAssetInstance.Bodies.Length; ++I)
    {
        Body = M.Mesh.PhysicsAssetInstance.Bodies[I];
        if (Body != None && Body.IsValidBodyInstance() && Body.IsFixed())
        { ReleaseLocal(); return false; }
    }
    Body = M.Mesh.FindBodyInstanceNamed(Pin.CorpseBone);
    if (Body == None || !Body.IsValidBodyInstance()) return false;
    TM = Body.GetUnrealWorldTM();
    Inverse = QuatInvert(QuatFromRotator(Direction));
    BodyOffset = MatrixGetOrigin(TM) - Point;
    if (VSize(BodyOffset) > 24) BodyOffset = Normal(BodyOffset) * 24;
    BodyOffset = QuatRotateVector(Inverse, BodyOffset);
    BodyRotation = QuatProduct(Inverse, QuatFromRotator(MatrixGetRotator(TM)));
    HeldMesh = M.Mesh;
    HeldBody = Body;
    HeldMesh.bUpdateKinematicBonesFromAnimation = false; // dead mesh stays ragdoll on release
    HeldBody.SetFixed(true);
    bHaveBody = true;
    return true;
}

simulated event Tick(float DeltaTime)
{
    local vector Point;
    local rotator Direction;
    local Quat Q;
    Super.Tick(DeltaTime);
    if (Pin.Phase == 0 || Pin.Phase == 3 || bLocalReleased) return;
    if (!Frame(Point, Direction))
    {
        // References and final anchor state may arrive after this actor.
        if (WorldInfo.TimeSeconds - BornAt > 1.5)
        {
            ReleaseLocal();
            if (Role == ROLE_Authority) ReleasePin();
        }
        return;
    }
    SetLocation(Point);
    SetRotation(Direction);
    if (WorldInfo.NetMode == NM_DedicatedServer) return;
    MakeRod();
    if (Pin.Corpse == None)
    {
        // Never guess which ragdoll an unresolved/torn-off reference meant.
        if (Pin.bHasCorpse && WorldInfo.TimeSeconds - BornAt > 1.5) ReleaseLocal();
        return;
    }
    if (bHaveBody && (Pin.Corpse.bDeleteMe || Pin.Corpse.Mesh != HeldMesh
        || HeldBody == None || !HeldBody.IsValidBodyInstance()
        || HeldMesh.FindBodyInstanceNamed(Pin.CorpseBone) != HeldBody
        || HeldMesh.IsBoneHidden(HeldMesh.MatchRefBone(Pin.CorpseBone))))
    { ReleaseLocal(); return; }
    if (!bHaveBody && !AttachBody(Point, Direction))
    {
        if (WorldInfo.TimeSeconds - BornAt > 1.5) ReleaseLocal();
        return;
    }
    if (bLocalReleased) return;
    Q = QuatFromRotator(Direction);
    HeldMesh.SetRBPosition(Point + QuatRotateVector(Q, BodyOffset), Pin.CorpseBone);
    HeldMesh.SetRBRotation(QuatToRotator(QuatProduct(Q, BodyRotation)), Pin.CorpseBone);
    HeldMesh.WakeRigidBody(Pin.CorpseBone);
}

simulated event Destroyed()
{
    ReleaseLocal();
    if (Rod != None) DetachComponent(Rod);
    Rod = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=true
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    bNetTemporary=false
    NetUpdateFrequency=30
    LifeSpan=8.0
}
