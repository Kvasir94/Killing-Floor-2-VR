// Local bridge between atomic held poses and independently relevant props.
// Registration owns discovery; only active cosmetic transforms run at120Hz.
class KF2VRNetWorldPresentation extends Actor dependsOn(KF2VRNetTypes)
    implements(VRWorldDropObserver);

struct WorldEntry
{
    var NetWorldTransition Transition;
    var KF2VRNetWorldVisual Visual;
    var VRWorldDropGun Prop;
    var float Started, Blending;
    var vector BlendPosition;
    var rotator BlendRotation;
    var bool bClosed;
};
var KF2VRNetPose PoseOwner;
var private VRWorldDropObserverHub Hub;
var private array<WorldEntry> Entries;
var private int LastSerial, InitialSerial, LeftItemId, RightItemId;
var private bool bInitialized, bHaveSerial, bFreshFrame;
var private bool bWaitingReferences, bAllowUnresolved;
var private float ReferenceWaitStarted;
var private float LastUpdate, NextCompact;
var private vector CatchRoot[2];
var private quat CatchRotation[2];
var private float CatchStarted[2];
var private int CatchItemId[2], CatchGeneration[2];
var private byte bCatchRoot[2], bCatchRelative[2];

simulated function bool TransitionReady(NetWorldTransition T)
{
    return T.ReleaseOwner != None && T.ReleaseRequestId > 0 && T.ReleasedItemId > 0
        && (T.Action == 2 || (T.WeaponClass != None && T.PickupMesh != None));
}

simulated function bool SupersededUnresolved(int Index, int Boundary, const out array<NetWorldTransition> Journal)
{
    local int J;
    for (J = Index + 1; J < Journal.Length; ++J)
        if (!class'KF2VRNetTypes'.static.IsNewerSequence(Journal[J].Serial, Boundary)
            && Journal[J].ReleaseOwner == Journal[Index].ReleaseOwner
            && Journal[J].ReleasedItemId == Journal[Index].ReleasedItemId
            && TransitionReady(Journal[J])) return true;
    return false;
}

// A replicated serial can arrive before its actor/asset references resolve.
// Retain the previous held identity briefly; then let authoritative props
// resume rather than indefinitely freezing an obsolete hand on missing art.
simulated function bool CanPresentFrame(NetPoseSnapshot Frame, const out array<NetWorldTransition> Journal)
{
    local int I;
    bAllowUnresolved = false;
    for (I = 0; I < Journal.Length; ++I)
    {
        if (class'KF2VRNetTypes'.static.IsNewerSequence(Journal[I].Serial, Frame.WorldTransitionSerial)
            || (bHaveSerial && !class'KF2VRNetTypes'.static.IsNewerSequence(Journal[I].Serial, LastSerial))) continue;
        if (TransitionReady(Journal[I]) || SupersededUnresolved(I, Frame.WorldTransitionSerial, Journal)) continue;
        if (!bWaitingReferences)
        { bWaitingReferences = true; ReferenceWaitStarted = WorldInfo.RealTimeSeconds; }
        bAllowUnresolved = WorldInfo.RealTimeSeconds - ReferenceWaitStarted >= 0.25;
        return bAllowUnresolved;
    }
    bWaitingReferences = false;
    return true;
}

simulated function bool SameRelease(NetWorldTransition T, VRWorldDropGun P)
{
    return P != None && P.DropOwner == T.ReleaseOwner && P.ReleaseRequestId == T.ReleaseRequestId
        && P.ReleasedItemId == T.ReleasedItemId;
}

simulated function WorldDropAvailable(VRWorldDropGun Prop)
{
    local int I;
    for (I = 0; I < Entries.Length; ++I)
        if (SameRelease(Entries[I].Transition, Prop)) Entries[I].Prop = Prop;
}

simulated function WorldDropClosed(KFPawn_Human Human, int ItemId, int ReleaseRequest)
{
    local int I;
    for (I = 0; I < Entries.Length; ++I)
        if (Entries[I].Transition.ReleaseOwner == Human && Entries[I].Transition.ReleasedItemId == ItemId
            && Entries[I].Transition.ReleaseRequestId <= ReleaseRequest)
        {
            Entries[I].bClosed = true;
            if (Entries[I].Visual != None) Entries[I].Visual.Destroy();
            Entries[I].Visual = None;
        }
}

simulated function bool ShouldHideWorldDrop(VRWorldDropGun Prop)
{
    local int I;
    if (PoseOwner == None || Prop == None || Prop.bDeleteMe || Prop.ReleasedItemId <= 0) return false;
    if (bFreshFrame && Prop.DropOwner == PoseOwner.TargetPawn
        && (Prop.ReleasedItemId == LeftItemId || Prop.ReleasedItemId == RightItemId)) return true;
    for (I = 0; I < Entries.Length; ++I)
        if (Entries[I].Visual != None && SameRelease(Entries[I].Transition, Prop)) return true;
    return false;
}

simulated function bool Accept(NetWorldTransition T, bool bAudio)
{
    local WorldEntry E;
    local int I;
    local vector Root;
    local quat RootQ;
    if (!TransitionReady(T)) return false;
    if (T.Action == 0 && Hub.Closed(T.ReleaseOwner, T.ReleasedItemId, T.ReleaseRequestId)) return true;
    for (I = 0; I < Entries.Length; ++I)
        if (Entries[I].Transition.ReleaseOwner == T.ReleaseOwner
            && Entries[I].Transition.ReleasedItemId == T.ReleasedItemId) break;
    if (I == Entries.Length)
    {
        // At most the eight retained journal events can need a local bridge.
        // Exact closed identities live in the hub's compact per-item stamps.
        if (Entries.Length == 8)
        {
            if (Entries[0].Visual != None) Entries[0].Visual.Destroy();
            Entries.Remove(0, 1);
            I = Entries.Length;
        }
        Entries.AddItem(E);
    }
    else if (Entries[I].Transition.ReleaseRequestId > T.ReleaseRequestId) return true;
    else if (Entries[I].Transition.ReleaseRequestId != T.ReleaseRequestId)
    {
        if (Entries[I].Visual != None) Entries[I].Visual.Destroy();
        Entries[I] = E;
    }
    Entries[I].Transition = T;
    Entries[I].Started = WorldInfo.RealTimeSeconds;
    Entries[I].bClosed = T.Action != 0;
    Entries[I].Prop = Hub.Resolve(T.ReleaseOwner, T.ReleasedItemId, T.ReleaseRequestId);
    if (Entries[I].Visual == None && T.Action != 2)
    {
        Entries[I].Visual = Spawn(class'KF2VRNetWorldVisual', self);
        if (Entries[I].Visual != None && !Entries[I].Visual.InitializeVisual(T))
        { Entries[I].Visual.Destroy(); Entries[I].Visual = None; }
    }
    if (T.Action == 0 && Entries[I].Visual != None && PoseOwner != None)
        Entries[I].Visual.CopySharedPose(PoseOwner.ReleasedWeaponMesh(T.ReleasedItemId));
    if (Entries[I].bClosed && Entries[I].Visual != None)
    {
        Entries[I].Visual.MyMeshComp.ForceUpdate(true);
        if (T.Action == 1 && T.Hand >= 0 && T.Hand <= 1)
        {
            bCatchRoot[T.Hand] = Entries[I].Visual.GetWeaponRoot(Root, RootQ) ? 1 : 0;
            CatchRoot[T.Hand] = Root; CatchRotation[T.Hand] = RootQ;
            bCatchRelative[T.Hand] = 0;
            CatchItemId[T.Hand] = T.ItemId; CatchStarted[T.Hand] = WorldInfo.RealTimeSeconds;
            CatchGeneration[T.Hand] = T.Generation;
        }
        Entries[I].Visual.Destroy(); Entries[I].Visual = None;
    }
    Hub.Remember(T.ReleaseOwner, T.ReleasedItemId, T.ReleaseRequestId, T.Action != 0);
    if (bAudio && T.Action < 2)
        class'VRWorldHandlingAudio'.static.Play(self, T.WeaponClass, T.Action == 1, T.Position);
    return true;
}

simulated function UpdateFrame(NetPoseSnapshot Frame, bool bFresh, const out array<NetWorldTransition> Journal)
{
    local int I;
    local float Now, Delta, Blend;
    local bool bRefresh;
    local VRWorldDropGun P;
    local vector At, X, Y, Z;
    local rotator Facing;
    Now = WorldInfo.RealTimeSeconds;
    Delta = LastUpdate > 0 ? FClamp(Now - LastUpdate, 0, 0.1) : 0.0;
    LastUpdate = Now;
    bRefresh = LeftItemId != Frame.LeftWeapon.ItemId || RightItemId != Frame.RightWeapon.ItemId || bFreshFrame != bFresh;
    LeftItemId = Frame.LeftWeapon.ItemId; RightItemId = Frame.RightWeapon.ItemId; bFreshFrame = bFresh;
    if (Hub == None)
    {
        Hub = class'VRWorldDropObserverHub'.static.Find(self);
        if (Hub == None) return;
        Hub.RegisterObserver(self);
    }
    if (!bInitialized) InitialSerial = Frame.WorldTransitionSerial;
    if (!bHaveSerial || LastSerial != Frame.WorldTransitionSerial)
        for (I = 0; I < Journal.Length; ++I)
        {
            if (class'KF2VRNetTypes'.static.IsNewerSequence(Journal[I].Serial, Frame.WorldTransitionSerial)) continue;
            if (bHaveSerial && !class'KF2VRNetTypes'.static.IsNewerSequence(Journal[I].Serial, LastSerial)) continue;
            if (!Accept(Journal[I], bFresh && class'KF2VRNetTypes'.static.IsNewerSequence(Journal[I].Serial, InitialSerial)))
            {
                if (!bAllowUnresolved && !SupersededUnresolved(I, Frame.WorldTransitionSerial, Journal)) break;
                // Preserve an available exact closed identity even if its art
                // never streamed in; missing art must not resurrect that prop.
                Hub.Remember(Journal[I].ReleaseOwner, Journal[I].ReleasedItemId,
                    Journal[I].ReleaseRequestId, Journal[I].Action != 0);
            }
            LastSerial = Journal[I].Serial; bHaveSerial = true; bRefresh = true;
        }
    bInitialized = true;
    for (I = 0; I < Entries.Length; ++I)
    {
        if (Entries[I].Visual == None) continue;
        P = Entries[I].Prop;
        if (Entries[I].bClosed || !bFresh || Now - Entries[I].Started > 0.75)
        { Entries[I].Visual.Destroy(); Entries[I].Visual = None; bRefresh = true; continue; }
        if (P == None || P.bDeleteMe || P.MyMeshComp == None)
        { Entries[I].Visual.Advance(Delta); continue; }
        if (Entries[I].Blending == 0)
        {
            Entries[I].Blending = Now;
            Entries[I].BlendPosition = Entries[I].Visual.Location;
            Entries[I].BlendRotation = Entries[I].Visual.Rotation;
        }
        At = TransformVector(P.MyMeshComp.LocalToWorld, vect(0,0,0));
        X = TransformNormal(P.MyMeshComp.LocalToWorld, vect(1,0,0));
        Y = TransformNormal(P.MyMeshComp.LocalToWorld, vect(0,1,0));
        Z = TransformNormal(P.MyMeshComp.LocalToWorld, vect(0,0,1));
        Facing = OrthoRotation(Normal(X), Normal(Y), Normal(Z));
        Blend = FClamp((Now - Entries[I].Blending) / 0.065, 0, 1);
        Entries[I].Visual.SetLocation(Entries[I].BlendPosition + (At - Entries[I].BlendPosition) * Blend);
        Entries[I].Visual.SetRotation(RLerp(Entries[I].BlendRotation, Facing, Blend, true));
        Entries[I].Visual.UpdateSharedVisual();
        if (Blend >= 1 && P.SharedVisual != None) P.CopySharedPose(Entries[I].Visual.SharedVisual);
        if (Blend >= 1) { Entries[I].Visual.Destroy(); Entries[I].Visual = None; bRefresh = true; }
    }
    if (Now >= NextCompact)
    {
        NextCompact = Now + 0.1;
        for (I = Entries.Length - 1; I >= 0; --I)
            if (Entries[I].Visual == None && Now - Entries[I].Started > 0.8) Entries.Remove(I, 1);
    }
    if (bRefresh) Hub.Refresh();
}

simulated function BlendCaughtWeapon(KF2VRNetRemoteWeapon W, NetWeaponVisual Visual,
    const out NetPoseSnapshot Frame, vector PawnAt, rotator PawnFacing, vector HandCorrection)
{
    local int Hand, Generation;
    local float Blend;
    local vector Root, RelativeRoot, Start, HandAt;
    local rotator RootAim, HandFacing;
    local quat RelativeQ, StartQ, Q, HandQ, RootQ, TouchQ;
    if (W == None || W.Attachment == None || !W.bPresentationReady) return;
    Hand = W.Hand;
    if (Hand < 0 || Hand > 1 || bCatchRoot[Hand] == 0 || CatchItemId[Hand] != Visual.ItemId) return;
    Blend = FClamp((WorldInfo.RealTimeSeconds - CatchStarted[Hand]) / 0.10, 0, 1);
    if (Blend >= 1) { bCatchRoot[Hand] = 0; return; }
    Blend = Blend * Blend * (3 - 2 * Blend);
    Generation = Hand == 0 ? Frame.Sample.LeftWeaponRootGeneration : Frame.Sample.RightWeaponRootGeneration;
    if ((Frame.Sample.WeaponRootFlags & (Hand == 0 ? 2 : 1)) == 0 || Generation != CatchGeneration[Hand]) return;
    HandAt = Hand == 0 ? Frame.Sample.LeftPosition : Frame.Sample.RightPosition;
    HandFacing = Hand == 0 ? Frame.Sample.LeftRotation : Frame.Sample.RightRotation;
    HandAt = PawnAt + (HandAt >> PawnFacing);
    HandFacing = Normalize(PawnFacing + HandFacing);
    if (class'VRWeaponBlockShapes'.static.PublishesRoot(class'VRWeaponBlockShapes'.static.ProfileClass(Visual.WeaponClass)))
    {
        Root = Hand == 0 ? Frame.Sample.LeftMuzzlePosition : Frame.Sample.MuzzlePosition;
        RootAim = Hand == 0 ? Frame.Sample.LeftMuzzleRotation : Frame.Sample.MuzzleRotation;
    }
    else
    {
        Root = Hand == 0 ? Frame.Sample.LeftWeaponRootPosition : Frame.Sample.RightWeaponRootPosition;
        RootAim = Hand == 0 ? Frame.Sample.LeftWeaponRootRotation : Frame.Sample.RightWeaponRootRotation;
    }
    Root = PawnAt + (Root >> PawnFacing) + HandCorrection;
    RootQ = QuatFromRotator(Normalize(PawnFacing + RootAim));
    HandQ = QuatFromRotator(HandFacing);
    if (bCatchRelative[Hand] == 0)
    {
        // Capture once against the accepted buffered hand, then follow that
        // tracked hand throughout acquire instead of dragging from world space.
        CatchRoot[Hand] = QuatRotateVector(QuatInvert(HandQ), CatchRoot[Hand] - HandAt);
        CatchRotation[Hand] = QuatProduct(QuatInvert(HandQ), CatchRotation[Hand]);
        bCatchRelative[Hand] = 1;
    }
    Q = QuatFromRotator(W.Attachment.Rotation);
    // The attachment already follows its exact optical or measured melee
    // frame. Express that result in the matching generation's 1P held root;
    // never assume the two assets share an identically named root basis.
    RelativeRoot = QuatRotateVector(QuatInvert(RootQ), W.Attachment.Location - Root);
    RelativeQ = QuatProduct(QuatInvert(RootQ), Q);
    TouchQ = QuatProduct(HandQ, CatchRotation[Hand]);
    StartQ = QuatProduct(TouchQ, RelativeQ);
    Start = HandAt + HandCorrection + QuatRotateVector(HandQ, CatchRoot[Hand])
        + QuatRotateVector(TouchQ, RelativeRoot);
    W.Attachment.SetLocation(Start + (W.Attachment.Location - Start) * Blend);
    W.Attachment.SetRotation(QuatToRotator(QuatSlerp(StartQ, Q, Blend, true)));
    W.Attachment.WeapMesh.ForceUpdate(true);
}

simulated event Destroyed()
{
    local int I;
    for (I = 0; I < Entries.Length; ++I) if (Entries[I].Visual != None) Entries[I].Visual.Destroy();
    if (Hub != None) Hub.UnregisterObserver(self);
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bReplicateMovement=false
    bHidden=true
    Physics=PHYS_None
}
