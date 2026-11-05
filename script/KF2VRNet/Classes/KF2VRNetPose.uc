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
// Sender timeline for interpolation: snapshot times follow the sender's
// clock (or the sample sequence from older senders), anchored to arrivals.
var private float PoseTimeBase, PoseSequenceTime;
var private int LastPoseSequence, LastPoseMillis;
var KF2VRNetAvatarPreview AvatarPreview;
var private float PreviewStrength, PreviousPreviewTick;
var bool bIndependentWeapons;
var bool bDiagnosticVisuals;
var NetWeaponVisual LeftWeapon, RightWeapon;
var int ShieldHandToken;
var int ShieldSkinId;
var private KF2VRNetRemoteShield RemoteShield;
var private KF2VRNetRemoteWeapon RemoteWeapons[2];
var private KF2VRNetRemoteBody RemoteBody;
var private KF2VRNetRemoteLight RemoteLight;
var private NetPoseSnapshot FlashlightFrame;
var private bool bHaveFlashlightFrame;
var private ParticleSystemComponent HeldGrenade;
var private KF2VRNetReloadProps ReloadProps;
var private class<KFProj_Grenade> HeldGrenadeClass;
var private KF2VRNetWorldPresentation WorldPresentation;
var repnotify NetWorldJournal WorldActions;
var private array<NetWorldTransition> WorldJournal;
var private array<float> WorldJournalTimes;
var private int WorldTransitionSerial;
var private NetPoseSnapshot LastPresentedFrame;
var private bool bHavePresentedFrame;
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
        bIndependentWeapons, WorldActions;
}

function NetWeaponVisual SampleWeapon(KFWeapon W, int Id, KF2VRNetItemRuntime Runtime)
{
    local NetWeaponVisual Result;
    if (W == None || W.bDeleteMe) return Result;
    Result.WeaponClass = W.Class;
    Result.ItemId = Id;
    Result.SkinId = class'VRWeaponPair'.static.VisibleSkin(W);
    Result.Ammo = W.AmmoCount[0];
    if (Runtime != None) Result.ShotSequence = Runtime.ShotSequence;
    Result.WeaponState = W.GetWeaponStateId();
    Result.ReloadStage = W.ReloadStatus;
    Result.AnimRate = W.GetThirdPersonAnimRate();
    Result.FireMode = Runtime != None ? Runtime.LastShotFireMode : W.CurrentFireMode;
    return Result;
}

function PublishWeapons(bool bEnabled, KFWeapon Left, int LeftId, KFWeapon Right, int RightId,
    KF2VRNetHeldInventory Inventory)
{
    bIndependentWeapons = bEnabled;
    LeftWeapon = SampleWeapon(bEnabled ? Left : None, LeftId, Inventory.RuntimeFor(Left));
    RightWeapon = SampleWeapon(bEnabled ? Right : None, RightId, Inventory.RuntimeFor(Right));
    ShieldHandToken=bEnabled ? Inventory.Snapshot.ShieldHandToken : 0;
    ShieldSkinId=ShieldHandToken>0 ? class'VRWeaponPair'.static.VisibleSkin(Inventory.HeldShield()) : 0;
    if (KFWeap_SMG_G18(Left)!=None && (Inventory.Snapshot.CarryMask & 1)!=0) LeftWeapon=SampleWeapon(None,0,None);
    if (KFWeap_SMG_G18(Right)!=None && (Inventory.Snapshot.CarryMask & 2)!=0) RightWeapon=SampleWeapon(None,0,None);
}

function NetWorldTransition MakeWorldTransition(int Hand, int Generation, int Action,
    int Request, int ItemId, VRWorldDropGun Prop, optional int ContactRequest)
{
    local NetWorldTransition T;
    local vector X, Y, Z;
    local StaticMeshComponent M;
    if (Prop == None || Prop.MyMeshComp == None) return T;
    M = StaticMeshComponent(Prop.MyMeshComp);
    if (M == None || M.StaticMesh == None) return T;
    T.Hand = Hand; T.Generation = Generation; T.Action = Action;
    T.Request = Request; T.ItemId = ItemId; T.ContactRequest = ContactRequest;
    T.ReleaseOwner = Prop.DropOwner; T.Prop = Prop;
    T.ReleaseRequestId = Prop.ReleaseRequestId; T.ReleasedItemId = Prop.ReleasedItemId;
    T.WeaponClass = class<KFWeapon>(Prop.InventoryClass); T.SkinId = Prop.SkinItemId;
    T.PickupMesh = M.StaticMesh;
    T.Position = TransformVector(M.LocalToWorld, vect(0,0,0));
    X = TransformNormal(M.LocalToWorld, vect(1,0,0));
    Y = TransformNormal(M.LocalToWorld, vect(0,1,0));
    Z = TransformNormal(M.LocalToWorld, vect(0,0,1));
    T.Scale3D.X = VSize(X); T.Scale3D.Y = VSize(Y); T.Scale3D.Z = VSize(Z);
    T.Rotation = OrthoRotation(Normal(X), Normal(Y), Normal(Z));
    T.Linear = Prop.Velocity;
    if (M.BodyInstance != None)
    {
        T.Linear = M.BodyInstance.Velocity;
        T.Angular = M.BodyInstance.GetUnrealWorldAngularVelocity();
    }
    return T;
}

function PublishWorldTransition(NetWorldTransition T)
{
    if (Role != ROLE_Authority || (T.Action != 2 && (T.Hand < 0 || T.Hand > 1)) || T.WeaponClass == None
        || T.ReleaseOwner == None || T.ReleaseRequestId <= 0) return;
    WorldTransitionSerial = (WorldTransitionSerial + 1) & 65535;
    T.Serial = WorldTransitionSerial;
    WorldJournal.AddItem(T); WorldJournalTimes.AddItem(WorldInfo.RealTimeSeconds);
    if (WorldJournal.Length > 8) { WorldJournal.Remove(0, 1); WorldJournalTimes.Remove(0, 1); }
    WorldActions.Serial = WorldTransitionSerial; WorldActions.Entries = WorldJournal;
    bForceNetUpdate = true;
}

// Presentation anchor for the sampled offsets: the simulated pawn's collision
// centre and yaw, the frame the owner sampled against (RootPosition's
// convention). The replicated root trails a running body by the network
// delay, so hands and guns hung from it lag behind the visible pawn. No
// MTO_PhysSmoothOffset: the owner's eye base already carries its own stair
// smoothing into the offsets.
// The offsets turn with the yaw the sender measured them against, carried in
// the same interpolated frame: the simulated pawn's yaw arrives at the
// server's tick rate and out of step with the buffered pose, and turned the
// arms into the body or the gun over the head while the player turned.
simulated function PresentationRoot(NetPoseSnapshot Frame, out vector Root, out rotator Basis)
{
    if (Snapshot.Motion.bEnabled)
    {
        // Saved replay owns the pawn root through authority. Present the same
        // atomic frame as its hands/muzzle; live movement yaw can arrive later.
        Root = Frame.RootPosition; Basis = Frame.RootRotation;
        TargetPawn.SetLocation(Root); TargetPawn.SetRotation(Basis);
        return;
    }
    Root = TargetPawn.Location;
    Basis = rot(0,0,0);
    Basis.Yaw = (Frame.Sample.PresentationFlags & 64) != 0 ? Frame.Sample.RootYaw : TargetPawn.Rotation.Yaw;
}

simulated function RestoreStockAttachment()
{
    if (HiddenStockAttachment != None && !HiddenStockAttachment.bDeleteMe)
        HiddenStockAttachment.WeapMesh.SetHidden(bStockWasHidden);
    HiddenStockAttachment = None;
}

simulated function ReleaseHeldGrenade()
{
    if (HeldGrenade != None)
    {
        HeldGrenade.DeactivateSystem();
        DetachComponent(HeldGrenade);
    }
    HeldGrenade = None;
    HeldGrenadeClass = None;
}

// Visual only: the actual projectile exists only after the reliable release.
// Use the owner's authored transform plus the same rig corrections as guns.
simulated function UpdateHeldGrenade(NetPoseSnapshot Frame, bool bFresh, vector Root, rotator Basis)
{
    local class<KFProj_Grenade> GrenadeClass;
    local int Hand;
    local bool bNew;
    Hand = int(Frame.Sample.GrenadeHand) - 1;
    GrenadeClass = Frame.Sample.GrenadeClass;
    if (!bFresh || Frame.Motion.bEnabled || Hand < 0 || Hand > 1
        || GrenadeClass == None || GrenadeClass.default.ProjFlightTemplate == None
        // Clear immediately on the latest release/tracking loss, even if a
        // weapon journal boundary temporarily holds an older display frame.
        || DisplaySnapshot.Sample.GrenadeHand != Frame.Sample.GrenadeHand
        || DisplaySnapshot.Sample.GrenadeClass != GrenadeClass
        || (DisplaySnapshot.Sample.TrackingFlags & (1 | (2 << Hand))) != (1 | (2 << Hand))
        || (Frame.Sample.TrackingFlags & (1 | (2 << Hand))) != (1 | (2 << Hand))
        || RemoteBody == None || !RemoteBody.IsReady()
        || (Hand == 0 ? Frame.LeftWeapon.WeaponClass : Frame.RightWeapon.WeaponClass) != None)
    { ReleaseHeldGrenade(); return; }
    if (HeldGrenadeClass != GrenadeClass) ReleaseHeldGrenade();
    if (HeldGrenade == None)
    {
        HeldGrenade = new(self) class'ParticleSystemComponent';
        HeldGrenade.bAutoActivate = false;
        HeldGrenade.SetTemplate(GrenadeClass.default.ProjFlightTemplate);
        HeldGrenade.SetAbsolute(true, true, true);
        HeldGrenade.SetScale(class'VRChestGrenade'.static.GrenadeDisplayScale(GrenadeClass));
        HeldGrenade.SetOnlyOwnerSee(false);
        HeldGrenade.SetOwnerNoSee(false);
        // The replicated pose actor itself is hidden; this prop is visible.
        HeldGrenade.SetIgnoreOwnerHidden(true);
        HeldGrenade.SetHidden(false);
        HeldGrenade.SetActorCollision(false, false);
        HeldGrenade.SetTraceBlocking(false, false);
        HeldGrenade.bUpdateComponentInTick = true;
        AttachComponent(HeldGrenade);
        HeldGrenadeClass = GrenadeClass;
        bNew = true;
    }
    HeldGrenade.SetTranslation(Root + (Frame.Sample.GrenadePosition >> Basis)
        + RemoteBody.HandCorrection + RemoteBody.ReachShift[Hand]);
    HeldGrenade.SetRotation(Normalize(Basis + Frame.Sample.GrenadeRotation));
    HeldGrenade.ForceUpdate(true);
    if (bNew) HeldGrenade.ActivateSystem();
}

simulated function SkeletalMeshComponent ReleasedWeaponMesh(int ItemId)
{
    local int I;
    for (I = 0; I < 2; ++I)
        if (RemoteWeapons[I] != None && RemoteWeapons[I].Previous.ItemId == ItemId
            && RemoteWeapons[I].bFirstPersonMesh && RemoteWeapons[I].Attachment != None)
            return RemoteWeapons[I].Attachment.WeapMesh;
    return None;
}

simulated function UpdateRemoteWeapons(bool bFresh)
{
    local KF2VRNetPlayerController PC;
    local bool bWanted, bAnyVisualRequested, bAllVisualsReady, bVisualReady, bSelf, bUseWeaponRoot;
    local int I;
    local NetPoseSnapshot Frame;
    local NetWeaponVisual Visual;
    local int PumpCode;
    local array<NetMechanismPart> Mechanisms;
    local vector Muzzle, Root, CatchHandCorrection;
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
        if (RemoteShield!=None) RemoteShield.Destroy();
        RemoteShield=None;
        ReleaseHeldGrenade();
        if (ReloadProps != None) ReloadProps.Shutdown(self);
        ReloadProps = None;
        if (WorldPresentation != None) WorldPresentation.Destroy();
        WorldPresentation = None;
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
    if (!bSelf && !Frame.Motion.bEnabled && WorldPresentation == None)
    {
        WorldPresentation = Spawn(class'KF2VRNetWorldPresentation', self);
        if (WorldPresentation != None) WorldPresentation.PoseOwner = self;
    }
    // Journal and snapshots are properties of one actor but may span network
    // bunches. Hold the last complete presentation until its event boundary
    // is available; never consume the new held identity ahead of its release.
    if (!Frame.Motion.bEnabled
        && (class'KF2VRNetTypes'.static.IsNewerSequence(Frame.WorldTransitionSerial, WorldActions.Serial)
            || (WorldPresentation != None && !WorldPresentation.CanPresentFrame(Frame, WorldActions.Entries))))
    {
        if (!bHavePresentedFrame) { RestoreStockAttachment(); return; }
        Frame = LastPresentedFrame;
    }
    else { LastPresentedFrame = Frame; bHavePresentedFrame = true; }
    FlashlightFrame = Frame;
    bHaveFlashlightFrame = true;
    if (!bSelf && !Frame.Motion.bEnabled)
    {
        if (WorldPresentation != None) WorldPresentation.UpdateFrame(Frame, bFresh, WorldActions.Entries);
    }
    if (Frame.Motion.bEnabled && Frame.Motion.ReplayId != PreviousMotionReplayId)
    {
        for (I = 0; I < 2; ++I) { if (RemoteWeapons[I] != None) RemoteWeapons[I].Destroy(); RemoteWeapons[I] = None; }
        PreviousMotionReplayId = Frame.Motion.ReplayId;
    }
    PresentationRoot(Frame, Root, Basis);
    if (RemoteBody == None)
    {
        RemoteBody = Spawn(class'KF2VRNetRemoteBody', self);
        if (RemoteBody != None) RemoteBody.PoseOwner = self;
    }
    if (RemoteBody != None) RemoteBody.UpdateBody(Frame, bFresh);
    if (Frame.ShieldHandToken>0 && RemoteShield==None) RemoteShield=Spawn(class'KF2VRNetRemoteShield',self);
    if (RemoteShield!=None)
    {
        bAnyVisualRequested=bAnyVisualRequested || Frame.ShieldHandToken>0;
        I=Frame.ShieldHandToken-1;
        Muzzle=I==0 ? Frame.Sample.LeftMuzzlePosition : Frame.Sample.MuzzlePosition;
        Aim=I==0 ? Frame.Sample.LeftMuzzleRotation : Frame.Sample.MuzzleRotation;
        Muzzle=Muzzle >> Basis;
        if (RemoteBody!=None && I>=0 && I<2) Muzzle+=RemoteBody.HandCorrection+RemoteBody.ReachShift[I];
        RemoteShield.UpdateShield(Root+Muzzle,Normalize(Basis+Aim),bFresh && I>=0 && I<2
            && (Frame.Sample.TrackingFlags & (2<<I))!=0 && (Frame.Sample.PresentationFlags & (I==0 ? 2 : 1))!=0,Frame.ShieldSkinId);
    }
    UpdateHeldGrenade(Frame, bFresh, Root, Basis);
    Mechanisms = CurrentMechanisms(Frame);
    if (ReloadProps == None && Frame.Sample.ReloadProps.Length > 0)
        ReloadProps = new(self) class'KF2VRNetReloadProps';
    if (ReloadProps != None) ReloadProps.Update(self, Frame, DisplaySnapshot, bFresh, Root, Basis, RemoteBody);
    bAllVisualsReady = true;
    if (Frame.ShieldHandToken>0) bAllVisualsReady=RemoteShield!=None && RemoteShield.Shield!=None;
    for (I = 0; I < 2; ++I)
    {
        Visual = Frame.Motion.bEnabled ? (I == 0 ? Frame.Motion.LeftWeapon : Frame.Motion.RightWeapon)
            : (I == 0 ? Frame.LeftWeapon : Frame.RightWeapon);
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
        bUseWeaponRoot = RemoteWeapons[I].bFirstPersonMesh && !Frame.Motion.bEnabled
            && (Frame.Sample.WeaponRootFlags & (I == 0 ? 2 : 1)) != 0
            && !class'VRWeaponBlockShapes'.static.PublishesRoot(class'VRWeaponBlockShapes'.static.ProfileClass(Visual.WeaponClass));
        if (bUseWeaponRoot)
        {
            Muzzle = I == 0 ? Frame.Sample.LeftWeaponRootPosition : Frame.Sample.RightWeaponRootPosition;
            Aim = I == 0 ? Frame.Sample.LeftWeaponRootRotation : Frame.Sample.RightWeaponRootRotation;
        }
        // The body's head-fit shift and the arm's reach limit (a player who
        // reaches farther than the model's arms), so the gun stays in the
        // drawn hand instead of floating ahead of it.
        if (RemoteBody != None) Muzzle = (Muzzle >> Basis) + RemoteBody.HandCorrection + RemoteBody.ReachShift[I];
        else Muzzle = Muzzle >> Basis;
        PumpCode = I == 0 ? (Frame.Sample.LeftPumpLo | (Frame.Sample.LeftPumpHi << 8))
            : (Frame.Sample.RightPumpLo | (Frame.Sample.RightPumpHi << 8));
        bVisualReady = RemoteWeapons[I].UpdateVisual(Visual, Root + Muzzle,
            Normalize(Basis + Aim), bFresh
                && (!Frame.Motion.bEnabled || (RemoteBody != None && RemoteBody.IsTrackedPoseReady()))
                && (Frame.Sample.TrackingFlags & (2 << I)) != 0
                && (Frame.Sample.PresentationFlags & (I == 0 ? 2 : 1)) != 0, PumpCode, Mechanisms, bUseWeaponRoot);
        if (WorldPresentation != None)
        {
            CatchHandCorrection = vect(0,0,0);
            if (RemoteBody != None) CatchHandCorrection = RemoteBody.HandCorrection + RemoteBody.ReachShift[I];
            WorldPresentation.BlendCaughtWeapon(RemoteWeapons[I], Visual, Frame, Root, Basis, CatchHandCorrection);
        }
        if (Visual.WeaponClass != None && !bVisualReady) bAllVisualsReady = false;
    }
    bPresentationReady = bFresh && RemoteBody != None && RemoteBody.IsReady() && bAllVisualsReady;
    // Build the same remote presentation before the view switch. Keep it
    // invisible until the controller has committed that switch.
    if (bSelf)
        foreach WorldInfo.LocalPlayerControllers(class'KF2VRNetPlayerController', PC)
            if (PC.Pawn == TargetPawn && PC.NativeSelfViewActive == 0)
            {
                if (RemoteShield!=None && RemoteShield.Shield!=None) RemoteShield.Shield.SetHidden(true);
                if (ReloadProps != None) ReloadProps.Hide();
                for (I = 0; I < 2; ++I)
                    if (RemoteWeapons[I] != None && RemoteWeapons[I].Attachment != None)
                        RemoteWeapons[I].Attachment.WeapMesh.SetHidden(true);
            }
    if ((!bAnyVisualRequested && WorldPresentation == None) || (!bAllVisualsReady && !Frame.Motion.bEnabled))
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
    Snapshot.LeftWeapon = LeftWeapon; Snapshot.RightWeapon = RightWeapon;
    Snapshot.ShieldHandToken=ShieldHandToken;
    Snapshot.ShieldSkinId=ShieldSkinId;
    while (WorldJournalTimes.Length > 0 && WorldInfo.RealTimeSeconds - WorldJournalTimes[0] > 1.0)
    { WorldJournalTimes.Remove(0, 1); WorldJournal.Remove(0, 1); }
    WorldActions.Entries = WorldJournal;
    Snapshot.WorldTransitionSerial = WorldTransitionSerial;
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
    local int Delta;
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
    // Place each snapshot by its sample sequence rather than its arrival:
    // internet jitter bunched arrivals and the arms froze, then jumped. The
    // base follows arrivals slowly and never puts a snapshot in the future.
    if (PreviewHistory.Length == 0)
    {
        PoseSequenceTime = 0;
        PoseTimeBase = LastReceivedRealTime;
    }
    else
    {
        // The sender's clock: its frames do not land on an exact interval.
        if ((Snapshot.Sample.PresentationFlags & 64) != 0)
            PoseSequenceTime += FClamp(((Snapshot.Sample.SampleMillis - LastPoseMillis) & 65535) / 1000.0, 0.001, 1.0);
        else
        {
            Delta = (Snapshot.Sample.Sequence - LastPoseSequence) & 65535;
            PoseSequenceTime += FClamp(Delta, 1, 120) * class'KF2VRNetTypes'.const.ClientPoseInterval;
        }
        PoseTimeBase += (LastReceivedRealTime - PoseSequenceTime - PoseTimeBase) * 0.015;
        if (PoseTimeBase + PoseSequenceTime > LastReceivedRealTime)
            PoseTimeBase = LastReceivedRealTime - PoseSequenceTime;
    }
    LastPoseSequence = Snapshot.Sample.Sequence;
    LastPoseMillis = Snapshot.Sample.SampleMillis;
    Timed.ReceivedAt = PoseTimeBase + PoseSequenceTime;
    PreviewHistory.AddItem(Timed);
    if (PreviewHistory.Length > 32) PreviewHistory.Remove(0, 1);
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

// Cosmetic interpolation on the sender timeline, 100 ms behind (twelve
// samples at 120 Hz, so ordinary jitter does not run the buffer dry), bounded
// to 32 snapshots. Never extrapolate tracking or expose this buffered state to
// input/damage code.
simulated function array<NetMechanismPart> CurrentMechanisms(NetPoseSnapshot Frame)
{
    local array<NetMechanismPart> Result;
    local NetMechanismPart Part;
    local int I, J;
    if (Frame.Motion.bEnabled) return Result;
    for (I = 0; I < Frame.Sample.Mechanisms.Length; ++I)
    {
        Part = Frame.Sample.Mechanisms[I];
        for (J = 0; J < DisplaySnapshot.Sample.Mechanisms.Length; ++J)
            if (class'KF2VRNetTypes'.static.SameMechanism(Part, DisplaySnapshot.Sample.Mechanisms[J])) break;
        if (J >= DisplaySnapshot.Sample.Mechanisms.Length) continue;
        // Hidden ammo and released controls retire at the latest accepted
        // sample, even while the avatar interpolates older hand transforms.
        Part.Flags = (Part.Flags & DisplaySnapshot.Sample.Mechanisms[J].Flags & 1)
            | (DisplaySnapshot.Sample.Mechanisms[J].Flags & 6);
        Result.AddItem(Part);
    }
    return Result;
}

simulated function NetPoseSnapshot SamplePreview()
{
    local NetPoseSnapshot A, B, Result;
    local int I, J, K, PumpA, PumpB, Pump;
    local float At, Blend, Span;
    if (PreviewHistory.Length == 0) return DisplaySnapshot;
    At = WorldInfo.RealTimeSeconds - 0.10;
    if (At <= PreviewHistory[0].ReceivedAt) return PreviewHistory[0].Pose;
    for (I = 1; I < PreviewHistory.Length; ++I)
    {
        if (At > PreviewHistory[I].ReceivedAt) continue;
        A = PreviewHistory[I-1].Pose;
        B = PreviewHistory[I].Pose;
        Span = PreviewHistory[I].ReceivedAt - PreviewHistory[I-1].ReceivedAt;
        Blend = FClamp((At - PreviewHistory[I-1].ReceivedAt) / FMax(Span, 0.001), 0, 1);
        Result = B;
        Result.Sample.Mechanisms = A.Sample.Mechanisms;
        for (J = 0; J < Result.Sample.Mechanisms.Length; ++J)
            for (K = 0; K < B.Sample.Mechanisms.Length; ++K)
                if (class'KF2VRNetTypes'.static.SameMechanism(A.Sample.Mechanisms[J], B.Sample.Mechanisms[K]))
                {
                    if ((A.Sample.Mechanisms[J].Flags & B.Sample.Mechanisms[K].Flags & 1) != 0)
                    {
                        Result.Sample.Mechanisms[J].Translation = VLerp(A.Sample.Mechanisms[J].Translation, B.Sample.Mechanisms[K].Translation, Blend);
                        Result.Sample.Mechanisms[J].Rotation = RLerp(A.Sample.Mechanisms[J].Rotation, B.Sample.Mechanisms[K].Rotation, Blend, true);
                    }
                    break;
                }
        Result.Sample.ReloadProps = A.Sample.ReloadProps;
        for (J = 0; J < Result.Sample.ReloadProps.Length; ++J)
            for (K = 0; K < B.Sample.ReloadProps.Length; ++K)
                if (class'KF2VRNetTypes'.static.SameReloadProp(A.Sample.ReloadProps[J], B.Sample.ReloadProps[K]))
                {
                    Result.Sample.ReloadProps[J].Position = VLerp(A.Sample.ReloadProps[J].Position, B.Sample.ReloadProps[K].Position, Blend);
                    Result.Sample.ReloadProps[J].Rotation = RLerp(A.Sample.ReloadProps[J].Rotation, B.Sample.ReloadProps[K].Rotation, Blend, true);
                    Result.Sample.ReloadProps[J].Scale = VLerp(A.Sample.ReloadProps[J].Scale, B.Sample.ReloadProps[K].Scale, Blend);
                    break;
                }
        // Discrete identity changes take effect at their sampled boundary,
        // never early while the hands still interpolate from the old item.
        Result.LeftWeapon = A.LeftWeapon; Result.RightWeapon = A.RightWeapon;
        Result.ShieldHandToken = A.ShieldHandToken;
        Result.ShieldSkinId = A.ShieldSkinId;
        Result.WorldTransitionSerial = A.WorldTransitionSerial;
        Result.Sample.PresentationFlags = A.Sample.PresentationFlags;
        Result.Sample.TrackingFlags = A.Sample.TrackingFlags;
        Result.Sample.EyeHeight = A.Sample.EyeHeight;
        if (A.Sample.EyeHeight > 0 && B.Sample.EyeHeight > 0)
            Result.Sample.EyeHeight = Clamp(Round(Lerp(float(A.Sample.EyeHeight), float(B.Sample.EyeHeight), Blend)), 1, 128);
        Result.Sample.GrenadeHand = A.Sample.GrenadeHand;
        Result.Sample.GrenadeClass = A.Sample.GrenadeClass;
        Result.Sample.GrenadePosition = A.Sample.GrenadePosition;
        Result.Sample.GrenadeRotation = A.Sample.GrenadeRotation;
        if (A.Sample.GrenadeHand == B.Sample.GrenadeHand && A.Sample.GrenadeClass == B.Sample.GrenadeClass)
        {
            Result.Sample.GrenadePosition += (B.Sample.GrenadePosition - A.Sample.GrenadePosition) * Blend;
            Result.Sample.GrenadeRotation = RLerp(A.Sample.GrenadeRotation, B.Sample.GrenadeRotation, Blend, true);
        }
        Result.Sample.WeaponRootFlags = A.Sample.WeaponRootFlags & B.Sample.WeaponRootFlags;
        Result.Sample.LeftWeaponRootPosition = A.Sample.LeftWeaponRootPosition
            + (B.Sample.LeftWeaponRootPosition - A.Sample.LeftWeaponRootPosition) * Blend;
        Result.Sample.RightWeaponRootPosition = A.Sample.RightWeaponRootPosition
            + (B.Sample.RightWeaponRootPosition - A.Sample.RightWeaponRootPosition) * Blend;
        Result.Sample.LeftWeaponRootRotation = RLerp(A.Sample.LeftWeaponRootRotation, B.Sample.LeftWeaponRootRotation, Blend, true);
        Result.Sample.RightWeaponRootRotation = RLerp(A.Sample.RightWeaponRootRotation, B.Sample.RightWeaponRootRotation, Blend, true);
        // A root belongs to one exact acknowledged hand generation. Never
        // interpolate a new incarnation through the previous weapon's frame.
        Result.Sample.LeftWeaponRootGeneration = A.Sample.LeftWeaponRootGeneration;
        Result.Sample.RightWeaponRootGeneration = A.Sample.RightWeaponRootGeneration;
        if (A.Sample.LeftWeaponRootGeneration != B.Sample.LeftWeaponRootGeneration)
        {
            Result.Sample.LeftWeaponRootPosition = A.Sample.LeftWeaponRootPosition;
            Result.Sample.LeftWeaponRootRotation = A.Sample.LeftWeaponRootRotation;
            Result.Sample.WeaponRootFlags = Result.Sample.WeaponRootFlags & 1;
        }
        if (A.Sample.RightWeaponRootGeneration != B.Sample.RightWeaponRootGeneration)
        {
            Result.Sample.RightWeaponRootPosition = A.Sample.RightWeaponRootPosition;
            Result.Sample.RightWeaponRootRotation = A.Sample.RightWeaponRootRotation;
            Result.Sample.WeaponRootFlags = Result.Sample.WeaponRootFlags & 2;
        }
        Result.RootPosition = A.RootPosition + (B.RootPosition - A.RootPosition) * Blend;
        Result.RootRotation = RLerp(A.RootRotation, B.RootRotation, Blend, true);
        Result.Sample.RootYaw = A.Sample.RootYaw + NormalizeRotAxis(B.Sample.RootYaw - A.Sample.RootYaw) * Blend;
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
        if (A.LeftWeapon.ItemId != B.LeftWeapon.ItemId || A.LeftWeapon.WeaponClass != B.LeftWeapon.WeaponClass)
        {
            Result.Sample.LeftMuzzlePosition = A.Sample.LeftMuzzlePosition;
            Result.Sample.LeftMuzzleRotation = A.Sample.LeftMuzzleRotation;
            Result.Sample.WeaponRootFlags = Result.Sample.WeaponRootFlags & 1;
        }
        if (A.RightWeapon.ItemId != B.RightWeapon.ItemId || A.RightWeapon.WeaponClass != B.RightWeapon.WeaponClass)
        {
            Result.Sample.MuzzlePosition = A.Sample.MuzzlePosition;
            Result.Sample.MuzzleRotation = A.Sample.MuzzleRotation;
            Result.Sample.WeaponRootFlags = Result.Sample.WeaponRootFlags & 2;
        }
        // A shield uses this hand's optical slot. A role change switches the
        // slot between shield root and gun muzzle; never blend those frames.
        if (A.ShieldHandToken != B.ShieldHandToken)
        {
            if (A.ShieldHandToken == 1 || B.ShieldHandToken == 1)
            {
                Result.Sample.LeftMuzzlePosition = A.Sample.LeftMuzzlePosition;
                Result.Sample.LeftMuzzleRotation = A.Sample.LeftMuzzleRotation;
            }
            if (A.ShieldHandToken == 2 || B.ShieldHandToken == 2)
            {
                Result.Sample.MuzzlePosition = A.Sample.MuzzlePosition;
                Result.Sample.MuzzleRotation = A.Sample.MuzzleRotation;
            }
        }
        Result.Sample.LeftWristRotation = RLerp(A.Sample.LeftWristRotation, B.Sample.LeftWristRotation, Blend, true);
        Result.Sample.RightWristRotation = RLerp(A.Sample.RightWristRotation, B.Sample.RightWristRotation, Blend, true);
        PumpA = A.Sample.LeftPumpLo | (A.Sample.LeftPumpHi << 8);
        PumpB = B.Sample.LeftPumpLo | (B.Sample.LeftPumpHi << 8);
        Pump = (PumpA > 0 && PumpB > 0) ? Round(Lerp(float(PumpA), float(PumpB), Blend)) : PumpB;
        Result.Sample.LeftPumpLo = Pump & 255; Result.Sample.LeftPumpHi = (Pump >> 8) & 255;
        PumpA = A.Sample.RightPumpLo | (A.Sample.RightPumpHi << 8);
        PumpB = B.Sample.RightPumpLo | (B.Sample.RightPumpHi << 8);
        Pump = (PumpA > 0 && PumpB > 0) ? Round(Lerp(float(PumpA), float(PumpB), Blend)) : PumpB;
        Result.Sample.RightPumpLo = Pump & 255; Result.Sample.RightPumpHi = (Pump >> 8) & 255;
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

// Read the frame already used by the body, including any held journal boundary.
// Latest head validity overrides the delayed frame so tracking loss goes dark
// immediately. This is observer presentation, never another tracking transport.
simulated function bool GetFlashlightTransform(out vector Head, out rotator Aim)
{
    local vector Root;
    local rotator Basis;
    if (!bHaveFlashlightFrame || !HasFreshPose() || !TargetPawn.bFlashlightOn
        || FlashlightFrame.Motion.bEnabled
        || (DisplaySnapshot.Sample.TrackingFlags & 1) == 0
        || (FlashlightFrame.Sample.TrackingFlags & 1) == 0) return false;
    PresentationRoot(FlashlightFrame, Root, Basis);
    Head = Root + (FlashlightFrame.Sample.HeadPosition >> Basis);
    Aim = Normalize(Basis + FlashlightFrame.Sample.HeadRotation);
    return true;
}

simulated function CacheFlashlightFrame(NetPoseSnapshot Frame)
{
    local PlayerController PC;
    FlashlightFrame = Frame;
    bHaveFlashlightFrame = true;
    if (RemoteLight != None && !RemoteLight.bDeleteMe) return;
    // One world light budget, matching the stock game's local observer. Every
    // pose shares it; it survives a teammate leaving and dies with the observer.
    foreach WorldInfo.DynamicActors(class'KF2VRNetRemoteLight', RemoteLight)
        if (!RemoteLight.bDeleteMe) return;
    PC = WorldInfo.GetALocalPlayerController();
    if (PC != None) RemoteLight = Spawn(class'KF2VRNetRemoteLight', PC);
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
    local int Last, First;
    local bool bApply;
    if (TargetPawn != None && !TargetPawn.bDeleteMe && TargetPawn.Role == ROLE_SimulatedProxy
        && TargetPawn.Physics == PHYS_Walking && bFresh)
    {
        // About 0.1 s of snapshots, whatever the send rate.
        Last = PreviewHistory.Length - 1;
        First = Last;
        while (First > 0 && PreviewHistory[Last].ReceivedAt - PreviewHistory[First].ReceivedAt < 0.1) --First;
        if (First < Last)
        {
            Span = PreviewHistory[Last].ReceivedAt - PreviewHistory[First].ReceivedAt;
            if (Span >= 0.06 && Span <= 0.5)
            {
                Observed = (PreviewHistory[Last].Pose.RootPosition - PreviewHistory[First].Pose.RootPosition) / Span;
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
    bHaveFlashlightFrame = false;
    UpdateRemoteWeapons(bFresh);
    if (!bHaveFlashlightFrame) FlashlightFrame = SamplePreview();
    CacheFlashlightFrame(FlashlightFrame);
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
    if (RemoteShield!=None) RemoteShield.Destroy();
    ReleaseHeldGrenade();
    if (ReloadProps != None) ReloadProps.Shutdown(self);
    ReloadProps = None;
    for (I = 0; I < 2; ++I)
        if (RemoteWeapons[I] != None) RemoteWeapons[I].Destroy();
    if (RemoteBody != None) RemoteBody.Destroy();
    if (WorldPresentation != None) WorldPresentation.Destroy();
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
    // Six-player prototype broadcasts small state. Distance relevancy is a
    // separate measured milestone.
    bAlwaysRelevant=true
    bReplicateMovement=false
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    // Every server tick: clients sample at 120 Hz and the host ticks at 120.
    NetUpdateFrequency=120.0
    TickGroup=TG_PreAsyncWork
}
