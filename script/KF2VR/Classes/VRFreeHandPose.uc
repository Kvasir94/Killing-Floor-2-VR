// Weapon-independent empty-hand presentation. The mesh's relaxed reference
// pose supplies the base; local finger rotations curl it toward a fist.
// This object never requests a grab, support attachment, fire or inventory action.
class VRFreeHandPose extends Object;

struct FingerJoint
{
    var name Bone;
    var SkelControlSingleBone Control;
    var vector Axis;
    var vector OppositionAxis;
    var float OppositionDegrees;
    var float Degrees;
    var int Hand;
};

var array<FingerJoint> Joints;
var quat WristBasis[2];
// Calibrated from the imported reference skeleton, including Origin/RotOrigin.
// Wrist-mounted art must use these same axes as the rendered hand.
var vector LocalForward[2], LocalThumb[2], LocalPalm[2];
var float Amount[2];
var bool bReady;
var VRHandsBridge BoundBridge;

function name FingerBone(int Hand, int Finger, int Joint)
{
    local string Side, Digit;
    Side = Hand == 0 ? "Left" : "Right";
    switch (Finger)
    {
        case 0: Digit = "Thumb"; break;
        case 1: Digit = "Index"; break;
        case 2: Digit = "Middle"; break;
        case 3: Digit = "Ring"; break;
        default: Digit = "Pinky"; break;
    }
    return name(Side $ "Hand" $ Digit $ Joint $ "_1stP");
}

function float CurlDegrees(int Finger, int Joint)
{
    if (Finger == 0)
    {
        if (Joint == 1) return 55;
        if (Joint == 2) return -45;
        return -15;
    }
    if (Joint == 1) return 40 + (Finger - 1) * 4;
    if (Joint == 2) return 45;
    return 25;
}

function BuildControls(AnimTree Template)
{
    local int Hand, Finger, Joint;
    local SkelControlSingleBone Control;
    local AnimTree.SkelControlListHead Link;
    for (Hand = 0; Hand < 2; ++Hand)
        for (Finger = 0; Finger < 5; ++Finger)
            for (Joint = 1; Joint <= 3; ++Joint)
            {
                Control = new(Template) class'SkelControlSingleBone';
                Control.ControlName = name("VRCurl_" $ FingerBone(Hand, Finger, Joint));
                Control.ControlStrength = 0;
                Control.StrengthTarget = 0;
                Control.bApplyRotation = true;
                Control.bAddRotation = true;
                Control.BoneRotationSpace = BCS_BoneSpace;
                Control.bIgnoreWhenNotRendered = false;
                Link.BoneName = FingerBone(Hand, Finger, Joint);
                Link.ControlHead = Control;
                Template.SkelControlLists.AddItem(Link);
            }
}

// Called on the evaluated reference pose, with wrist/finger controls disabled.
// Calibrate in world coordinates to include the imported mesh's Origin and
// RotOrigin. No weapon animation or weapon-specific wrist rotation is sampled.
function bool Bind(VRHandsBridge B)
{
    local int Hand, Finger, Joint;
    local vector Forward, Thumb, Palm, Segment, Curve, Direction, Axis, Position;
    local quat Align, Twist;
    local FingerJoint Entry;
    local name Bone;
    BoundBridge = B;
    bReady = false;
    Joints.Length = 0;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (B.Arms.MatchRefBone(B.HandBone(Hand)) < 0) return false;
        for (Finger = 0; Finger < 5; ++Finger)
            for (Joint = 1; Joint <= 3; ++Joint)
                if (B.Arms.MatchRefBone(FingerBone(Hand, Finger, Joint)) < 0) return false;
        Forward = Normal(B.Arms.GetBoneLocation(FingerBone(Hand, 2, 1)) - B.Arms.GetBoneLocation(B.HandBone(Hand)));
        Thumb = B.Arms.GetBoneLocation(FingerBone(Hand, 1, 1)) - B.Arms.GetBoneLocation(FingerBone(Hand, 4, 1));
        Thumb = Normal(Thumb - Forward * (Thumb dot Forward));
        Palm = Normal(Forward cross Thumb);
        Segment = Normal(B.Arms.GetBoneLocation(FingerBone(Hand, 2, 2)) - B.Arms.GetBoneLocation(FingerBone(Hand, 2, 1)));
        Curve = Normal(B.Arms.GetBoneLocation(FingerBone(Hand, 2, 3)) - B.Arms.GetBoneLocation(FingerBone(Hand, 2, 2)));
        if (((Curve - Segment * (Curve dot Segment)) dot Palm) < 0) Palm = -Palm;
        if (VSizeSq(Palm) < 0.9 || VSizeSq(Forward) < 0.9 || VSizeSq(Thumb) < 0.9) return false;
        LocalForward[Hand] = QuatRotateVector(QuatInvert(B.Arms.GetBoneQuaternion(B.HandBone(Hand))), Forward);
        LocalThumb[Hand] = QuatRotateVector(QuatInvert(B.Arms.GetBoneQuaternion(B.HandBone(Hand))), Thumb);
        LocalPalm[Hand] = QuatRotateVector(QuatInvert(B.Arms.GetBoneQuaternion(B.HandBone(Hand))), Palm);
        Align = QuatFindBetween(Forward, vect(1,0,0));
        Twist = QuatFindBetween(QuatRotateVector(Align, Thumb), vect(0,0,1));
        WristBasis[Hand] = QuatProduct(QuatProduct(Twist, Align), B.Arms.GetBoneQuaternion(B.HandBone(Hand)));
        for (Finger = 0; Finger < 5; ++Finger)
            for (Joint = 1; Joint <= 3; ++Joint)
            {
                Bone = FingerBone(Hand, Finger, Joint);
                Position = B.Arms.GetBoneLocation(Bone);
                if (Joint < 3) Direction = B.Arms.GetBoneLocation(FingerBone(Hand, Finger, Joint + 1)) - Position;
                else Direction = Position - B.Arms.GetBoneLocation(FingerBone(Hand, Finger, Joint - 1));
                Axis = Normal(Direction cross Palm);
                if (VSizeSq(Axis) < 0.9) return false;
                Entry.Bone = Bone;
                Entry.Hand = Hand;
                Entry.Degrees = CurlDegrees(Finger, Joint);
                Entry.Axis = QuatRotateVector(QuatInvert(B.Arms.GetBoneQuaternion(Bone)), Axis);
                Entry.OppositionDegrees = 0;
                Entry.OppositionAxis = vect(0,0,0);
                if (Finger == 0 && Joint == 1)
                {
                    // Lift clear of the closing fingertips before opposition.
                    // Inward flex alone drove the thumb through the fingers.
                    Axis = Palm;
                    if (((Direction cross (B.Arms.GetBoneLocation(FingerBone(Hand, 1, 1)) - Position)) dot Palm) < 0)
                        Axis = -Axis;
                    Entry.OppositionAxis = QuatRotateVector(QuatInvert(B.Arms.GetBoneQuaternion(Bone)), Axis);
                    Entry.OppositionDegrees = 45;
                }
                Entry.Control = SkelControlSingleBone(B.Arms.FindSkelControl(name("VRCurl_" $ Bone)));
                if (Entry.Control == None) return false;
                Joints.AddItem(Entry);
            }
    }
    bReady = Joints.Length == 30;
    Apply();
    return bReady;
}

function Apply()
{
    local int I, Hand, GrenadeProfile[2];
    local float Alpha, LiftAlpha;
    local quat Curl, Authored;
    local VRChestGrenade Grenade;
    if (!bReady) return;
    GrenadeProfile[0] = -1;
    GrenadeProfile[1] = -1;
    if (BoundBridge != None && BoundBridge.HandInventory != None
        && BoundBridge.HandInventory.Input != None)
        Grenade = BoundBridge.HandInventory.Input.Grenade;
    if (Grenade != None)
        for (Hand = 0; Hand < 2; ++Hand)
            if (Grenade.IsHeld(Hand))
                GrenadeProfile[Hand] = class'VRGrenadeGripPose'.static.ProfileFor(Grenade.HeldClass.Name);
    for (I = 0; I < Joints.Length; ++I)
    {
        Alpha = Amount[Joints[I].Hand];
        LiftAlpha = Joints[I].OppositionDegrees != 0 ? FMin(1, Alpha * 1.8) : Alpha;
        Curl = QuatFromAxisAndAngle(Joints[I].Axis, Joints[I].Degrees * Pi / 180.0 * LiftAlpha);
        if (Joints[I].OppositionDegrees != 0)
            Curl = QuatProduct(QuatFromAxisAndAngle(Joints[I].OppositionAxis,
                Joints[I].OppositionDegrees * Pi / 180.0 * Alpha), Curl);
        // A held stock grenade uses its reviewed pose at full strength. Grip
        // pressure still owns the ordinary free fist and gameplay admission.
        if (class'VRGrenadeGripPose'.static.Read(GrenadeProfile[Joints[I].Hand],
            Joints[I].Hand, I % 15, Authored)) Curl = Authored;
        Joints[I].Control.BoneRotation = QuatToRotator(Curl);
        Joints[I].Control.ControlStrength = 1;
        Joints[I].Control.StrengthTarget = 1;
    }
}

// Advance once per simulation tick, never once per eye/late pose refresh.
function Advance(VRHandsBridge B, float DeltaTime)
{
    local int Hand;
    local float Target, Blend;
    if (DeltaTime <= 0 || DeltaTime != DeltaTime) return;
    Blend = 1 - Exp(-FMin(DeltaTime, 1) / 0.035);
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Target = Hand == 0 ? B.LeftGripValue : B.RightGripValue;
        if ((B.NativeGripActiveMask & B.NativeValidMask & (1 << Hand)) == 0 || Target != Target) Target = 0;
        Target = FClamp(Target, 0, 1);
        Amount[Hand] += (Target - Amount[Hand]) * Blend;
    }
    Apply();
}

function quat WristRotation(int Hand, rotator ControllerRotation)
{
    return QuatProduct(QuatFromRotator(ControllerRotation), WristBasis[Hand]);
}
