// Public, server-authored cosmetic snapshot. Never an input or damage endpoint.
class KF2VRNetPose extends Actor dependsOn(KF2VRNetTypes);

var KFPawn_Human TargetPawn;
var int WorldEpoch;
var int ConnectionEpoch;
var int PawnEpoch;
var int CalibrationEpoch;
var repnotify NetPoseSnapshot Snapshot;

var private NetPoseSnapshot DisplaySnapshot;
var private float LastReceivedRealTime;
var private bool bHaveSnapshot;
var int ReceivedSnapshots;
var private bool bDiagnosticWasFresh;
struct TimedPreviewSnapshot
{
    var NetPoseSnapshot Pose;
    var float ReceivedAt;
};
var private array<TimedPreviewSnapshot> PreviewHistory;
var KF2VRNetAvatarPreview AvatarPreview;
var private float PreviewStrength, PreviousPreviewTick;
var bool bIndependentWeapons;
var bool bDiagnosticVisuals;
var NetWeaponVisual LeftWeapon, RightWeapon;
var private KF2VRNetRemoteWeapon RemoteWeapons[2];
var private KF2VRNetRemoteBody RemoteBody;
var private KFWeaponAttachment HiddenStockAttachment;
var private bool bStockWasHidden;
var bool bPresentationReady;
// Horizontal speed handed to the simulated pawn while it is moved by roomscale.
var private vector RoomAnimVelocity, AppliedAnimVelocity;
var private bool bRoomAnimApplied;
var private float NextRoomAnimLog, StrideMin, StrideMax;

var private int PreviousMotionReplayId;

replication
{
    if (Role == ROLE_Authority)
        TargetPawn, WorldEpoch, ConnectionEpoch, PawnEpoch, CalibrationEpoch, Snapshot,
        bIndependentWeapons, LeftWeapon, RightWeapon;
}

function NetWeaponVisual SampleWeapon(KFWeapon W, int Id, NetWeaponVisual Previous)
{
    local NetWeaponVisual Result;
    if (W == None || W.bDeleteMe) return Result;
    Result.WeaponClass = W.Class;
    Result.ItemId = Id;
    Result.Ammo = W.AmmoCount[0];
    if (Previous.ItemId == Id)
    {
        Result.ShotSequence = Previous.ShotSequence;
        if (Result.Ammo < Previous.Ammo) Result.ShotSequence = (Result.ShotSequence + 1) & 65535;
    }
    Result.WeaponState = W.GetWeaponStateId();
    Result.ReloadStage = W.ReloadStatus;
    Result.AnimRate = W.GetThirdPersonAnimRate();
    Result.FireMode = W.CurrentFireMode;
    return Result;
}

function PublishWeapons(bool bEnabled, KFWeapon Left, int LeftId, KFWeapon Right, int RightId)
{
    bIndependentWeapons = bEnabled;
    LeftWeapon = SampleWeapon(bEnabled ? Left : None, LeftId, LeftWeapon);
    RightWeapon = SampleWeapon(bEnabled ? Right : None, RightId, RightWeapon);
}

// Presentation anchor for the sampled offsets: the simulated pawn's collision
// centre and yaw, the frame the owner sampled against (RootPosition's
// convention). The replicated root trails a running body by the network
// delay, so hands and guns hung from it lag behind the visible pawn. No
// MTO_PhysSmoothOffset: the owner's eye base already carries its own stair
// smoothing into the offsets.
simulated function PresentationRoot(out vector Root, out rotator Basis)
{
    local NetPoseSnapshot Frame;
    if (Snapshot.Motion.bEnabled)
    {
        // Saved replay owns the pawn root through authority. Present the same
        // atomic frame as its hands/muzzle; live movement yaw can arrive later.
        Frame = SamplePreview();
        Root = Frame.RootPosition; Basis = Frame.RootRotation;
        TargetPawn.SetLocation(Root); TargetPawn.SetRotation(Basis);
        return;
    }
    Root = TargetPawn.Location;
    Basis = rot(0,0,0);
    Basis.Yaw = TargetPawn.Rotation.Yaw;
}

simulated function RestoreStockAttachment()
{
    if (HiddenStockAttachment != None && !HiddenStockAttachment.bDeleteMe)
        HiddenStockAttachment.WeapMesh.SetHidden(bStockWasHidden);
    HiddenStockAttachment = None;
}

simulated function UpdateRemoteWeapons(bool bFresh)
{
    local KF2VRNetPlayerController PC;
    local bool bWanted, bAnyVisualRequested, bAllVisualsReady, bVisualReady, bSelf;
    local int I;
    local NetPoseSnapshot Frame;
    local NetWeaponVisual Visual;
    local vector Muzzle, Root;
    local rotator Aim, Basis;
    bWanted = bIndependentWeapons && TargetPawn != None && !TargetPawn.bDeleteMe && TargetPawn.Health > 0;
    bPresentationReady = false;
    bDiagnosticVisuals = Snapshot.Motion.bEnabled;
    foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
    {
        bDiagnosticVisuals = bDiagnosticVisuals || PC.bDiagnosticObserverDebug;
        if (PC.Pawn == TargetPawn)
        {
            bSelf = true;
            bWanted = bWanted && PC.bSelfAvatarInspection;
        }
    }
    if (!bWanted)
    {
        if (RemoteBody != None) RemoteBody.Destroy();
        RemoteBody = None;
        for (I = 0; I < 2; ++I)
        {
            if (RemoteWeapons[I] != None) RemoteWeapons[I].Destroy();
            RemoteWeapons[I] = None;
        }
        RestoreStockAttachment();
        return;
    }
    Frame = SamplePreview();
    if (Frame.Motion.bEnabled && Frame.Motion.ReplayId != PreviousMotionReplayId)
    {
        for (I = 0; I < 2; ++I) { if (RemoteWeapons[I] != None) RemoteWeapons[I].Destroy(); RemoteWeapons[I] = None; }
        PreviousMotionReplayId = Frame.Motion.ReplayId;
    }
    PresentationRoot(Root, Basis);
    if (RemoteBody == None)
    {
        RemoteBody = Spawn(class'KF2VRNetRemoteBody', self);
        if (RemoteBody != None) RemoteBody.PoseOwner = self;
    }
    if (RemoteBody != None) RemoteBody.UpdateBody(Frame, bFresh);
    bAllVisualsReady = true;
    for (I = 0; I < 2; ++I)
    {
        Visual = Frame.Motion.bEnabled ? (I == 0 ? Frame.Motion.LeftWeapon : Frame.Motion.RightWeapon)
            : (I == 0 ? LeftWeapon : RightWeapon);
        if (Visual.WeaponClass != None) bAnyVisualRequested = true;
        if (RemoteWeapons[I] == None && Visual.WeaponClass != None)
        {
            RemoteWeapons[I] = Spawn(class'KF2VRNetRemoteWeapon', self);
            if (RemoteWeapons[I] != None)
            {
                RemoteWeapons[I].PoseOwner = self;
                RemoteWeapons[I].Hand = I;
            }
        }
        if (RemoteWeapons[I] == None)
        {
            if (Visual.WeaponClass != None) bAllVisualsReady = false;
            continue;
        }
        Muzzle = I == 0 ? Frame.Sample.LeftMuzzlePosition : Frame.Sample.MuzzlePosition;
        Aim = I == 0 ? Frame.Sample.LeftMuzzleRotation : Frame.Sample.MuzzleRotation;
        bVisualReady = RemoteWeapons[I].UpdateVisual(Visual, Root + (Muzzle >> Basis),
            Normalize(Basis + Aim), bFresh
                && (!Frame.Motion.bEnabled || (RemoteBody != None && RemoteBody.IsTrackedPoseReady()))
                && (Frame.Sample.TrackingFlags & (2 << I)) != 0
                && (Frame.Sample.PresentationFlags & (I == 0 ? 2 : 1)) != 0);
        if (Visual.WeaponClass != None && !bVisualReady) bAllVisualsReady = false;
    }
    bPresentationReady = bFresh && RemoteBody != None && RemoteBody.IsReady() && bAllVisualsReady;
    // Build the same remote presentation before the view switch. Keep it
    // invisible until the controller has committed that switch.
    if (bSelf)
        foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
            if (PC.Pawn == TargetPawn && PC.NativeSelfViewActive == 0)
                for (I = 0; I < 2; ++I)
                    if (RemoteWeapons[I] != None && RemoteWeapons[I].Attachment != None)
                        RemoteWeapons[I].Attachment.WeapMesh.SetHidden(true);
    if (!bAnyVisualRequested || (!bAllVisualsReady && !Frame.Motion.bEnabled))
    {
        RestoreStockAttachment();
        return;
    }
    if (TargetPawn.WeaponAttachment != HiddenStockAttachment)
    {
        RestoreStockAttachment();
        HiddenStockAttachment = TargetPawn.WeaponAttachment;
        if (HiddenStockAttachment != None) bStockWasHidden = HiddenStockAttachment.WeapMesh.HiddenGame;
    }
    if (HiddenStockAttachment != None)
    {
        HiddenStockAttachment.WeapMesh.SetHidden(true);
        HiddenStockAttachment.StopThirdPersonFireEffects(true);
    }
}

function Initialize(KFPawn_Human NewPawn, int NewWorldEpoch,
    int NewConnectionEpoch, int NewPawnEpoch, int NewCalibrationEpoch)
{
    TargetPawn = NewPawn;
    WorldEpoch = NewWorldEpoch;
    ConnectionEpoch = NewConnectionEpoch;
    PawnEpoch = NewPawnEpoch;
    CalibrationEpoch = NewCalibrationEpoch;
    bForceNetUpdate = true;
}

function PublishPose(NetPoseSample Sample, KFPawn_Human SourcePawn, bool bIsSynthetic, optional NetMotionFrame Motion)
{
    if (Role != ROLE_Authority || SourcePawn != TargetPawn || SourcePawn == None)
    {
        return;
    }
    Snapshot.Sample = Sample;
    Snapshot.Revision = (Snapshot.Revision + 1) & 65535;
    Snapshot.RootPosition = SourcePawn.Location;
    Snapshot.RootRotation = rot(0,0,0);
    Snapshot.RootRotation.Yaw = SourcePawn.Rotation.Yaw;
    Snapshot.bSynthetic = bIsSynthetic;
    Snapshot.Motion = Motion;
    if (Motion.bEnabled)
    {
        bIndependentWeapons = true;
        LeftWeapon = Motion.LeftWeapon; RightWeapon = Motion.RightWeapon;
    }
    // Capture the authoritative root with the offsets for world-space readers
    // (server checks, diagnostics). The avatar on the observer's pawn hangs
    // them from that pawn instead (PresentationRoot). No movement is authorized.
    SetLocation(SourcePawn.Location);
    if (WorldInfo.NetMode != NM_DedicatedServer)
    {
        ConsumeSnapshot();
    }
}

function ExpirePose()
{
    if (Role != ROLE_Authority || Snapshot.Sample.TrackingFlags == 0)
    {
        return;
    }
    Snapshot.Sample.TrackingFlags = 0;
    Snapshot.Motion.bEnabled = false;
    Snapshot.Revision = (Snapshot.Revision + 1) & 65535;
    bForceNetUpdate = true;
    if (WorldInfo.NetMode != NM_DedicatedServer)
    {
        ConsumeSnapshot();
    }
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'Snapshot')
    {
        ConsumeSnapshot();
    }
    else
    {
        Super.ReplicatedEvent(VarName);
    }
}

simulated function ConsumeSnapshot()
{
    local TimedPreviewSnapshot Timed;
    if (TargetPawn == None || TargetPawn.bDeleteMe || WorldEpoch == 0
        || Snapshot.Sample.WorldEpoch != WorldEpoch
        || Snapshot.Sample.ConnectionEpoch != ConnectionEpoch
        || Snapshot.Sample.PawnEpoch != PawnEpoch
        || Snapshot.Sample.CalibrationEpoch != CalibrationEpoch
        || !class'KF2VRNetTypes'.static.IsValidSample(Snapshot.Sample)
        || (bHaveSnapshot && !class'KF2VRNetTypes'.static.IsNewerSequence(
            Snapshot.Revision, DisplaySnapshot.Revision)))
    {
        return;
    }
    if (!bHaveSnapshot || Snapshot.Sample.ReferenceEpoch != DisplaySnapshot.Sample.ReferenceEpoch
        || Snapshot.Sample.TrackingFlags != DisplaySnapshot.Sample.TrackingFlags
        || Snapshot.Sample.PresentationFlags != DisplaySnapshot.Sample.PresentationFlags
        || WorldInfo.RealTimeSeconds - LastReceivedRealTime > class'KF2VRNetTypes'.const.PoseLeaseSeconds
        || VSizeSq(Snapshot.RootPosition - DisplaySnapshot.RootPosition) > 160000.0
        || Snapshot.Motion.bEnabled != DisplaySnapshot.Motion.bEnabled
        || (Snapshot.Motion.bEnabled && Snapshot.Motion.Boundary != 0)
        || Snapshot.Sample.TrackingFlags == 0)
        PreviewHistory.Length = 0;
    DisplaySnapshot = Snapshot;
    LastReceivedRealTime = WorldInfo.RealTimeSeconds;
    Timed.Pose = Snapshot;
    Timed.ReceivedAt = LastReceivedRealTime;
    PreviewHistory.AddItem(Timed);
    if (PreviewHistory.Length > 8) PreviewHistory.Remove(0, 1);
    bHaveSnapshot = true;
    ReceivedSnapshots = Min(ReceivedSnapshots + 1, 2147483646);
    if (Snapshot.Motion.bEnabled)
        `log("KF2VRNet motion_received replay=" $ Snapshot.Motion.ReplayId $ " sample=" $ Snapshot.Motion.SampleIndex
            $ " clip_time=" $ Snapshot.Motion.ClipSeconds $ " sequence=" $ Snapshot.Sample.Sequence
            $ " paused=" $ Snapshot.Motion.bPaused $ " root=" $ Snapshot.RootPosition
            $ " left=" $ Snapshot.Sample.LeftPosition $ " right=" $ Snapshot.Sample.RightPosition
            $ " right_class=" $ PathName(Snapshot.Motion.RightWeapon.WeaponClass) $ " shot=" $ Snapshot.Motion.RightWeapon.ShotSequence
            $ " time=" $ WorldInfo.RealTimeSeconds);
}

// Cosmetic receive-time interpolation, bounded to eight snapshots. Never
// extrapolate tracking or expose this buffered state to input/damage code.
simulated function NetPoseSnapshot SamplePreview()
{
    local NetPoseSnapshot A, B, Result;
    local int I;
    local float At, Blend, Span;
    if (PreviewHistory.Length == 0) return DisplaySnapshot;
    At = WorldInfo.RealTimeSeconds - 0.06;
    if (At <= PreviewHistory[0].ReceivedAt) return PreviewHistory[0].Pose;
    for (I = 1; I < PreviewHistory.Length; ++I)
    {
        if (At > PreviewHistory[I].ReceivedAt) continue;
        A = PreviewHistory[I-1].Pose;
        B = PreviewHistory[I].Pose;
        Span = PreviewHistory[I].ReceivedAt - PreviewHistory[I-1].ReceivedAt;
        Blend = FClamp((At - PreviewHistory[I-1].ReceivedAt) / FMax(Span, 0.001), 0, 1);
        Result = B;
        Result.RootPosition = A.RootPosition + (B.RootPosition - A.RootPosition) * Blend;
        Result.RootRotation = RLerp(A.RootRotation, B.RootRotation, Blend, true);
        Result.Sample.HeadPosition = A.Sample.HeadPosition + (B.Sample.HeadPosition - A.Sample.HeadPosition) * Blend;
        Result.Sample.LeftPosition = A.Sample.LeftPosition + (B.Sample.LeftPosition - A.Sample.LeftPosition) * Blend;
        Result.Sample.RightPosition = A.Sample.RightPosition + (B.Sample.RightPosition - A.Sample.RightPosition) * Blend;
        Result.Sample.MuzzlePosition = A.Sample.MuzzlePosition + (B.Sample.MuzzlePosition - A.Sample.MuzzlePosition) * Blend;
        Result.Sample.LeftMuzzlePosition = A.Sample.LeftMuzzlePosition + (B.Sample.LeftMuzzlePosition - A.Sample.LeftMuzzlePosition) * Blend;
        Result.Sample.LeftWristPosition = A.Sample.LeftWristPosition + (B.Sample.LeftWristPosition - A.Sample.LeftWristPosition) * Blend;
        Result.Sample.RightWristPosition = A.Sample.RightWristPosition + (B.Sample.RightWristPosition - A.Sample.RightWristPosition) * Blend;
        Result.Sample.HeadRotation = RLerp(A.Sample.HeadRotation, B.Sample.HeadRotation, Blend, true);
        Result.Sample.LeftGripRotation = RLerp(A.Sample.LeftGripRotation, B.Sample.LeftGripRotation, Blend, true);
        Result.Sample.RightGripRotation = RLerp(A.Sample.RightGripRotation, B.Sample.RightGripRotation, Blend, true);
        Result.Sample.RightRotation = RLerp(A.Sample.RightRotation, B.Sample.RightRotation, Blend, true);
        Result.Sample.LeftRotation = RLerp(A.Sample.LeftRotation, B.Sample.LeftRotation, Blend, true);
        Result.Sample.MuzzleRotation = RLerp(A.Sample.MuzzleRotation, B.Sample.MuzzleRotation, Blend, true);
        Result.Sample.LeftMuzzleRotation = RLerp(A.Sample.LeftMuzzleRotation, B.Sample.LeftMuzzleRotation, Blend, true);
        Result.Sample.LeftWristRotation = RLerp(A.Sample.LeftWristRotation, B.Sample.LeftWristRotation, Blend, true);
        Result.Sample.RightWristRotation = RLerp(A.Sample.RightWristRotation, B.Sample.RightWristRotation, Blend, true);
        return Result;
    }
    return PreviewHistory[PreviewHistory.Length-1].Pose;
}

simulated function UpdateAvatarPreview(bool bFresh)
{
    local KF2VRNetPlayerController PC;
    local bool bWanted;
    local NetPoseSnapshot Frame;
    local float RealDelta;
    local vector Root, Head, Left, Right, Muzzle;
    local rotator Basis;
    foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
    {
        if (PC.bDiagnosticAvatarPreview && PC.Pawn != TargetPawn) bWanted = true;
        // Self inspection uses UpdateRemoteWeapons and the actual pawn rig.
        // This separate mannequin remains an explicitly requested diagnostic.
    }
    if (!bWanted || TargetPawn == None || TargetPawn.bDeleteMe || TargetPawn.Health <= 0)
    {
        if (AvatarPreview != None) AvatarPreview.Destroy();
        AvatarPreview = None;
        PreviewStrength = 0;
        PreviousPreviewTick = WorldInfo.RealTimeSeconds;
        return;
    }
    // This side mannequin is diagnostic-only. Self inspection is owned by
    // the shared remote renderer above, including its supported rigs/weapons.
    if (AvatarPreview != None && (AvatarPreview.bDeleteMe
        || AvatarPreview.SourcePawn != TargetPawn || AvatarPreview.bSelfPreview))
    {
        if (!AvatarPreview.bDeleteMe) AvatarPreview.Destroy();
        AvatarPreview = None;
        PreviewStrength = 0;
        PreviousPreviewTick = WorldInfo.RealTimeSeconds;
    }
    if (AvatarPreview == None && bFresh)
    {
        AvatarPreview = Spawn(class'KF2VRNetAvatarPreview', self);
        if (AvatarPreview != None) AvatarPreview.Initialize(TargetPawn, self);
    }
    if (AvatarPreview != None && AvatarPreview.bDeleteMe) AvatarPreview = None;
    if (AvatarPreview == None) return;
    RealDelta = FClamp(WorldInfo.RealTimeSeconds - PreviousPreviewTick, 0, 0.05);
    PreviousPreviewTick = WorldInfo.RealTimeSeconds;
    PreviewStrength = FClamp(PreviewStrength + (bFresh ? RealDelta : -RealDelta) / 0.12, 0, 1);
    Frame = SamplePreview();
    Root = Frame.RootPosition;
    Basis = Frame.RootRotation;
    Head = Root + (Frame.Sample.HeadPosition >> Basis);
    Left = Root + (Frame.Sample.LeftPosition >> Basis);
    Right = Root + (Frame.Sample.RightPosition >> Basis);
    Muzzle = Root + (Frame.Sample.MuzzlePosition >> Basis);
    AvatarPreview.UpdatePreviewRoot(Root, Basis);
    AvatarPreview.SetTrackingFlags(bFresh ? Frame.Sample.TrackingFlags : 0);
    AvatarPreview.UpdateWeaponPreview(Muzzle, Normalize(Basis + Frame.Sample.MuzzleRotation),
        bFresh && (Frame.Sample.PresentationFlags & 1) != 0, Right,
        Normalize(Basis + Frame.Sample.RightRotation));
    AvatarPreview.UpdatePreview(Head, Normalize(Basis + Frame.Sample.HeadRotation),
        Left, Normalize(Basis + Frame.Sample.LeftGripRotation),
        Right, Normalize(Basis + Frame.Sample.RightGripRotation), PreviewStrength);
}

simulated function bool HasFreshPose()
{
    return bHaveSnapshot && TargetPawn != None && !TargetPawn.bDeleteMe
        && TargetPawn.Health > 0 && DisplaySnapshot.Sample.TrackingFlags != 0
        && WorldInfo.RealTimeSeconds - LastReceivedRealTime
            <= class'KF2VRNetTypes'.const.PoseLeaseSeconds;
}

simulated function DrawDiagnosticPose()
{
    local vector Head, LeftHand, RightHand, Root;
    local rotator RootRotation;
    Root = DisplaySnapshot.RootPosition;
    RootRotation = DisplaySnapshot.RootRotation;
    Head = Root + (DisplaySnapshot.Sample.HeadPosition >> RootRotation);
    LeftHand = Root + (DisplaySnapshot.Sample.LeftPosition >> RootRotation);
    RightHand = Root + (DisplaySnapshot.Sample.RightPosition >> RootRotation);
    if ((DisplaySnapshot.Sample.TrackingFlags & 1) != 0)
    {
        DrawDebugSphere(Head, 8, 8, 255, 220, 0);
        DrawDebugLine(Root, Head, 255, 220, 0);
    }
    if ((DisplaySnapshot.Sample.TrackingFlags & 2) != 0)
    {
        DrawDebugSphere(LeftHand, 5, 8, 0, 200, 255);
        DrawDebugLine(Root, LeftHand, 0, 200, 255);
    }
    if ((DisplaySnapshot.Sample.TrackingFlags & 4) != 0)
    {
        DrawDebugSphere(RightHand, 5, 8, 255, 100, 80);
        DrawDebugLine(Root, RightHand, 255, 100, 80);
    }
}

// Roomscale moves (ApplyServerRoomMove) sweep the pawn with MoveSmooth, so
// its physics velocity, and the Velocity replicated to other players, stays
// near zero. The stock locomotion node (KFAnim_Movement, 2D speed from
// Velocity) then keeps the legs idle while the body slides. Rebuild the
// horizontal speed from the server-authored snapshot roots, which this client
// never moves, and give it to the simulated pawn so the stock walk/run and
// direction blends play. Stick walking already replicates a real velocity and
// is left alone. Cosmetic only: never on the owner or the server.
simulated function UpdateRoomscaleAnimation(float DeltaTime, bool bFresh)
{
    local vector Observed, Current;
    local float Span, FootSpread;
    local int Last;
    local bool bApply;
    if (TargetPawn != None && !TargetPawn.bDeleteMe && TargetPawn.Role == ROLE_SimulatedProxy
        && TargetPawn.Physics == PHYS_Walking && bFresh)
    {
        Last = PreviewHistory.Length - 1;
        if (Last >= 3)
        {
            Span = PreviewHistory[Last].ReceivedAt - PreviewHistory[Last - 3].ReceivedAt;
            if (Span >= 0.06 && Span <= 0.5)
            {
                Observed = (PreviewHistory[Last].Pose.RootPosition - PreviewHistory[Last - 3].Pose.RootPosition) / Span;
                Observed.Z = 0;
            }
        }
        Current = TargetPawn.Velocity;
        Current.Z = 0;
        // What replication delivered, unless it is still the value this
        // function wrote last tick.
        if (bRoomAnimApplied && VSizeSq(Current - AppliedAnimVelocity) < 1.0) Current = vect(0,0,0);
        bApply = VSize(Observed) > 30.0 && VSize(Current) < VSize(Observed) * 0.5;
        // Diagnostic: the spread of the feet over each half second. A
        // stepping body swings it through a stride; a sliding one holds it.
        if (bDiagnosticVisuals && TargetPawn.Mesh != None && TargetPawn.LeftFootBoneName != ''
            && TargetPawn.RightFootBoneName != '')
        {
            FootSpread = VSize((TargetPawn.Mesh.GetBoneLocation(TargetPawn.LeftFootBoneName)
                - TargetPawn.Mesh.GetBoneLocation(TargetPawn.RightFootBoneName)) * vect(1,1,0));
            StrideMin = StrideMax == 0 ? FootSpread : FMin(StrideMin, FootSpread);
            StrideMax = FMax(StrideMax, FootSpread);
            if (WorldInfo.RealTimeSeconds >= NextRoomAnimLog)
            {
                NextRoomAnimLog = WorldInfo.RealTimeSeconds + 0.5;
                `log("KF2VRNet remote_locomotion pawn=" $ PawnEpoch $ " observed=" $ VSize(Observed)
                    $ " replicated=" $ VSize(Current) $ " applied=" $ bApply
                    $ " velocity=" $ VSize(TargetPawn.Velocity * vect(1,1,0))
                    $ " stride=" $ (StrideMax - StrideMin));
                StrideMax = 0;
            }
        }
    }
    if (!bApply)
    {
        // Hand the pawn back with no leftover speed, unless replication has
        // already replaced the value written here.
        if (bRoomAnimApplied && TargetPawn != None && !TargetPawn.bDeleteMe
            && VSizeSq(TargetPawn.Velocity * vect(1,1,0) - AppliedAnimVelocity) < 1.0)
        {
            TargetPawn.Velocity.X = 0;
            TargetPawn.Velocity.Y = 0;
        }
        bRoomAnimApplied = false;
        RoomAnimVelocity = vect(0,0,0);
        return;
    }
    if (!bRoomAnimApplied) RoomAnimVelocity = Observed;
    else RoomAnimVelocity += (Observed - RoomAnimVelocity) * FMin(1.0, DeltaTime * 8.0);
    TargetPawn.Velocity.X = RoomAnimVelocity.X;
    TargetPawn.Velocity.Y = RoomAnimVelocity.Y;
    AppliedAnimVelocity = RoomAnimVelocity;
    AppliedAnimVelocity.Z = 0;
    bRoomAnimApplied = true;
}

simulated event Tick(float DeltaTime)
{
    local KF2VRNetPlayerController PC;
    local bool bFresh;
    Super.Tick(DeltaTime);
    if (WorldInfo.NetMode == NM_DedicatedServer)
    {
        return;
    }
    // A pawn reference can resolve after Snapshot's repnotify; retry without
    // extending the lease for a duplicate snapshot.
    ConsumeSnapshot();
    bFresh = HasFreshPose();
    UpdateRoomscaleAnimation(DeltaTime, bFresh);
    UpdateRemoteWeapons(bFresh);
    UpdateAvatarPreview(bFresh);
    if (bFresh != bDiagnosticWasFresh)
    {
        foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
        {
            if (PC.bDiagnosticObserverDebug && PC.NetChannel != None)
                `log("KF2VRNet freshness world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch
                    $ " pawn=" $ PawnEpoch $ " observer=" $ PC.NetChannel.ConnectionEpoch
                    $ " fresh=" $ bFresh $ " sequence=" $ DisplaySnapshot.Sample.Sequence
                    $ " flags=" $ DisplaySnapshot.Sample.TrackingFlags
                    $ " netmode=" $ WorldInfo.NetMode);
        }
        bDiagnosticWasFresh = bFresh;
    }
    if (bFresh)
    {
        foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
        {
            if (PC.bDiagnosticObserverDebug)
            {
                DrawDiagnosticPose();
                break;
            }
        }
    }
}

simulated event Destroyed()
{
    local KF2VRNetPlayerController PC;
    local int I;
    for (I = 0; I < 2; ++I)
        if (RemoteWeapons[I] != None) RemoteWeapons[I].Destroy();
    if (RemoteBody != None) RemoteBody.Destroy();
    RestoreStockAttachment();
    if (AvatarPreview != None) AvatarPreview.Destroy();
    AvatarPreview = None;
    foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
        if (PC.bDiagnosticObserverDebug && PC.NetChannel != None)
            `log("KF2VRNet pose_destroyed world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch
                $ " pawn=" $ PawnEpoch $ " observer=" $ PC.NetChannel.ConnectionEpoch
                $ " netmode=" $ WorldInfo.NetMode);
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=false
    // Six-player prototype broadcasts small state. Distance relevancy and a
    // production avatar interpolator are separate measured milestones.
    bAlwaysRelevant=true
    bReplicateMovement=false
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=25.0
    TickGroup=TG_PreAsyncWork
}
