// Temporary contact-to-authored grip on the existing root hand only.
// This object creates no mesh and never changes tracking or gameplay state.
class VRWorldCatchRootPose extends Object;

struct ContactHand
{
    var VRWorldDropPrediction Source;
    var int ContactRequest;
    var array<quat> ContactFingers, AuthoredFingers;
    var quat WristInController, ShownWrist;
    var KFSkeletalMeshComponent HiddenHand;
    var bool bWasHidden, bActive;
};
var ContactHand Hands[2];
var VRHandsBridge Bridge;

function bool SampleFingers(KFSkeletalMeshComponent Mesh, int Hand, out array<quat> Fingers)
{
    local int Finger, Joint;
    local name Bone, Wrist;
    local quat WristQ, Q;
    Fingers.Length = 0;
    Wrist = class'VRReloadHandPose'.static.WristBone(Hand);
    if (Mesh == None || Mesh.MatchRefBone(Wrist) < 0) return false;
    WristQ = Mesh.GetBoneQuaternion(Wrist);
    if (!class'VRHandRolePose'.static.ValidQuaternion(WristQ)) return false;
    for (Finger = 0; Finger < 5; ++Finger)
        for (Joint = 1; Joint <= 3; ++Joint)
        {
            Bone = class'VRHandRolePose'.static.FingerBone(Hand, Finger, Joint);
            if (Mesh.MatchRefBone(Bone) < 0) return false;
            Q = QuatProduct(QuatInvert(WristQ), Mesh.GetBoneQuaternion(Bone));
            if (!class'VRHandRolePose'.static.ValidQuaternion(Q)) return false;
            Fingers.AddItem(Q);
        }
    return Fingers.Length == 15;
}

function RestoreAttached(int Hand)
{
    if (Hands[Hand].HiddenHand != None)
        Hands[Hand].HiddenHand.SetHidden(Hands[Hand].bWasHidden);
    Hands[Hand].HiddenHand = None;
    Hands[Hand].AuthoredFingers.Length = 0;
}

function bool Cancel(int Hand)
{
    if (Hand < 0 || Hand > 1) return false;
    RestoreAttached(Hand);
    Hands[Hand].Source = None;
    Hands[Hand].ContactFingers.Length = 0;
    Hands[Hand].bActive = false;
    if (Bridge != None && Bridge.FreeHandPose != None)
        Bridge.FreeHandPose.EndWorldCatchPose(Hand);
    return false;
}

// Called after canonical presenters place their actual stock gun/hand mesh.
// All fifteen source joints validate before the attached hand is hidden.
function bool Place(VRHandsBridge B, int Hand, VRWeaponRuntime Runtime)
{
    local VRWorldDropPrediction P;
    local KFSkeletalMeshComponent Authored;
    local array<quat> Fingers;
    local quat ControllerQ, WristQ, Q;
    local float Alpha;
    local int I;
    if (B != None) Bridge = B;
    if (B == None || Hand < 0 || Hand > 1 || B.FreeHandPose == None || !B.FreeHandPose.bReady
        || B.HandInventory == None || B.HandInventory.WorldDrops == None
        || (B.NativeValidMask & (1 << Hand)) == 0) return Cancel(Hand);
    for (I = 0; I < B.HandInventory.WorldDrops.Predictions.Length; ++I)
    {
        P = B.HandInventory.WorldDrops.Predictions[I];
        if (P != None && !P.bDeleteMe && P.bVisualHeld && P.VisualHand == Hand) break;
        P = None;
    }
    if (P == None || P.OwnedWeapon == None || P.OwnedWeapon.bDeleteMe) return Cancel(Hand);
    if (Runtime != None && Runtime.Item != P.OwnedWeapon) return Cancel(Hand);
    ControllerQ = QuatFromRotator(Hand == 0 ? B.LeftRotation : B.RightRotation);
    if (Hands[Hand].Source != P || Hands[Hand].ContactRequest != P.ContactRequest)
    {
        Cancel(Hand);
        if (!SampleFingers(B.Arms, Hand, Fingers)) return false;
        WristQ = B.Arms.GetBoneQuaternion(B.HandBone(Hand));
        Hands[Hand].ContactFingers = Fingers;
        Hands[Hand].WristInController = QuatProduct(QuatInvert(ControllerQ), WristQ);
        Hands[Hand].Source = P; Hands[Hand].ContactRequest = P.ContactRequest;
    }
    WristQ = QuatProduct(ControllerQ, Hands[Hand].WristInController);
    Alpha = 0;
    if (P.bConfirmedAcquire)
    {
        Alpha = P.ConfirmedAcquireAlpha();
        if (Alpha >= 1) return Cancel(Hand);
        Alpha = Alpha * Alpha * (3 - 2 * Alpha);
        if (Runtime == None || Runtime.Item != P.OwnedWeapon || Runtime.Presenter == None) return Cancel(Hand);
        Authored = Runtime.Presenter.AttachedHands[Hand];
        if (Authored == None) return Cancel(Hand);
        if (Hands[Hand].HiddenHand != Authored)
        {
            RestoreAttached(Hand);
            if (!SampleFingers(Authored, Hand, Fingers)) return Cancel(Hand);
            Hands[Hand].AuthoredFingers = Fingers;
            Hands[Hand].HiddenHand = Authored;
            Hands[Hand].bWasHidden = Authored.HiddenGame;
        }
        Q = Authored.GetBoneQuaternion(B.HandBone(Hand));
        if (!class'VRHandRolePose'.static.ValidQuaternion(Q)) return Cancel(Hand);
        WristQ = QuatSlerp(WristQ, Q, Alpha, true);
        Authored.SetHidden(true);
    }
    else RestoreAttached(Hand);
    if (Hands[Hand].ContactFingers.Length != 15) return Cancel(Hand);
    for (I = 0; I < 15; ++I)
    {
        Q = Hands[Hand].ContactFingers[I];
        if (P.bConfirmedAcquire) Q = QuatSlerp(Q, Hands[Hand].AuthoredFingers[I], Alpha, true);
        B.FreeHandPose.SetWorldCatchFinger(Hand, I, Q);
    }
    Hands[Hand].ShownWrist = WristQ;
    Hands[Hand].bActive = true;
    B.FreeHandPose.BeginWorldCatchPose(Hand);
    return true;
}

function bool CoversHand(int Hand)
{
    return Hand >= 0 && Hand <= 1 && Hands[Hand].bActive;
}

function quat WristRotation(int Hand) { return Hands[Hand].ShownWrist; }

function Shutdown()
{
    Cancel(0); Cancel(1); Bridge = None;
}
