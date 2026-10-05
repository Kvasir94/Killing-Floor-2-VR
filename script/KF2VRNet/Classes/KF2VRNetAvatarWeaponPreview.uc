// Cosmetic diagnostic only. Every component and sequence below belongs to this
// actor; the source pawn, attachment, materials and gameplay are read-only.
class KF2VRNetAvatarWeaponPreview extends Actor dependsOn(KFWeaponAttachment);

var KFPawn_Human SourcePawn;
var KFWeaponAttachment SourceAttachment;
var SkeletalMeshComponent SourceMesh;
var SkeletalMeshComponent WeaponMesh;
var private AnimNodeSequence PreviewSequence;
var private vector PrimaryGripLocal;
var private quat PrimaryGripRotationLocal;
var private bool bGripCalibrated;
var private float LastCalibrationDistance;

var bool bReady, bUsingEffectiveMuzzle;
var vector PrimaryWristPosition, VisualMuzzlePosition;
var rotator PrimaryWristRotation, VisualMuzzleRotation;
var float MuzzlePositionError, MuzzleAngleErrorDegrees;
var private float NextDiagnosticTime;
var private int PlacementCount;
var private int DiagnosticWorldEpoch, DiagnosticConnectionEpoch, DiagnosticPawnEpoch, DiagnosticReferenceEpoch;

simulated function bool Initialize(KFPawn_Human NewSourcePawn)
{
    if (NewSourcePawn == None || WorldInfo.NetMode == NM_DedicatedServer) return false;
    SourcePawn = NewSourcePawn;
    return true;
}

simulated function bool FinitePosition(vector Position)
{
    return Position.X == Position.X && Position.Y == Position.Y && Position.Z == Position.Z
        && Abs(Position.X) < 100000000 && Abs(Position.Y) < 100000000 && Abs(Position.Z) < 100000000;
}

simulated function SetDiagnosticEpochs(int WorldEpoch, int ConnectionEpoch, int PawnEpoch, int ReferenceEpoch)
{
    DiagnosticWorldEpoch = WorldEpoch;
    DiagnosticConnectionEpoch = ConnectionEpoch;
    DiagnosticPawnEpoch = PawnEpoch;
    DiagnosticReferenceEpoch = ReferenceEpoch;
}

simulated function bool IsNonColliding()
{
    return !bCollideActors && !bBlockActors && Physics == PHYS_None && WeaponMesh != None
        && !WeaponMesh.CollideActors && !WeaponMesh.BlockActors
        && !WeaponMesh.BlockZeroExtent && !WeaponMesh.BlockNonZeroExtent
        && !WeaponMesh.bHasPhysicsAssetInstance && WeaponMesh.PhysicsAssetInstance == None;
}

simulated function ReleaseMesh()
{
    bReady = false;
    bGripCalibrated = false;
    if (WeaponMesh != None)
    {
        WeaponMesh.SetHidden(true);
        WeaponMesh.DetachFromAny();
    }
    WeaponMesh = None;
    PreviewSequence = None;
    SourceMesh = None;
    SourceAttachment = None;
}

simulated function HidePreview()
{
    bReady = false;
    if (WeaponMesh != None) WeaponMesh.SetHidden(true);
}

simulated function bool ResolveSource()
{
    local KFWeaponAttachment Attachment;
    local SkeletalMeshComponent MeshSource;
    local AnimTree Tree;
    local AnimNodeSequence Sequence;

    if (SourcePawn == None || SourcePawn.bDeleteMe || SourcePawn.Health <= 0
        || SourcePawn.Mesh == None || SourcePawn.IsDoingSpecialMove()) return false;
    Attachment = SourcePawn.WeaponAttachment;
    if (Attachment == None || Attachment.bDeleteMe || Attachment.bWeapMeshIsPawnMesh) return false;
    MeshSource = Attachment.WeapMesh;
    // First proof is the audited rigid-root single 9mm world rig only.
    if (MeshSource == None || MeshSource.SkeletalMesh == None
        || MeshSource.SkeletalMesh.Name != 'Wep_3rdP_9mm_Rig') return false;
    if (Attachment == SourceAttachment && MeshSource == SourceMesh && WeaponMesh != None && PreviewSequence != None
        && WeaponMesh.SkeletalMesh == MeshSource.SkeletalMesh) return true;

    ReleaseMesh();
    SourceAttachment = Attachment;
    SourceMesh = MeshSource;
    WeaponMesh = new(self) class'SkeletalMeshComponent';
    WeaponMesh.SetSkeletalMesh(SourceMesh.SkeletalMesh);
    WeaponMesh.AnimSets = SourceMesh.AnimSets;
    WeaponMesh.SetOwnerNoSee(false);
    WeaponMesh.SetOnlyOwnerSee(false);
    WeaponMesh.SetActorCollision(false, false);
    WeaponMesh.SetTraceBlocking(false, false);
    WeaponMesh.SetDepthPriorityGroup(SDPG_World);
    WeaponMesh.bUpdateSkelWhenNotRendered = true;
    WeaponMesh.bTickAnimNodesWhenNotRendered = true;
    WeaponMesh.bIgnoreControllersWhenNotRendered = false;
    WeaponMesh.CastShadow = true;
    WeaponMesh.bCastDynamicShadow = true;
    WeaponMesh.SetScale(SourceMesh.Scale);
    WeaponMesh.SetScale3D(SourceMesh.Scale3D);
    WeaponMesh.SetLightingChannels(SourceMesh.LightingChannels);
    WeaponMesh.SetHidden(true);

    Tree = new(self) class'AnimTree';
    Sequence = new(Tree) class'AnimNodeSequence';
    Sequence.NodeName = 'VRPreviewWeaponSequence';
    Sequence.bPlaying = false;
    Sequence.bNoNotifies = true;
    Sequence.bCauseActorAnimEnd = false;
    Sequence.bCauseActorAnimPlay = false;
    Sequence.bForceRefposeWhenNotPlaying = false;
    Tree.Children[0].Anim = Sequence;
    Tree.Children[0].Weight = 1;
    WeaponMesh.SetAnimTreeTemplate(Tree);
    AttachComponent(WeaponMesh);
    PreviewSequence = AnimNodeSequence(WeaponMesh.FindAnimNode('VRPreviewWeaponSequence'));
    WeaponMesh.ForceUpdate(false);
    return PreviewSequence != None && WeaponMesh.MatchRefBone('RW_Weapon') >= 0;
}

simulated function CopyCosmeticState()
{
    local int I;
    local AnimNodeSequence SourceSequence;
    local float SampleTime;

    for (I = 0; I < SourceMesh.GetNumElements(); ++I)
        if (WeaponMesh.GetMaterial(I) != SourceMesh.GetMaterial(I))
            WeaponMesh.SetMaterial(I, SourceMesh.GetMaterial(I));
    SourceSequence = SourceAttachment.WeapAnimNode;
    if (SourceSequence == None) SourceSequence = AnimNodeSequence(SourceMesh.Animations);
    if (SourceMesh.bForceRefPose != 0 || SourceSequence == None || SourceSequence.AnimSeq == None)
    {
        WeaponMesh.SetForceRefPose(true);
    }
    else
    {
        WeaponMesh.SetForceRefPose(false);
        if (PreviewSequence.AnimSeqName != SourceSequence.AnimSeqName)
            PreviewSequence.SetAnim(SourceSequence.AnimSeqName);
        if (PreviewSequence.AnimSeq != None)
        {
            SampleTime = FClamp(SourceSequence.CurrentTime, 0, PreviewSequence.AnimSeq.SequenceLength);
            // Never re-issue sounds, script calls, camera shakes or gameplay
            // notifies while following the original attachment's action phase.
            PreviewSequence.SetPosition(SampleTime, false);
            PreviewSequence.bPlaying = false;
        }
    }
    WeaponMesh.ForceSkelUpdate();
    WeaponMesh.ForceUpdate(false);
}

simulated function CalibratePrimaryGrip()
{
    local vector RootPosition, HandPosition, Contact;
    local quat RootRotation;

    if (bGripCalibrated || SourcePawn.CurrentWeaponState != WEP_Idle
        || SourceAttachment.bIsReloading
        || WorldInfo.TimeSeconds - SourcePawn.LastWeaponFireTime < 0.3
        || SourcePawn.Mesh.MatchRefBone(SourcePawn.RightHandBoneName) < 0) return;
    // Read the naturally evaluated held pose; never force-update the source.
    // RW_Weapon's bind-pose offset is ~71 units, so reject that pose outright.
    RootPosition = SourceMesh.GetBoneLocation('RW_Weapon');
    RootRotation = SourceMesh.GetBoneQuaternion('RW_Weapon');
    HandPosition = SourcePawn.Mesh.GetBoneLocation(SourcePawn.RightHandBoneName);
    Contact = QuatRotateVector(QuatInvert(RootRotation), HandPosition - RootPosition);
    LastCalibrationDistance = VSize(Contact);
    if (!FinitePosition(Contact) || VSize(Contact) > 35) return;
    PrimaryGripLocal = Contact;
    PrimaryGripRotationLocal = QuatProduct(QuatInvert(RootRotation),
        SourcePawn.Mesh.GetBoneQuaternion(SourcePawn.RightHandBoneName));
    bGripCalibrated = true;
    `log("KF2VRNet avatar_weapon_grip source=" $ SourcePawn $ " attachment=" $ SourceAttachment
        $ " local=" $ PrimaryGripLocal $ " calibrated=true");
}

// Inputs are unshifted source-world poses; only this owned preview is offset.
// PrimaryRotation is the controller AIM frame, not the anatomical wrist frame.
simulated function UpdateWeaponPreview(vector PrimaryPosition, rotator PrimaryRotation,
    vector EffectiveMuzzlePosition, rotator EffectiveMuzzleRotation, bool bHasVisualMuzzle,
    vector PreviewOffset, float Alpha)
{
    local vector SocketPosition, SocketRelative, Target, RootPosition, RootRelative;
    local rotator SocketRotation;
    local quat ActorRotation, DesiredRotation, RelativeQuat, RootRotation;
    local float Dot;

    if (Alpha <= 0.01 || !FinitePosition(PrimaryPosition) || !FinitePosition(PreviewOffset)
        || !ResolveSource())
    {
        HidePreview();
        return;
    }
    CopyCosmeticState();
    CalibratePrimaryGrip();
    if (!bGripCalibrated
        || !WeaponMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', SocketPosition, SocketRotation))
    {
        HidePreview();
        if (WorldInfo.RealTimeSeconds >= NextDiagnosticTime)
        {
            NextDiagnosticTime = WorldInfo.RealTimeSeconds + 3;
            `log("KF2VRNet avatar_weapon_wait source=" $ SourcePawn $ " grip=" $ bGripCalibrated
                $ " candidate_distance=" $ LastCalibrationDistance $ " weapon_state=" $ SourcePawn.CurrentWeaponState);
        }
        return;
    }
    ActorRotation = QuatFromRotator(Rotation);
    bUsingEffectiveMuzzle = bHasVisualMuzzle && FinitePosition(EffectiveMuzzlePosition);
    if (bUsingEffectiveMuzzle)
    {
        // Match the literal optical socket, never the wall-clamped gameplay
        // shot origin. This also accounts for differing 1P/3P mesh offsets.
        SocketRelative = QuatRotateVector(QuatInvert(ActorRotation), SocketPosition - Location);
        RelativeQuat = QuatProduct(QuatInvert(ActorRotation), QuatFromRotator(SocketRotation));
        DesiredRotation = QuatProduct(QuatFromRotator(EffectiveMuzzleRotation), QuatInvert(RelativeQuat));
        SetRotation(QuatToRotator(DesiredRotation));
        Target = EffectiveMuzzlePosition + PreviewOffset;
        SetLocation(Target - QuatRotateVector(QuatFromRotator(Rotation), SocketRelative));
    }
    else
    {
        // Explicit diagnostic fallback. The audited 9mm has +X root/bore.
        // With no transmitted optical socket, anchor the calibrated grip.
        RootPosition = WeaponMesh.GetBoneLocation('RW_Weapon');
        RootRotation = WeaponMesh.GetBoneQuaternion('RW_Weapon');
        RootRelative = QuatRotateVector(QuatInvert(ActorRotation), RootPosition - Location);
        RelativeQuat = QuatProduct(QuatInvert(ActorRotation), RootRotation);
        DesiredRotation = QuatFromRotator(PrimaryRotation);
        Target = PrimaryPosition + PreviewOffset - QuatRotateVector(DesiredRotation, PrimaryGripLocal);
        SetRotation(QuatToRotator(QuatProduct(DesiredRotation, QuatInvert(RelativeQuat))));
        SetLocation(Target - QuatRotateVector(QuatFromRotator(Rotation), RootRelative));
    }
    WeaponMesh.ForceUpdate(true);
    if (!WeaponMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', VisualMuzzlePosition, VisualMuzzleRotation))
    {
        HidePreview();
        return;
    }
    RootPosition = WeaponMesh.GetBoneLocation('RW_Weapon');
    RootRotation = WeaponMesh.GetBoneQuaternion('RW_Weapon');
    PrimaryWristPosition = RootPosition + QuatRotateVector(RootRotation, PrimaryGripLocal);
    PrimaryWristRotation = QuatToRotator(QuatProduct(RootRotation, PrimaryGripRotationLocal));
    MuzzlePositionError = 0;
    MuzzleAngleErrorDegrees = 0;
    if (bUsingEffectiveMuzzle)
    {
        MuzzlePositionError = VSize(VisualMuzzlePosition - EffectiveMuzzlePosition - PreviewOffset);
        Dot = vector(VisualMuzzleRotation) dot vector(EffectiveMuzzleRotation);
        MuzzleAngleErrorDegrees = ACos(FClamp(Dot, -1, 1)) * 57.2957795;
    }
    bReady = FinitePosition(PrimaryWristPosition) && FinitePosition(VisualMuzzlePosition);
    WeaponMesh.SetHidden(!bReady);
    ++PlacementCount;
    if (WorldInfo.RealTimeSeconds >= NextDiagnosticTime)
    {
        NextDiagnosticTime = WorldInfo.RealTimeSeconds + 3;
        `log("KF2VRNet avatar_weapon_preview source=" $ SourcePawn
            $ " world=" $ DiagnosticWorldEpoch $ " connection=" $ DiagnosticConnectionEpoch
            $ " pawn=" $ DiagnosticPawnEpoch $ " reference=" $ DiagnosticReferenceEpoch
            $ " time=" $ WorldInfo.RealTimeSeconds $ " ready=" $ bReady
            $ " effective_muzzle=" $ bUsingEffectiveMuzzle $ " placements=" $ PlacementCount
            $ " muzzle_error=" $ MuzzlePositionError $ " bore_error_deg=" $ MuzzleAngleErrorDegrees
            $ " noncolliding=" $ IsNonColliding()
            $ " physics_asset=" $ (WeaponMesh.PhysicsAsset != None || WeaponMesh.PhysicsAssetInstance != None)
            $ " physics_mode=" $ Physics
            $ " wrist=" $ PrimaryWristPosition $ " muzzle=" $ VisualMuzzlePosition);
    }
}

simulated function bool GetPrimaryGrip(out vector Position, out rotator Orientation)
{
    if (!bReady) return false;
    Position = PrimaryWristPosition;
    Orientation = PrimaryWristRotation;
    return true;
}

simulated event Destroyed()
{
    ReleaseMesh();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bNoEncroachCheck=true
    bAlwaysRelevant=false
    bReplicateMovement=false
    Physics=PHYS_None
}
