// Opt-in, client-only rig experiment. This actor never changes the real pawn.
// Its saved local pose comes from the stock graph already evaluated on that
// pawn; a separate tree then applies tracking to this non-colliding duplicate.
// This is not a separately retimed locomotion graph or a gameplay hitbox.
class KF2VRNetAvatarPreview extends Actor;

var KFPawn_Human SourcePawn;
var KF2VRNetPose PoseOwner;
var KFSkeletalMeshComponent BodyMesh;
var SkeletalMeshComponent HeadMesh;
var array<MeshComponent> CosmeticMeshes;
var array<MeshComponent> CosmeticSources;
var SkeletalMeshComponent BoundSourceMesh;
var SkeletalMesh BoundBodyAsset;
var AnimNode BoundSourceTree;
var PhysicsAsset BoundSourcePhysicsAsset;
var bool bSourceMeshCollide, bSourceMeshTrace;
var AnimTree PoseTree;
var SkelControlSingleBone HeadControl;
var SkelControlLimb ArmControl[2];
var SkelControlSingleBone WristControl[2];
var SkelControl_TwistBone TwistControl[2];
var KF2VRNetAvatarWeaponPreview WeaponPreview;
var KF2VRNetAvatarPreviewProbe PostUpdateProbe;
var name ShoulderBone[2], ElbowBone[2];
var float ArmLength[2];
var quat WristBasis[2], HeadBasis;
var int BoneCount;
var bool bReady, bReferencePending, bHaveRoot, bSourceWasCrouched;
var float ReferenceStarted, NextDiagnosticTime, NextCosmeticCheck;
var float NextBuildAttempt;
var float LastTargetTime, TargetAlpha, ReachClampDistance[2];
var vector PreviewRoot, PreviewOffset, TargetHand[2], RequestedHand[2], TargetHead;
var rotator PreviewYaw, ReferenceYaw, TargetHeadRotation, PreviousHeadRotation;
var bool bDrawPreviewAxes;
var byte TrackingFlags;
var int PreviewSamples;
var bool bRequestedWeaponContact, bStaleHidden;
var bool bSafePlacement, bPlacementChecked;
var vector LocalPreviewOffset, CheckedPlacementRoot;
var rotator CheckedPlacementYaw;
var float NextPlacementCheck, NextPlacementDiagnostic;
var bool bSelfPreview;
var private KF2VRNetPlayerController SelfInspectController;
var private float NextSourcePoseDiagnostic;

simulated function Initialize(KFPawn_Human NewPawn, KF2VRNetPose NewPose,
    optional bool bNewSelfPreview)
{
    local KF2VRNetPlayerController PC;
    SourcePawn = NewPawn;
    PoseOwner = NewPose;
    bSelfPreview = bNewSelfPreview;
    if (bSelfPreview)
        foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
            if (PC.Pawn == SourcePawn) SelfInspectController = PC;
    SetOwner(NewPose);
    PostUpdateProbe = Spawn(class'KF2VRNetAvatarPreviewProbe', self);
    if (PostUpdateProbe == None)
    {
        `log("KF2VRNet avatar_preview_unavailable reason=post_update_probe");
        Destroy();
        return;
    }
    PostUpdateProbe.Preview = self;
    if (SourcePawn != None)
    {
        UpdatePreviewRoot(SourcePawn.Location, SourcePawn.Rotation);
        if (bSafePlacement) BuildRig();
    }
}

simulated function bool IsSelfViewActive()
{
    return !bSelfPreview || (SourcePawn != None && !SourcePawn.bDeleteMe && SourcePawn.Health > 0
        && SelfInspectController != None
        && !SelfInspectController.bDeleteMe && SelfInspectController.Pawn == SourcePawn
        && SelfInspectController.bSelfAvatarInspection
        && SelfInspectController.NativeSelfViewActive == 1);
}

simulated function ReportMissingSourcePose()
{
    if (BoundSourceMesh == None || WorldInfo.RealTimeSeconds < NextSourcePoseDiagnostic) return;
    NextSourcePoseDiagnostic = WorldInfo.RealTimeSeconds + 2.0;
    `log("KF2VRNet avatar_preview_waiting_source_pose world=" $ PoseOwner.WorldEpoch
        $ " connection=" $ PoseOwner.ConnectionEpoch $ " pawn=" $ PoseOwner.PawnEpoch
        $ " time=" $ WorldInfo.RealTimeSeconds $ " self_mode=" $ bSelfPreview
        $ " source=" $ SourcePawn $ " source_atoms=" $ BoundSourceMesh.LocalAtoms.Length
        $ " expected_atoms=" $ BoneCount $ " source_tick_tag=" $ BoundSourceMesh.TickTag
        $ " source_cached_atoms_tag=" $ BoundSourceMesh.CachedAtomsTag
        $ " source_update_hidden=" $ BoundSourceMesh.bUpdateSkelWhenNotRendered
        $ " source_tick_nodes_hidden=" $ BoundSourceMesh.bTickAnimNodesWhenNotRendered
        $ " source_owner_no_see=" $ BoundSourceMesh.bOwnerNoSee);
}

simulated function CheckPreviewPlacement()
{
    local vector Candidate, HitLocation, HitNormal, OldOffset;
    local Actor Obstacle, FirstObstacle;
    local rotator RotationChange;
    local int I;
    local bool bWasSafe;
    if (SourcePawn == None || SourcePawn.bDeleteMe || !ValidVector(PreviewRoot))
    {
        bSafePlacement = false;
        SetPreviewVisible(false);
        return;
    }
    RotationChange = Normalize(PreviewYaw - CheckedPlacementYaw);
    if (bPlacementChecked && WorldInfo.RealTimeSeconds < NextPlacementCheck
        && VSizeSq(PreviewRoot - CheckedPlacementRoot) < 64.0
        && Abs(RotationChange.Yaw) < 512) return;
    bWasSafe = bSafePlacement;
    OldOffset = LocalPreviewOffset;
    bSafePlacement = false;
    // Trace from the buffered root through a torso-sized volume. TraceActors
    // includes map StaticMeshActors; invoking the source pawn ignores itself.
    // Retain a clear local offset to avoid oscillating between candidates.
    for (I = 0; I < 5; ++I)
    {
        switch (I)
        {
        case 0: Candidate = LocalPreviewOffset; break;
        case 1: Candidate = vect(0,110,0); break;
        case 2: Candidate = vect(0,-110,0); break;
        case 3: Candidate = vect(110,0,0); break;
        case 4: Candidate = vect(-110,0,0); break;
        }
        if (I > 0 && VSizeSq(Candidate - OldOffset) < 1.0) continue;
        Obstacle = SourcePawn.Trace(HitLocation, HitNormal,
            PreviewRoot + (Candidate >> PreviewYaw), PreviewRoot, true,
            vect(24,24,44),, TRACEFLAG_Blocking);
        if (Obstacle == None)
        {
            LocalPreviewOffset = Candidate;
            bSafePlacement = true;
            break;
        }
        if (FirstObstacle == None) FirstObstacle = Obstacle;
    }
    CheckedPlacementRoot = PreviewRoot;
    CheckedPlacementYaw = PreviewYaw;
    NextPlacementCheck = WorldInfo.RealTimeSeconds + 0.5;
    if (!bPlacementChecked || bWasSafe != bSafePlacement
        || VSizeSq(OldOffset - LocalPreviewOffset) > 1.0
        || (!bSafePlacement && WorldInfo.RealTimeSeconds >= NextPlacementDiagnostic))
    {
        `log("KF2VRNet avatar_preview_placement world=" $ PoseOwner.WorldEpoch
            $ " connection=" $ PoseOwner.ConnectionEpoch $ " pawn=" $ PoseOwner.PawnEpoch
            $ " reference=" $ PoseOwner.Snapshot.Sample.ReferenceEpoch
            $ " time=" $ WorldInfo.RealTimeSeconds $ " safe=" $ bSafePlacement
            $ " root=" $ PreviewRoot $ " local_offset=" $ LocalPreviewOffset
            $ " rejected_obstacle=" $ FirstObstacle $ " trace_actors=true extent=24,24,44");
        NextPlacementDiagnostic = WorldInfo.RealTimeSeconds + 2.0;
    }
    bPlacementChecked = true;
    if (!bSafePlacement) SetPreviewVisible(false);
}

simulated function UpdatePreviewRoot(vector Root, rotator RootYaw)
{
    PreviewRoot = Root;
    PreviewYaw = rot(0,0,0);
    PreviewYaw.Yaw = RootYaw.Yaw;
    if (bSelfPreview)
    {
        // The self inspector occupies its sampled pawn root. Camera clearance
        // is independently owned by the utility view; never shift the avatar.
        LocalPreviewOffset = vect(0,0,0);
        bSafePlacement = SourcePawn != None && !SourcePawn.bDeleteMe && ValidVector(Root);
        if (!bSafePlacement) SetPreviewVisible(false);
    }
    else CheckPreviewPlacement();
    PreviewOffset = LocalPreviewOffset >> PreviewYaw;
    bHaveRoot = true;
    // Reference calibration must observe the same actor frame it started in.
    if (!bReferencePending && bSafePlacement)
    {
        SetLocation(PreviewRoot + PreviewOffset);
        SetRotation(PreviewYaw);
    }
}

simulated function vector GetPreviewOffset()
{
    return PreviewOffset;
}

simulated function SetTrackingFlags(byte Flags)
{
    TrackingFlags = Flags & 7;
}

simulated function name HandBone(int Hand)
{
    return Hand == 0 ? 'LeftHand' : 'RightHand';
}

simulated function bool ValidVector(vector V)
{
    return class'KF2VRNetTypes'.static.IsBoundedVector(V, 10000000.0);
}

simulated function ConfigureMesh(MeshComponent M, MeshComponent Source)
{
    local int I;
    M.SetActorCollision(false, false);
    M.SetTraceBlocking(false, false);
    M.SetBlockRigidBody(false);
    M.SetNotifyRigidBodyCollision(false);
    M.SetOwnerNoSee(false);
    M.SetOnlyOwnerSee(false);
    M.SetHidden(true);
    M.SetScale(Source.Scale);
    M.SetScale3D(Source.Scale3D);
    M.SetTranslation(Source.Translation);
    M.SetRotation(Source.Rotation);
    M.SetLightingChannels(Source.LightingChannels);
    M.SetLightEnvironment(Source.LightEnvironment);
    M.CastShadow = true;
    M.bCastDynamicShadow = true;
    for (I = 0; I < Source.GetNumElements(); ++I)
        M.SetMaterial(I, Source.GetMaterial(I));
}

simulated function ConfigureSkeleton(SkeletalMeshComponent M)
{
    // No physics asset means even bone-oriented trace helpers cannot hit this
    // mesh. No native KF animation nodes or gameplay notifies are evaluated.
    M.SetPhysicsAsset(None);
    M.SetHasPhysicsAssetInstance(false);
    M.SetEnableClothSimulation(false);
    M.PhysicsWeight = 0;
    M.bUpdateKinematicBonesFromAnimation = false;
    M.bForceDiscardRootMotion = true;
    M.bDisableFaceFX = true;
    M.bUpdateSkelWhenNotRendered = true;
    M.bTickAnimNodesWhenNotRendered = true;
    M.bIgnoreControllersWhenNotRendered = false;
    M.bForceUpdateAttachmentsInTick = true;
    M.ForcedLodModel = 1;
    // Pose targets arrive before PostAsyncWork; evaluate this private mesh afterward.
    // A separate componentless actor measures the bones in PostUpdateWork.
    M.SetTickGroup(TG_PostAsyncWork);
}

simulated function AddControl(AnimTree T, name Bone, SkelControlBase Control)
{
    local AnimTree.SkelControlListHead Link;
    local SkelControlBase Tail;
    local int I;
    Control.ControlStrength = 0;
    Control.StrengthTarget = 0;
    Control.bControlledByAnimMetada = false;
    Control.bSetStrengthFromAnimNode = false;
    Control.bPropagateSetActive = false;
    Control.bIgnoreWhenNotRendered = false;
    for (I = 0; I < T.SkelControlLists.Length; ++I)
        if (T.SkelControlLists[I].BoneName == Bone)
        {
            Tail = T.SkelControlLists[I].ControlHead;
            while (Tail.NextControl != None) Tail = Tail.NextControl;
            Tail.NextControl = Control;
            return;
        }
    Link.BoneName = Bone;
    Link.ControlHead = Control;
    T.SkelControlLists.AddItem(Link);
}

simulated function bool BuildRig()
{
    local AnimTree Template;
    local AnimNodeSequence Sequence;
    local SkelControlSingleBone RotationControl;
    local SkelControlLimb Limb;
    local array<name> Bones;
    local int I;
    local name TwistBone;
    local SkelControl_TwistBone Twist;
    if (WorldInfo.NetMode == NM_DedicatedServer || SourcePawn == None
        || !bSafePlacement
        || SourcePawn.bDeleteMe || SourcePawn.Health <= 0
        || SourcePawn.Mesh == None || SourcePawn.Mesh.SkeletalMesh == None)
        return false;
    if (WorldInfo.RealTimeSeconds < NextBuildAttempt) return false;
    NextBuildAttempt = WorldInfo.RealTimeSeconds + 1.0;
    ReleaseMeshes();
    BoundSourceMesh = SourcePawn.Mesh;
    BoundBodyAsset = BoundSourceMesh.SkeletalMesh;
    BoundSourceTree = BoundSourceMesh.Animations;
    BoundSourcePhysicsAsset = BoundSourceMesh.PhysicsAsset;
    bSourceMeshCollide = BoundSourceMesh.CollideActors;
    bSourceMeshTrace = BoundSourceMesh.BlockZeroExtent;
    BodyMesh = new(self) class'KFSkeletalMeshComponent';
    BodyMesh.SetSkeletalMesh(BoundBodyAsset);
    ConfigureMesh(BodyMesh, BoundSourceMesh);
    ConfigureSkeleton(BodyMesh);
    BodyMesh.GetBoneNames(Bones);
    BoneCount = Bones.Length;
    if (BoneCount == 0 || BodyMesh.MatchRefBone('head') < 0)
    {
        `log("KF2VRNet avatar_preview_unavailable reason=head_or_skeleton mesh=" $ BoundBodyAsset);
        ReleaseMeshes();
        return false;
    }
    for (I = 0; I < 2; ++I)
    {
        ElbowBone[I] = BodyMesh.GetParentBone(HandBone(I));
        ShoulderBone[I] = BodyMesh.GetParentBone(ElbowBone[I]);
        if (BodyMesh.MatchRefBone(HandBone(I)) < 0 || ElbowBone[I] == ''
            || ShoulderBone[I] == '' || BodyMesh.MatchRefBone(ShoulderBone[I]) < 0)
        {
            `log("KF2VRNet avatar_preview_unavailable reason=arm_hierarchy hand=" $ I);
            ReleaseMeshes();
            return false;
        }
    }
    Template = new(self) class'AnimTree';
    Template.bEnablePooling = false;
    Sequence = new(Template) class'AnimNodeSequence';
    Sequence.NodeName = 'VRPreviewReference';
    Sequence.bNoNotifies = true;
    Sequence.bPlaying = false;
    Sequence.bCauseActorAnimEnd = false;
    Sequence.bCauseActorAnimPlay = false;
    Template.Children[0].Anim = Sequence;
    Template.Children[0].Weight = 1;
    RotationControl = new(Template) class'SkelControlSingleBone';
    RotationControl.ControlName = 'VRPreviewHead';
    RotationControl.bApplyRotation = true;
    RotationControl.BoneRotationSpace = BCS_WorldSpace;
    AddControl(Template, 'head', RotationControl);
    for (I = 0; I < 2; ++I)
    {
        Limb = new(Template) class'SkelControlLimb';
        Limb.ControlName = I == 0 ? 'VRPreviewArmLeft' : 'VRPreviewArmRight';
        Limb.EffectorLocationSpace = BCS_WorldSpace;
        Limb.JointTargetLocationSpace = BCS_WorldSpace;
        Limb.bAllowStretching = false;
        Limb.bMaintainEffectorRelRot = false;
        Limb.bTakeRotationFromEffectorSpace = false;
        AddControl(Template, HandBone(I), Limb);
        RotationControl = new(Template) class'SkelControlSingleBone';
        RotationControl.ControlName = I == 0 ? 'VRPreviewWristLeft' : 'VRPreviewWristRight';
        RotationControl.bApplyRotation = true;
        RotationControl.bApplyTranslation = false;
        RotationControl.BoneRotationSpace = BCS_WorldSpace;
        AddControl(Template, HandBone(I), RotationControl);
        TwistBone = I == 0 ? 'LeftForeArmTwist1' : 'RightForeArmTwist1';
        if (BodyMesh.MatchRefBone(TwistBone) >= 0)
        {
            Twist = new(Template) class'SkelControl_TwistBone';
            Twist.ControlName = I == 0 ? 'VRPreviewTwistLeft' : 'VRPreviewTwistRight';
            Twist.SourceBoneName = HandBone(I);
            Twist.TwistAngleScale = -0.5;
            AddControl(Template, TwistBone, Twist);
        }
    }
    BodyMesh.SetAnimTreeTemplate(Template);
    PoseTree = AnimTree(BodyMesh.Animations);
    if (PoseTree == None || PoseTree == Template || PoseTree == BoundSourceTree)
    {
        `log("KF2VRNet avatar_preview_unavailable reason=private_tree");
        ReleaseMeshes();
        return false;
    }
    PoseTree.bEnablePooling = false;
    HeadControl = SkelControlSingleBone(BodyMesh.FindSkelControl('VRPreviewHead'));
    ArmControl[0] = SkelControlLimb(BodyMesh.FindSkelControl('VRPreviewArmLeft'));
    ArmControl[1] = SkelControlLimb(BodyMesh.FindSkelControl('VRPreviewArmRight'));
    WristControl[0] = SkelControlSingleBone(BodyMesh.FindSkelControl('VRPreviewWristLeft'));
    WristControl[1] = SkelControlSingleBone(BodyMesh.FindSkelControl('VRPreviewWristRight'));
    TwistControl[0] = SkelControl_TwistBone(BodyMesh.FindSkelControl('VRPreviewTwistLeft'));
    TwistControl[1] = SkelControl_TwistBone(BodyMesh.FindSkelControl('VRPreviewTwistRight'));
    if (HeadControl == None || ArmControl[0] == None || ArmControl[1] == None
        || WristControl[0] == None || WristControl[1] == None)
    {
        ReleaseMeshes();
        return false;
    }
    ReferenceYaw = PreviewYaw;
    SetLocation(PreviewRoot + PreviewOffset);
    SetRotation(ReferenceYaw);
    BodyMesh.SetForceRefPose(true);
    AttachComponent(BodyMesh);
    ReferenceStarted = WorldInfo.RealTimeSeconds;
    bReferencePending = true;
    return true;
}

simulated function EAxis DominantAxis(vector Direction, out int Invert,
    optional bool bExclude, optional EAxis Excluded)
{
    local float X, Y, Z;
    X = Abs(Direction.X);
    Y = Abs(Direction.Y);
    Z = Abs(Direction.Z);
    if (bExclude)
    {
        if (Excluded == AXIS_X) X = -1;
        if (Excluded == AXIS_Y) Y = -1;
        if (Excluded == AXIS_Z) Z = -1;
    }
    if (X >= Y && X >= Z) { Invert = Direction.X < 0 ? 1 : 0; return AXIS_X; }
    if (Y >= Z) { Invert = Direction.Y < 0 ? 1 : 0; return AXIS_Y; }
    Invert = Direction.Z < 0 ? 1 : 0;
    return AXIS_Z;
}

simulated function quat ReferenceWristBasis(int Hand)
{
    local vector Forward, Up, Side, Wrist;
    local name Middle, Index, Pinky;
    local string Prefix;
    Prefix = Hand == 0 ? "LeftHand" : "RightHand";
    Middle = name(Prefix $ "Middle1");
    Index = name(Prefix $ "Index1");
    Pinky = name(Prefix $ "Pinky1");
    Wrist = BodyMesh.GetBoneLocation(HandBone(Hand));
    if (BodyMesh.MatchRefBone(Middle) >= 0 && BodyMesh.MatchRefBone(Index) >= 0
        && BodyMesh.MatchRefBone(Pinky) >= 0)
    {
        Forward = Normal(BodyMesh.GetBoneLocation(Middle) - Wrist);
        Up = BodyMesh.GetBoneLocation(Index) - BodyMesh.GetBoneLocation(Pinky);
    }
    else
    {
        Forward = Normal(Wrist - BodyMesh.GetBoneLocation(ElbowBone[Hand]));
        Up = vect(0,0,1);
        `log("KF2VRNet avatar_preview_wrist_basis hand=" $ Hand $ " basis=forearm_fallback");
    }
    Up = Normal(Up - Forward * (Up dot Forward));
    if (VSizeSq(Up) < 0.5) Up = Normal(vect(1,0,0) - Forward * Forward.X);
    Side = Normal(Up cross Forward);
    Up = Normal(Forward cross Side);
    return QuatProduct(QuatInvert(QuatFromRotator(OrthoRotation(Forward, Side, Up))),
        BodyMesh.GetBoneQuaternion(HandBone(Hand)));
}

simulated function bool FinishReference()
{
    local int I;
    local vector Shoulder, Elbow, Wrist, Direction, Hinge, Pole;
    local int Invert;
    if (bReferencePending && BoundSourceMesh != None
        && BoundSourceMesh.LocalAtoms.Length != BoneCount
        && WorldInfo.RealTimeSeconds - ReferenceStarted > 0.5)
        ReportMissingSourcePose();
    if (!bReferencePending || BodyMesh == None || PoseTree == None
        || WorldInfo.RealTimeSeconds <= ReferenceStarted
        || BodyMesh.SpaceBases.Length != BoneCount
        || BoundSourceMesh.LocalAtoms.Length != BoneCount) return false;
    HeadBasis = QuatProduct(QuatInvert(QuatFromRotator(ReferenceYaw)),
        BodyMesh.GetBoneQuaternion('head'));
    for (I = 0; I < 2; ++I)
    {
        Shoulder = BodyMesh.GetBoneLocation(ShoulderBone[I]);
        Elbow = BodyMesh.GetBoneLocation(ElbowBone[I]);
        Wrist = BodyMesh.GetBoneLocation(HandBone(I));
        ArmLength[I] = VSize(Elbow - Shoulder) + VSize(Wrist - Elbow);
        if (VSize(Elbow - Shoulder) < 4 || VSize(Wrist - Elbow) < 4
            || !(ArmLength[I] > 10 && ArmLength[I] < 160))
        {
            `log("KF2VRNet avatar_preview_unavailable reason=arm_lengths hand=" $ I
                $ " shoulder=" $ ShoulderBone[I] $ " elbow=" $ ElbowBone[I]
                $ " length=" $ ArmLength[I]);
            ReleaseMeshes();
            return false;
        }
        Direction = QuatRotateVector(QuatInvert(BodyMesh.GetBoneQuaternion(ShoulderBone[I])),
            Normal(Elbow - Shoulder));
        ArmControl[I].BoneAxis = DominantAxis(Direction, Invert);
        ArmControl[I].bInvertBoneAxis = Invert != 0;
        Pole = vect(-18,0,-28);
        Pole.Y = I == 0 ? -16 : 16;
        Hinge = Normal((Wrist - Shoulder) cross (Pole >> ReferenceYaw));
        Direction = QuatRotateVector(QuatInvert(BodyMesh.GetBoneQuaternion(ElbowBone[I])), Hinge);
        ArmControl[I].JointAxis = DominantAxis(Direction, Invert, true, ArmControl[I].BoneAxis);
        ArmControl[I].bInvertJointAxis = Invert != 0;
        WristBasis[I] = ReferenceWristBasis(I);
    }
    BodyMesh.SetForceRefPose(false);
    PoseTree.bUseSavedPose = true;
    bReferencePending = false;
    bReady = true;
    SetLocation(PreviewRoot + PreviewOffset);
    SetRotation(PreviewYaw);
    RefreshCosmetics();
    `log("KF2VRNet avatar_preview_bound world=" $ PoseOwner.WorldEpoch
        $ " connection=" $ PoseOwner.ConnectionEpoch $ " pawn=" $ PoseOwner.PawnEpoch
        $ " self_mode=" $ bSelfPreview
        $ " source=" $ SourcePawn $ " mesh=" $ BoundBodyAsset
        $ " body=" $ BodyMesh $ " tree=" $ PoseTree $ " bones=" $ BoneCount
        $ " left_shoulder=" $ ShoulderBone[0] $ " left_elbow=" $ ElbowBone[0]
        $ " left_length=" $ ArmLength[0] $ " right_length=" $ ArmLength[1]
        $ " colliding=false base=evaluated_stock_local_pose");
    return true;
}

simulated function SkeletalMeshComponent CloneSkeletalPart(SkeletalMeshComponent Source)
{
    local SkeletalMeshComponent Part;
    if (Source == None || Source.SkeletalMesh == None) return None;
    Part = new(self) class'SkeletalMeshComponent';
    Part.SetSkeletalMesh(Source.SkeletalMesh);
    ConfigureMesh(Part, Source);
    ConfigureSkeleton(Part);
    Part.SetParentAnimComponent(BodyMesh);
    Part.SetShadowParent(BodyMesh);
    Part.SetLODParent(BodyMesh);
    AttachComponent(Part);
    return Part;
}

simulated function RefreshCosmetics()
{
    local int I, J;
    local MeshComponent Source, Part;
    local StaticMeshComponent StaticPart;
    for (I = 0; I < CosmeticMeshes.Length; ++I)
        if (CosmeticMeshes[I] != None) CosmeticMeshes[I].DetachFromAny();
    CosmeticMeshes.Length = 0;
    CosmeticSources.Length = 0;
    if (HeadMesh != None) HeadMesh.DetachFromAny();
    HeadMesh = CloneSkeletalPart(SourcePawn.ThirdPersonHeadMeshComponent);
    for (I = 0; I < ArrayCount(SourcePawn.ThirdPersonAttachments); ++I)
    {
        Source = SourcePawn.ThirdPersonAttachments[I];
        CosmeticSources.AddItem(Source);
        if (Source == None || Source.HiddenGame) continue;
        Part = None;
        if (SkeletalMeshComponent(Source) != None)
            Part = CloneSkeletalPart(SkeletalMeshComponent(Source));
        else if (StaticMeshComponent(Source) != None)
        {
            for (J = 0; J < BoundSourceMesh.Attachments.Length; ++J)
                if (BoundSourceMesh.Attachments[J].Component == Source)
                {
                    StaticPart = new(self) class'StaticMeshComponent';
                    StaticPart.SetStaticMesh(StaticMeshComponent(Source).StaticMesh);
                    ConfigureMesh(StaticPart, Source);
                    BodyMesh.AttachComponent(StaticPart, BoundSourceMesh.Attachments[J].BoneName,
                        BoundSourceMesh.Attachments[J].RelativeLocation,
                        BoundSourceMesh.Attachments[J].RelativeRotation,
                        BoundSourceMesh.Attachments[J].RelativeScale);
                    Part = StaticPart;
                    break;
                }
        }
        if (Part != None) CosmeticMeshes.AddItem(Part);
    }
    NextCosmeticCheck = WorldInfo.RealTimeSeconds + 1.0;
}

simulated function SetPreviewVisible(bool bVisible)
{
    local int I;
    bVisible = bVisible && bSafePlacement && IsSelfViewActive();
    if (BodyMesh != None) BodyMesh.SetHidden(!bVisible);
    if (HeadMesh != None) HeadMesh.SetHidden(!bVisible);
    for (I = 0; I < CosmeticMeshes.Length; ++I)
        if (CosmeticMeshes[I] != None) CosmeticMeshes[I].SetHidden(!bVisible);
    if (!bVisible && WeaponPreview != None) WeaponPreview.HidePreview();
}

simulated function UpdateWeaponPreview(vector Muzzle, rotator MuzzleRotation,
    bool bValidMuzzle, vector Right, rotator RightAim)
{
    if (SourcePawn == None || SourcePawn.Health <= 0) return;
    if (!bSafePlacement || !IsSelfViewActive())
    {
        if (WeaponPreview != None) WeaponPreview.HidePreview();
        return;
    }
    if (WeaponPreview == None)
    {
        WeaponPreview = Spawn(class'KF2VRNetAvatarWeaponPreview', self);
        if (WeaponPreview != None) WeaponPreview.Initialize(SourcePawn);
    }
    if (WeaponPreview != None)
    {
        if (PoseOwner != None)
            WeaponPreview.SetDiagnosticEpochs(PoseOwner.WorldEpoch, PoseOwner.ConnectionEpoch,
                PoseOwner.PawnEpoch, PoseOwner.Snapshot.Sample.ReferenceEpoch);
        WeaponPreview.UpdateWeaponPreview(Right, RightAim, Muzzle, MuzzleRotation,
            bValidMuzzle, PreviewOffset, (bReady && (TrackingFlags & 4) != 0) ? 1.0 : 0.0);
    }
}

simulated function vector SourceBoneInPreview(name Bone)
{
    local rotator SourceYaw;
    SourceYaw.Yaw = SourcePawn.Rotation.Yaw;
    return PreviewRoot + PreviewOffset
        + (((BoundSourceMesh.GetBoneLocation(Bone) - SourcePawn.Location) << SourceYaw) >> PreviewYaw);
}

simulated function UpdatePreview(vector Head, rotator HeadRotation,
    vector Left, rotator LeftRotation, vector Right, rotator RightRotation, float Alpha)
{
    local int I;
    local vector Shoulder, Direction, Pole, Grip;
    local rotator GripRotation;
    local quat DesiredWrist;
    local SkelControlBase SourceHeadScale;
    if (!bSafePlacement) { SetPreviewVisible(false); return; }
    if (SourcePawn == None || SourcePawn.bDeleteMe || SourcePawn.Health <= 0
        || SourcePawn.Physics == PHYS_RigidBody || SourcePawn.Mesh == None)
    { SetPreviewVisible(false); return; }
    if (!ValidVector(Head) || !ValidVector(Left) || !ValidVector(Right))
    { SetPreviewVisible(false); return; }
    if (BodyMesh == None || BoundSourceMesh != SourcePawn.Mesh
        || BoundBodyAsset != SourcePawn.Mesh.SkeletalMesh || BoundSourceTree != SourcePawn.Mesh.Animations)
    {
        SetPreviewVisible(false);
        if (!BuildRig()) return;
    }
    if (bReferencePending && !FinishReference()) return;
    if (BoundSourceMesh.LocalAtoms.Length != BoneCount) ReportMissingSourcePose();
    if (!bReady || PoseTree == None || BoundSourceMesh.LocalAtoms.Length != BoneCount)
    { SetPreviewVisible(false); return; }
    // LocalAtoms and AnimTree.SavedPose are compatible BoneAtom arrays.
    // This value copy cannot edit source atoms or tick its animation/notifies.
    PoseTree.SavedPose = BoundSourceMesh.LocalAtoms;
    PoseTree.bUseSavedPose = true;
    BodyMesh.SetTranslation(BoundSourceMesh.Translation);
    BodyMesh.SetRotation(BoundSourceMesh.Rotation);
    BodyMesh.SetScale(BoundSourceMesh.Scale);
    BodyMesh.SetScale3D(BoundSourceMesh.Scale3D);
    TargetAlpha = FClamp(Alpha, 0.0, 1.0);
    if (SourcePawn.IsDoingSpecialMove()) TargetAlpha = 0;
    TargetHead = Head + PreviewOffset;
    PreviousHeadRotation = PreviewSamples > 0 ? TargetHeadRotation : HeadRotation;
    TargetHeadRotation = HeadRotation;
    HeadControl.BoneRotation = QuatToRotator(QuatProduct(QuatFromRotator(HeadRotation), HeadBasis));
    HeadControl.SetSkelControlStrength((TrackingFlags & 1) != 0 ? TargetAlpha : 0.0, 0.0);
    SourceHeadScale = BoundSourceMesh.FindSkelControl('HeadScale');
    if (SourceHeadScale != None) HeadControl.BoneScale = SourceHeadScale.BoneScale;
    TargetHand[0] = Left + PreviewOffset;
    TargetHand[1] = Right + PreviewOffset;
    bRequestedWeaponContact = false;
    for (I = 0; I < 2; ++I)
    {
        DesiredWrist = QuatProduct(QuatFromRotator(I == 0 ? LeftRotation : RightRotation), WristBasis[I]);
        if (I == 1 && WeaponPreview != None && WeaponPreview.GetPrimaryGrip(Grip, GripRotation))
        {
            TargetHand[I] = Grip;
            DesiredWrist = QuatFromRotator(GripRotation);
            bRequestedWeaponContact = true;
        }
        RequestedHand[I] = TargetHand[I];
        Shoulder = SourceBoneInPreview(ShoulderBone[I]);
        Direction = TargetHand[I] - Shoulder;
        if (VSize(Direction) > ArmLength[I] * 0.98)
            TargetHand[I] = Shoulder + Normal(Direction) * ArmLength[I] * 0.98;
        ReachClampDistance[I] = VSize(RequestedHand[I] - TargetHand[I]);
        ArmControl[I].EffectorLocation = TargetHand[I];
        Pole = vect(-18,0,-28);
        Pole.Y = I == 0 ? -16 : 16;
        ArmControl[I].JointTargetLocation = Shoulder + (Pole >> PreviewYaw);
        ArmControl[I].SetSkelControlStrength((TrackingFlags & (2 << I)) != 0 ? TargetAlpha : 0.0, 0.0);
        WristControl[I].BoneRotation = QuatToRotator(DesiredWrist);
        WristControl[I].SetSkelControlStrength((TrackingFlags & (2 << I)) != 0 ? TargetAlpha : 0.0, 0.0);
        if (TwistControl[I] != None)
            TwistControl[I].SetSkelControlStrength((TrackingFlags & (2 << I)) != 0 ? TargetAlpha : 0.0, 0.0);
    }
    LastTargetTime = WorldInfo.RealTimeSeconds;
    bStaleHidden = false;
    ++PreviewSamples;
    // At zero tracking weight the duplicate still shows the saved stock pose.
    SetPreviewVisible(true);
    if ((TargetAlpha <= 0.001 || (TrackingFlags & 4) == 0) && WeaponPreview != None)
        WeaponPreview.HidePreview();
}

simulated function bool IsNonColliding()
{
    local int I;
    local SkeletalMeshComponent Part;
    if (bCollideActors || bBlockActors || Physics != PHYS_None || BodyMesh == None
        || BodyMesh.CollideActors || BodyMesh.BlockActors || BodyMesh.BlockZeroExtent
        || BodyMesh.BlockNonZeroExtent || BodyMesh.PhysicsAsset != None
        || BodyMesh.PhysicsAssetInstance != None || BodyMesh.bHasPhysicsAssetInstance) return false;
    if (HeadMesh != None && (HeadMesh.CollideActors || HeadMesh.BlockActors
        || HeadMesh.BlockZeroExtent || HeadMesh.BlockNonZeroExtent || HeadMesh.PhysicsAsset != None
        || HeadMesh.PhysicsAssetInstance != None || HeadMesh.bHasPhysicsAssetInstance)) return false;
    for (I = 0; I < CosmeticMeshes.Length; ++I)
    {
        if (CosmeticMeshes[I].CollideActors || CosmeticMeshes[I].BlockActors
            || CosmeticMeshes[I].BlockZeroExtent || CosmeticMeshes[I].BlockNonZeroExtent) return false;
        Part = SkeletalMeshComponent(CosmeticMeshes[I]);
        if (Part != None && (Part.PhysicsAsset != None || Part.PhysicsAssetInstance != None
            || Part.bHasPhysicsAssetInstance)) return false;
    }
    return true;
}

simulated function vector GetWristLocation(int Hand)
{
    if (!bReady || BodyMesh == None || Hand < 0 || Hand > 1) return vect(0,0,0);
    return BodyMesh.GetBoneLocation(HandBone(Hand));
}

simulated function float QuaternionAngleDegrees(quat A, quat B)
{
    local float ANormSquared, BNormSquared;
    ANormSquared = QuatDot(A, A);
    BNormSquared = QuatDot(B, B);
    // Bone-matrix quaternions need not be exactly unit length. Geodesic angle
    // uses normalized orientations; preserve the raw angle/norms in telemetry.
    // Degenerate or non-finite values fail the existing angle gate explicitly.
    if (!(ANormSquared > 0.000001 && ANormSquared < 1000000.0
        && BNormSquared > 0.000001 && BNormSquared < 1000000.0)) return 180.0;
    return 2.0 * Acos(FClamp(Abs(QuatDot(A, B))
        / Sqrt(ANormSquared * BNormSquared), 0.0, 1.0)) * RadToDeg;
}

// Called only by the separate PostUpdate probe. Keeping this actor's tick early
// allows its mesh to evaluate in PostAsyncWork before these measurements.
simulated function PostUpdatePreview(float DeltaTime)
{
    local int I;
    local bool bChanged, bUniqueTree, bSourceUnchanged;
    local vector Actual, Forward, Wanted;
    local float HeadError, RawHeadError, ActualHeadNormSquared, WantedHeadNormSquared;
    local quat ActualHead, WantedHead;
    if (SourcePawn == None || SourcePawn.bDeleteMe || SourcePawn.Health <= 0
        || PoseOwner == None || PoseOwner.bDeleteMe)
    { Destroy(); return; }
    if (!bReady || BodyMesh == None) return;
    if (!bSafePlacement) { SetPreviewVisible(false); return; }
    // The view may deactivate after the pose actor has already run this frame.
    if (!IsSelfViewActive()) SetPreviewVisible(false);
    if (WorldInfo.RealTimeSeconds - LastTargetTime > 0.3)
    {
        SetPreviewVisible(false);
        if (!bStaleHidden)
            `log("KF2VRNet avatar_preview_stale world=" $ PoseOwner.WorldEpoch
                $ " connection=" $ PoseOwner.ConnectionEpoch $ " pawn=" $ PoseOwner.PawnEpoch
                $ " reference=" $ PoseOwner.Snapshot.Sample.ReferenceEpoch
                $ " time=" $ WorldInfo.RealTimeSeconds $ " age=" $ (WorldInfo.RealTimeSeconds - LastTargetTime)
                $ " samples=" $ PreviewSamples $ " fresh=false hidden=true");
        bStaleHidden = true;
        return;
    }
    if (WorldInfo.RealTimeSeconds >= NextCosmeticCheck)
    {
        bChanged = (HeadMesh == None) != (SourcePawn.ThirdPersonHeadMeshComponent == None);
        if (HeadMesh != None && SourcePawn.ThirdPersonHeadMeshComponent != None)
            bChanged = bChanged || HeadMesh.SkeletalMesh != SourcePawn.ThirdPersonHeadMeshComponent.SkeletalMesh;
        for (I = 0; I < CosmeticSources.Length; ++I)
            bChanged = bChanged || CosmeticSources[I] != SourcePawn.ThirdPersonAttachments[I];
        if (bChanged) RefreshCosmetics();
        NextCosmeticCheck = WorldInfo.RealTimeSeconds + 1.0;
    }
    ActualHead = QuatProduct(BodyMesh.GetBoneQuaternion('head'), QuatInvert(HeadBasis));
    WantedHead = QuatFromRotator(TargetHeadRotation);
    ActualHeadNormSquared = QuatDot(ActualHead, ActualHead);
    WantedHeadNormSquared = QuatDot(WantedHead, WantedHead);
    Forward = QuatRotateVector(ActualHead, vect(1,0,0));
    Wanted = vector(TargetHeadRotation);
    HeadError = QuaternionAngleDegrees(ActualHead, WantedHead);
    RawHeadError = 2.0 * Acos(FClamp(Abs(QuatDot(ActualHead, WantedHead)), 0.0, 1.0)) * RadToDeg;
    if (bDrawPreviewAxes && TargetAlpha > 0.001 && IsSelfViewActive())
    {
        Actual = BodyMesh.GetBoneLocation('head');
        DrawDebugLine(Actual, Actual + Forward * 25, 0, 255, 0);
        DrawDebugLine(Actual, Actual + Wanted * 30, 255, 220, 0);
        for (I = 0; I < 2; ++I)
            DrawDebugLine(GetWristLocation(I), TargetHand[I], 0, 200, 255);
    }
    if (WorldInfo.RealTimeSeconds >= NextDiagnosticTime)
    {
        bUniqueTree = PoseTree != None && PoseTree == BodyMesh.Animations
            && PoseTree != BoundSourceTree && PoseTree != BodyMesh.AnimTreeTemplate;
        bSourceUnchanged = SourcePawn.Mesh == BoundSourceMesh
            && BoundSourceMesh.Animations == BoundSourceTree && BoundSourceMesh.SkeletalMesh == BoundBodyAsset
            && BoundSourceMesh.PhysicsAsset == BoundSourcePhysicsAsset
            && BoundSourceMesh.CollideActors == bSourceMeshCollide && BoundSourceMesh.BlockZeroExtent == bSourceMeshTrace;
        `log("KF2VRNet avatar_preview_frame world=" $ PoseOwner.WorldEpoch
            $ " connection=" $ PoseOwner.ConnectionEpoch $ " pawn=" $ PoseOwner.PawnEpoch
            $ " reference=" $ PoseOwner.Snapshot.Sample.ReferenceEpoch
            $ " source=" $ SourcePawn $ " time=" $ WorldInfo.RealTimeSeconds
            $ " self_mode=" $ bSelfPreview $ " self_view_active=" $ (bSelfPreview && IsSelfViewActive())
            $ " visible=" $ !BodyMesh.HiddenGame
            $ " ready=" $ (bReady && PoseTree != None && HeadControl != None
                && ArmControl[0] != None && ArmControl[1] != None && WristControl[0] != None && WristControl[1] != None)
            $ " samples=" $ PreviewSamples $ " fresh=" $ (TrackingFlags != 0 && TargetAlpha > 0.001)
            $ " placement_safe=" $ bSafePlacement
            $ " owner_tick=" $ TickGroup $ " mesh_tick=" $ BodyMesh.TickGroup
            $ " probe_tick=" $ PostUpdateProbe.TickGroup
            $ " flags=" $ TrackingFlags $ " alpha=" $ TargetAlpha
            $ " head_degrees=" $ HeadError $ " head_degrees_raw=" $ RawHeadError
            $ " head_actual_norm2=" $ ActualHeadNormSquared $ " head_wanted_norm2=" $ WantedHeadNormSquared
            $ " head_norm_error_ppm=" $ ((Sqrt(ActualHeadNormSquared * WantedHeadNormSquared) - 1.0) * 1000000.0)
            $ " head_previous_degrees=" $ QuaternionAngleDegrees(ActualHead, QuatFromRotator(PreviousHeadRotation))
            $ " head_target_step_degrees=" $ QuaternionAngleDegrees(WantedHead, QuatFromRotator(PreviousHeadRotation))
            $ " head_position_error=" $ VSize(BodyMesh.GetBoneLocation('head') - TargetHead)
            $ " left_error=" $ VSize(GetWristLocation(0) - RequestedHand[0])
            $ " right_error=" $ VSize(GetWristLocation(1) - RequestedHand[1])
            $ " left_solve_error=" $ VSize(GetWristLocation(0) - TargetHand[0])
            $ " right_solve_error=" $ VSize(GetWristLocation(1) - TargetHand[1])
            $ " right_contact=" $ bRequestedWeaponContact
            $ " left_reach_clamp=" $ ReachClampDistance[0] $ " right_reach_clamp=" $ ReachClampDistance[1]
            $ " saved_atoms=" $ PoseTree.SavedPose.Length $ " offset=" $ PreviewOffset
            $ " source_atoms=" $ BoundSourceMesh.LocalAtoms.Length
            $ " source_tick_tag=" $ BoundSourceMesh.TickTag
            $ " source_cached_atoms_tag=" $ BoundSourceMesh.CachedAtomsTag
            $ " source_update_hidden=" $ BoundSourceMesh.bUpdateSkelWhenNotRendered
            $ " source_tick_nodes_hidden=" $ BoundSourceMesh.bTickAnimNodesWhenNotRendered
            $ " source_owner_no_see=" $ BoundSourceMesh.bOwnerNoSee
            $ " unique_tree=" $ bUniqueTree $ " source_unchanged=" $ bSourceUnchanged
            $ " noncolliding=" $ IsNonColliding() $ " body_collide=" $ BodyMesh.CollideActors
            $ " body_blockzero=" $ BodyMesh.BlockZeroExtent $ " physics=" $ BodyMesh.PhysicsAsset);
        NextDiagnosticTime = WorldInfo.RealTimeSeconds + 2.0;
    }
}

simulated function ReleaseMeshes()
{
    local int I;
    bReady = false;
    bReferencePending = false;
    if (HeadMesh != None) HeadMesh.DetachFromAny();
    HeadMesh = None;
    for (I = 0; I < CosmeticMeshes.Length; ++I)
        if (CosmeticMeshes[I] != None) CosmeticMeshes[I].DetachFromAny();
    CosmeticMeshes.Length = 0;
    CosmeticSources.Length = 0;
    if (BodyMesh != None)
    {
        BodyMesh.DetachFromAny();
        BodyMesh.SetAnimTreeTemplate(None);
    }
    BodyMesh = None;
    PoseTree = None;
    HeadControl = None;
    for (I = 0; I < 2; ++I) { ArmControl[I] = None; WristControl[I] = None; TwistControl[I] = None; }
}

simulated event Destroyed()
{
    if (PostUpdateProbe != None) PostUpdateProbe.Destroy();
    PostUpdateProbe = None;
    if (WeaponPreview != None) WeaponPreview.Destroy();
    WeaponPreview = None;
    ReleaseMeshes();
    SourcePawn = None;
    PoseOwner = None;
    SelfInspectController = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    bReplicateMovement=false
    bDrawPreviewAxes=true
    LocalPreviewOffset=(X=0,Y=110,Z=0)
    TickGroup=TG_PreAsyncWork
}
