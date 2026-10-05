// Throw and recall input for the RAVEN-7 melee inventory weapon. The trigger
// prepares while held and throws on release at measured hand velocity.
// A fresh airborne hold suspends it; release recalls. A resting axe recalls
// immediately on a fresh press. Grip remains a direct recall shortcut.
class VRTomahawks extends Object;

var VRDualHandInput Input;
var VRHandsBridge Bridge;
var VRWeap_Tomahawk Sampled[2];
var vector LastPosition[2], LastPawn[2], Velocity[2];
var float LastTime[2], NextRecallSample[2];
var int Samples[2], Epoch[2];
struct ThrowGesture
{
    // bReady: the trigger has been released since this hand took the axe,
    // so a pull is deliberate. Each recall input must be released before a
    // fresh press; a grip held through the throw must never auto-recall.
    var bool bReady, bTriggerWasDown, bRecallReady, bPreparing, bRecallOnRelease;
    var bool bGripWasDown, bGripReady, bGripRecallRequested;
};
var ThrowGesture Gesture[2];

function Initialize(VRDualHandInput I)
{
    Input = I; Bridge = I.Bridge;
}

function bool CanThrowHand(VRWeap_Tomahawk W, int Hand)
{
    return Hand >= 0 && Hand < 2 && Input.ContextValid() && Input.Grenade.HandTracked(Hand)
        && !Input.IsSelectorOpen(0) && !Input.IsSelectorOpen(1)
        && Input.Inventory.Registry.GetPrimary(Hand) != None
        && Input.Inventory.Registry.GetPrimary(Hand).Item == W;
}

function CancelHand(int Hand)
{
    if (Hand < 0 || Hand > 1) return;
    Sampled[Hand] = None; Samples[Hand] = 0;
    Gesture[Hand].bReady = false;
    Gesture[Hand].bPreparing = false;
    Gesture[Hand].bRecallOnRelease = false;
    Gesture[Hand].bRecallReady = false;
    Gesture[Hand].bGripReady = false;
    Gesture[Hand].bGripRecallRequested = false;
    Gesture[Hand].bTriggerWasDown = (Bridge.NativeTriggerMask & Bridge.NativeTriggerActiveMask & (1 << Hand)) != 0;
    Gesture[Hand].bGripWasDown = (Bridge.NativeGripMask & (1 << Hand)) != 0;
}

// The held axe's own frame when the rig is posed; the fist otherwise.
function HandPose(VRWeap_Tomahawk W, int Hand, out vector At, out rotator Facing)
{
    local vector Wrist, Forward, Thumb, Palm;
    if (W != None && W.HeldFrame(At, Facing)) return;
    Input.Grenade.HandFrame(Hand, Wrist, Forward, Thumb, Palm);
    Forward = Normal(Forward); Thumb = Normal(Thumb - Forward * (Thumb dot Forward));
    At = Wrist + Forward * 8.5 + Palm * 3;
    Facing = OrthoRotation(Forward, Thumb cross Forward, Thumb);
}

function Update(float Delta)
{
    local int Hand;
    local VRWeaponRuntime R;
    local VRWeap_Tomahawk W;
    local float Now, Elapsed;
    local vector At, Measured;
    local rotator Facing;
    local bool Grip, GripEdge, Trigger, TriggerEdge, TriggerReleased;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Input.Inventory.Registry.GetPrimary(Hand);
        W = R != None ? VRWeap_Tomahawk(R.Item) : None;
        // Standalone authority validates its own throws; a server binds the
        // owner's network channel instead (KF2VRNetChannel).
        if (W != None && W.Role == ROLE_Authority && W.ThrowAuthority != self)
        { W.CanThrowHand = CanThrowHand; W.ThrowAuthority = self; }
        if (W == None || !CanThrowHand(W, Hand))
        { CancelHand(Hand); continue; }
        Grip = (Bridge.NativeGripMask & (1 << Hand)) != 0;
        Trigger = (Bridge.NativeTriggerMask & Bridge.NativeTriggerActiveMask & (1 << Hand)) != 0;
        GripEdge = Grip && !Gesture[Hand].bGripWasDown;
        Gesture[Hand].bGripWasDown = Grip;
        TriggerEdge = Trigger && !Gesture[Hand].bTriggerWasDown;
        TriggerReleased = !Trigger && Gesture[Hand].bTriggerWasDown;
        Gesture[Hand].bTriggerWasDown = Trigger;
        if (W.bAxeAway)
        {
            // Release-to-throw has already released the trigger. A new hold
            // therefore cannot be confused with the throwing gesture.
            if (!Trigger) Gesture[Hand].bRecallReady = true;
            if (!Grip) Gesture[Hand].bGripReady = true;
            if (GripEdge && Gesture[Hand].bGripReady) Gesture[Hand].bGripRecallRequested = true;
            if (TriggerEdge && Gesture[Hand].bRecallReady)
                Gesture[Hand].bRecallOnRelease = true;
            if (Now >= NextRecallSample[Hand])
            {
                HandPose(W, Hand, At, Facing);
                if (Gesture[Hand].bRecallOnRelease)
                {
                    if (Trigger) W.ServerSuspend(Hand, At, Facing);
                    else W.ServerRecall(Hand, At, Facing);
                }
                else if (Gesture[Hand].bGripRecallRequested)
                    W.ServerRecall(Hand, At, Facing);
                W.ServerRecallPose(Hand, At, Facing);
                NextRecallSample[Hand] = Now + 0.1;
            }
            // Keep the gesture through network phase latency; an early release
            // retries recall until authority accepts it or the axe is caught.
            Sampled[Hand] = None; Samples[Hand] = 0;
            Gesture[Hand].bPreparing = false;
            continue;
        }
        Elapsed = Now - LastTime[Hand];
        if (Sampled[Hand] != W || Epoch[Hand] != Bridge.NativeCalibrationEpoch
            || Elapsed < 0 || Elapsed > 0.1)
        {
            CancelHand(Hand); Sampled[Hand] = W;
            Epoch[Hand] = Bridge.NativeCalibrationEpoch;
            LastPosition[Hand] = Bridge.PalmPosition(Hand); LastPawn[Hand] = Bridge.Human.Location;
            LastTime[Hand] = Now; Velocity[Hand] = vect(0,0,0);
            // A trigger already held on draw/recenter must release before a throw.
            Gesture[Hand].bReady = !Trigger;
            Gesture[Hand].bRecallOnRelease = false;
            continue;
        }
        if (Elapsed > 0)
        {
            Measured = (Bridge.PalmPosition(Hand) - LastPosition[Hand]
                - (Bridge.Human.Location - LastPawn[Hand])) / Elapsed;
            if (!class'VRGrenadeThrow'.static.Bounded(Measured, 1800))
            { CancelHand(Hand); continue; }
            Velocity[Hand] = Measured * 0.65 + Velocity[Hand] * 0.35;
            LastPosition[Hand] = Bridge.PalmPosition(Hand); LastPawn[Hand] = Bridge.Human.Location;
            LastTime[Hand] = Now; ++Samples[Hand];
        }
        if (TriggerEdge && Gesture[Hand].bReady) Gesture[Hand].bPreparing = true;
        // Releasing a prepared swing throws; a still-hand release keeps it.
        if (TriggerReleased && Gesture[Hand].bPreparing && Samples[Hand] >= 3 && VSize(Velocity[Hand]) >= 120)
        {
            HandPose(W, Hand, At, Facing);
            W.ServerThrow(Hand, At, Velocity[Hand], Facing);
            if (R.Presenter != None && R.Presenter.PhysicalMelee != None) R.Presenter.PhysicalMelee.Cancel();
            Input.CancelSprint();
            Gesture[Hand].bReady = false; Gesture[Hand].bRecallReady = true;
            Gesture[Hand].bRecallOnRelease = false;
            Gesture[Hand].bGripReady = !Grip; Gesture[Hand].bGripRecallRequested = false;
        }
        if (!Trigger) { Gesture[Hand].bReady = true; Gesture[Hand].bPreparing = false; }
    }
}
