// Freeze the visible weapon mechanism on a local toss. These component-space
// controls belong only to the cosmetic copy; they cannot run reload notifies.
class VRLocalDropPose extends Object;

static function Capture(SkeletalMeshComponent Source, SkeletalMeshComponent Copy, name Root)
{
    local array<name> Bones;
    local AnimTree Tree;
    local AnimTree.SkelControlListHead Link;
    local SkelControlSingleBone Control;
    local int I;
    if (Source == None || Copy == None || Source.SkeletalMesh == None
        || Source.SkeletalMesh != Copy.SkeletalMesh) return;
    Tree = AnimTree(Copy.Animations);
    if (Tree == None || Tree == Copy.AnimTreeTemplate) return;
    Tree.bEnablePooling = false;
    // Both components use the exact same skeletal asset and therefore its
    // origin/rot-origin. Copy the evaluated component pose directly; deriving
    // it through world quaternions loses reflection/nonuniform scale and can
    // turn a barrel independently of its receiver. Include the weapon root:
    // Place later accounts for that captured root exactly once.
    Copy.SetScale(Source.Scale);
    Copy.SetScale3D(Source.Scale3D);
    Source.GetBoneNames(Bones);
    for (I = 0; I < Bones.Length; ++I)
    {
        if ((Bones[I] != Root && Left(string(Bones[I]), 3) != "RW_") || Copy.MatchRefBone(Bones[I]) < 0) continue;
        Control = new(Tree) class'SkelControlSingleBone';
        Control.ControlName = 'VRLocalDropPose';
        Control.bApplyTranslation = true; Control.bAddTranslation = false;
        Control.bApplyRotation = true; Control.bAddRotation = false;
        Control.BoneTranslationSpace = BCS_ComponentSpace; Control.BoneRotationSpace = BCS_ComponentSpace;
        Control.BoneTranslation = Source.GetBoneLocation(Bones[I], 1);
        Control.BoneRotation = QuatToRotator(Source.GetBoneQuaternion(Bones[I], 1));
        Control.bIgnoreWhenNotRendered = false; Control.bControlledByAnimMetada = false;
        Control.bSetStrengthFromAnimNode = false;
        Control.ControlStrength = 1; Control.StrengthTarget = 1;
        Link.BoneName = Bones[I]; Link.ControlHead = Control;
        Tree.SkelControlLists.AddItem(Link);
    }
    Copy.InitSkelControls(); Copy.ForceSkelUpdate(); Copy.ForceUpdate(false);
}
