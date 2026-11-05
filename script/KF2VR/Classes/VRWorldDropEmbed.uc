// The same dropped prop follows the exact struck body. No inventory or corpse
// actor is created; a missing/hidden/replaced body releases this prop safely.
class VRWorldDropEmbed extends Object;

var VRWorldDropGun Prop;
var SkeletalMeshComponent SubjectMesh;
var SkeletalMesh SubjectModel;
var PhysicsAsset SubjectAsset;
var int BoundSerial;
var vector LastPosition, LastVelocity;
var quat LastRotation;
var bool bHavePose;
var bool bSavedRigidBlock;

simulated function bool Bind(VRWorldDropGun P)
{
    local KFPawn_Monster M;
    Prop = P;
    if (P == None || P.Embedded.Victim == None) return false;
    M = P.Embedded.Victim;
    if (M.Mesh == None || M.Mesh.SkeletalMesh == None || M.Mesh.PhysicsAsset == None) return false;
    if (BoundSerial != P.Embedded.Serial || SubjectMesh != M.Mesh)
    {
        bHavePose = false;
        LastPosition = vect(0,0,0); LastVelocity = vect(0,0,0);
        LastRotation = QuatFromRotator(rot(0,0,0));
    }
    if (SubjectMesh == None) bSavedRigidBlock = P.MyMeshComp != None && P.MyMeshComp.BlockRigidBody;
    SubjectMesh = M.Mesh; SubjectModel = M.Mesh.SkeletalMesh; SubjectAsset = M.Mesh.PhysicsAsset;
    BoundSerial = P.Embedded.Serial;
    return true;
}

simulated function bool ValidBody()
{
    local int BoneIndex;
    local KFPawn_Monster M;
    M = Prop != None ? Prop.Embedded.Victim : None;
    if (M == None || M.bDeleteMe || SubjectMesh == None || M.Mesh != SubjectMesh
        || SubjectMesh.SkeletalMesh != SubjectModel || SubjectMesh.PhysicsAsset != SubjectAsset
        || Prop.Embedded.Bone == '' || Prop.MyMeshComp == None) return false;
    BoneIndex = SubjectMesh.MatchRefBone(Prop.Embedded.Bone);
    if (BoneIndex < 0 || class'VRBoneVisibility'.static.IsHiddenIndex(SubjectMesh, BoneIndex)
        || class'VRBodyHold'.static.Consumed(SubjectMesh, Prop.Embedded.Bone)) return false;
    // A severed body may remain on this exact mesh. Follow it only while its
    // actual physics instance survives; never jump to an independently spawned gib.
    if (SubjectMesh.IsBrokenConstraint(Prop.Embedded.Bone)
        && class'VRBodyHold'.static.BodyFor(SubjectMesh, Prop.Embedded.Bone) == None) return false;
    return true;
}

function bool Begin(VRWorldDropGun P, KFPawn_Monster M, name Bone, vector BodyAt, quat BodyQ)
{
    local matrix BoneTM;
    local quat BoneQ;
    if (P == None || P.Role != ROLE_Authority || P.bReturning || P.bCatchPending || P.bPublic
        || M == None || M.Mesh == None || P.MyMeshComp == None
        || P.MyMeshComp.BodyInstance == None || !P.MyMeshComp.BodyInstance.IsValidBodyInstance()
        || M.Mesh.MatchRefBone(Bone) < 0) return false;
    BoneTM = M.Mesh.GetBoneMatrix(M.Mesh.MatchRefBone(Bone));
    BoneQ = M.Mesh.GetBoneQuaternion(Bone);
    P.Embedded.Victim = M; P.Embedded.Bone = Bone;
    P.Embedded.Offset = InverseTransformVector(BoneTM, BodyAt);
    P.Embedded.Orientation = QuatProduct(QuatInvert(BoneQ), BodyQ);
    ++P.Embedded.Serial;
    if (!Bind(P) || !ValidBody()) { P.Embedded.Victim = None; return false; }
    LastPosition = BodyAt; LastRotation = BodyQ; LastVelocity = vect(0,0,0); bHavePose = true;
    P.MyMeshComp.SetRBLinearVelocity(vect(0,0,0));
    P.MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
    P.MyMeshComp.BodyInstance.SetFixed(true);
    P.MyMeshComp.SetBlockRigidBody(false);
    P.MyMeshComp.SetRBRotation(QuatToRotator(BodyQ)); P.MyMeshComp.SetRBPosition(BodyAt);
    P.InvalidateBallisticContact();
    P.bGrounded = false; P.bHavePrevious = false; P.GripHistoryCount = 0;
    P.bForceNetUpdate = true; P.bNetDirty = true;
    return true;
}

simulated function bool Update(float DeltaSeconds)
{
    local matrix BoneTM;
    local vector At;
    local quat Q;
    if (Prop == None || Prop.Embedded.Victim == None) return false;
    if (SubjectMesh == None && Prop.Role < ROLE_Authority && !Bind(Prop)) return false;
    if (!ValidBody())
    {
        if (Prop.Role == ROLE_Authority) Clear(true);
        return false;
    }
    BoneTM = SubjectMesh.GetBoneMatrix(SubjectMesh.MatchRefBone(Prop.Embedded.Bone));
    At = TransformVector(BoneTM, Prop.Embedded.Offset);
    Q = QuatProduct(SubjectMesh.GetBoneQuaternion(Prop.Embedded.Bone), Prop.Embedded.Orientation);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(At)
        || !class'VRHandRolePose'.static.ValidQuaternion(Q)
        || (bHavePose && VSizeSq(At - LastPosition) > Square(128.0)))
    {
        if (Prop.Role == ROLE_Authority) Clear(true);
        return false;
    }
    if (bHavePose && DeltaSeconds > 0) LastVelocity = (At - LastPosition) / DeltaSeconds;
    LastPosition = At; LastRotation = Q; bHavePose = true;
    if (Prop.MyMeshComp.BodyInstance != None && Prop.MyMeshComp.BodyInstance.IsValidBodyInstance())
        Prop.MyMeshComp.BodyInstance.SetFixed(true);
    Prop.MyMeshComp.SetRBRotation(QuatToRotator(Q)); Prop.MyMeshComp.SetRBPosition(At);
    Prop.MyMeshComp.SetBlockRigidBody(false);
    Prop.bGrounded = false;
    return true;
}

// Recall/catch clears before changing inventory ownership. Geometry loss drops
// the original prop with the last body's finite velocity; it never grants a hit.
simulated function Clear(optional bool bRelease)
{
    if (Prop == None) return;
    if (Prop.MyMeshComp != None) Prop.MyMeshComp.SetBlockRigidBody(bSavedRigidBlock);
    if (Prop.MyMeshComp != None && Prop.MyMeshComp.BodyInstance != None
        && Prop.MyMeshComp.BodyInstance.IsValidBodyInstance())
    {
        Prop.MyMeshComp.BodyInstance.SetFixed(false);
        if (bRelease && Prop.Role == ROLE_Authority)
        {
            if (bHavePose)
            {
                Prop.MyMeshComp.SetRBRotation(QuatToRotator(LastRotation));
                Prop.MyMeshComp.SetRBPosition(LastPosition);
            }
            if (VSize(LastVelocity) > 900) LastVelocity = Normal(LastVelocity) * 900;
            Prop.MyMeshComp.SetRBLinearVelocity(LastVelocity);
            Prop.MyMeshComp.WakeRigidBody();
        }
    }
    if (Prop.Role == ROLE_Authority)
    {
        Prop.Embedded.Victim = None; Prop.Embedded.Bone = ''; ++Prop.Embedded.Serial;
        Prop.bHavePrevious = false; Prop.GripHistoryCount = 0;
        if (Prop.WeaponContact != None) Prop.WeaponContact.Reset(Prop);
        Prop.bNetDirty = true; Prop.bForceNetUpdate = true;
    }
    SubjectMesh = None; SubjectModel = None; SubjectAsset = None; bHavePose = false;
}
