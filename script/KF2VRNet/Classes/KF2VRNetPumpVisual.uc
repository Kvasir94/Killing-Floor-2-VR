// Cosmetic controls on one privately spawned remote attachment.
// Bind before UpdateActions; sample a temporary reference pose without seeking
// or stopping the attachment's animation timeline.
// Apply tracked mechanism deltas after actor/muzzle placement and stock actions.
// The original two-pump scalar path remains available for older motion clips.
// No receiver/root motion is added here: it is already in the transmitted muzzle.
class KF2VRNetPumpVisual extends Object dependsOn(KFWeaponAttachment, KF2VRNetTypes);

struct PumpPart
{
    var name Bone;
    var vector IdleLocal;
    var quat IdleLocalQ;
    var SkelControlSingleBone Control;
    var bool bVisibilityOwned, bWasHidden;
};

var KFWeaponAttachment BoundAttachment;
var class<KFWeapon> BoundClass;
var SkeletalMeshComponent Mesh;
var SkeletalMesh BoundMesh;
var AnimTree Tree;
var AnimNodeSequence Sequence;
var array<PumpPart> Parts;
var bool bHolding, bSavedPooling, bSavedNoNotifies, bSavedNodeForceRef, bSavedMeshForceRef;
var float MaxPullUU;

static function bool FiniteFloat(float Value)
{
    return Value == Value && Abs(Value) < 100000000;
}

static function bool FiniteVector(vector Value)
{
    return FiniteFloat(Value.X) && FiniteFloat(Value.Y) && FiniteFloat(Value.Z);
}

static function bool ValidQ(quat Q)
{
    local float SizeSquared;
    if (!FiniteFloat(Q.X) || !FiniteFloat(Q.Y) || !FiniteFloat(Q.Z) || !FiniteFloat(Q.W)) return false;
    SizeSquared = Q.X*Q.X + Q.Y*Q.Y + Q.Z*Q.Z + Q.W*Q.W;
    return Abs(SizeSquared - 1) < 0.02;
}

static function name SupportedMesh(class<KFWeapon> WeaponClass)
{
    if (WeaponClass == class'KFWeap_Shotgun_MB500') return 'Wep_3rdP_MB500_Rig';
    if (WeaponClass == class'KFWeap_Shotgun_DragonsBreath') return 'Wep_3rdP_DragonsBreath_Rig';
    return '';
}

function bool OwnsBinding()
{
    return BoundAttachment != None && !BoundAttachment.bDeleteMe && Mesh != None
        && BoundAttachment.WeapMesh == Mesh && Mesh.SkeletalMesh == BoundMesh
        && Tree != None && Mesh.Animations == Tree && Tree != Mesh.AnimTreeTemplate
        && Sequence != None && Tree.Children.Length > 0 && Tree.Children[0].Anim == Sequence
        && BoundAttachment.WeapAnimNode == Sequence && Parts.Length > 0
        && Parts[0].Control != None;
}

function bool Bind(KFWeaponAttachment InAttachment, class<KFWeapon> WeaponClass, optional bool bFirstPerson)
{
    local name Animation;
    local array<name> Bones;
    local AnimTree Template, ExistingTree;
    local AnimNodeSequence SourceSequence, TemplateSequence;
    local AnimTree.SkelControlListHead Link;
    local PumpPart Part;
    local vector RootPosition;
    local quat InvRoot;
    local float Position, Rate;
    local bool bPlaying, bLooping;
    local int I;

    if (InAttachment == BoundAttachment && WeaponClass == BoundClass && OwnsBinding()) return true;
    Shutdown();
    class'KF2VRNetMechanismCatalog'.static.Collect(WeaponClass, Bones);
    if (Bones.Length == 0 || InAttachment == None || InAttachment.bDeleteMe
        || InAttachment.bWeapMeshIsPawnMesh || InAttachment.WeapMesh == None) return false;
    Mesh = InAttachment.WeapMesh;
    if (Mesh.SkeletalMesh == None || Mesh.MatchRefBone('RW_Weapon') < 0) { Mesh = None; return false; }
    ExistingTree = AnimTree(Mesh.Animations);
    SourceSequence = AnimNodeSequence(Mesh.Animations);
    if (ExistingTree != None)
    {
        // Also permit a neutral private wrapper left by an earlier Shutdown.
        // Reject other extensions rather than sampling their controlled pose.
        if (ExistingTree == Mesh.AnimTreeTemplate || ExistingTree.Children.Length != 1
            || ExistingTree.SkelControlLists.Length != 0) { Mesh = None; return false; }
        SourceSequence = AnimNodeSequence(ExistingTree.Children[0].Anim);
    }
    if (SourceSequence == None || SourceSequence != InAttachment.WeapAnimNode)
    { Mesh = None; return false; }

    BoundAttachment = InAttachment;
    BoundClass = WeaponClass;
    BoundMesh = Mesh.SkeletalMesh;
    bSavedMeshForceRef = Mesh.bForceRefpose != 0;
    bSavedNoNotifies = SourceSequence.bNoNotifies;
    bSavedNodeForceRef = SourceSequence.bForceRefposeWhenNotPlaying;
    Animation = SourceSequence.AnimSeqName;
    Position = SourceSequence.CurrentTime;
    Rate = SourceSequence.Rate;
    bPlaying = SourceSequence.bPlaying;
    bLooping = SourceSequence.bLooping;
    Mesh.SetForceRefPose(!bFirstPerson);
    Mesh.ForceSkelUpdate();
    Mesh.ForceUpdate(true);
    RootPosition = Mesh.GetBoneLocation('RW_Weapon');
    InvRoot = QuatInvert(Mesh.GetBoneQuaternion('RW_Weapon'));
    if (!FiniteVector(RootPosition) || !ValidQ(InvRoot))
    { Mesh.SetForceRefPose(bSavedMeshForceRef); Shutdown(); return false; }
    for (I = 0; I < Bones.Length; ++I)
    {
        Part.Bone = Bones[I];
        if (Mesh.MatchRefBone(Part.Bone) < 0) continue;
        Part.IdleLocal = QuatRotateVector(InvRoot, Mesh.GetBoneLocation(Part.Bone) - RootPosition);
        Part.IdleLocalQ = QuatProduct(InvRoot, Mesh.GetBoneQuaternion(Part.Bone));
        Part.Control = None;
        if (!FiniteVector(Part.IdleLocal) || !ValidQ(Part.IdleLocalQ))
        { Mesh.SetForceRefPose(bSavedMeshForceRef); Shutdown(); return false; }
        // These are already scaled world distances in the root's axes.
        // Applying another mesh/actor scale in Update would double-scale them.
        Parts.AddItem(Part);
    }
    Mesh.SetForceRefPose(bSavedMeshForceRef);
    Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(true);
    if (Parts.Length == 0) { Shutdown(); return false; }

    if (ExistingTree == None)
    {
        Template = new(InAttachment) class'AnimTree';
        TemplateSequence = new(Template) class'AnimNodeSequence'(SourceSequence);
        TemplateSequence.NodeName = 'KF2VRRemotePumpSequence';
        TemplateSequence.bNoNotifies = true;
        Template.Children[0].Anim = TemplateSequence;
        Template.Children[0].Weight = 1;
        Template.bEnablePooling = false;
        Mesh.SetAnimTreeTemplate(Template);
        Tree = AnimTree(Mesh.Animations);
        Sequence = AnimNodeSequence(Mesh.FindAnimNode('KF2VRRemotePumpSequence'));
        if (Tree == None || Tree == Mesh.AnimTreeTemplate || Sequence == None
            || Tree.Children.Length != 1 || Tree.Children[0].Anim != Sequence)
        { Shutdown(); return false; }
        // Resolve the cloned node's linkup without issuing an animation event.
        if (Animation != '')
        {
            Sequence.SetAnim(Animation);
            if (Sequence.AnimSeq != None) Sequence.SetPosition(Position, false);
        }
        Sequence.Rate = Rate;
        Sequence.bLooping = bLooping;
        Sequence.bPlaying = bPlaying;
        InAttachment.WeapAnimNode = Sequence;
    }
    else { Tree = ExistingTree; Sequence = SourceSequence; }

    bSavedPooling = Tree.bEnablePooling;
    Tree.bEnablePooling = false;
    Sequence.bNoNotifies = true;
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control = new(Tree) class'SkelControlSingleBone';
        Parts[I].Control.ControlName = I == 0 ? 'KF2VRRemotePump' : 'KF2VRRemotePumpBolt';
        Parts[I].Control.bApplyTranslation = true;
        Parts[I].Control.bAddTranslation = false;
        Parts[I].Control.BoneTranslationSpace = BCS_WorldSpace;
        Parts[I].Control.bApplyRotation = true;
        Parts[I].Control.bAddRotation = false;
        Parts[I].Control.BoneRotationSpace = BCS_WorldSpace;
        Parts[I].Control.bIgnoreWhenNotRendered = false;
        Parts[I].Control.bControlledByAnimMetada = false;
        Parts[I].Control.bSetStrengthFromAnimNode = false;
        Parts[I].Control.bPropagateSetActive = false;
        Parts[I].Control.ControlStrength = 0;
        Parts[I].Control.StrengthTarget = 0;
        Link.BoneName = Parts[I].Bone;
        Link.ControlHead = Parts[I].Control;
        Tree.SkelControlLists.AddItem(Link);
    }
    Mesh.InitSkelControls();
    return OwnsBinding();
}

function DisableControls()
{
    local int I;
    for (I = 0; I < Parts.Length; ++I)
    {
        if (Parts[I].Control != None) Parts[I].Control.SetSkelControlStrength(0, 0);
        RestoreVisibility(I);
    }
    if (OwnsBinding())
    {
        Sequence.bForceRefposeWhenNotPlaying = bSavedNodeForceRef;
        // Do not rewind/stop a stock clip that started while controls were active.
        if (bHolding && !Sequence.bPlaying)
            Mesh.SetForceRefPose(bSavedMeshForceRef || bSavedNodeForceRef);
        if (bHolding) { Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(true); }
    }
    bHolding = false;
}

function RestoreVisibility(int Index)
{
    if (!Parts[Index].bVisibilityOwned || Mesh == None) return;
    class'VRBoneVisibility'.static.SetVisible(Mesh, Parts[Index].Bone, !Parts[Index].bWasHidden);
    Parts[Index].bVisibilityOwned = false;
}

function bool UpdateMechanisms(array<NetMechanismPart> Motion, int Hand, int ItemId)
{
    local int I, J;
    local vector Base;
    local quat Root, Rest;
    local bool bAny, bPose;
    if (!OwnsBinding() || Mesh.HiddenGame) { DisableControls(); return false; }
    Base = Mesh.GetBoneLocation('RW_Weapon'); Root = Mesh.GetBoneQuaternion('RW_Weapon');
    if (!FiniteVector(Base) || !ValidQ(Root)) { DisableControls(); return false; }
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control.SetSkelControlStrength(0, 0);
        for (J = 0; J < Motion.Length; ++J)
            if (Motion[J].Hand == Hand && Motion[J].ItemId == ItemId && Motion[J].Bone == Parts[I].Bone) break;
        if (J >= Motion.Length) { RestoreVisibility(I); continue; }
        bAny = true;
        if (!Parts[I].bVisibilityOwned)
        {
            Parts[I].bWasHidden = class'VRBoneVisibility'.static.IsHidden(Mesh, Parts[I].Bone);
            Parts[I].bVisibilityOwned = true;
        }
        class'VRBoneVisibility'.static.SetVisible(Mesh, Parts[I].Bone, (Motion[J].Flags & 2) == 0);
        if ((Motion[J].Flags & 1) == 0) continue;
        bPose = true;
        Rest = QuatProduct(Root, Parts[I].IdleLocalQ);
        Parts[I].Control.BoneTranslation = Base + QuatRotateVector(Root, Parts[I].IdleLocal)
            + QuatRotateVector(Rest, Motion[J].Translation);
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(Rest, QuatFromRotator(Motion[J].Rotation)));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    if (!bAny) { DisableControls(); return false; }
    if (bPose)
    {
        Sequence.bNoNotifies = true;
        Sequence.bForceRefposeWhenNotPlaying = false;
        Mesh.SetForceRefPose(false);
    }
    else if (bHolding)
    {
        Sequence.bForceRefposeWhenNotPlaying = bSavedNodeForceRef;
        if (!Sequence.bPlaying) Mesh.SetForceRefPose(bSavedMeshForceRef || bSavedNodeForceRef);
    }
    bHolding = bPose;
    Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(true);
    return true;
}

function Update(float ActualPull, bool bActive)
{
    local vector Base, Back;
    local quat Q;
    local int I;
    if (!bActive || !OwnsBinding() || SupportedMesh(BoundClass) == '' || Mesh.HiddenGame || !FiniteFloat(ActualPull)
        || ActualPull < 0 || !FiniteFloat(MaxPullUU) || MaxPullUU <= 0 || ActualPull > MaxPullUU)
    { DisableControls(); return; }
    Base = Mesh.GetBoneLocation('RW_Weapon');
    Q = Mesh.GetBoneQuaternion('RW_Weapon');
    if (!FiniteVector(Base) || !ValidQ(Q)) { DisableControls(); return; }
    Back = -QuatRotateVector(Q, vect(1,0,0)) * ActualPull;
    Sequence.bNoNotifies = true;
    Sequence.bForceRefposeWhenNotPlaying = false;
    Mesh.SetForceRefPose(false);
    for (I = 0; I < Parts.Length; ++I)
    {
        if (Parts[I].Bone != 'RW_Pump' && Parts[I].Bone != 'RW_Bolt')
        { Parts[I].Control.SetSkelControlStrength(0, 0); continue; }
        Parts[I].Control.BoneTranslation = Base + QuatRotateVector(Q, Parts[I].IdleLocal) + Back;
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(Q, Parts[I].IdleLocalQ));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    bHolding = true;
    Mesh.ForceSkelUpdate();
    Mesh.ForceUpdate(true);
}

function Shutdown()
{
    local int I, J;
    local SkelControlBase Previous, Current;
    local bool bOwnsMesh;
    bOwnsMesh = OwnsBinding();
    DisableControls();
    if (Tree != None && (Mesh == None || Tree != Mesh.AnimTreeTemplate))
    {
        for (J = 0; J < Parts.Length; ++J)
        {
            if (Parts[J].Control == None) continue;
            for (I = Tree.SkelControlLists.Length - 1; I >= 0; --I)
            {
                Previous = None;
                Current = Tree.SkelControlLists[I].ControlHead;
                while (Current != None && Current != Parts[J].Control)
                { Previous = Current; Current = Current.NextControl; }
                if (Current == None) continue;
                if (Previous == None) Tree.SkelControlLists[I].ControlHead = Current.NextControl;
                else Previous.NextControl = Current.NextControl;
                if (Tree.SkelControlLists[I].ControlHead == None) Tree.SkelControlLists.Remove(I, 1);
                break;
            }
            Parts[J].Control.NextControl = None;
        }
        Tree.bEnablePooling = bSavedPooling;
    }
    if (bOwnsMesh)
    {
        Sequence.bNoNotifies = bSavedNoNotifies;
        Sequence.bForceRefposeWhenNotPlaying = bSavedNodeForceRef;
        Mesh.InitSkelControls();
        Mesh.ForceSkelUpdate();
        Mesh.ForceUpdate(true);
    }
    // SDK Animations is const, and SetAnimTreeTemplate accepts only AnimTree.
    // Keep the now-neutral private child-0 wrapper rather than clearing a live
    // sequence or restoring an old playback time. Mesh.PlayAnim still works.
    // The owning remote presenter normally destroys this attachment next.
    Parts.Length = 0;
    Sequence = None;
    Tree = None;
    Mesh = None;
    BoundMesh = None;
    BoundAttachment = None;
    BoundClass = None;
    bHolding = false;
}

defaultproperties
{
    // Safety bound only; ordinary audited strokes are approximately 7-12 UU.
    MaxPullUU=64.0
}
