// Authored wrist/fingers for a hand operating a lever or bolt. Input, action stops
// and ammunition remain with the existing manual/reload action owners.
class VRLeverHand extends Object;

var VRReloadHandPose Pose;
var VRHandsBridge Bridge;
var VRWeaponRuntime Runtime;
var KFWeapon Gun;
var KFSkeletalMeshComponent HiddenHeldHand;
var int Hand;
var bool bBoneContact;

function bool Begin(VRHandsBridge B, VRWeaponRuntime R, VRActionPath Path, int TargetHand,
    optional int SourceHand = 1, optional bool bAttachToBone)
{
    Cancel();
    if (B == None || R == None || R.Item == None || Path == None || Path.RefSeq == None
        || Path.RefSeq.AnimSeq == None
        || TargetHand < 0 || TargetHand > 1) return false;
    Bridge = B; Runtime = R; Gun = R.Item; Hand = TargetHand;
    bBoneContact = bAttachToBone;
    if (Pose == None) Pose = new(self) class'VRReloadHandPose';
    return Pose.Build(B, Gun.MySkelMesh, Path.RefSeq.AnimSeqName,
        bBoneContact ? Path.Bones[0] : Path.RefRoot,
        bBoneContact ? Path.GripTime : Path.StartTime,
        bBoneContact ? Path.GripTime : Path.OpenTime, Hand, SourceHand, true);
}

function bool CoversHand(int Side)
{
    return Pose != None && Pose.bVisible && Side == Hand;
}

function Cancel()
{
    if (Pose != None) Pose.Cancel();
    RestoreHeldHand();
    HiddenHeldHand = None;
}

function RestoreHeldHand()
{
    if (HiddenHeldHand != None && Runtime != None && Runtime.IsCurrent()
        && Runtime.Item == Gun && Runtime.Presenter != None
        && (Runtime.PrimaryHand == Hand || Runtime.SupportHand == Hand)
        && Runtime.Presenter.AttachedHands[Hand] == HiddenHeldHand)
        HiddenHeldHand.SetHidden(false);
}

function Place(VRActionPath Path, float Amount, vector RootPosition, quat RootRotation,
    float Scale, bool bHeld)
{
    local vector P, Offset;
    local quat Q, WristQ;
    local float Fraction, Progress;
    local int Segment;
    local KFSkeletalMeshComponent HeldHand;
    if (!bHeld || Pose == None || !Pose.bReady || Bridge == None || Runtime == None
        || !Runtime.IsCurrent() || Runtime.Item != Gun || Path == None || Path.Path.Length < 2
        || Bridge.FreeHandPose == None || !Bridge.FreeHandPose.bReady
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0)
    { Cancel(); return; }
    // Amount is arc length, while the hand cache is sampled in clip time.
    Segment = Path.Segment(Amount, Fraction);
    Progress = (float(Segment - 1) + Fraction) / float(Path.Path.Length - 1);
    Path.PoseAt(Amount, 0, P, Q);
    // The drawn wrist rides the authored lever path at the current amount.
    // GrabLocal only maps tracking to that amount: a regrab of an open lever
    // starts at the grip, and carrying that offset left the hand off the lever.
    Offset = vect(0,0,0);
    // A bolt uses the stock contact sampled in the handle's own frame.
    // Tracking drives the action amount, never a second floating wrist.
    if (bBoneContact)
    {
        Offset = P * Scale;
        RootPosition += QuatRotateVector(RootRotation, Offset);
        RootRotation = QuatProduct(RootRotation, Q);
        Offset = vect(0,0,0);
        Progress = 0;
    }
    WristQ = Bridge.FreeHandPose.WristRotation(Hand, Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    if (!Pose.Place(Bridge.WorldInfo.RealTimeSeconds, true, Progress, 1,
        Bridge.Hands[Hand].Position, WristQ,
        RootPosition + QuatRotateVector(RootRotation, Offset), RootRotation, Scale))
    { Cancel(); return; }
    if (Runtime.Presenter != None) HeldHand = Runtime.Presenter.AttachedHands[Hand];
    if (HeldHand != HiddenHeldHand)
    {
        RestoreHeldHand();
        HiddenHeldHand = HeldHand;
    }
    if (HiddenHeldHand != None) HiddenHeldHand.SetHidden(true);
}
