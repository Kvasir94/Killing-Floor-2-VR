// Weapon-independent empty-hand presentation. The mesh's relaxed reference
// pose supplies the base; local finger rotations curl it toward a fist.
// This object never requests a grab, support attachment, fire or inventory action.
class VRFreeHandPose extends Object config(Game);

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
// Gravity pull: 1 reaching (spread toward a highlighted item), 2 claw (locked
// or pulling), blended in over the ordinary grip curl.
var float GravityBlend[2];
var float ReachDegrees[16], LockDegrees[16];
var byte GravityShape[2];
var bool bReady;
var VRHandsBridge BoundBridge;
var byte bWorldCatchPose[2];
var quat WorldCatchFingers[30];

function SetWorldCatchFinger(int Hand, int Joint, quat Q)
{
    if (Hand >= 0 && Hand <= 1 && Joint >= 0 && Joint < 15)
        WorldCatchFingers[Hand * 15 + Joint] = Q;
}

function BeginWorldCatchPose(int Hand)
{
    if (Hand < 0 || Hand > 1) return;
    bWorldCatchPose[Hand] = 1;
    Apply();
}

function EndWorldCatchPose(int Hand)
{
    if (Hand < 0 || Hand > 1 || bWorldCatchPose[Hand] == 0) return;
    bWorldCatchPose[Hand] = 0;
    Apply();
}

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
    local byte Grapple[2];
    local float Alpha, LiftAlpha;
    local quat Curl, Authored;
    local VRChestGrenade Grenade;
    if (!bReady) return;
    GrenadeProfile[0] = -1;
    GrenadeProfile[1] = -1;
    // A held stock grenade always takes its authored pose (Kvasir94, 2026-11-04).
    if (BoundBridge != None && BoundBridge.HandInventory != None
        && BoundBridge.HandInventory.Input != None)
        Grenade = BoundBridge.HandInventory.Input.Grenade;
    if (Grenade != None && Grenade.HeldClass != None)
        for (Hand = 0; Hand < 2; ++Hand)
            if (Grenade.IsHeld(Hand))
                GrenadeProfile[Hand] = class'VRGrenadeGripPose'.static.ProfileFor(Grenade.HeldClass.Name);
    for (Hand = 0; Hand < 2; ++Hand) Grapple[Hand] = GrappleRegion(Hand);
    for (I = 0; I < Joints.Length; ++I)
    {
        // The existing root hand bridges the exact contact until its already
        // authored attached grip takes over. Reference bone lengths stay put.
        if (bWorldCatchPose[Joints[I].Hand] != 0)
        {
            Joints[I].Control.bAddRotation = false;
            Joints[I].Control.BoneRotationSpace = BCS_OtherBoneSpace;
            Joints[I].Control.RotationSpaceBoneName = BoundBridge.HandBone(Joints[I].Hand);
            Joints[I].Control.BoneRotation = QuatToRotator(WorldCatchFingers[I]);
            Joints[I].Control.ControlStrength = 1;
            Joints[I].Control.StrengthTarget = 1;
            continue;
        }
        Joints[I].Control.bAddRotation = true;
        Joints[I].Control.BoneRotationSpace = BCS_BoneSpace;
        Joints[I].Control.RotationSpaceBoneName = '';
        Alpha = Amount[Joints[I].Hand];
        LiftAlpha = Joints[I].OppositionDegrees != 0 ? FMin(1, Alpha * 1.8) : Alpha;
        Curl = QuatFromAxisAndAngle(Joints[I].Axis, Joints[I].Degrees * Pi / 180.0 * LiftAlpha);
        if (Joints[I].OppositionDegrees != 0)
            Curl = QuatProduct(QuatFromAxisAndAngle(Joints[I].OppositionAxis,
                Joints[I].OppositionDegrees * Pi / 180.0 * Alpha), Curl);
        if (GravityBlend[Joints[I].Hand] > 0.001)
            Curl = QuatSlerp(Curl, GravityCurl(I), GravityBlend[Joints[I].Hand], true);
        // Only exact stock classes in the catalog receive an authored pose.
        if (class'VRGrenadeGripPose'.static.Read(GrenadeProfile[Joints[I].Hand],
            Joints[I].Hand, I % 15, Authored)) Curl = Authored;
        // Melee item 15: a hand holding a Zed part closes onto it in the
        // authored B&S-style grapple pose (VRGrapplePose), with the grip.
        else if (class'VRGrapplePose'.static.Read(Grapple[Joints[I].Hand], Joints[I].Hand, I % 15, Authored))
            Curl = QuatSlerp(QuatFromAxisAndAngle(vect(1,0,0), 0), Authored, FClamp(Alpha, 0, 1), true);
        Joints[I].Control.BoneRotation = QuatToRotator(Curl);
        Joints[I].Control.ControlStrength = 1;
        Joints[I].Control.StrengthTarget = 1;
    }
}

// Gravity pull hand shapes. Locked or pulling uses Half-Life: Alyx's own half
// grab (its right hand's @grab_curl frame 40, decoded from
// alyx_hand_right.vmdl_c and fitted to this hand's curl and thumb opposition
// controls by matching each digit's segment directions in the palm frame;
// tools/author_grenade_grips.py hand() reproduces these controls). While an
// item is highlighted the hand opens past relaxed, fingers straightened toward
// it and the thumb lifted clear (Alyx's own open pose was reviewed and rejected).
// Index = finger * 3 + joint - 1; [15] is the thumb opposition, all degrees.
function quat GravityCurl(int I)
{
    local int Index, Hand;
    local float Degrees, Opposition;
    local quat Curl;
    Hand = Joints[I].Hand;
    Index = I - (I / 15) * 15;
    Degrees = GravityShape[Hand] == 1 ? ReachDegrees[Index] : LockDegrees[Index];
    Curl = QuatFromAxisAndAngle(Joints[I].Axis, Degrees * Pi / 180.0);
    if (Joints[I].OppositionDegrees != 0)
    {
        Opposition = GravityShape[Hand] == 1 ? ReachDegrees[15] : LockDegrees[15];
        Curl = QuatProduct(QuatFromAxisAndAngle(Joints[I].OppositionAxis, Opposition * Pi / 180.0), Curl);
    }
    return Curl;
}

function byte GravityPose(int Hand)
{
    if (BoundBridge == None || BoundBridge.HandInventory == None || BoundBridge.HandInventory.GravityPull == None) return 0;
    return BoundBridge.HandInventory.GravityPull.PoseFor(Hand);
}

// The B&S grapple region of the Zed part this hand holds, 0 for none (gibs,
// empty hands, B&S2 interactions off, or VRHandsBridge.bLegacyMeleeGrapplePose).
function byte GrappleRegion(int Hand)
{
    local VRZedGrab Grab;
    if (BoundBridge == None || BoundBridge.UseLegacyMelee(BoundBridge.bLegacyMeleeGrapplePose) || BoundBridge.HandInventory == None) return 0;
    Grab = BoundBridge.HandInventory.ZedGrab;
    if (Grab == None || !Grab.Grabs[Hand].bActive || Grab.Grabs[Hand].bGib || Grab.Grabs[Hand].Pawn == None) return 0;
    return class'VRGrapplePose'.static.RegionForBone(Grab.Grabs[Hand].BoneName);
}

// Advance once per simulation tick, never once per eye/late pose refresh.
function Advance(VRHandsBridge B, float DeltaTime)
{
    local int Hand;
    local float Target, Blend, ShapeBlend;
    local byte Shape;
    if (DeltaTime <= 0 || DeltaTime != DeltaTime) return;
    Blend = 1 - Exp(-FMin(DeltaTime, 1) / 0.035);
    ShapeBlend = 1 - Exp(-FMin(DeltaTime, 1) / 0.06);
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Target = Hand == 0 ? B.LeftGripValue : B.RightGripValue;
        if ((B.NativeGripActiveMask & B.NativeValidMask & (1 << Hand)) == 0 || Target != Target) Target = 0;
        Target = FClamp(Target, 0, 1);
        Amount[Hand] += (Target - Amount[Hand]) * Blend;
        Shape = GravityPose(Hand);
        if (Shape != 0) GravityShape[Hand] = Shape;
        GravityBlend[Hand] += ((Shape != 0 ? 1.0 : 0.0) - GravityBlend[Hand]) * ShapeBlend;
    }
    Apply();
}

function quat WristRotation(int Hand, rotator ControllerRotation)
{
    return QuatProduct(QuatFromRotator(ControllerRotation), WristBasis[Hand]);
}

defaultproperties
{
    ReachDegrees(0)=-24.75
    ReachDegrees(1)=9.0
    ReachDegrees(2)=3.0
    ReachDegrees(3)=-12.0
    ReachDegrees(4)=-6.75
    ReachDegrees(5)=-2.5
    ReachDegrees(6)=-13.2
    ReachDegrees(7)=-6.75
    ReachDegrees(8)=-2.5
    ReachDegrees(9)=-14.4
    ReachDegrees(10)=-6.75
    ReachDegrees(11)=-2.5
    ReachDegrees(12)=-15.6
    ReachDegrees(13)=-6.75
    ReachDegrees(14)=-2.5
    ReachDegrees(15)=0.0
    LockDegrees(0)=34.0
    LockDegrees(1)=11.0
    LockDegrees(2)=8.0
    LockDegrees(3)=0.0
    LockDegrees(4)=7.0
    LockDegrees(5)=-11.0
    LockDegrees(6)=-11.0
    LockDegrees(7)=32.0
    LockDegrees(8)=-38.0
    LockDegrees(9)=-15.0
    LockDegrees(10)=26.0
    LockDegrees(11)=-34.0
    LockDegrees(12)=-6.0
    LockDegrees(13)=2.0
    LockDegrees(14)=-26.0
    LockDegrees(15)=-27.0
}
