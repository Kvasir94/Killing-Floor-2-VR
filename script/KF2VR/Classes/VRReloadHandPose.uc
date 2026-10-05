// Stock KF2 reload finger motion on one reusable floating hand. Only the
// presentation is blended: this object never owns input, ammo or a grab.
class VRReloadHandPose extends Object;

struct HandFrame
{
    var vector WristInAnchor;
    var quat WristInAnchorQ;
};

var int SourceHand, MirrorSide;
var KFSkeletalMeshComponent Mesh, SampleMesh, FreeMesh;
var Actor ComponentOwner;
var VRHandsBridge Bridge;
var VRFreeHandPose FreePose;
var array<HandFrame> Frames;
// Fifteen wrist-relative rotations per frame, in FingerBone order.
var array<quat> FingerRotations;
var array<SkelControlSingleBone> Controls;
var array<quat> SourceReference, TargetReference, ReleaseFingers, AcquireFingers;
var array<vector> TargetTranslation;
var vector MeshWrist, LastWrist, ReleaseOffset, AcquireOffset;
var quat MeshWristQ, LastWristQ, ReleaseOffsetQ, AcquireOffsetQ;
var int Hand;
var string Key, FailureReason;
var bool bReady, bVisible, bWasHeld, bAcquireSnapshot;
var float TransitionTime, AcquireSeconds, ReleaseSeconds;
// AS2 scales its pickup lerp with distance (itemPickupTimeOverDistanceCurve):
// a hand that closes on a part from further away eases in for longer, so the
// drawn hand never flies to the contact. Fixed on the first held frame.
var float AcquireDistanceSeconds, AcquireMaxSeconds, AcquireDuration;

static function float Smooth(float Alpha)
{
    Alpha = FClamp(Alpha, 0, 1);
    return Alpha * Alpha * (3 - 2 * Alpha);
}

static function name WristBone(int Side)
{
    return Side == 0 ? 'LeftHand_1stP' : 'RightHand_1stP';
}

static function bool ValidQ(quat Q)
{
    return class'VRHandRolePose'.static.ValidQuaternion(Q);
}

// Preserve the target skeleton's own bind pose and segment lengths. This is
// the same anatomical transfer as VRHandRolePose, evaluated for every cached
// stock frame instead of replacing the clip with one frozen fist.
// Mirror is 1 when the target hand is the other side from the stock one.
static function quat TransferFinger(quat SourceAnimation, quat SourceBind,
    quat TargetBind, quat SourceBasis, quat TargetBasis, int Mirror)
{
    local quat Delta;
    if (Mirror == 0) return SourceAnimation;
    Delta = class'VRHandRolePose'.static.MirrorCanonicalRotation(
        QuatProduct(QuatProduct(SourceBasis, SourceAnimation),
            QuatInvert(QuatProduct(SourceBasis, SourceBind))));
    return QuatProduct(QuatProduct(QuatProduct(QuatInvert(TargetBasis), Delta), TargetBasis), TargetBind);
}

// Convert the source contact through the controller's anatomical frame before
// mirroring. A naked world-space wrist reflection puts the opposite hand on
// the wrong side of angled shells and charging handles.
static function AnchorWrist(vector AnchorPosition, quat AnchorQ,
    vector SourcePosition, quat SourceQ, quat SourceBasis, quat TargetBasis,
    int Mirror, out vector Position, out quat Rotation)
{
    local vector Offset;
    local quat OffsetQ;
    Offset = QuatRotateVector(SourceBasis,
        QuatRotateVector(QuatInvert(SourceQ), AnchorPosition - SourcePosition));
    OffsetQ = QuatProduct(SourceBasis, QuatProduct(QuatInvert(SourceQ), AnchorQ));
    if (Mirror == 1)
    {
        Offset.Y = -Offset.Y;
        OffsetQ = class'VRHandRolePose'.static.MirrorCanonicalRotation(OffsetQ);
    }
    Position = -QuatRotateVector(QuatInvert(OffsetQ), Offset);
    Rotation = QuatProduct(QuatInvert(OffsetQ), TargetBasis);
}

function AnimNodeSequence SetSequence(KFSkeletalMeshComponent M, Actor OwnerActor)
{
    local AnimTree Template;
    local AnimNodeSequence Sequence;
    Template = new(OwnerActor) class'AnimTree';
    Sequence = new(Template) class'AnimNodeSequence';
    Sequence.NodeName = 'VRReloadHandStock';
    Sequence.bNoNotifies = true;
    Sequence.bPlaying = false;
    Template.Children[0].Anim = Sequence;
    Template.Children[0].Weight = 1;
    M.SetAnimTreeTemplate(Template);
    return AnimNodeSequence(M.FindAnimNode('VRReloadHandStock'));
}

function Configure(KFSkeletalMeshComponent M)
{
    M.bUpdateSkelWhenNotRendered = true;
    M.bTickAnimNodesWhenNotRendered = false;
    M.bIgnoreControllersWhenNotRendered = false;
    M.CastShadow = false;
    M.bCastDynamicShadow = false;
    M.SetAbsolute(true, true, true);
    M.SetTranslation(vect(0,0,0));
    M.SetRotation(rot(0,0,0));
    M.SetScale(1);
    M.SetHidden(true);
}

function Pose(KFSkeletalMeshComponent M, AnimNodeSequence Sequence, float Time)
{
    Sequence.SetPosition(Time, false);
    Sequence.bPlaying = false;
    M.ForceSkelUpdate();
    M.ForceUpdate(false);
}

function bool Fail(string Reason)
{
    FailureReason = Reason;
    bReady = false;
    Frames.Length = 0;
    FingerRotations.Length = 0;
    Cancel();
    if (SampleMesh != None) SampleMesh.DetachFromAny();
    return false;
}

// Asset-only entry point also used by the SDK commandlet. Sampling components
// remain private, at identity and notify-free; the live gun is never posed.
function bool Cache(Actor OwnerActor, SkeletalMesh FloatingMesh,
    KFSkeletalMeshComponent GunMesh, name Anim, name AnchorBone,
    float EntryTime, float EndTime, int TargetHand, quat SourceBasis, quat TargetBasis,
    optional bool bPreservePresentation, optional int InSourceHand)
{
    local AnimNodeSequence Sequence, SampleSequence;
    local AnimTree Template;
    local AnimTree.SkelControlListHead Link;
    local SkelControlSingleBone Control;
    local int I, F, J, FrameIndex, Count;
    local name SourceBone, TargetBone, ParentBone;
    local quat SourceWristQ, TargetWristQ, FingerQ;
    local HandFrame Frame;
    local float Time;
    local bool bResumePresentation;
    local array<quat> PreviousFingers;
    local vector PreviousWrist;
    local quat PreviousWristQ;

    // Switching from the carried magazine to the stock action grip must
    // begin at the hand the player can currently see. Keep this snapshot
    // local until the entire new clip passes validation; failure still hides
    // immediately, and a different anatomical hand never inherits it.
    bResumePresentation = bPreservePresentation && bReady && bVisible && Hand == TargetHand
        && ComponentOwner == OwnerActor && Controls.Length == 15;
    if (bResumePresentation)
    {
        PreviousWrist = LastWrist;
        PreviousWristQ = LastWristQ;
        for (I = 0; I < Controls.Length; ++I)
            PreviousFingers.AddItem(QuatFromRotator(Controls[I].BoneRotation));
    }
    bReady = false;
    FailureReason = "";
    Frames.Length = 0; FingerRotations.Length = 0; Controls.Length = 0;
    SourceReference.Length = 0; TargetReference.Length = 0; TargetTranslation.Length = 0;
    Cancel();
    if (OwnerActor == None || FloatingMesh == None || GunMesh == None || GunMesh.SkeletalMesh == None
        || TargetHand < 0 || TargetHand > 1 || !ValidQ(SourceBasis) || !ValidQ(TargetBasis))
        return Fail("missing-rig");
    if (EntryTime != EntryTime || EndTime != EndTime || EntryTime < 0 || EndTime < EntryTime
        || Anim == '' || AnchorBone == '') return Fail("invalid-clip-range");
    ComponentOwner = OwnerActor;
    Hand = TargetHand;
    // The stock hand the clip animates (the Frost Fang loads with its right).
    SourceHand = Clamp(InSourceHand, 0, 1);
    MirrorSide = Hand != SourceHand ? 1 : 0;
    if (Mesh == None) Mesh = new(OwnerActor) class'KFSkeletalMeshComponent';
    Mesh.DetachFromAny();
    Mesh.SetSkeletalMesh(FloatingMesh);
    Mesh.AnimSets = GunMesh.AnimSets;
    Configure(Mesh);
    Sequence = SetSequence(Mesh, OwnerActor);
    OwnerActor.AttachComponent(Mesh);
    Sequence = AnimNodeSequence(Mesh.FindAnimNode('VRReloadHandStock'));
    if (Sequence == None) return Fail("missing-hand-sequence");
    Mesh.SetForceRefPose(true);
    Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(false);
    Mesh.UnHideBoneByName(WristBone(0)); Mesh.UnHideBoneByName(WristBone(1));
    Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(false);
    if (Mesh.MatchRefBone(WristBone(SourceHand)) < 0 || Mesh.MatchRefBone(WristBone(Hand)) < 0)
        return Fail("missing-wrist");
    SourceWristQ = Mesh.GetBoneQuaternion(WristBone(SourceHand));
    TargetWristQ = Mesh.GetBoneQuaternion(WristBone(Hand));
    if (!ValidQ(SourceWristQ) || !ValidQ(TargetWristQ)) return Fail("invalid-bind-wrist");
    for (F = 0; F < 5; ++F)
        for (J = 1; J <= 3; ++J)
        {
            SourceBone = class'VRHandRolePose'.static.FingerBone(SourceHand, F, J);
            TargetBone = class'VRHandRolePose'.static.FingerBone(Hand, F, J);
            if (Mesh.MatchRefBone(SourceBone) < 0 || Mesh.MatchRefBone(TargetBone) < 0)
                return Fail("missing-finger");
            ParentBone = Mesh.GetParentBone(TargetBone);
            if (ParentBone == '' || Mesh.MatchRefBone(ParentBone) < 0) return Fail("missing-finger-parent");
            SourceReference.AddItem(QuatProduct(QuatInvert(SourceWristQ), Mesh.GetBoneQuaternion(SourceBone)));
            TargetReference.AddItem(QuatProduct(QuatInvert(TargetWristQ), Mesh.GetBoneQuaternion(TargetBone)));
            TargetTranslation.AddItem(QuatRotateVector(QuatInvert(Mesh.GetBoneQuaternion(ParentBone)),
                Mesh.GetBoneLocation(TargetBone) - Mesh.GetBoneLocation(ParentBone)));
        }
    Mesh.SetForceRefPose(false);
    Sequence.SetAnim(Anim);
    if (Sequence.AnimSeq == None || EndTime > Sequence.AnimSeq.SequenceLength)
        return Fail("missing-hand-clip");

    if (SampleMesh == None) SampleMesh = new(OwnerActor) class'KFSkeletalMeshComponent';
    SampleMesh.DetachFromAny();
    SampleMesh.SetSkeletalMesh(GunMesh.SkeletalMesh);
    SampleMesh.AnimSets = GunMesh.AnimSets;
    Configure(SampleMesh);
    SampleSequence = SetSequence(SampleMesh, OwnerActor);
    OwnerActor.AttachComponent(SampleMesh);
    SampleSequence = AnimNodeSequence(SampleMesh.FindAnimNode('VRReloadHandStock'));
    if (SampleSequence == None || SampleMesh.MatchRefBone(AnchorBone) < 0
        || SampleMesh.MatchRefBone(WristBone(SourceHand)) < 0) return Fail("missing-anchor");
    SampleSequence.SetAnim(Anim);
    if (SampleSequence.AnimSeq == None || EndTime > SampleSequence.AnimSeq.SequenceLength)
        return Fail("missing-anchor-clip");
    Count = EndTime == EntryTime ? 1 : 17;
    for (FrameIndex = 0; FrameIndex < Count; ++FrameIndex)
    {
        Time = EntryTime;
        if (Count > 1) Time += (EndTime - EntryTime) * float(FrameIndex) / float(Count - 1);
        Pose(Mesh, Sequence, Time);
        Pose(SampleMesh, SampleSequence, Time);
        AnchorWrist(SampleMesh.GetBoneLocation(AnchorBone), SampleMesh.GetBoneQuaternion(AnchorBone),
            SampleMesh.GetBoneLocation(WristBone(SourceHand)), SampleMesh.GetBoneQuaternion(WristBone(SourceHand)),
            SourceBasis, TargetBasis, MirrorSide, Frame.WristInAnchor, Frame.WristInAnchorQ);
        if (!ValidQ(Frame.WristInAnchorQ) || VSize(Frame.WristInAnchor) != VSize(Frame.WristInAnchor))
            return Fail("invalid-contact");
        Frames.AddItem(Frame);
        SourceWristQ = Mesh.GetBoneQuaternion(WristBone(SourceHand));
        I = 0;
        for (F = 0; F < 5; ++F)
            for (J = 1; J <= 3; ++J)
            {
                SourceBone = class'VRHandRolePose'.static.FingerBone(SourceHand, F, J);
                FingerQ = TransferFinger(QuatProduct(QuatInvert(SourceWristQ), Mesh.GetBoneQuaternion(SourceBone)),
                    SourceReference[I], TargetReference[I], SourceBasis, TargetBasis, MirrorSide);
                if (!ValidQ(FingerQ)) return Fail("invalid-finger-pose");
                FingerRotations.AddItem(FingerQ);
                ++I;
            }
    }
    SampleMesh.DetachFromAny();
    Pose(Mesh, Sequence, EntryTime);
    MeshWrist = Mesh.GetBoneLocation(WristBone(Hand));
    MeshWristQ = Mesh.GetBoneQuaternion(WristBone(Hand));
    if (!ValidQ(MeshWristQ)) return Fail("invalid-render-wrist");

    // Build once per cached clip. Absolute wrist-relative controls preserve
    // the stock finger silhouette while keeping the target hand's anatomy.
    Template = new(OwnerActor) class'AnimTree';
    Sequence = new(Template) class'AnimNodeSequence';
    Sequence.NodeName = 'VRReloadHandStock';
    Sequence.bNoNotifies = true; Sequence.bPlaying = false;
    Template.Children[0].Anim = Sequence; Template.Children[0].Weight = 1;
    I = 0;
    for (F = 0; F < 5; ++F)
        for (J = 1; J <= 3; ++J)
        {
            TargetBone = class'VRHandRolePose'.static.FingerBone(Hand, F, J);
            Control = new(Template) class'SkelControlSingleBone';
            Control.ControlName = name("VRReloadFinger_" $ TargetBone);
            Control.bApplyRotation = true; Control.bAddRotation = false;
            Control.BoneRotationSpace = BCS_OtherBoneSpace;
            Control.RotationSpaceBoneName = WristBone(Hand);
            Control.BoneRotation = QuatToRotator(FingerRotations[I]);
            Control.bApplyTranslation = true; Control.bAddTranslation = false;
            Control.BoneTranslationSpace = BCS_ParentBoneSpace;
            Control.BoneTranslation = TargetTranslation[I];
            Control.bIgnoreWhenNotRendered = false;
            Control.ControlStrength = 1; Control.StrengthTarget = 1;
            Link.BoneName = TargetBone; Link.ControlHead = Control;
            Template.SkelControlLists.AddItem(Link);
            ++I;
        }
    Mesh.SetAnimTreeTemplate(Template);
    Sequence = AnimNodeSequence(Mesh.FindAnimNode('VRReloadHandStock'));
    if (Sequence == None) return Fail("missing-render-sequence");
    Sequence.SetAnim(Anim);
    Pose(Mesh, Sequence, EntryTime);
    for (F = 0; F < 5; ++F)
        for (J = 1; J <= 3; ++J)
        {
            Control = SkelControlSingleBone(Mesh.FindSkelControl(name("VRReloadFinger_"
                $ class'VRHandRolePose'.static.FingerBone(Hand, F, J))));
            if (Control == None) return Fail("missing-render-control");
            Controls.AddItem(Control);
        }
    Mesh.HideBoneByName(WristBone(1 - Hand), PBO_None);
    Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(false);
    bReady = Frames.Length == Count && FingerRotations.Length == Count * 15 && Controls.Length == 15;
    if (bReady && bResumePresentation)
    {
        for (I = 0; I < Controls.Length; ++I)
            Controls[I].BoneRotation = QuatToRotator(PreviousFingers[I]);
        ApplyTransform(PreviousWrist, PreviousWristQ, 1);
        // The next Place/Start captures these restored angles and correction
        // as its acquisition endpoint. Input ownership belongs to the caller.
        bWasHeld = false;
    }
    return bReady;
}

function bool Build(VRHandsBridge B, KFSkeletalMeshComponent GunMesh, name Anim,
    name AnchorBone, float EntryTime, float EndTime, int TargetHand, optional int StockHand)
{
    local string NewKey;
    if (B == None || B.Arms == None || B.FreeHandPose == None || !B.FreeHandPose.bReady
        || GunMesh == None || GunMesh.SkeletalMesh == None || TargetHand < 0 || TargetHand > 1)
        return Fail("missing-runtime-rig");
    Bridge = B;
    FreeMesh = B.Arms;
    FreePose = B.FreeHandPose;
    NewKey = string(B.FloatingHandsMesh) $ "/" $ GunMesh.SkeletalMesh $ "/" $ Anim $ "/" $ AnchorBone $ "/"
        $ EntryTime $ "/" $ EndTime $ "/" $ TargetHand $ "/" $ StockHand;
    if (NewKey == Key && bReady)
    {
        Mesh.SetMaterial(0, B.GetFloatingHandsMaterial());
        return true;
    }
    Key = "";
    if (!Cache(B, B.FloatingHandsMesh, GunMesh, Anim, AnchorBone, EntryTime, EndTime,
        TargetHand, B.FreeHandPose.WristBasis[Clamp(StockHand, 0, 1)], B.FreeHandPose.WristBasis[TargetHand], true,
        StockHand)) return false;
    Mesh.SetMaterial(0, B.GetFloatingHandsMaterial());
    Mesh.SetLightingChannels(B.Arms.LightingChannels);
    B.UseWorldRendering(Mesh);
    Key = NewKey;
    return true;
}

function GetFrame(float Progress, out vector Position, out quat Rotation)
{
    local int Index;
    local float Frame, Fraction;
    Position = vect(0,0,0); Rotation = QuatFromRotator(rot(0,0,0));
    if (Frames.Length == 0) return;
    if (Frames.Length == 1) { Position = Frames[0].WristInAnchor; Rotation = Frames[0].WristInAnchorQ; return; }
    Frame = FClamp(Progress, 0, 1) * float(Frames.Length - 1);
    Index = Min(int(Frame), Frames.Length - 2);
    Fraction = Frame - float(Index);
    Position = Frames[Index].WristInAnchor * (1 - Fraction) + Frames[Index + 1].WristInAnchor * Fraction;
    Rotation = QuatSlerp(Frames[Index].WristInAnchorQ, Frames[Index + 1].WristInAnchorQ, Fraction, true);
}

function quat GetFinger(int Joint, float Progress)
{
    local int Index;
    local float Frame;
    if (Joint < 0 || Joint >= 15 || Frames.Length == 0 || FingerRotations.Length != Frames.Length * 15)
        return QuatFromRotator(rot(0,0,0));
    if (Frames.Length == 1) return FingerRotations[Joint];
    Frame = FClamp(Progress, 0, 1) * float(Frames.Length - 1);
    Index = Min(int(Frame), Frames.Length - 2);
    return QuatSlerp(FingerRotations[Index * 15 + Joint], FingerRotations[(Index + 1) * 15 + Joint],
        Frame - float(Index), true);
}

function ApplyTransform(vector Position, quat Rotation, float Scale)
{
    local quat ComponentQ;
    ComponentQ = QuatProduct(Rotation, QuatInvert(MeshWristQ));
    Mesh.SetRotation(QuatToRotator(ComponentQ));
    Mesh.SetScale(Scale);
    Mesh.SetTranslation(Position - QuatRotateVector(ComponentQ, MeshWrist * Scale));
    Mesh.SetHidden(false);
    Mesh.ForceSkelUpdate(); Mesh.ForceUpdate(true);
    LastWrist = Position; LastWristQ = Rotation;
    bVisible = true;
}

// Also lets asset checks evaluate the actual controls, positive mesh scale,
// wrist placement and target bone lengths without spawning a gameplay actor.
function bool PoseCached(float Progress, vector Position, quat Rotation, float Scale)
{
    local int I;
    if (!bReady || Mesh == None || Scale <= 0 || !ValidQ(Rotation)) return false;
    for (I = 0; I < Controls.Length; ++I)
        Controls[I].BoneRotation = QuatToRotator(GetFinger(I, Progress));
    ApplyTransform(Position, Rotation, Scale);
    return true;
}

function quat FreeFinger(int Joint)
{
    local name Bone;
    local quat Result, BindLocal;
    local int First, I;
    // Hiding the live wrist also zero-scales its descendants. Read its
    // existing curl controls rather than extracting rotations from those
    // collapsed bone matrices. No new finger animation is invented here.
    if (FreePose != None && FreePose.bReady && FreePose.Joints.Length >= (Hand + 1) * 15)
    {
        First = (Joint / 3) * 3;
        Result = QuatFromRotator(rot(0,0,0));
        for (I = First; I <= Joint; ++I)
        {
            BindLocal = TargetReference[I];
            if (I > First) BindLocal = QuatProduct(QuatInvert(TargetReference[I - 1]), BindLocal);
            Result = QuatProduct(Result, BindLocal);
            if (FreePose.Joints[Hand * 15 + I].Control != None)
                Result = QuatProduct(Result, QuatFromRotator(FreePose.Joints[Hand * 15 + I].Control.BoneRotation));
        }
        return Result;
    }
    if (FreeMesh == None) return TargetReference[Joint];
    Bone = class'VRHandRolePose'.static.FingerBone(Hand, Joint / 3, Joint % 3 + 1);
    return QuatProduct(QuatInvert(FreeMesh.GetBoneQuaternion(WristBone(Hand))),
        FreeMesh.GetBoneQuaternion(Bone));
}

// Start/reacquire needs no mesh rebuild. All interpolation uses absolute game
// time so a late-pose or second-eye refresh cannot advance the transition.
function Start(float Time)
{
    local int I;
    AcquireFingers.Length = 0;
    bAcquireSnapshot = bVisible;
    if (bAcquireSnapshot)
        for (I = 0; I < Controls.Length; ++I)
            AcquireFingers.AddItem(QuatFromRotator(Controls[I].BoneRotation));
    TransitionTime = Time;
    bWasHeld = true;
    ReleaseFingers.Length = 0;
}

function Cancel()
{
    bVisible = false;
    bWasHeld = false;
    bAcquireSnapshot = false;
    ReleaseFingers.Length = 0;
    AcquireFingers.Length = 0;
    if (Mesh != None) Mesh.SetHidden(true);
}

// Returning true hides only the duplicate free-hand rendering. It must never
// extend gameplay hand ownership after release; a new action cancels it.
function bool Place(float Time, bool bHeld, float GuideFraction, float GuideBlend,
    vector TrackedWristPosition, quat TrackedWristQ, vector AnchorPosition, quat AnchorQ, float Scale)
{
    local int I;
    local float Alpha;
    local vector Position, AuthoredPosition;
    local quat Rotation, AuthoredQ, FingerQ;
    if (!bReady || (FreeMesh == None && FreePose == None) || Mesh == None || FreeMesh == Mesh
        || Time != Time || Scale != Scale || Scale <= 0 || !ValidQ(TrackedWristQ)
        || !ValidQ(AnchorQ)) { Cancel(); return false; }
    if (bHeld)
    {
        if (!bWasHeld) Start(Time);
        if (bAcquireSnapshot)
        {
            AcquireOffset = QuatRotateVector(QuatInvert(TrackedWristQ), LastWrist - TrackedWristPosition);
            AcquireOffsetQ = QuatProduct(QuatInvert(TrackedWristQ), LastWristQ);
            bAcquireSnapshot = false;
        }
        GetFrame(GuideFraction, AuthoredPosition, AuthoredQ);
        AuthoredPosition = AnchorPosition + QuatRotateVector(AnchorQ, AuthoredPosition * Scale);
        AuthoredQ = QuatProduct(AnchorQ, AuthoredQ);
        if (Time == TransitionTime)
            AcquireDuration = FClamp(AcquireSeconds
                + AcquireDistanceSeconds * VSize(TrackedWristPosition - AuthoredPosition) * FClamp(GuideBlend, 0, 1),
                AcquireSeconds, AcquireMaxSeconds);
        Alpha = Smooth((Time - TransitionTime) / FMax(AcquireDuration, 0.001));
        GuideBlend = FClamp(GuideBlend, 0, 1) * Alpha;
        Position = TrackedWristPosition;
        Rotation = TrackedWristQ;
        // Reacquiring during the short cosmetic release starts at the visible
        // pose, so repeated grabs do not snap the fingers or wrist to neutral.
        if (AcquireFingers.Length == Controls.Length)
        {
            Position += QuatRotateVector(TrackedWristQ, AcquireOffset * (1 - Alpha));
            Rotation = QuatProduct(TrackedWristQ,
                QuatSlerp(AcquireOffsetQ, QuatFromRotator(rot(0,0,0)), Alpha, true));
        }
        Position = Position * (1 - GuideBlend) + AuthoredPosition * GuideBlend;
        Rotation = QuatSlerp(Rotation, AuthoredQ, GuideBlend, true);
        for (I = 0; I < Controls.Length; ++I)
        {
            FingerQ = AcquireFingers.Length == Controls.Length ? AcquireFingers[I] : FreeFinger(I);
            Controls[I].BoneRotation = QuatToRotator(QuatSlerp(FingerQ, GetFinger(I, GuideFraction), Alpha, true));
        }
    }
    else
    {
        if (!bVisible) return false;
        // A successful clip-cache change can preserve a visible pose before
        // another hold starts. It still needs its own first release snapshot.
        if (bWasHeld || ReleaseFingers.Length != Controls.Length)
        {
            bWasHeld = false;
            TransitionTime = Time;
            ReleaseOffset = QuatRotateVector(QuatInvert(TrackedWristQ), LastWrist - TrackedWristPosition);
            ReleaseOffsetQ = QuatProduct(QuatInvert(TrackedWristQ), LastWristQ);
            ReleaseFingers.Length = 0;
            for (I = 0; I < Controls.Length; ++I)
                ReleaseFingers.AddItem(QuatFromRotator(Controls[I].BoneRotation));
        }
        Alpha = Smooth((Time - TransitionTime) / FMax(ReleaseSeconds, 0.001));
        if (Alpha >= 1) { Cancel(); return false; }
        // Follow the tracked hand during release, decaying only the previous
        // authored correction. Moving the gun cannot drag a released hand.
        Position = TrackedWristPosition + QuatRotateVector(TrackedWristQ, ReleaseOffset * (1 - Alpha));
        Rotation = QuatProduct(TrackedWristQ,
            QuatSlerp(ReleaseOffsetQ, QuatFromRotator(rot(0,0,0)), Alpha, true));
        for (I = 0; I < Controls.Length; ++I)
        {
            FingerQ = QuatSlerp(ReleaseFingers[I], FreeFinger(I), Alpha, true);
            Controls[I].BoneRotation = QuatToRotator(FingerQ);
        }
    }
    // Match the neutral and bound floating hands' fixed physical size. Gun
    // scale affects the authored contact offset, not the player's anatomy.
    ApplyTransform(Position, Rotation, 1);
    return true;
}

function Destroy()
{
    Cancel();
    if (Mesh != None) Mesh.DetachFromAny();
    if (SampleMesh != None) SampleMesh.DetachFromAny();
    Mesh = None; SampleMesh = None; FreeMesh = None; FreePose = None;
    Frames.Length = 0; FingerRotations.Length = 0; Controls.Length = 0;
    SourceReference.Length = 0; TargetReference.Length = 0; TargetTranslation.Length = 0;
    bReady = false; Key = "";
}

defaultproperties
{
    AcquireSeconds=0.08
    AcquireDistanceSeconds=0.01
    AcquireMaxSeconds=0.25
    AcquireDuration=0.08
    ReleaseSeconds=0.10
}
