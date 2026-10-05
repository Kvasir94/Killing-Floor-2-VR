// The 1858/Flare/Winterbite off hand is authored for hammer fanning, not a
// wrap grip. Reuse KF2's 9mm support pose in the target firing-wrist frame.
class VRPistolBracePose extends Object;

static function bool Calibrate(VRHandsBridge B)
{
    local KFSkeletalMeshComponent Reference;
    local SkeletalMesh Mesh;
    local AnimSet Anims;
    local AnimTree Template;
    local AnimNodeSequence Sequence;
    local quat WristToTarget;
    local int I;

    if (B == None || B.ActiveProfile < 0
        || B.WeaponProfiles[B.ActiveProfile].SupportBone != B.WeaponProfiles[B.ActiveProfile].RootBone)
        return false;
    Mesh = SkeletalMesh(DynamicLoadObject(class'KFWeap_Pistol_9mm'.default.FirstPersonMeshName,
        class'SkeletalMesh', true));
    if (Mesh == None) return false;
    Reference = new(B) class'KFSkeletalMeshComponent';
    Reference.SetSkeletalMesh(Mesh);
    for (I = 0; I < class'KFWeap_Pistol_9mm'.default.FirstPersonAnimSetNames.Length; ++I)
    {
        Anims = AnimSet(DynamicLoadObject(class'KFWeap_Pistol_9mm'.default.FirstPersonAnimSetNames[I],
            class'AnimSet', true));
        if (Anims == None) return false;
        Reference.AnimSets.AddItem(Anims);
    }
    if (Reference.MatchRefBone(B.HandBone(0)) < 0 || Reference.MatchRefBone(B.HandBone(1)) < 0)
        return false;
    Template = new(B) class'AnimTree';
    Sequence = new(Template) class'AnimNodeSequence';
    Sequence.NodeName = 'VRPistolBraceReference';
    Sequence.bNoNotifies = true;
    Template.Children[0].Anim = Sequence;
    Template.Children[0].Weight = 1;
    Reference.SetHidden(true);
    Reference.bUpdateSkelWhenNotRendered = true;
    Reference.bTickAnimNodesWhenNotRendered = true;
    Reference.SetAnimTreeTemplate(Template);
    Sequence = AnimNodeSequence(Reference.FindAnimNode('VRPistolBraceReference'));
    if (Sequence == None) return false;
    Sequence.SetAnim('Idle');
    if (Sequence.AnimSeq == None) return false;
    Sequence.SetPosition(0, false);
    Sequence.bPlaying = false;
    B.AttachComponent(Reference);
    Reference.ForceUpdate(false);

    WristToTarget = QuatProduct(B.GripRotationInWeapon[1],
        QuatInvert(Reference.GetBoneQuaternion(B.HandBone(1))));
    B.GripInWeapon[0] = B.GripInWeapon[1] + QuatRotateVector(WristToTarget,
        Reference.GetBoneLocation(B.HandBone(0)) - Reference.GetBoneLocation(B.HandBone(1)));
    B.GripRotationInWeapon[0] = QuatProduct(WristToTarget, Reference.GetBoneQuaternion(B.HandBone(0)));
    B.SupportGripOffset = B.GripInWeapon[0];
    B.SupportGripRotation = B.GripRotationInWeapon[0];
    B.SupportPoseAnimSets = Reference.AnimSets;
    Reference.DetachFromAny();
    return true;
}
