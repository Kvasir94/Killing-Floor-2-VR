// Asset references stay in one place. Missing originals are a failed asset
// gate, never permission to silently display a stock KF2 turret/tool.
class VREngineerPresentation extends Object;

static simulated function PlayCue(Actor Context, name CueName)
{
    local SoundCue Cue;
    if (Context == None) return;
    Cue = SoundCue(DynamicLoadObject("KF2VREngineer." $ CueName, class'SoundCue', true));
    if (Cue != None) Context.PlaySound(Cue);
}

static simulated function bool HasCoreAssets()
{
    local int Level;
    for (Level = 1; Level <= 3; ++Level)
        if (DynamicLoadObject("KF2VREngineer.Sentry" $ Level, class'SkeletalMesh', true) == None) return false;
    return DynamicLoadObject("KF2VREngineer.ConstructionPDA", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.DestructionPDA", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.Toolbox", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.Wrench", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.SentryBlueprint", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.SentryRocket", class'StaticMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.Mat_7dc8b1aaae023b86", class'MaterialInterface', true) != None
        && DynamicLoadObject("KF2VREngineer.SentryScrap", class'StaticMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.Mat_29d6b9e21a6780b8", class'MaterialInterface', true) != None
        && DynamicLoadObject("KF2VREngineer.sentry_shoot", class'SoundCue', true) != None;
}

static simulated function bool HasWranglerAssets()
{
    return DynamicLoadObject("KF2VREngineer.Wrangler", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.SentryShield", class'SkeletalMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.WranglerDot", class'StaticMesh', true) != None
        && DynamicLoadObject("KF2VREngineer.Mat_a2a912eb3833fbe6", class'MaterialInterface', true) != None
        && DynamicLoadObject("KF2VREngineer.sentry_shaft_shoot", class'SoundCue', true) != None
        && DynamicLoadObject("KF2VREngineer.sentry_shaft_shoot2", class'SoundCue', true) != None
        && DynamicLoadObject("KF2VREngineer.sentry_shaft_shoot3", class'SoundCue', true) != None;
}

static simulated function ConfigureTurret(VREngineerSentry Sentry)
{
    local AnimTree Tree;
    local AnimNodeSequence Idle;
    local SkelControlSingleBone YawBone, PitchBone;
    local AnimTree.SkelControlListHead Link;
    Tree = new(Sentry) class'AnimTree';
    Idle = new(Tree) class'AnimNodeSequence';
    Idle.NodeName = 'EngineerBaseSequence';
    Tree.Children[0].Anim = Idle;
    Tree.Children[0].Weight = 1;
    if (!Sentry.bConstructing && !Sentry.bUpgrading)
    {
    YawBone = new(Tree) class'SkelControlSingleBone';
    YawBone.ControlName = 'EngineerYaw';
    YawBone.bApplyRotation = true;
    YawBone.bAddRotation = true;
    YawBone.BoneRotationSpace = BCS_ComponentSpace;
    YawBone.ControlStrength = 1; YawBone.StrengthTarget = 1;
    Link.BoneName = 'upper_telescope_01'; Link.ControlHead = YawBone;
    Tree.SkelControlLists.AddItem(Link);
    PitchBone = new(Tree) class'SkelControlSingleBone';
    PitchBone.ControlName = 'EngineerPitch';
    PitchBone.bApplyRotation = true;
    PitchBone.bAddRotation = true;
    PitchBone.BoneRotationSpace = BCS_ComponentSpace;
    PitchBone.ControlStrength = 1; PitchBone.StrengthTarget = 1;
    Link.BoneName = Sentry.BuildingLevel == 1 ? 'turret_back' : 'S2turret_back';
    Link.ControlHead = PitchBone;
    Tree.SkelControlLists.AddItem(Link);
    }
    Sentry.Mesh.SetAnimTreeTemplate(Tree);
    Sentry.BaseSequence = AnimNodeSequence(Sentry.Mesh.FindAnimNode('EngineerBaseSequence'));
    if (Sentry.BaseSequence != None && Sentry.bOriginalAnimationAvailable)
    {
        Sentry.BaseSequence.SetAnim(Sentry.BaseSequenceName);
        if (!Sentry.bConstructing && !Sentry.bUpgrading) Sentry.BaseSequence.PlayAnim(true);
    }
    Sentry.YawControl = None; Sentry.PitchControl = None;
    if (!Sentry.bConstructing && !Sentry.bUpgrading)
    {
        Sentry.YawControl = SkelControlSingleBone(Sentry.Mesh.FindSkelControl('EngineerYaw'));
        Sentry.PitchControl = SkelControlSingleBone(Sentry.Mesh.FindSkelControl('EngineerPitch'));
    }
}

static simulated function UpdateTurret(VREngineerSentry Sentry)
{
    local rotator Relative;
    Relative = Normalize(Sentry.TurretAim - Sentry.Rotation);
    if (Sentry.YawControl != None) Sentry.YawControl.BoneRotation.Yaw = Relative.Yaw;
    if (Sentry.PitchControl != None) Sentry.PitchControl.BoneRotation.Pitch = Relative.Pitch;
    Sentry.Mesh.ForceSkelUpdate();
}
