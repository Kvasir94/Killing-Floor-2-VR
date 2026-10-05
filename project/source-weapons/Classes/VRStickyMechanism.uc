// Sample the original Source mechanism takes independently of the stock hand
// animation tree. Only the three moving Source bones receive the sampled pose.
class VRStickyMechanism extends Object;

var VRWeap_StickybombLauncher Gun;
var KFSkeletalMeshComponent SampleMesh;
var AnimNodeSequence Sequence;
var SkelControlSingleBone Controls[3];
var name BoneNames[3];
var vector RestPosition[3];
var quat RestRotation[3];
var bool bAttempted, bInitialized;
var float LastSampleTime;

simulated function bool Initialize(VRWeap_StickybombLauncher W)
{
    local AnimSet Set;
    local AnimTree SampleTree, WeaponTree;
    local AnimTree.SkelControlListHead Link;
    local AnimNodeSequence Node;
    local int I;
    if (bAttempted) return bInitialized;
    if (W == None || W.MySkelMesh == None || W.MySkelMesh.Animations == None) return false;
    Gun = W;
    bAttempted = true;
    Set = AnimSet(DynamicLoadObject("KF2VRSource.StickybombLauncher_Anims", class'AnimSet', true));
    WeaponTree = AnimTree(Gun.MySkelMesh.Animations);
    if (Set == None || WeaponTree == None)
    { `log("KF2VR_STICKY mechanism-unavailable reason=animation-assets"); return false; }
    SampleTree = new(Gun) class'AnimTree';
    Node = new(SampleTree) class'AnimNodeSequence';
    Node.NodeName = 'VRSourceMechanismSample';
    Node.bNoNotifies = true;
    SampleTree.Children[0].Anim = Node;
    SampleTree.Children[0].Weight = 1;
    SampleMesh = new(Gun) class'KFSkeletalMeshComponent';
    SampleMesh.SetSkeletalMesh(Gun.MySkelMesh.SkeletalMesh);
    SampleMesh.AnimSets.AddItem(Set);
    SampleMesh.SetHidden(true);
    SampleMesh.SetAnimTreeTemplate(SampleTree);
    Gun.AttachComponent(SampleMesh);
    Sequence = AnimNodeSequence(SampleMesh.FindAnimNode('VRSourceMechanismSample'));
    if (Sequence == None) return false;
    Sequence.SetAnim('StickyIdle');
    if (Sequence.AnimSeq == None) return false;
    Sequence.SetPosition(0, false);
    Sequence.bPlaying = false;
    SampleMesh.ForceUpdate(false);
    for (I = 0; I < 3; ++I)
    {
        if (SampleMesh.MatchRefBone(BoneNames[I]) < 0) return false;
        RelativeBone(I, RestPosition[I], RestRotation[I]);
        Controls[I] = new(WeaponTree) class'SkelControlSingleBone';
        Controls[I].ControlName = name("VRStickyMechanism" $ I);
        Controls[I].bApplyRotation = true;
        Controls[I].bAddRotation = true;
        Controls[I].BoneRotationSpace = BCS_BoneSpace;
        Controls[I].bApplyTranslation = true;
        Controls[I].bAddTranslation = true;
        Controls[I].BoneTranslationSpace = BCS_ParentBoneSpace;
        Controls[I].ControlStrength = 1;
        Controls[I].StrengthTarget = 1;
        Controls[I].bIgnoreWhenNotRendered = false;
        Link.BoneName = BoneNames[I];
        Link.ControlHead = Controls[I];
        WeaponTree.SkelControlLists.AddItem(Link);
    }
    Gun.MySkelMesh.InitSkelControls();
    bInitialized = true;
    return true;
}

simulated function RelativeBone(int I, out vector Position, out quat Orientation)
{
    local quat ParentQ;
    local vector ParentPos;
    ParentQ = SampleMesh.GetBoneQuaternion('SRC_weapon_bone');
    ParentPos = SampleMesh.GetBoneLocation('SRC_weapon_bone');
    Position = QuatRotateVector(QuatInvert(ParentQ), SampleMesh.GetBoneLocation(BoneNames[I]) - ParentPos);
    Orientation = QuatProduct(QuatInvert(ParentQ), SampleMesh.GetBoneQuaternion(BoneNames[I]));
}

simulated function Update()
{
    local int I;
    local float Now, Time;
    local name Take;
    local vector Position;
    local quat Orientation;
    if (!bInitialized || Gun == None || Gun.MySkelMesh == None) return;
    Now = Gun.WorldInfo.TimeSeconds;
    if (Now == LastSampleTime) return;
    LastSampleTime = Now;
    Take = 'StickyIdle';
    if (Gun.bCharging) { Take = 'StickyCharge'; Time = Now - Gun.ChargeStartedAt; }
    else if (Now - Gun.LastShotAt < 0.6) { Take = 'StickyFire'; Time = Now - Gun.LastShotAt; }
    else if (Gun.bSourceReloading)
    {
        if (Now - Gun.ReloadStartedAt < 1.0 / 3.0)
        { Take = 'StickyReloadStart'; Time = Now - Gun.ReloadStartedAt; }
        else
        {
            Take = 'StickyReloadLoop';
            Time = FClamp(1.0 - (Gun.ReloadAt - Now) / 0.67, 0, 1) * (2.0 / 3.0);
        }
    }
    else if (Now - Gun.ReloadEndedAt < 16.0 / 30.0)
    { Take = 'StickyReloadEnd'; Time = Now - Gun.ReloadEndedAt; }
    else if (Now - Gun.DrawStartedAt < 1.0)
    { Take = 'StickyDraw'; Time = Now - Gun.DrawStartedAt; }
    if (Sequence.AnimSeqName != Take) Sequence.SetAnim(Take);
    if (Sequence.AnimSeq == None) return;
    Sequence.SetPosition(FClamp(Time, 0, Sequence.AnimSeq.SequenceLength), false);
    SampleMesh.ForceSkelUpdate();
    SampleMesh.ForceUpdate(true);
    for (I = 0; I < 3; ++I)
    {
        RelativeBone(I, Position, Orientation);
        Controls[I].BoneTranslation = Position - RestPosition[I];
        Controls[I].BoneRotation = QuatToRotator(QuatProduct(QuatInvert(RestRotation[I]), Orientation));
    }
}

simulated function DestroyPresentation()
{
    if (SampleMesh != None) SampleMesh.DetachFromAny();
    SampleMesh = None;
    Sequence = None;
    Gun = None;
}

defaultproperties
{
    BoneNames(0)=SRC_weapon_bone_1
    BoneNames(1)=SRC_vm_weapon_bone
    BoneNames(2)=SRC_vm_weapon_bone_1
    LastSampleTime=-100
}
