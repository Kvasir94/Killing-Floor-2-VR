// Transfers an authored grip to the opposite anatomical hand. A left primary
// uses the weapon's right-hand animation, and a right support uses its left.
// Only the bound hand's frozen pose changes; weapon transforms stay rigid.
class VRHandRolePose extends Object;

struct RetargetJoint
{
    var name TargetBone;
    var quat SourceAnimation;
    var quat TargetRotation;
    var vector TargetTranslation;
};

static function name FingerBone(int Hand, int Finger, int Joint)
{
    local string Side, Digit;
    Side = Hand == 0 ? "Left" : "Right";
    switch (Finger)
    {
        case 0: Digit = "Thumb"; break;
        case 1: Digit = "Index"; break;
        case 2: Digit = "Middle"; break;
        case 3: Digit = "Ring"; break;
        default: Digit = "Pinky"; break;
    }
    return name(Side $ "Hand" $ Digit $ Joint $ "_1stP");
}

static function bool ValidQuaternion(quat Q)
{
    local float SizeSquared;
    SizeSquared = Q.X * Q.X + Q.Y * Q.Y + Q.Z * Q.Z + Q.W * Q.W;
    return SizeSquared == SizeSquared && Abs(SizeSquared - 1) < 0.01;
}

// F * R * F for the reflection F = diag(1,-1,1). A quaternion's vector
// part is an axial vector, so reflection negates X/Z, not Y. The resulting
// quaternion is still a proper rotation; no component receives negative scale.
static function quat MirrorCanonicalRotation(quat Q)
{
    Q.X = -Q.X;
    Q.Z = -Q.Z;
    return Q;
}

// Reflect the anatomical wrist frame through the weapon root's XZ plane, then
// reflect canonical hand chirality back into a proper target-hand rotation.
// SourceGrip stays authored and attachment-bone-relative: pumps and hinged
// barrels can have different axes from the root. Neither the gun nor its bone
// transforms receive a reflection or negative scale.
static function quat RetargetWrist(VRHandsBridge B, int SourceHand, int TargetHand, quat SourceGrip)
{
    local quat FrameToRoot, AnatomicalRoot, TargetRoot;
    if (SourceHand == TargetHand || B == None || B.FreeHandPose == None
        || !B.FreeHandPose.bReady || SourceHand < 0 || SourceHand > 1
        || TargetHand < 0 || TargetHand > 1) return SourceGrip;
    FrameToRoot = QuatProduct(B.GripRotationInWeapon[SourceHand], QuatInvert(SourceGrip));
    AnatomicalRoot = QuatProduct(B.GripRotationInWeapon[SourceHand],
        QuatInvert(B.FreeHandPose.WristBasis[SourceHand]));
    TargetRoot = QuatProduct(MirrorCanonicalRotation(AnatomicalRoot), B.FreeHandPose.WristBasis[TargetHand]);
    return QuatProduct(QuatInvert(FrameToRoot), TargetRoot);
}

static function vector MirrorRootPosition(vector Position)
{
    Position.Y = -Position.Y;
    return Position;
}

// Call once on the evaluated, frozen VRBoundGrip mesh before hiding the unused
// hand or sampling its target wrist. Reads both reference hands from a private
// mesh so an empty hand's current curl/IK never contaminates the authored grip.
// The original animation remains responsible for the wrist/arm pose. Fifteen
// controls replace finger rotations and retain the target's own segment lengths.
static function bool Apply(VRHandsBridge B, KFSkeletalMeshComponent HandMesh, int SourceHand, int TargetHand)
{
    local KFSkeletalMeshComponent ReferenceMesh;
    local AnimTree Template, ReferenceTree;
    local AnimNodeSequence Sequence;
    local SkelControlSingleBone Control;
    local AnimTree.SkelControlListHead Link;
    local array<RetargetJoint> Joints;
    local RetargetJoint Entry;
    local name SourceBone, TargetBone, ParentBone, Animation;
    local quat SourceWrist, TargetWrist, SourceBasis, TargetBasis;
    local quat SourceReference, TargetReference, Delta, Result;
    local float AnimationTime;
    local int Finger, Joint, I;
    local bool bValid;

    if (B == None || HandMesh == None || SourceHand < 0 || SourceHand > 1
        || TargetHand < 0 || TargetHand > 1) return false;
    if (SourceHand == TargetHand) return true;
    if (B.FreeHandPose == None || !B.FreeHandPose.bReady
        || HandMesh.SkeletalMesh == None || HandMesh.SkeletalMesh != B.FloatingHandsMesh) return false;
    Sequence = AnimNodeSequence(HandMesh.FindAnimNode('VRBoundGrip'));
    if (Sequence == None || Sequence.AnimSeq == None || Sequence.bPlaying) return false;
    Animation = Sequence.AnimSeqName;
    AnimationTime = Sequence.CurrentTime;
    SourceBasis = B.FreeHandPose.WristBasis[SourceHand];
    TargetBasis = B.FreeHandPose.WristBasis[TargetHand];
    if (!ValidQuaternion(SourceBasis) || !ValidQuaternion(TargetBasis)) return false;
    if (HandMesh.MatchRefBone(B.HandBone(SourceHand)) < 0
        || HandMesh.MatchRefBone(B.HandBone(TargetHand)) < 0) return false;
    SourceWrist = HandMesh.GetBoneQuaternion(B.HandBone(SourceHand));
    if (!ValidQuaternion(SourceWrist)) return false;

    // Capture every source joint before changing any animation tree or pose.
    for (Finger = 0; Finger < 5; ++Finger)
        for (Joint = 1; Joint <= 3; ++Joint)
        {
            SourceBone = FingerBone(SourceHand, Finger, Joint);
            TargetBone = FingerBone(TargetHand, Finger, Joint);
            if (HandMesh.MatchRefBone(SourceBone) < 0 || HandMesh.MatchRefBone(TargetBone) < 0) return false;
            Entry.TargetBone = TargetBone;
            Entry.SourceAnimation = QuatProduct(SourceBasis,
                QuatProduct(QuatInvert(SourceWrist), HandMesh.GetBoneQuaternion(SourceBone)));
            if (!ValidQuaternion(Entry.SourceAnimation)) return false;
            Joints.AddItem(Entry);
        }

    ReferenceMesh = new(B) class'KFSkeletalMeshComponent';
    ReferenceMesh.SetSkeletalMesh(HandMesh.SkeletalMesh);
    ReferenceMesh.SetHidden(true);
    ReferenceMesh.CastShadow = false;
    ReferenceMesh.bCastDynamicShadow = false;
    ReferenceMesh.bUpdateSkelWhenNotRendered = true;
    ReferenceMesh.bTickAnimNodesWhenNotRendered = true;
    ReferenceTree = new(B) class'AnimTree';
    Sequence = new(ReferenceTree) class'AnimNodeSequence';
    Sequence.bNoNotifies = true;
    ReferenceTree.Children[0].Anim = Sequence;
    ReferenceTree.Children[0].Weight = 1;
    ReferenceMesh.SetAnimTreeTemplate(ReferenceTree);
    ReferenceMesh.SetForceRefPose(true);
    B.AttachComponent(ReferenceMesh);
    ReferenceMesh.ForceSkelUpdate();
    ReferenceMesh.ForceUpdate(false);
    SourceWrist = ReferenceMesh.GetBoneQuaternion(B.HandBone(SourceHand));
    TargetWrist = ReferenceMesh.GetBoneQuaternion(B.HandBone(TargetHand));
    bValid = ValidQuaternion(SourceWrist) && ValidQuaternion(TargetWrist);
    I = 0;
    for (Finger = 0; Finger < 5 && bValid; ++Finger)
        for (Joint = 1; Joint <= 3 && bValid; ++Joint)
        {
            SourceBone = FingerBone(SourceHand, Finger, Joint);
            TargetBone = Joints[I].TargetBone;
            ParentBone = ReferenceMesh.GetParentBone(TargetBone);
            if (ParentBone == '' || ReferenceMesh.MatchRefBone(ParentBone) < 0)
            {
                bValid = false;
                break;
            }
            SourceReference = QuatProduct(SourceBasis,
                QuatProduct(QuatInvert(SourceWrist), ReferenceMesh.GetBoneQuaternion(SourceBone)));
            TargetReference = QuatProduct(QuatInvert(TargetWrist), ReferenceMesh.GetBoneQuaternion(TargetBone));
            // Subtract the source bind pose in anatomical wrist coordinates,
            // mirror that motion, then add it to the target's own bind pose.
            // This also handles the thumb's different metacarpal axes.
            Delta = MirrorCanonicalRotation(QuatProduct(Joints[I].SourceAnimation, QuatInvert(SourceReference)));
            Result = QuatProduct(QuatProduct(QuatProduct(QuatInvert(TargetBasis), Delta), TargetBasis), TargetReference);
            Joints[I].TargetRotation = Result;
            Joints[I].TargetTranslation = QuatRotateVector(QuatInvert(ReferenceMesh.GetBoneQuaternion(ParentBone)),
                ReferenceMesh.GetBoneLocation(TargetBone) - ReferenceMesh.GetBoneLocation(ParentBone));
            bValid = ValidQuaternion(SourceReference) && ValidQuaternion(TargetReference) && ValidQuaternion(Result);
            ++I;
        }
    ReferenceMesh.DetachFromAny();
    ReferenceMesh = None;
    if (!bValid || I != 15) return false;

    Template = new(B) class'AnimTree';
    Sequence = new(Template) class'AnimNodeSequence';
    Sequence.NodeName = 'VRBoundGrip';
    Sequence.bNoNotifies = true;
    Template.Children[0].Anim = Sequence;
    Template.Children[0].Weight = 1;
    for (I = 0; I < Joints.Length; ++I)
    {
        Control = new(Template) class'SkelControlSingleBone';
        Control.ControlName = name("VRHandRole_" $ Joints[I].TargetBone);
        Control.bApplyRotation = true;
        Control.bAddRotation = false;
        Control.BoneRotationSpace = BCS_OtherBoneSpace;
        Control.RotationSpaceBoneName = B.HandBone(TargetHand);
        Control.BoneRotation = QuatToRotator(Joints[I].TargetRotation);
        Control.bApplyTranslation = true;
        Control.bAddTranslation = false;
        Control.BoneTranslationSpace = BCS_ParentBoneSpace;
        Control.BoneTranslation = Joints[I].TargetTranslation;
        Control.bIgnoreWhenNotRendered = false;
        Control.ControlStrength = 1;
        Control.StrengthTarget = 1;
        Link.BoneName = Joints[I].TargetBone;
        Link.ControlHead = Control;
        Template.SkelControlLists.AddItem(Link);
    }
    HandMesh.SetAnimTreeTemplate(Template);
    Sequence = AnimNodeSequence(HandMesh.FindAnimNode('VRBoundGrip'));
    if (Sequence == None) return false;
    Sequence.SetAnim(Animation);
    Sequence.SetPosition(AnimationTime, false);
    Sequence.bPlaying = false;
    HandMesh.ForceSkelUpdate();
    HandMesh.ForceUpdate(false);
    return true;
}
