// Crossbow cocking precedes bolt insertion (R32). After a shot the string has
// flown forward and the pump stands back: the hand pushes the pump forward to
// catch the string, then pulls it back to cock, then loads the bolt. Both
// strokes are the ordinary stock clip's own, sampled with the complete cable
// and spring deformation. Progress runs -1 (pump back, string loose) through
// 0 (pump forward on the string) to 1 (cocked). This helper owns
// presentation/input only; the ordinary reload pays the bolt.
class VRCrossbowCocking extends Object;

var VRInteractiveReload Owner;
var VRWeaponRuntime Runtime;
var KFWeapon Gun;
var VRActionPath Sample;
var VRReloadHandPose HandPose;
var VRReloadMotionGuard Motion;
var AnimNodeSequence LiveNode;
// The empty reload stock chose (Reload_Empty_Elite under a tactical-reload perk).
var name CockClip;
var float StartTime, EndTime, GrabProgress;
var vector RestPump, ForwardPump, RearPump, GripLocal, GrabHand;
var bool bEngaged, bGripWasDown;
var StaticMeshComponent HintRing;
var MaterialInstanceConstant HintMaterial;
var float HintSince;
struct CockFrame
{
    var float Time, Progress;
    var vector Pump;
    var quat PumpQ;
};
var array<CockFrame> Frames, ForwardFrames;

static function bool Supported(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_Bow_Crossbow';
}

function bool Begin(VRInteractiveReload O)
{
    local int I;
    local float T, Limit, Best, Travel;
    local vector P, Initial, Axis;
    local quat Q;
    local CockFrame Frame;
    Cancel();
    if (O.Automatic(O.Runtime)) return true;
    Owner = O; Runtime = O.Runtime; Gun = O.Gun;
    HintSince = O.Now();
    if (!Supported(Gun) || Runtime == None || Gun.MySkelMesh == None) return false;
    // A fired bolt, or a gun no hand has cocked yet, starts with the pump
    // back and the string loose. A stroke left part-way keeps its place.
    if (Gun.AmmoCount[0] == 0 && (Runtime.bCrossbowCockLoaded || !Runtime.bCrossbowStroked))
    {
        Runtime.CrossbowCockProgress = -1;
        Runtime.bCrossbowCockLoaded = false;
        Runtime.bCrossbowStroked = false;
    }
    if (Gun.AmmoCount[0] > 0)
    {
        Runtime.bCrossbowCockLoaded = true;
        Runtime.CrossbowCockProgress = 1;
    }
    // Sample, pose and resume the clip whose timers stock started; scrubbing
    // the plain clip under elite timers resumed the wrong tail.
    CockClip = Gun.UseTacticalReload() ? class'KFWeapon'.const.ReloadEmptyMagEliteAnim
        : class'KFWeapon'.const.ReloadEmptyMagAnim;
    if (Gun.MySkelMesh.FindAnimSequence(CockClip) == None) CockClip = 'Reload_Empty';
    Sample = new(self) class'VRActionPath';
    if (!Sample.PrepareRef(O.Bridge, Gun, O.RootBone)) return false;
    O.Bridge.AttachComponent(Sample.Ref);
    Sample.RefSeq.SetAnim(CockClip);
    if (Sample.RefSeq.AnimSeq == None || Sample.Ref.MatchRefBone('RW_Pump') < 0)
    { O.Bridge.DetachComponent(Sample.Ref); return false; }
    Limit = Sample.RefSeq.AnimSeq.SequenceLength;
    for (I = 0; I < Sample.RefSeq.AnimSeq.Notifies.Length; ++I)
        if (KFAnimNotify_ReloadAmmo(Sample.RefSeq.AnimSeq.Notifies[I].Notify) != None)
            Limit = FMin(Limit, Sample.RefSeq.AnimSeq.Notifies[I].Time);
    Sample.PoseRef(0);
    Sample.RefRelative('RW_Pump', Initial, Q);
    RestPump = Initial;
    Best = 0;
    for (I = 0; I <= 240; ++I)
    {
        T = Limit * float(I) / 240.0;
        Sample.PoseRef(T);
        Sample.RefRelative('RW_Pump', P, Q);
        Travel = VSize(P - Initial);
        if (Travel > Best) { Best = Travel; StartTime = T; ForwardPump = P; }
    }
    EndTime = 0;
    for (I = 1; I <= 240; ++I)
    {
        T = StartTime + (Limit - StartTime) * float(I) / 240.0;
        Sample.PoseRef(T);
        Sample.RefRelative('RW_Pump', P, Q);
        if (VSize(P - Initial) > Best * 0.03) continue;
        EndTime = T; RearPump = P; break;
    }
    if (!(Best > 1 && Best < 40 && EndTime > StartTime))
    { O.Bridge.DetachComponent(Sample.Ref); return false; }
    Sample.PoseRef(StartTime);
    GripLocal = QuatRotateVector(QuatInvert(Sample.Ref.GetBoneQuaternion('RW_Pump')),
        Sample.Ref.GetBoneLocation(O.Bridge.HandBone(0)) - Sample.Ref.GetBoneLocation('RW_Pump'));
    Frames.Length = 0;
    Axis = RearPump - ForwardPump;
    for (I = 0; I <= 64; ++I)
    {
        Frame.Time = StartTime + (EndTime - StartTime) * float(I) / 64.0;
        Sample.PoseRef(Frame.Time);
        Sample.RefRelative('RW_Pump', Frame.Pump, Frame.PumpQ);
        Frame.Progress = FClamp(((Frame.Pump - ForwardPump) dot Axis) / VSizeSq(Axis), 0, 1);
        if (I > 0 && Frame.Progress < Frames[I - 1].Progress - 0.01)
        { O.Bridge.DetachComponent(Sample.Ref); return false; }
        Frames.AddItem(Frame);
    }
    // The forward stroke onto the string: the clip's own push from the pump's
    // rest at the start of the empty reload to its forward stop.
    ForwardFrames.Length = 0;
    Axis = ForwardPump - RestPump;
    for (I = 0; I <= 32; ++I)
    {
        Frame.Time = StartTime * float(I) / 32.0;
        Sample.PoseRef(Frame.Time);
        Sample.RefRelative('RW_Pump', Frame.Pump, Frame.PumpQ);
        Frame.Progress = FClamp(((Frame.Pump - RestPump) dot Axis) / VSizeSq(Axis), 0, 1);
        // Cable settle can step back a hair; keep the stroke one-way.
        if (I > 0) Frame.Progress = FMax(Frame.Progress, ForwardFrames[I - 1].Progress);
        ForwardFrames.AddItem(Frame);
    }
    O.Bridge.DetachComponent(Sample.Ref);
    HandPose = new(self) class'VRReloadHandPose';
    if (O.Bridge.FreeHandPose == None || !O.Bridge.FreeHandPose.bReady
        || !HandPose.Build(O.Bridge, Gun.MySkelMesh,
            CockClip, 'RW_Pump', StartTime, EndTime, O.OffHand(), 0, true)) return false;
    Motion = new(self) class'VRReloadMotionGuard';
    Motion.SpeedLimit = 1500;
    LiveNode = O.Bridge.ResolveLiveWeaponAnimNode(Gun);
    if (LiveNode == None || LiveNode != Gun.WeaponAnimSeqNode) return false;
    bGripWasDown = O.GripDown(O.OffHand());
    O.PauseStock();
    return true;
}

function bool Valid()
{
    return Owner != None && Owner.bActive && Owner.Gun == Gun && Owner.Runtime == Runtime
        && Owner.StillValid() && Gun != None && !Gun.bDeleteMe && Sample != None
        && LiveNode != None && Gun.WeaponAnimSeqNode == LiveNode;
}

function bool BlocksInsert()
{
    return Valid() && Runtime.CrossbowCockProgress < 1;
}

function vector Contact()
{
    local vector P;
    local quat Q;
    local float T;
    SamplePose(P, Q, T);
    return Owner.Gun.MySkelMesh.GetBoneLocation(Owner.RootBone)
        + QuatRotateVector(Owner.Gun.MySkelMesh.GetBoneQuaternion(Owner.RootBone),
            (P + QuatRotateVector(Q, GripLocal)) * Owner.ScaleOf(Gun));
}

function SamplePose(out vector P, out quat Q, out float T)
{
    if (Runtime.CrossbowCockProgress < 0 && ForwardFrames.Length >= 2)
        SampleFrames(ForwardFrames, Runtime.CrossbowCockProgress + 1, P, Q, T);
    else SampleFrames(Frames, FMax(Runtime.CrossbowCockProgress, 0), P, Q, T);
}

function SampleFrames(array<CockFrame> Track, float Progress, out vector P, out quat Q, out float T)
{
    local int I;
    local float Blend;
    I = 0;
    while (I < Track.Length - 2 && Track[I + 1].Progress < Progress) ++I;
    Blend = FClamp((Progress - Track[I].Progress)
        / FMax(Track[I + 1].Progress - Track[I].Progress, 0.0001), 0, 1);
    P = Track[I].Pump * (1 - Blend) + Track[I + 1].Pump * Blend;
    Q = QuatSlerp(Track[I].PumpQ, Track[I + 1].PumpQ, Blend, true);
    T = Track[I].Time * (1 - Blend) + Track[I + 1].Time * Blend;
}

// A reload started by gripping the pump (VRInteractiveReload.TryCrossbowCock):
// the squeeze that started it also takes the pump.
function TakeHeldGrip()
{
    bGripWasDown = false;
}

function Tick()
{
    local bool Grip, Edge, Support;
    local vector P, Axis;
    local float Progress;
    if (!Valid()) { Cancel(); return; }
    if (Gun.AmmoCount[0] > 0) Runtime.bCrossbowCockLoaded = true;
    if (!BlocksInsert()) { bEngaged = false; return; }
    Grip = Owner.GripDown(Owner.OffHand());
    Edge = Grip && !bGripWasDown;
    bGripWasDown = Grip;
    if ((Owner.Bridge.NativeValidMask & Owner.Bridge.NativeGripActiveMask & 3) != 3
        || !Owner.HandFree(Owner.OffHand(), true))
    { bEngaged = false; Motion.Reset(); return; }
    P = QuatRotateVector(QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(Owner.RootBone)),
        Owner.Bridge.Hands[Owner.OffHand()].Position - Gun.MySkelMesh.GetBoneLocation(Owner.RootBone)) / Owner.ScaleOf(Gun);
    if (!bEngaged)
    {
        Support = Owner.InputOwner.Inventory.Registry.GetSupport(Owner.OffHand()) == Runtime;
        if ((!Edge && !(Support && Grip))
            || VSize(Owner.Bridge.Hands[Owner.OffHand()].Position - Contact()) > Owner.RackRadius) return;
        if (Support) Owner.InputOwner.Inventory.ReleaseHand(Owner.OffHand());
        bEngaged = true; GrabHand = P; GrabProgress = Runtime.CrossbowCockProgress;
        Motion.Begin(P * Owner.ScaleOf(Gun), Owner.Now());
    }
    if (!Grip || !Motion.Check(P * Owner.ScaleOf(Gun), Owner.Now()))
    { bEngaged = false; Motion.Reset(); return; }
    if (Runtime.CrossbowCockProgress < 0)
    {
        // Push forward onto the string. Once caught, the same hold pulls back.
        Axis = ForwardPump - RestPump;
        Progress = FClamp(GrabProgress + ((P - GrabHand) dot Axis) / VSizeSq(Axis), -1, 0);
        Runtime.CrossbowCockProgress = Progress;
        Runtime.bCrossbowStroked = true;
        if (Progress >= -0.03)
        {
            Runtime.CrossbowCockProgress = 0;
            GrabHand = P; GrabProgress = 0;
            Owner.Pulse(1 << Owner.OffHand(), 0.35, 0.025);
        }
        return;
    }
    Axis = RearPump - ForwardPump;
    Progress = FClamp(GrabProgress + ((P - GrabHand) dot Axis) / VSizeSq(Axis), 0, 1);
    Runtime.CrossbowCockProgress = Progress;
    if (Progress >= 0.97)
    {
        Runtime.CrossbowCockProgress = 1;
        bEngaged = false; Motion.Reset();
        Owner.Pulse(1 << Owner.OffHand(), 0.5, 0.03);
    }
}

function Place()
{
    local vector P;
    local quat Q, WristQ;
    local float T;
    if (HintRing != None) HintRing.SetHidden(true);
    if (!Valid() || Owner.bSeated) { if (HandPose != None) HandPose.Cancel(); return; }
    // Pose the complete original mechanism, including the cable/leaf springs.
    // Stock timers stay under VRInteractiveReload; posing executes no notify.
    if (LiveNode.AnimSeqName != CockClip) LiveNode.SetAnim(CockClip);
    SamplePose(P, Q, T);
    LiveNode.SetPosition(T, false);
    LiveNode.bPlaying = false;
    Gun.MySkelMesh.ForceSkelUpdate(); Gun.MySkelMesh.ForceUpdate(true);
    PlaceHint();
    if (HandPose == None) return;
    P = Gun.MySkelMesh.GetBoneLocation(Owner.RootBone)
        + QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(Owner.RootBone), P * Owner.ScaleOf(Gun));
    Q = QuatProduct(Gun.MySkelMesh.GetBoneQuaternion(Owner.RootBone), Q);
    WristQ = Owner.Bridge.FreeHandPose.WristRotation(Owner.OffHand(), Owner.OffHand() == 0 ? Owner.Bridge.LeftRotation : Owner.Bridge.RightRotation);
    HandPose.Place(Owner.Now(), bEngaged, FMax(0, (T - StartTime) / (EndTime - StartTime)), 1,
        Owner.Bridge.Hands[Owner.OffHand()].Position, WristQ, P, Q, Owner.ScaleOf(Gun));
}

function PlaceHint()
{
    local float Alpha;
    local vector At, ToEye;
    if (!BlocksInsert() || bEngaged || Owner.CluesAutomatic(Gun)
        || !Owner.HandFree(Owner.OffHand(), true)) return;
    At = Contact();
    Alpha = Owner.ClueAlpha(HintSince, Gun,
        VSize(Owner.Bridge.Hands[Owner.OffHand()].Position - At) <= Owner.RackRadius);
    if (Alpha <= 0) return;
    Owner.EnsureVisuals();
    // A fitted cocking-handle shell replaces the ring fallback.
    if (!Owner.bRingMesh || Owner.PartGlows(Gun, 2)) return;
    if (HintRing == None)
    {
        HintMaterial = Owner.MakeRingMaterial(Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true)), class'VRInteractionColours'.const.ROLE_ACTION);
        HintRing = Owner.MakeComponent(Owner.SeatRing.StaticMesh, HintMaterial);
    }
    HintMaterial.SetScalarParameterValue('Scalar_Opacity', Alpha);
    HintRing.SetDepthPriorityGroup(Gun.MySkelMesh.DepthPriorityGroup);
    ToEye = Normal(Owner.Bridge.HeadPosition - At);
    Owner.PlaceProp(HintRing, At + ToEye * 1.5, QuatFromRotator(rotator(ToEye)), Owner.RackRingRadius);
}

function string ReloadPrompt(KFWeapon W)
{
    if (W != Gun || !BlocksInsert() || !Owner.Bridge.bReloadHints || Owner.CluesAutomatic(W)) return "";
    if (Runtime.CrossbowCockProgress < 0) return bEngaged ? "PUSH FORWARD ONTO STRING" : "GRIP COCKING HANDLE";
    return bEngaged ? "PULL TO COCK" : "GRIP COCKING HANDLE";
}

function bool OwnsHand(int Hand) { return Valid() && bEngaged && Hand == Owner.OffHand(); }
function bool CoversHand(int Hand) { return Valid() && HandPose != None && HandPose.bVisible && Hand == Owner.OffHand(); }

function Cancel()
{
    if (HintRing != None && Owner != None) Owner.Bridge.DetachComponent(HintRing);
    HintRing = None; HintMaterial = None;
    // Payment and completion can happen in one update, between helper ticks.
    // Remember the real loaded bolt here so the next shot owes a fresh cock.
    if (Runtime != None && Gun != None && !Gun.bDeleteMe && Gun.AmmoCount[0] > 0)
        Runtime.bCrossbowCockLoaded = true;
    if (HandPose != None) HandPose.Cancel();
    if (Sample != None && Sample.Ref != None) Sample.Ref.DetachFromAny();
    if (Motion != None) Motion.Reset();
    bEngaged = false; Owner = None; Runtime = None; Gun = None; LiveNode = None;
}
