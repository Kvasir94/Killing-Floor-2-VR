// Tracking controls on the remote pawn's existing, instanced stock graph.
// No duplicate body, animation graph, physics asset or locomotion simulation.
class KF2VRNetRemoteBody extends VRThirdPersonRig dependsOn(KF2VRNetTypes);

// Stock upper-body layers that fight the tracked rig, saved per instance node
// so ReleaseRig and special moves hand the pawn back exactly as found.
struct StockAimNode { var AnimNodeAimOffset Node; var bool bForce; var EAnimAimDir Dir; };
struct StockMask { var AnimNode_MultiBlendPerBone Node; var int Index; var bool bRules; var float Weight; };
struct StockControl { var SkelControlBase Control; var bool bMetadata; var float Strength, Target; };
// One finger segment: reference rotation relative to its parent and the
// bone-local axes that bend it toward the palm (Swing: thumb root opposition).
struct FingerSegment { var SkelControlSingleBone Control; var quat Rest; var vector Axis, Swing; var int Hand, Finger, Joint; };

// Torso-from-head tunables (headset re-tune).
var float ChestYawLimit;      // degrees the chest may turn from the hips (soft limit)
var float ChestYawBlendTime;  // seconds, chest yaw smoothing
var float SpineSplit;         // Spine1 share of the chest yaw and lean; Spine2 takes the rest
var float SpineBendLimit;     // degrees of Spine1+Spine2 lean toward the tracked head
var float PelvisLift;         // UU the Spine bone may rise or sink (waist stretch)
var float PelvisShift;        // UU the Spine bone may slide horizontally (feet stay on locomotion)
var float NeckReach;          // UU of final neck shift for what the spine cannot reach
var float SpineBlendTime;     // seconds, tracked head offset smoothing
var vector HeadEyeOffset;     // tracked eye point from the head bone, in head axes
// Finger curl tunables (headset re-tune): degrees at full curl, by segment.
var float FingerDegrees[3];   // index..pinky proximal, middle, distal
var float ThumbDegrees[3];    // thumb segments, toward the palm centre
var float ThumbSwing;         // thumb root opposition across the palm
var float TriggerFingerCurl;  // share of the curl the index keeps around a held weapon
var float FingerBlendTime;    // seconds, finger curl smoothing
// Residual stock upper-body clip weight: keeps the slot relevant (3P reload sounds).
var float StockUpperWeight;

var KF2VRNetPose PoseOwner;
var private KFPawn_Human RigPawn;
var private SkeletalMeshComponent BodyMesh;
var private AnimTree BodyTree;
// 0 head, 1-4 arms/wrists, 5-6 shoulders, 7-8 twist, 9-12 spine, 13+ fingers.
var private SkelControlBase Controls[43];
var private array<FingerSegment> Fingers;
var private vector Curl[2];   // per hand: X fingers, Y index, Z thumb (0..1)
var private byte HandPose[2];
var private SkelControlLimb Arm[2];
var private SkelControlSingleBone Wrist[2], Head;
var private SkelControlSingleBone ShoulderFollow[2];
var private SkelControl_TwistBone ForearmTwist[2];
var private vector ShoulderOffset[2];
var private float LastBodyTime;
var private name ShoulderBone[2];
var private float ArmLength[2];
var private quat WristBasis[2], HeadBasis, SpineRest[2];
var private EAxis ReferenceBoneAxis[2], ReferenceJointAxis[2];
var private int ReferenceInvertBone[2], ReferenceInvertJoint[2];
var private bool bSavedPooling;
var private vector WantedHand[2], ReachableHand[2];
var private rotator WantedWrist[2];
var private byte Tracking;
var private float NextLog;
// A teammate's charged fist, lit on its own hand bone.
var private PointLightComponent FistGlow[2];
var private PointLightComponent FistGlowTemplate;
var private array<StockAimNode> StockAim;
var private array<StockMask> StockMasks;
var private array<StockControl> StockControls;
var private bool bStockSuppressed;
var private SkelControlSingleBone Pelvis, SpineBend[2], NeckShift;
var private vector PelvisOffset, NeckOffset, HeadError, HeadTarget, BendAxis;
var private float ChestYaw, BendAngle;

simulated function bool IsReady() { return BodyTree != None; }

simulated function bool IsTrackedPoseReady()
{
    local int I;
    if (BodyTree == None || Tracking == 0) return false;
    for (I = 0; I < 2; ++I)
        if ((Tracking & (2 << I)) != 0 && (Arm[I].ControlStrength < 0.99 || Wrist[I].ControlStrength < 0.99))
            return false;
    return true;
}

simulated function bool UpdateLocalTracking(VRHandsBridge B)
{
    local NetPoseSnapshot Frame;
    local rotator Basis, Aim;
    local vector WristPosition;
    local VRWeaponRuntime R;
    local int I, LocalCurl, Pose;
    if (B == None || LocalPawn == None || B.Human != LocalPawn || B.NativeConnection <= 0
        || B.NativeHeadTracked == 0 || B.NativeValidMask != 3) return false;
    Basis.Yaw = LocalPawn.Rotation.Yaw;
    Frame.Sample.TrackingFlags = 7;
    Frame.Sample.HeadPosition = (B.HeadPosition - LocalPawn.Location) << Basis;
    Frame.Sample.HeadRotation = Normalize(B.NativeHeadRotation - Basis);
    Frame.Sample.LeftPosition = (B.LeftPosition - LocalPawn.Location) << Basis;
    Frame.Sample.LeftRotation = Normalize(B.LeftRotation - Basis);
    Frame.Sample.RightPosition = (B.RightPosition - LocalPawn.Location) << Basis;
    Frame.Sample.RightRotation = Normalize(B.RightRotation - Basis);
    for (I = 0; I < 2; ++I)
    {
        R = None;
        if (B.HandInventory != None && B.HandInventory.Registry != None)
        {
            R = B.HandInventory.Registry.GetPrimary(I);
            if (R == None) R = B.HandInventory.Registry.GetSupport(I);
        }
        LocalCurl = B.FreeHandPose != None ? Clamp(Round(B.FreeHandPose.Amount[I] * 15), 0, 15) : 0;
        Pose = R != None ? 79 : (LocalCurl <= 2 ? (48 | LocalCurl) : LocalCurl);
        if (I == 0) Frame.Sample.LeftHandPose = Pose;
        else Frame.Sample.RightHandPose = Pose;
        if (R != None && R.Presenter != None && R.Presenter.Arms != None
            && R.Presenter.FreeHandPose != None && R.Presenter.FreeHandPose.bReady && R.NativePoseReady == 1)
        {
            WristPosition = (R.Presenter.RenderedHandPosition(I) - LocalPawn.Location) << Basis;
            Aim = Normalize(QuatToRotator(QuatProduct(R.Presenter.RenderedHandRotation(I),
                QuatInvert(R.Presenter.FreeHandPose.WristBasis[I]))) - Basis);
            Frame.Sample.PresentationFlags = Frame.Sample.PresentationFlags | (4 << I);
            if (I == 0) { Frame.Sample.LeftWristPosition = WristPosition; Frame.Sample.LeftWristRotation = Aim; }
            else { Frame.Sample.RightWristPosition = WristPosition; Frame.Sample.RightWristRotation = Aim; }
        }
    }
    if (!class'KF2VRNetTypes'.static.IsValidSample(Frame.Sample)) return false;
    UpdateBody(Frame, true);
    return IsReady();
}

// Map an anatomical frame (fingers forward, thumb up) onto this character's
// own wrist axes. Sampling the reference rig avoids animation/left-right axis
// assumptions and preserves the first-person grip orientation during retarget.
simulated function bool BindWristReference()
{
    local KFSkeletalMeshComponent Reference;
    local int I;
    local string Prefix;
    local name Middle, Index, Pinky, ElbowBone, UpperBone;
    local int Invert;
    local vector Shoulder, Elbow, Hand, Hinge, Direction;
    local vector Forward, Up, Side;
    local bool Valid;
    Reference = new(self) class'KFSkeletalMeshComponent';
    Reference.SetSkeletalMesh(BodyMesh.SkeletalMesh);
    Reference.SetHidden(true);
    Reference.SetForceRefPose(true);
    Reference.bUpdateSkelWhenNotRendered = true;
    AttachComponent(Reference);
    Reference.ForceSkelUpdate();
    Reference.ForceUpdate(false);
    Valid = true;
    for (I = 0; I < 2; ++I)
    {
        Prefix = I == 0 ? "LeftHand" : "RightHand";
        Middle = name(Prefix $ "Middle1"); Index = name(Prefix $ "Index1"); Pinky = name(Prefix $ "Pinky1");
        if (Reference.MatchRefBone(Middle) < 0 || Reference.MatchRefBone(Index) < 0
            || Reference.MatchRefBone(Pinky) < 0) { Valid = false; break; }
        Forward = Normal(Reference.GetBoneLocation(Middle) - Reference.GetBoneLocation(HandBone(I)));
        Up = Reference.GetBoneLocation(Index) - Reference.GetBoneLocation(Pinky);
        Up = Normal(Up - Forward * (Up dot Forward));
        Side = Normal(Up cross Forward);
        Up = Normal(Forward cross Side);
        if (VSizeSq(Forward) < 0.9 || VSizeSq(Up) < 0.9) { Valid = false; break; }
        WristBasis[I] = QuatProduct(QuatInvert(QuatFromRotator(OrthoRotation(Forward, Side, Up))),
            Reference.GetBoneQuaternion(HandBone(I)));
        // A limb's hinge is an anatomical bind axis, not the desired elbow
        // pole. Deriving it from that target flips the left arm's local Z
        // and rolls its upper arm 180 degrees through the sleeve.
        ElbowBone = Reference.GetParentBone(HandBone(I));
        UpperBone = Reference.GetParentBone(ElbowBone);
        Shoulder = Reference.GetBoneLocation(UpperBone);
        Elbow = Reference.GetBoneLocation(ElbowBone);
        Hand = Reference.GetBoneLocation(HandBone(I));
        Hinge = Normal((Hand - Shoulder) cross (Elbow - Shoulder));
        if (VSizeSq(Hinge) < 0.9) { Valid = false; break; }
        Direction = QuatRotateVector(QuatInvert(Reference.GetBoneQuaternion(UpperBone)), Normal(Elbow - Shoulder));
        ReferenceBoneAxis[I] = BoneAxis(Direction, Invert);
        ReferenceInvertBone[I] = Invert;
        Direction = QuatRotateVector(QuatInvert(Reference.GetBoneQuaternion(ElbowBone)), Hinge);
        ReferenceJointAxis[I] = BoneAxis(Direction, Invert, int(ReferenceBoneAxis[I]));
        ReferenceInvertJoint[I] = Invert;
        // Up is the thumb side, so Side faces the palm on a left hand.
        BindFingers(Reference, I, I == 0 ? Side : -Side);
    }
    for (I = 0; I < 2; ++I)
    {
        UpperBone = I == 0 ? 'Spine1' : 'Spine2';
        SpineRest[I] = QuatProduct(QuatInvert(Reference.GetBoneQuaternion('Root')),
            Reference.GetBoneQuaternion(UpperBone));
    }
    // Bind from the authored reference head, not an unevaluated live pose.
    // The live bone can still be in reference space when the pawn already has
    // a spawn yaw. Subtracting that yaw would bake it into every tracked pose.
    HeadBasis = QuatProduct(QuatFromRotator(BodyMesh.Rotation),
        QuatProduct(QuatInvert(QuatFromRotator(Rotation)), Reference.GetBoneQuaternion('head')));
    Reference.DetachFromAny();
    return Valid;
}

// Curl axes measured on the reference pose, like the wrist basis: each
// segment bends toward the palm (the thumb toward the palm centre) about its
// own bone-local axis, from its authored rest rotation. Missing fingers skip.
simulated function BindFingers(KFSkeletalMeshComponent Reference, int I, vector Palm)
{
    local int Finger, Joint;
    local string Prefix;
    local name Bone;
    local vector Position, Direction, Toward, Axis;
    local quat Q;
    local FingerSegment Entry;
    Prefix = I == 0 ? "LeftHand" : "RightHand";
    for (Finger = 0; Finger < 5; ++Finger)
    {
        for (Joint = 1; Joint <= 3; ++Joint)
            if (Reference.MatchRefBone(FingerBone(Prefix, Finger, Joint)) < 0) break;
        if (Joint <= 3) continue;
        for (Joint = 1; Joint <= 3; ++Joint)
        {
            Bone = FingerBone(Prefix, Finger, Joint);
            Position = Reference.GetBoneLocation(Bone);
            Direction = Joint < 3 ? Reference.GetBoneLocation(FingerBone(Prefix, Finger, Joint + 1)) - Position
                : Position - Reference.GetBoneLocation(FingerBone(Prefix, Finger, Joint - 1));
            Toward = Palm;
            if (Finger == 0) Toward = Reference.GetBoneLocation(FingerBone(Prefix, 2, 1)) + Palm * 4 - Position;
            Axis = Normal(Direction cross Toward);
            if (VSizeSq(Axis) < 0.9) continue;
            Q = Reference.GetBoneQuaternion(Bone);
            Entry.Hand = I; Entry.Finger = Finger; Entry.Joint = Joint - 1;
            Entry.Axis = QuatRotateVector(QuatInvert(Q), Axis);
            Entry.Swing = vect(0,0,0);
            if (Finger == 0 && Joint == 1)
            {
                // Swing the thumb root across the palm, toward the index.
                Axis = Palm;
                if ((Palm dot (Direction cross (Reference.GetBoneLocation(FingerBone(Prefix, 1, 1)) - Position))) < 0)
                    Axis = -Palm;
                Entry.Swing = QuatRotateVector(QuatInvert(Q), Axis);
            }
            Entry.Rest = QuatProduct(QuatInvert(Reference.GetBoneQuaternion(Reference.GetParentBone(Bone))), Q);
            // Absolute in parent space: the hand closes from the authored rest
            // pose, not on top of whatever grip the locomotion clip left.
            Entry.Control = new(BodyTree) class'SkelControlSingleBone';
            Entry.Control.ControlName = name("VRRemote" $ Bone);
            Entry.Control.bApplyRotation = true;
            Entry.Control.BoneRotationSpace = BCS_ParentBoneSpace;
            Controls[13 + I * 15 + Finger * 3 + Joint - 1] = Entry.Control;
            AppendControl(Bone, Entry.Control);
            Fingers.AddItem(Entry);
        }
    }
}

simulated function name FingerBone(string Prefix, int Finger, int Joint)
{
    switch (Finger)
    {
        case 0: return name(Prefix $ "Thumb" $ Joint);
        case 1: return name(Prefix $ "Index" $ Joint);
        case 2: return name(Prefix $ "Middle" $ Joint);
        case 3: return name(Prefix $ "Ring" $ Joint);
    }
    return name(Prefix $ "Pinky" $ Joint);
}

simulated function name HandBone(int I)
{
    return I == 0 ? 'LeftHand' : 'RightHand';
}

simulated function EAxis BoneAxis(vector Direction, out int Invert, optional int Exclude = -1)
{
    local vector Size;
    Size.X = Exclude == 0 ? -1.0 : Abs(Direction.X);
    Size.Y = Exclude == 1 ? -1.0 : Abs(Direction.Y);
    Size.Z = Exclude == 2 ? -1.0 : Abs(Direction.Z);
    if (Size.X >= Size.Y && Size.X >= Size.Z) { Invert = Direction.X < 0 ? 1 : 0; return AXIS_X; }
    if (Size.Y >= Size.Z) { Invert = Direction.Y < 0 ? 1 : 0; return AXIS_Y; }
    Invert = Direction.Z < 0 ? 1 : 0;
    return AXIS_Z;
}

simulated function AppendControl(name Bone, SkelControlBase Control)
{
    local int I;
    local SkelControlBase Tail;
    local AnimTree.SkelControlListHead Link;
    Control.ControlStrength = 0;
    Control.StrengthTarget = 0;
    Control.bControlledByAnimMetada = false;
    Control.bSetStrengthFromAnimNode = false;
    Control.bPropagateSetActive = false;
    for (I = 0; I < BodyTree.SkelControlLists.Length; ++I)
        if (BodyTree.SkelControlLists[I].BoneName == Bone)
        {
            Tail = BodyTree.SkelControlLists[I].ControlHead;
            if (Tail == None) BodyTree.SkelControlLists[I].ControlHead = Control;
            else
            {
                while (Tail.NextControl != None) Tail = Tail.NextControl;
                Tail.NextControl = Control;
            }
            return;
        }
    Link.BoneName = Bone;
    Link.ControlHead = Control;
    BodyTree.SkelControlLists.AddItem(Link);
}

// While tracked, the rig owns the upper body: aim offsets hold centre (no
// head-pitch spine bend), the upper-body slot masks pass locomotion through
// (weapon clips keep a token weight, so they stay relevant and their stock
// sounds still play) and the stock left-hand IK,
// head look-at and head scale sit at zero ahead of the VR controls.
simulated function SuppressStock()
{
    local AnimNodeAimOffset Aim;
    local AnimNode_MultiBlendPerBone Blend;
    local AnimNodeSlot Upper, CrouchUpper;
    local StockAimNode SavedAim;
    local StockMask SavedMask;
    local int I;
    if (!bStockSuppressed)
    {
        bStockSuppressed = true;
        foreach BodyMesh.AllAnimNodes(class'AnimNodeAimOffset', Aim)
        {
            SavedAim.Node = Aim; SavedAim.bForce = Aim.bForceAimDir; SavedAim.Dir = Aim.ForcedAimDir;
            StockAim.AddItem(SavedAim);
            Aim.bForceAimDir = true;
            Aim.ForcedAimDir = ANIMAIM_CENTERCENTER;
        }
        Upper = AnimNodeSlot(BodyMesh.FindAnimNode('Custom_Upper'));
        CrouchUpper = AnimNodeSlot(BodyMesh.FindAnimNode('Custom_CH_Upper'));
        foreach BodyMesh.AllAnimNodes(class'AnimNode_MultiBlendPerBone', Blend)
            for (I = 1; I < Blend.Children.Length && I <= Blend.MaskList.Length; ++I)
            {
                if (Blend.Children[I].Anim == None
                    || (Blend.Children[I].Anim != Upper && Blend.Children[I].Anim != CrouchUpper)) continue;
                SavedMask.Node = Blend; SavedMask.Index = I - 1;
                SavedMask.bRules = Blend.MaskList[I - 1].bWeightBasedOnNodeRules;
                SavedMask.Weight = Blend.MaskList[I - 1].DesiredWeight;
                StockMasks.AddItem(SavedMask);
                Blend.MaskList[I - 1].bWeightBasedOnNodeRules = false;
                // Not 0: the slot must stay relevant. KFWeaponAttachment.Tick
                // interrupts its pawn-synchronised weapon clip once the slot
                // is not, and that hidden clip's AkEvent notifies are the
                // stock 3P reload sounds (character reload clips carry none).
                Blend.SetMaskWeight(I - 1, StockUpperWeight, 0.1);
            }
        // KFPawn caches HeadLook/HeadScale as IK_Look_Head/HeadScaleControl.
        SaveStockControl('HandIK_L');
        SaveStockControl('HeadLook');
        SaveStockControl('HeadScale');
        if (PoseOwner != None)
        `log("KF2VRNet remote_body_stock world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
            $ " pawn=" $ PoseOwner.PawnEpoch $ " suppressed=true aim_nodes=" $ StockAim.Length
            $ " upper_masks=" $ StockMasks.Length $ " controls=" $ StockControls.Length);
    }
    // Stock code (head tracking, head scale) may raise these again.
    for (I = 0; I < StockControls.Length; ++I)
    {
        StockControls[I].Control.bControlledByAnimMetada = false;
        if (StockControls[I].Control.ControlStrength != 0 || StockControls[I].Control.StrengthTarget != 0)
            StockControls[I].Control.SetSkelControlStrength(0, 0);
    }
}

simulated function SaveStockControl(name ControlName)
{
    local StockControl Saved;
    Saved.Control = BodyMesh.FindSkelControl(ControlName);
    if (Saved.Control == None) return;
    Saved.bMetadata = Saved.Control.bControlledByAnimMetada;
    Saved.Strength = Saved.Control.ControlStrength;
    Saved.Target = Saved.Control.StrengthTarget;
    StockControls.AddItem(Saved);
}

simulated function RestoreStock()
{
    local int I;
    if (!bStockSuppressed) return;
    bStockSuppressed = false;
    for (I = 0; I < StockAim.Length; ++I)
    {
        StockAim[I].Node.bForceAimDir = StockAim[I].bForce;
        StockAim[I].Node.ForcedAimDir = StockAim[I].Dir;
    }
    for (I = 0; I < StockMasks.Length; ++I)
    {
        StockMasks[I].Node.MaskList[StockMasks[I].Index].bWeightBasedOnNodeRules = StockMasks[I].bRules;
        StockMasks[I].Node.SetMaskWeight(StockMasks[I].Index, StockMasks[I].Weight, 0.1);
    }
    for (I = 0; I < StockControls.Length; ++I)
    {
        StockControls[I].Control.bControlledByAnimMetada = StockControls[I].bMetadata;
        StockControls[I].Control.ControlStrength = StockControls[I].Strength;
        StockControls[I].Control.StrengthTarget = StockControls[I].Target;
    }
    StockAim.Length = 0;
    StockMasks.Length = 0;
    StockControls.Length = 0;
    if (PoseOwner != None)
        `log("KF2VRNet remote_body_stock world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
            $ " pawn=" $ PoseOwner.PawnEpoch $ " suppressed=false");
}

simulated function ReleaseRig()
{
    local int I, J;
    local SkelControlBase Previous, Current;
    RestoreStock();
    if (BodyTree != None)
    {
        for (I = 0; I < ArrayCount(Controls); ++I)
        {
            if (Controls[I] == None) continue;
            Controls[I].SetSkelControlStrength(0, 0);
            for (J = BodyTree.SkelControlLists.Length - 1; J >= 0; --J)
            {
                Previous = None;
                Current = BodyTree.SkelControlLists[J].ControlHead;
                while (Current != None && Current != Controls[I])
                {
                    Previous = Current;
                    Current = Current.NextControl;
                }
                if (Current == None) continue;
                if (Previous != None) Previous.NextControl = Current.NextControl;
                else BodyTree.SkelControlLists[J].ControlHead = Current.NextControl;
                if (BodyTree.SkelControlLists[J].ControlHead == None) BodyTree.SkelControlLists.Remove(J, 1);
                break;
            }
            Controls[I].NextControl = None;
            Controls[I] = None;
        }
        BodyTree.bEnablePooling = bSavedPooling;
        if (BodyMesh != None && BodyMesh.Animations == BodyTree) BodyMesh.InitSkelControls();
    }
    Head = None;
    Pelvis = None; SpineBend[0] = None; SpineBend[1] = None; NeckShift = None;
    PelvisOffset = vect(0,0,0); NeckOffset = vect(0,0,0); HeadError = vect(0,0,0);
    BendAxis = vect(0,0,0); BendAngle = 0; ChestYaw = 0;
    for (I = 0; I < 2; ++I)
    {
        if (FistGlow[I] == None) continue;
        FistGlow[I].SetEnabled(false);
        if (BodyMesh != None) BodyMesh.DetachComponent(FistGlow[I]);
        FistGlow[I] = None;
    }
    Fingers.Length = 0;
    for (I = 0; I < 2; ++I)
    {
        Arm[I] = None; Wrist[I] = None; ShoulderFollow[I] = None; ForearmTwist[I] = None; ShoulderOffset[I] = vect(0,0,0);
        Curl[I] = vect(0,0,0); HandPose[I] = 0;
    }
    BodyTree = None;
    BodyMesh = None;
}

simulated function bool BindRig()
{
    local int I;
    local name ElbowBone, TwistBone;
    local vector Shoulder, Elbow, Hand;
    BodyMesh = RigPawn.Mesh;
    if (BodyMesh == None || BodyMesh.SpaceBases.Length == 0) return false;
    BodyTree = AnimTree(BodyMesh.Animations);
    // An instance-only extension must never reach a shared asset/template.
    if (BodyTree == None || BodyTree == BodyMesh.AnimTreeTemplate) { BodyTree = None; return false; }
    bSavedPooling = BodyTree.bEnablePooling;
    if (!BindWristReference()) { ReleaseRig(); return false; }
    for (I = 0; I < 2; ++I)
    {
        if (BodyMesh.MatchRefBone(HandBone(I)) < 0) { ReleaseRig(); return false; }
        ElbowBone = BodyMesh.GetParentBone(HandBone(I));
        ShoulderBone[I] = BodyMesh.GetParentBone(ElbowBone);
        Shoulder = BodyMesh.GetBoneLocation(ShoulderBone[I]);
        Elbow = BodyMesh.GetBoneLocation(ElbowBone);
        Hand = BodyMesh.GetBoneLocation(HandBone(I));
        ArmLength[I] = VSize(Elbow - Shoulder) + VSize(Hand - Elbow);
        if (!(ArmLength[I] > 10 && ArmLength[I] < 160)) { ReleaseRig(); return false; }
        Arm[I] = new(BodyTree) class'SkelControlLimb';
        Arm[I].ControlName = I == 0 ? 'VRRemoteArmLeft' : 'VRRemoteArmRight';
        Arm[I].EffectorLocationSpace = BCS_WorldSpace;
        Arm[I].JointTargetLocationSpace = BCS_WorldSpace;
        // A little avatar reach adaptation keeps a reload grip connected when
        // the shoulder sits behind the tracked hand. Stock upper-body clips no
        // longer move the shoulder (SuppressStock), so the margin is small.
        // Keep a bend at full reach. The stock limb solver can alternate
        // folded/extended solutions at its straight, stretched singularity.
        Arm[I].bAllowStretching = false;
        Arm[I].BoneAxis = ReferenceBoneAxis[I];
        Arm[I].bInvertBoneAxis = ReferenceInvertBone[I] != 0;
        Arm[I].JointAxis = ReferenceJointAxis[I];
        Arm[I].bInvertJointAxis = ReferenceInvertJoint[I] != 0;
        Controls[1 + I * 2] = Arm[I];
        AppendControl(HandBone(I), Arm[I]);
        Wrist[I] = new(BodyTree) class'SkelControlSingleBone';
        Wrist[I].ControlName = I == 0 ? 'VRRemoteWristLeft' : 'VRRemoteWristRight';
        Wrist[I].bApplyRotation = true;
        Wrist[I].BoneRotationSpace = BCS_WorldSpace;
        Controls[2 + I * 2] = Wrist[I];
        AppendControl(HandBone(I), Wrist[I]);
        ShoulderFollow[I] = new(BodyTree) class'SkelControlSingleBone';
        ShoulderFollow[I].ControlName = I == 0 ? 'VRRemoteShoulderLeft' : 'VRRemoteShoulderRight';
        ShoulderFollow[I].bApplyTranslation = true;
        ShoulderFollow[I].bAddTranslation = true;
        ShoulderFollow[I].BoneTranslationSpace = BCS_WorldSpace;
        Controls[5 + I] = ShoulderFollow[I];
        AppendControl(ShoulderBone[I], ShoulderFollow[I]);
        TwistBone = I == 0 ? 'LeftForeArmTwist1' : 'RightForeArmTwist1';
        if (BodyMesh.MatchRefBone(TwistBone) >= 0)
        {
            ForearmTwist[I] = new(BodyTree) class'SkelControl_TwistBone';
            ForearmTwist[I].ControlName = I == 0 ? 'VRRemoteTwistLeft' : 'VRRemoteTwistRight';
            ForearmTwist[I].SourceBoneName = HandBone(I);
            ForearmTwist[I].TwistAngleScale = -0.5;
            ForearmTwist[I].bIgnoreWhenNotRendered = true;
            Controls[7 + I] = ForearmTwist[I];
            AppendControl(TwistBone, ForearmTwist[I]);
        }
    }
    Head = new(BodyTree) class'SkelControlSingleBone';
    Head.ControlName = 'VRRemoteHead';
    Head.bApplyRotation = true;
    Head.BoneRotationSpace = BCS_WorldSpace;
    Controls[0] = Head;
    AppendControl('head', Head);
    // Each SkelControlList runs once its bone is composed, and the skeleton
    // composes parents first, so these Spine/Spine1/Spine2/neck controls act
    // before the shoulder follow, arm limbs, wrists and head: the shoulders
    // move first and the arms re-solve to the tracked hands.
    if (BodyMesh.MatchRefBone('Spine') >= 0 && BodyMesh.MatchRefBone('Spine1') >= 0
        && BodyMesh.MatchRefBone('Spine2') >= 0 && BodyMesh.MatchRefBone('neck') >= 0)
    {
        Pelvis = NewShift('VRRemotePelvis', 'Spine', 9);
        for (I = 0; I < 2; ++I)
        {
            SpineBend[I] = new(BodyTree) class'SkelControlSingleBone';
            SpineBend[I].ControlName = I == 0 ? 'VRRemoteSpine1' : 'VRRemoteSpine2';
            SpineBend[I].bApplyRotation = true;
            // The stock weapon-ready base pose already twists the torso.
            // Apply tracked yaw/lean to the reference spine instead of adding
            // it on top of that asymmetric pose. Hips/locomotion stay stock.
            SpineBend[I].bAddRotation = false;
            SpineBend[I].BoneRotationSpace = BCS_WorldSpace;
            Controls[10 + I] = SpineBend[I];
            AppendControl(I == 0 ? 'Spine1' : 'Spine2', SpineBend[I]);
        }
        NeckShift = NewShift('VRRemoteNeck', 'neck', 12);
    }
    BodyTree.bEnablePooling = false;
    BodyMesh.InitSkelControls();
    if (PoseOwner != None)
    `log("KF2VRNet remote_body_bound world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
        $ " pawn=" $ PoseOwner.PawnEpoch $ " mesh=" $ BodyMesh $ " tree=" $ BodyTree
        $ " left_length=" $ ArmLength[0] $ " right_length=" $ ArmLength[1] $ " fingers=" $ Fingers.Length
        $ " stock_graph=true");
    return true;
}

simulated function SkelControlSingleBone NewShift(name ControlName, name Bone, int Slot)
{
    local SkelControlSingleBone Shift;
    Shift = new(BodyTree) class'SkelControlSingleBone';
    Shift.ControlName = ControlName;
    Shift.bApplyTranslation = true;
    Shift.bAddTranslation = true;
    Shift.BoneTranslationSpace = BCS_WorldSpace;
    Controls[Slot] = Shift;
    AppendControl(Bone, Shift);
    return Shift;
}

// World-space additive spine turn (lean after chest yaw), Share of it.
simulated function quat SpineTurn(float Share)
{
    return QuatProduct(QuatFromAxisAndAngle(BendAxis, BendAngle * Share),
        QuatFromAxisAndAngle(vect(0,0,1), ChestYaw * Share));
}

// Keep stock hips and legs, but do not inherit their weapon-ready twist
// into the tracked chest. Both spine targets use the character root frame.
simulated function rotator ReferenceSpineTurn(int I, quat Turn)
{
    return QuatToRotator(QuatProduct(Turn,
        QuatProduct(BodyMesh.GetBoneQuaternion('Root'), SpineRest[I])));
}

// The torso follows the head. Chest yaw is the AS2 body frame
// (VRHandsBridge.BodyYaw), soft-limited about the hips. The tracked neck's
// offset from the stock eye point (BaseEyeHeight follows bIsCrouched) moves
// the stock head bone, so the stock stance, crouch and bob stay the base:
// a bounded Spine lift, a Spine1/Spine2 lean, then a small neck shift. The
// head control is absolute world rotation, so the lean does not turn it.
simulated function UpdateSpine(NetPoseSnapshot Frame, float Delta)
{
    local vector X, Y, Z, Forward, Up, Wanted, Spine1, Spine2, Lever, Chain, Reach, Rest, Slide;
    local rotator Body;
    local quat Lower, Whole;
    local float Strength, Yaw, Room;
    if (Pelvis == None) return;
    Body.Yaw = RigPawn.Rotation.Yaw;
    // Last frame's bones carry these controls; take them back out to recover
    // the stock Spine1, Spine2 and head the animation produced.
    Strength = Pelvis.ControlStrength;
    Lower = SpineTurn(SpineSplit * Strength);
    Whole = SpineTurn(Strength);
    Spine1 = BodyMesh.GetBoneLocation('Spine1');
    Spine2 = BodyMesh.GetBoneLocation('Spine2');
    Lever = QuatRotateVector(QuatInvert(Whole), BodyMesh.GetBoneLocation('head') - NeckOffset * Strength - Spine2);
    Spine2 = Spine1 - PelvisOffset * Strength + QuatRotateVector(QuatInvert(Lower), Spine2 - Spine1);
    Spine1 -= PelvisOffset * Strength;
    Yaw = 0;
    if ((Tracking & 1) != 0)
    {
        // Body-relative: the replicated root lags the simulated pawn.
        Wanted = (Frame.Sample.HeadPosition - (HeadEyeOffset >> Frame.Sample.HeadRotation)
            + HeadEyeOffset - vect(0,0,1) * RigPawn.BaseEyeHeight) >> Body;
        Yaw = ChestYaw;
        GetAxes(Normalize(Body + Frame.Sample.HeadRotation), X, Y, Z);
        Forward = X; Forward.Z = 0;
        Up = Z; Up.Z = 0;
        if (X.Z > 0) Up = -Up;
        Forward += Up * FMax(0, 1 - VSize(Forward) / 0.3);
        if (VSize(Forward) > 0.05)
        {
            Yaw = NormalizeRotAxis(rotator(Forward).Yaw - Body.Yaw) * UnrRotToRad / (ChestYawLimit * DegToRad);
            Yaw = ChestYawLimit * DegToRad * (1 - 2 / (Exp(2 * Yaw) + 1));
        }
    }
    HeadError += (Wanted - HeadError) * (1 - Exp(-Delta / SpineBlendTime));
    ChestYaw += (Yaw - ChestYaw) * (1 - Exp(-Delta / ChestYawBlendTime));
    HeadTarget = Spine2 + Lever + HeadError;
    // Height: lift or sink Spine so the stock spine length still reaches.
    Reach = HeadTarget - Spine1;
    Chain = Spine2 + Lever - Spine1;
    Room = VSizeSq(Chain) - Square(Reach.X) - Square(Reach.Y);
    PelvisOffset = vect(0,0,1) * FClamp(Room > 0 ? Reach.Z - Sqrt(Room) : Reach.Z, -PelvisLift, PelvisLift);
    // Lean: turn the yawed chain toward the tracked head.
    Chain = QuatRotateVector(QuatFromAxisAndAngle(vect(0,0,1), ChestYaw), Chain);
    Reach -= PelvisOffset;
    BendAxis = Normal(Chain cross Reach);
    BendAngle = 0;
    if (VSizeSq(BendAxis) > 0.5)
        BendAngle = FMin(Acos(FClamp(Normal(Chain) dot Normal(Reach), -1, 1)), SpineBendLimit * DegToRad);
    else BendAxis = vect(0,0,0);
    Lower = SpineTurn(SpineSplit);
    Whole = SpineTurn(1);
    // Residual: a little hip slide, then the neck.
    Rest = HeadTarget - (Spine1 + PelvisOffset + QuatRotateVector(Lower, Spine2 - Spine1) + QuatRotateVector(Whole, Lever));
    Slide = Rest; Slide.Z = 0;
    Slide = ClampLength(Slide, PelvisShift);
    PelvisOffset += Slide;
    NeckOffset = ClampLength(Rest - Slide, NeckReach);
    if (!(VSizeSq(PelvisOffset) < 10000 && VSizeSq(NeckOffset) < 10000 && VSizeSq(HeadError) < 1000000
        && BendAngle == BendAngle && ChestYaw == ChestYaw))
    {
        PelvisOffset = vect(0,0,0); NeckOffset = vect(0,0,0); HeadError = vect(0,0,0);
        BendAxis = vect(0,0,0); BendAngle = 0; ChestYaw = 0;
        Lower = SpineTurn(1); Whole = Lower;
    }
    Pelvis.BoneTranslation = PelvisOffset;
    SpineBend[0].BoneRotation = ReferenceSpineTurn(0, Lower);
    SpineBend[1].BoneRotation = ReferenceSpineTurn(1, Whole);
    NeckShift.BoneTranslation = NeckOffset;
    Strength = (Tracking & 1) != 0 ? 1 : 0;
    Pelvis.SetSkelControlStrength(Strength, 0.12);
    SpineBend[0].SetSkelControlStrength(Strength, 0.12);
    SpineBend[1].SetSkelControlStrength(Strength, 0.12);
    NeckShift.SetSkelControlStrength(Strength, 0.12);
}

simulated function UpdateBody(NetPoseSnapshot Frame, bool bFresh)
{
    local int I;
    local vector Position, Shoulder, Direction, Pole, FollowTarget, Root;
    local float Delta, Blend;
    local rotator Aim, Body;
    local bool bSolved;
    RigPawn = PoseOwner != None ? PoseOwner.TargetPawn : LocalPawn;
    if (RigPawn == None || RigPawn.Health <= 0
        || RigPawn.Physics == PHYS_RigidBody) { ReleaseRig(); return; }
    if (BodyMesh != RigPawn.Mesh || (BodyMesh != None && BodyMesh.Animations != BodyTree)) ReleaseRig();
    if (BodyTree == None && !BindRig()) return;
    // Special moves (grabs, emotes) play through the stock graph untouched.
    if (LocalPawn == None && RigPawn.IsDoingSpecialMove()) RestoreStock();
    else SuppressStock();
    Delta = FClamp(WorldInfo.RealTimeSeconds - LastBodyTime, 0, 0.05);
    LastBodyTime = WorldInfo.RealTimeSeconds;
    Blend = 1 - Exp(-Delta / 0.06);
    Tracking = 0;
    if (bFresh && (LocalPawn != None || !RigPawn.IsDoingSpecialMove())) Tracking = Frame.Sample.TrackingFlags;
    // Offsets hang from the simulated pawn, not the lagging replicated root.
    if (PoseOwner != None) PoseOwner.PresentationRoot(Root, Body);
    else { Root = RigPawn.Location; Body.Yaw = RigPawn.Rotation.Yaw; }
    Head.BoneRotation = QuatToRotator(QuatProduct(QuatFromRotator(Normalize(Body + Frame.Sample.HeadRotation)), HeadBasis));
    Head.SetSkelControlStrength((Tracking & 1) != 0 ? 1 : 0, 0.12);
    UpdateSpine(Frame, Delta);
    for (I = 0; I < 2; ++I)
    {
        bSolved = (Frame.Sample.PresentationFlags & (4 << I)) != 0;
        Position = I == 0 ? Frame.Sample.LeftPosition : Frame.Sample.RightPosition;
        // Empty hands use the same uncalibrated controller aim frame as the
        // local neutral-hand presenter. Held hands supply canonical anatomy.
        Aim = I == 0 ? Frame.Sample.LeftRotation : Frame.Sample.RightRotation;
        if (bSolved)
        {
            Position = I == 0 ? Frame.Sample.LeftWristPosition : Frame.Sample.RightWristPosition;
            Aim = I == 0 ? Frame.Sample.LeftWristRotation : Frame.Sample.RightWristRotation;
        }
        WantedHand[I] = Root + (Position >> Body);
        WantedWrist[I] = Normalize(Body + Aim);
        WantedWrist[I] = QuatToRotator(QuatProduct(QuatFromRotator(WantedWrist[I]), WristBasis[I]));
        Shoulder = BodyMesh.GetBoneLocation(ShoulderBone[I]) - ShoulderOffset[I] * ShoulderFollow[I].ControlStrength;
        Direction = WantedHand[I] - Shoulder;
        FollowTarget = Normal(Direction) * FClamp(VSize(Direction) - ArmLength[I] * 0.98, 0, 6);
        if ((Tracking & (2 << I)) == 0) FollowTarget = vect(0,0,0);
        ShoulderOffset[I] += (FollowTarget - ShoulderOffset[I]) * Blend;
        ShoulderFollow[I].BoneTranslation = ShoulderOffset[I];
        ShoulderFollow[I].SetSkelControlStrength(1, 0);
        Shoulder += ShoulderOffset[I];
        Direction = WantedHand[I] - Shoulder;
        ReachableHand[I] = WantedHand[I];
        if (VSize(Direction) > ArmLength[I] * 0.98)
            ReachableHand[I] = Shoulder + Normal(Direction) * ArmLength[I] * 0.98;
        Pole = vect(-18,0,-28); Pole.Y = I == 0 ? -16 : 16;
        Arm[I].EffectorLocation = ReachableHand[I];
        Arm[I].JointTargetLocation = Shoulder + (Pole >> Body);
        Arm[I].SetSkelControlStrength((Tracking & (2 << I)) != 0 ? 1 : 0, 0.12);
        Wrist[I].BoneRotation = WantedWrist[I];
        Wrist[I].SetSkelControlStrength((Tracking & (2 << I)) != 0 ? 1 : 0, 0.12);
        if (ForearmTwist[I] != None)
            ForearmTwist[I].SetSkelControlStrength((Tracking & (2 << I)) != 0 ? 1 : 0, 0.12);
        UpdateFistGlow(I, (Tracking & (2 << I)) != 0 && (Frame.Sample.PresentationFlags & (16 << I)) != 0);
        HandPose[I] = I == 0 ? Frame.Sample.LeftHandPose : Frame.Sample.RightHandPose;
        if ((Tracking & (2 << I)) == 0) HandPose[I] = 0;
        UpdateFingers(I, Delta);
    }
}

// Curl 0-15 closes a natural fist from the rest pose; the index and thumb
// bits hold those digits straight and a held weapon eases the trigger
// finger. Pose 0 fades back to the stock fingers.
simulated function UpdateFingers(int I, float Delta)
{
    local int J;
    local vector Target;
    local float Amount;
    local quat Bend;
    if (HandPose[I] != 0)
    {
        Target.X = float(HandPose[I] & 15) / 15;
        Target.Y = (HandPose[I] & 16) != 0 ? 0.0 : Target.X * ((HandPose[I] & 64) != 0 ? TriggerFingerCurl : 1.0);
        Target.Z = (HandPose[I] & 32) != 0 ? 0.0 : Target.X;
        Curl[I] += (Target - Curl[I]) * (1 - Exp(-Delta / FingerBlendTime));
    }
    for (J = 0; J < Fingers.Length; ++J)
    {
        if (Fingers[J].Hand != I) continue;
        Amount = Fingers[J].Finger == 0 ? Curl[I].Z : (Fingers[J].Finger == 1 ? Curl[I].Y : Curl[I].X);
        Bend = QuatFromAxisAndAngle(Fingers[J].Axis, Amount * DegToRad
            * (Fingers[J].Finger == 0 ? ThumbDegrees[Fingers[J].Joint] : FingerDegrees[Fingers[J].Joint]));
        if (Fingers[J].Finger == 0 && Fingers[J].Joint == 0)
            Bend = QuatProduct(QuatFromAxisAndAngle(Fingers[J].Swing, Amount * ThumbSwing * DegToRad), Bend);
        Fingers[J].Control.BoneRotation = QuatToRotator(QuatProduct(Fingers[J].Rest, Bend));
        Fingers[J].Control.SetSkelControlStrength(HandPose[I] != 0 ? 1 : 0, 0.12);
    }
}

// The owner's full-charge throb, on the hand bone of this pawn's own rig.
simulated function UpdateFistGlow(int I, bool bCharged)
{
    local class<VRFistCharge> Charge;
    if (!bCharged)
    {
        if (FistGlow[I] != None && FistGlow[I].bEnabled) FistGlow[I].SetEnabled(false);
        return;
    }
    Charge = class'VRFistCharge';
    if (FistGlow[I] == None)
    {
        FistGlow[I] = new(self) class'PointLightComponent'(FistGlowTemplate);
        BodyMesh.AttachComponent(FistGlow[I], HandBone(I));
        FistGlow[I].SetRadius(Charge.default.GlowRadius);
    }
    FistGlow[I].SetLightProperties(Charge.default.GlowFullBrightness
        * (0.8 + 0.2 * Sin(WorldInfo.RealTimeSeconds * 2 * Pi * 2.5)), Charge.default.GlowColor);
    if (!FistGlow[I].bEnabled) FistGlow[I].SetEnabled(true);
}

simulated event Tick(float DeltaTime)
{
    local int I;
    if (LocalPawn != None)
    {
        if (LocalPawn.bDeleteMe || Owner == None || Owner.bDeleteMe) Destroy();
        return;
    }
    if (PoseOwner == None || PoseOwner.bDeleteMe) { Destroy(); return; }
    if (!PoseOwner.bDiagnosticVisuals || BodyTree == None || WorldInfo.RealTimeSeconds < NextLog) return;
    NextLog = WorldInfo.RealTimeSeconds + 1;
    for (I = 0; I < 2; ++I)
        `log("KF2VRNet remote_body world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
            $ " pawn=" $ PoseOwner.PawnEpoch $ " hand=" $ I $ " flags=" $ Tracking
            $ " strength=" $ Arm[I].ControlStrength
            $ " replay=" $ PoseOwner.Snapshot.Motion.ReplayId $ " sample=" $ PoseOwner.Snapshot.Motion.SampleIndex
            $ " target=" $ WantedHand[I] $ " actual=" $ BodyMesh.GetBoneLocation(HandBone(I))
            $ " desired_rotation=" $ WantedWrist[I] $ " actual_rotation=" $ QuatToRotator(BodyMesh.GetBoneQuaternion(HandBone(I)))
            $ " wrist_error=" $ VSize(BodyMesh.GetBoneLocation(HandBone(I)) - WantedHand[I])
            $ " solve_error=" $ VSize(BodyMesh.GetBoneLocation(HandBone(I)) - ReachableHand[I])
            $ " reach_clamp=" $ VSize(ReachableHand[I] - WantedHand[I])
            $ " hand_pose=" $ HandPose[I] $ " curl=" $ Curl[I]
            $ " stock_graph=" $ (BodyMesh.Animations == BodyTree) $ " mesh_tick=" $ BodyMesh.TickGroup);
    if (Pelvis != None)
        `log("KF2VRNet remote_body_spine world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
            $ " pawn=" $ PoseOwner.PawnEpoch $ " flags=" $ Tracking $ " strength=" $ Pelvis.ControlStrength
            $ " head_error=" $ VSize(BodyMesh.GetBoneLocation('head') - HeadTarget)
            $ " chest_yaw=" $ ChestYaw * RadToDeg $ " spine_bend=" $ BendAngle * RadToDeg
            $ " pelvis_offset=" $ PelvisOffset $ " neck_offset=" $ NeckOffset
            $ " crouched=" $ RigPawn.bIsCrouched);
}

simulated event Destroyed()
{
    ReleaseRig();
    Super.Destroyed();
}

defaultproperties
{
    // The owner's hand fill channels (VRHandsBridge), which reach pawn meshes.
    // A template only: never in Components, so nothing attaches it to this actor.
    Begin Object Class=PointLightComponent Name=RemoteFistGlow
        FalloffExponent=2
        bDisableSpecular=true
        CastShadows=false
        CastStaticShadows=false
        CastDynamicShadows=false
        bEnabled=false
        bForceDynamicLight=true
        bCanAffectDynamicPrimitivesOutsideDynamicChannel=true
        bOverrideAutoLightingChannels=true
        LightingChannels=(Indoor=true,Outdoor=true,Dynamic=true,bInitialized=true)
    End Object
    FistGlowTemplate=RemoteFistGlow
    ChestYawLimit=60
    ChestYawBlendTime=0.1
    SpineSplit=0.4
    SpineBendLimit=35
    PelvisLift=12
    PelvisShift=4
    NeckReach=8
    SpineBlendTime=0.06
    HeadEyeOffset=(X=8,Y=0,Z=10)
    FingerDegrees(0)=70
    FingerDegrees(1)=90
    FingerDegrees(2)=45
    ThumbDegrees(0)=30
    ThumbDegrees(1)=40
    ThumbDegrees(2)=40
    ThumbSwing=30
    TriggerFingerCurl=0.7
    FingerBlendTime=0.05
    StockUpperWeight=0.01
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bHidden=true
    bReplicateMovement=false
    TickGroup=TG_PostUpdateWork
}
