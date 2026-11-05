// Physical admission for authored reload controls. Stock remains the only
// ammunition writer and retains its perk-scaled completion timers.
class VRReloadFinishAction extends VRManualPump
    dependson(VRReloadFinishCatalog, VRActionPath);

var VRActionPath Cycle, SampleRef;
var array<VRActionPath> OutPaths, BackPaths;
var int Profile;
var bool bComplete, bOut, bReturning, bAcquirePlayed;
var float Amount, LiveStartTime, LiveFinishTime;
var AnimNodeSequence LiveNode;
var name LiveClip;
// Why the last Begin refused, for the session's rejection log.
var string BindFailure;
var bool bRecoveredPaid, bPaidAdmitted;
var float AutoFinishAt, AutoFinishAmount;
var vector LastPressPalm, LastPressTip;
var float LastPressTime;
var bool bPressArmed;
var VRWeaponRuntime PressOther;
var int PressOtherRevision, PressCalibration, PressRoom;

// These powered controls need contact, not a grip toggle. Require a fresh
// approach in the receiver frame so an overlapping hand cannot auto-press.
function bool PhysicalPress()
{
    local vector Palm, Button;
    local float Time, DT, Distance;
    local bool Press;
    local VRWeaponRuntime Other;
    local vector A, B;
    local quat Q;
    if (Profile < 0 || Profile > 2) return false;
    Time = Owner.Now(); DT = Time - LastPressTime;
    Palm = QuatRotateVector(QuatInvert(RootQ()), Bridge.PalmPosition(OffHand()) - RootPos());
    Button = QuatRotateVector(QuatInvert(RootQ()), Gun.MySkelMesh.GetBoneLocation(
        class'VRReloadFinishCatalog'.default.Profiles[Profile].Bone) - RootPos());
    Other = Owner.InputOwner.Inventory.GetHeldForHand(OffHand());
    if (Other != None && Other != Runtime && Other.IsCurrent() && Other.Item.MySkelMesh != None
        && Other.Item.MySkelMesh.MatchRefBone('RW_Weapon') >= 0 && Profile <= 2)
    {
        Q = Other.Item.MySkelMesh.GetBoneQuaternion('RW_Weapon');
        A = Other.Item.MySkelMesh.GetBoneLocation('RW_Weapon');
        Palm = QuatRotateVector(QuatInvert(RootQ()), A - RootPos());
        B = QuatRotateVector(QuatInvert(RootQ()), A + QuatRotateVector(Q, vect(28,0,0)) - RootPos());
        A = QuatRotateVector(QuatInvert(RootQ()), A - QuatRotateVector(Q, vect(8,0,0)) - RootPos());
        Distance = class'VRCylinderSession'.static.SegmentDistance(Button, A, B);
    }
    else
    {
        Other = None;
        if (!Owner.HandFree(OffHand(), true)) { LastPressTime = 0; bPressArmed = false; return false; }
        B = Palm;
        Distance = VSize(Palm - Button);
    }
    if (Other != PressOther || (Other != None && Other.OwnershipRevision != PressOtherRevision)
        || PressCalibration != Bridge.NativeCalibrationEpoch || PressRoom != Bridge.NativeRoomSpaceEpoch)
    { LastPressTime = 0; bPressArmed = false; }
    PressOther = Other;
    if (Other != None) PressOtherRevision = Other.OwnershipRevision;
    PressCalibration = Bridge.NativeCalibrationEpoch; PressRoom = Bridge.NativeRoomSpaceEpoch;
    if (LastPressTime <= 0 || DT <= 0 || DT > 0.1
        || VSize(Palm - LastPressPalm) > FMax(12, 1000 * DT)
        || VSize(B - LastPressTip) > FMax(12, 1000 * DT)) bPressArmed = false;
    else if (Distance > Radius * 1.4) bPressArmed = true;
    else if (bPressArmed && Distance <= Radius) { Press = true; bPressArmed = false; }
    LastPressPalm = Palm; LastPressTip = B; LastPressTime = Time;
    return Press;
}

function name PoseClip()
{
    if (Profile < 0) return '';
    return class'VRReloadFinishCatalog'.default.Profiles[Profile].ReferenceClip == ''
        ? 'Reload_Empty' : class'VRReloadFinishCatalog'.default.Profiles[Profile].ReferenceClip;
}

function bool SampleRange(float StartTime, float EndTime, out array<VRActionPath> Paths)
{
    local int I, J, Count;
    local name Bone;
    local VRActionPath P;
    local VRActionPath.PathPose Point;
    Count = 1;
    for (I = 0; I < 12; ++I)
        if (class'VRReloadFinishCatalog'.default.Profiles[Profile].FollowBones[I] != '') ++Count;
    for (J = 0; J < Count; ++J)
    {
        Bone = J == 0 ? class'VRReloadFinishCatalog'.default.Profiles[Profile].Bone
            : class'VRReloadFinishCatalog'.default.Profiles[Profile].FollowBones[J-1];
        if (SampleRef.Ref.MatchRefBone(Bone) < 0) return false;
        P = new(self) class'VRActionPath';
        P.Bones[0] = Bone; P.BoneCount = 1;
        P.GripLocal = SampleRef.GripLocal; P.GripQ = SampleRef.GripQ; P.GripTime = SampleRef.GripTime;
        Paths.AddItem(P);
    }
    for (I = 0; I <= 16; ++I)
    {
        SampleRef.PoseRef(StartTime + (EndTime - StartTime) * float(I) / 16.0);
        for (J = 0; J < Paths.Length; ++J)
        {
            P = Paths[J];
            SampleRef.RefRelative(P.Bones[0], Point.P[0], Point.Q[0]);
            Point.C = Point.P[0] + QuatRotateVector(Point.Q[0], P.GripLocal);
            if (J == 0 && I > 0) P.Length += VSize(Point.C - P.Path[I-1].C);
            P.Path.AddItem(Point);
            P.PathS.AddItem(Paths[0].Length);
        }
    }
    for (J = 0; J < Paths.Length; ++J)
        for (I = 0; I <= 16; ++I)
            Paths[J].PathS[I] = Paths[0].Length > 0.001 ? Paths[J].PathS[I] / Paths[0].Length : float(I) / 16.0;
    return true;
}

function bool Begin(VRWeaponRuntime R, int Hand, optional bool bResumePaid, optional name DetachedClip)
{
    local int I;
    local float EventTime, TimeScale;
    local vector P, HandP;
    local quat Q, HandQ;
    local name HandBone;
    local AnimNotify_AkEvent Event;
    local AnimSequence AcceptedSequence;
    local VRReloadFinishCatalog.FinishProfile F;
    BindFailure = "no-runtime";
    if (R == None) return false;
    Unbind();
    // A recovered magazine has no stock reload transaction. Sample its actual
    // normal/perk clip without entering Reloading or starting an ammo timer.
    if (DetachedClip != '')
    {
        AcceptedSequence = R.Item.MySkelMesh.FindAnimSequence(DetachedClip);
        BindFailure = "no-detached-clip";
        if (AcceptedSequence == None) return false;
    }
    else if (R.Item.WeaponAnimSeqNode != None) AcceptedSequence = R.Item.WeaponAnimSeqNode.AnimSeq;
    Profile = bResumePaid ? R.FinishProfileToken - 1 : class'VRReloadFinishCatalog'.static.Find(R.Item, Owner.bEmptyStart, AcceptedSequence);
    BindFailure = "no-profile live=" $ (AcceptedSequence == None ? 'None' : AcceptedSequence.SequenceName);
    if (Profile < 0 || Profile >= class'VRReloadFinishCatalog'.default.Profiles.Length) return false;
    F = class'VRReloadFinishCatalog'.default.Profiles[Profile];
    if (F.WeaponClass != class'VRReloadCatalog'.static.ProfileClass(R.Item.Class)) return false;
    LiveNode = R.Item.WeaponAnimSeqNode;
    if (!bResumePaid && AcceptedSequence == None) return false;
    LiveClip = bResumePaid ? R.FinishLiveClip : AcceptedSequence.SequenceName;
    if (DetachedClip != '') LiveNode = None;
    Runtime = R; Gun = R.Item; GunHand = Hand; RootBone = Owner.RootBone;
    SampleRef = new(self) class'VRActionPath';
    BindFailure = "reference";
    if (!SampleRef.PrepareRef(Bridge, Gun, RootBone)) { Gun = None; return false; }
    SampleRef.RefSeq.SetAnim(PoseClip());
    if (SampleRef.RefSeq.AnimSeq == None || SampleRef.Ref.MatchRefBone(F.Bone) < 0
        || SampleRef.RefSeq.AnimSeq.SequenceLength <= F.FinishTime) { Gun = None; return false; }
    BindFailure = "resume-clip";
    if (bResumePaid)
    {
        // The accepted clip/profile survives a swap. Idle and a later perk
        // choice cannot substitute another finishing action or omit this one.
        SampleRef.RefSeq.SetAnim(LiveClip);
        if (SampleRef.RefSeq.AnimSeq == None || R.FinishLiveStart < 0
            || R.FinishLiveEnd < R.FinishLiveStart
            || R.FinishLiveEnd > SampleRef.RefSeq.AnimSeq.SequenceLength) { Gun = None; return false; }
        LiveStartTime = R.FinishLiveStart; LiveFinishTime = R.FinishLiveEnd;
        LiveNode = None;
        SampleRef.RefSeq.SetAnim(PoseClip());
    }
    else
    {
        TimeScale = AcceptedSequence.SequenceLength / SampleRef.RefSeq.AnimSeq.SequenceLength;
        EventTime = F.SoundTime * TimeScale;
        for (I = 0; I < AcceptedSequence.Notifies.Length; ++I)
        {
            Event = AnimNotify_AkEvent(AcceptedSequence.Notifies[I].Notify);
            if (Event != None && Event.AkEvent != None && PathName(Event.AkEvent) ~= F.Sound)
            { EventTime = AcceptedSequence.Notifies[I].Time; break; }
        }
        LiveStartTime = FClamp(EventTime + (F.StartTime - F.SoundTime) * TimeScale, 0, AcceptedSequence.SequenceLength);
        LiveFinishTime = FClamp(EventTime + (F.FinishTime - F.SoundTime) * TimeScale, LiveStartTime, AcceptedSequence.SequenceLength);
    }
    HandBone = Bridge.HandBone(F.SourceHand);
    Bridge.AttachComponent(SampleRef.Ref);
    SampleRef.PoseRef(F.GripTime);
    SampleRef.RefRelative(F.Bone, P, Q);
    SampleRef.RefRelative(HandBone, HandP, HandQ);
    // Extended limits exist only for measured offset geometry (tank lever,
    // Caulk release); the user's contact remains the sampled wrist on that part.
    BindFailure = "grip-contact hand=" $ VSize(HandP - P) @ "finger=" $ Owner.RigSample.RackFingerContact(SampleRef.Ref, F.Bone, HandBone);
    if (VSize(HandP - P) > 48
        || Owner.RigSample.RackFingerContact(SampleRef.Ref, F.Bone, HandBone) > FMax(8, F.FingerLimit))
    { Bridge.DetachComponent(SampleRef.Ref); Gun = None; return false; }
    SampleRef.GripLocal = QuatRotateVector(QuatInvert(Q), HandP - P);
    SampleRef.GripQ = QuatProduct(QuatInvert(Q), HandQ);
    SampleRef.GripTime = F.GripTime;
    BindFailure = "path";
    if (!SampleRange(F.StartTime, F.EndTime, OutPaths)
        || (F.ReturnEnd > F.ReturnStart && !SampleRange(F.ReturnStart, F.ReturnEnd, BackPaths)))
    { Bridge.DetachComponent(SampleRef.Ref); Gun = None; return false; }
    Cycle = OutPaths[0];
    if (F.Kind != 0 && Cycle.Length < 2)
    { Bridge.DetachComponent(SampleRef.Ref); Gun = None; return false; }
    for (I = 0; I < OutPaths.Length; ++I) AddPart(SampleRef.Ref, OutPaths[I].Bones[0], true);
    Bridge.DetachComponent(SampleRef.Ref);
    BindFailure = "tree parts=" $ Parts.Length @ "paths=" $ OutPaths.Length;
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Parts.Length != OutPaths.Length)
    { Tree = None; Parts.Length = 0; Gun = None; return false; }
    BindFailure = "";
    bSavedPooling = Tree.bEnablePooling;
    if (Owner.Audio != None && Owner.Audio.OwnsTree(Tree)) bSavedPooling = Owner.Audio.bSavedPooling;
    Tree.bEnablePooling = false;
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    Gun.MySkelMesh.InitSkelControls();
    Amount = 0; bComplete = false; bOut = false; bReturning = false;
    bRecoveredPaid = bResumePaid || DetachedClip != '';
    bPaidAdmitted = bResumePaid;
    if (bResumePaid)
    {
        Amount = FClamp(R.FinishAmount, 0, 1); bOut = R.bFinishOut;
        bReturning = R.bFinishReturning; bAcquirePlayed = R.bFinishAcquirePlayed;
        if (bReturning && BackPaths.Length > 0) Cycle = BackPaths[0];
    }
    bEngaged = false; bGripWasDown = true;
    AutoFinishAt = 0;
    Motion.Reset(); Owner.PauseStock(); ClaimSounds();
    // Presentation only. Original completion timers are neither shortened nor reset.
    if (LiveNode != None) LiveNode.SetPosition(LiveStartTime, false);
    return true;
}

function bool NeedsAction()
{
    // A recovered insertion preflights its control before payment. Until its
    // receipt arrives the hand still carries a magazine, not an owed action.
    return Gun != None && !bComplete && (!bRecoveredPaid || bPaidAdmitted);
}
function bool OwnsHand(int Hand) { return Gun != None && bEngaged && Hand == OffHand(); }
function vector Contact() { return ContactAt(Amount); }
function vector ContactAt(float S) { return RootPos() + QuatRotateVector(RootQ(), Cycle.ContactLocal(S) * GunScale()); }
function float ContactDistance(int Hand)
{
    if (!NeedsAction() || Cycle == None || Gun.MySkelMesh == None || Hand != OffHand()) return 1000000;
    // M4 has no separate button bone. Its sampled release-hand pose locates
    // the carrier-control button; touching the exposed bolt is not release.
    if (Gun.Class == class'KFWeap_Shotgun_M4') return VSize(Bridge.Hands[Hand].Position - Contact());
    return FMin(VSize(Bridge.Hands[Hand].Position - Contact()),
        VSize(Bridge.PalmPosition(Hand) - Gun.MySkelMesh.GetBoneLocation(
            class'VRReloadFinishCatalog'.default.Profiles[Profile].Bone)));
}
function bool AdmitsHandContact(int Hand)
{
    local name SupportBone;
    local vector Support;
    local quat SupportQ;
    if (!NeedsAction() || !Owner.bActive || Owner.Gun != Gun || Owner.HandMode != 0 || Hand != OffHand()) return false;
    if (ContactDistance(Hand) <= Radius) return true;
    // Freeze Thrower/Healthrower support and actuator grips share a part.
    // The ordinary support wrist is sampled from Idle and can sit outside
    // the reload wrist/palm radius. The same visible handle must operate its
    // owed action before that squeeze can become ordinary aiming support.
    return Runtime.Presenter != None
        && Runtime.Presenter.GetSupportGripContact(Gun, SupportBone, Support, SupportQ)
        && SupportBone != RootBone
        && SupportBone == class'VRReloadFinishCatalog'.default.Profiles[Profile].Bone
        && Owner.InputOwner.Inventory.SupportGrabContact(Runtime, Hand);
}
function quat WristQ()
{
    local vector P;
    local quat Q, Wrist;
    local int SourceHand;
    Cycle.PoseAt(Amount, 0, P, Q);
    SourceHand = class'VRReloadFinishCatalog'.default.Profiles[Profile].SourceHand;
    Wrist = QuatProduct(QuatProduct(Q, Cycle.GripQ), QuatInvert(Bridge.FreeHandPose.WristBasis[SourceHand]));
    if (OffHand() != SourceHand) Wrist = class'VRHandRolePose'.static.MirrorCanonicalRotation(Wrist);
    return QuatProduct(RootQ(), QuatProduct(Wrist, Bridge.FreeHandPose.WristBasis[OffHand()]));
}

function Update()
{
    local bool Down, Edge;
    local vector P;
    local float Next;
    local byte Kind;
    if (!NeedsAction()) return;
    if (!Owner.bActive || Owner.Gun != Gun || !Owner.StillValid()) { Unbind(); return; }
    Owner.PauseStock();
    // Only the explicit button owner may finish this already-paid stroke.
    // Its identity remains valid when the opposite gun is put away.
    if (bPaidAdmitted && Owner.Automatic(Runtime) && Owner.InputOwner.ContextValid())
    { UpdateAutomaticFinish(); return; }
    AutoFinishAt = 0;
    if (!Owner.InputOwner.ContextValid() || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { LastPressTime = 0; bPressArmed = false; CancelHand(OffHand()); return; }
    // Update runs before the magazine owner observes its post-seat release.
    // Remember that open sample now, so the next squeeze at the actuator is
    // a real acquisition rather than requiring a second release/regrab.
    if (Owner.HandMode != 0) { bGripWasDown = Owner.GripDown(OffHand()); return; }
    // A held gun may tap a powered control without surrendering its grip.
    if (PhysicalPress()) { Complete(); return; }
    if (!Owner.HandFree(OffHand(), true)) { CancelHand(OffHand()); return; }
    Down = Owner.GripDown(OffHand()); Edge = Down && !bGripWasDown; bGripWasDown = Down;
    P = LocalHandPosition() / GunScale();
    Kind = class'VRReloadFinishCatalog'.default.Profiles[Profile].Kind;
    if (!bEngaged)
    {
        // The authored wrist can sit well below or behind a short control
        // (notably the Blunderbuss hammer). Admit the palm on the same live
        // part that glows, then retain the sampled wrist path for motion.
        if (!Edge || !AdmitsHandContact(OffHand())) return;
        Cycle.GrabOffset = P - Cycle.ContactLocal(Amount);
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bEngaged = true; Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << OffHand(), 0.2, 0.02);
        if (!bAcquirePlayed) { PlayPath(class'VRReloadFinishCatalog'.default.Profiles[Profile].AcquireSound); bAcquirePlayed = true; }
        if (Kind == 0) { Complete(); return; }
    }
    if (!Down) { bEngaged = false; Motion.Reset(); return; }
    if (!Motion.Check(LocalHandPosition(), Owner.Now())) { CancelHand(OffHand()); return; }
    Next = Cycle.ProjectNearby(P - Cycle.GrabOffset, Amount);
    // A held mechanism retains its grip through lateral controller drift.
    // Tracking continuity and explicit grip release still cancel ownership.
    if (VSize(P - Cycle.GrabOffset - Cycle.ContactLocal(Next)) * GunScale() > Radius * 4)
    { CancelHand(OffHand()); return; }
    Amount = Next;
    // A one-way stroke (the flamethrower's tank latch, the Railgun bolt)
    // closes like a magazine seats: most of the travel, not the end stop.
    if (Amount >= (Kind == 1 ? 0.70 : 0.90))
    {
        if (Kind == 1 || bReturning) { Amount = 1; Complete(); return; }
        if (!bOut) { class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.BoltRear, 1 << OffHand()); PlayFinishSound(false); }
        bOut = true;
        if (BackPaths.Length > 0)
        {
            Cycle = BackPaths[0]; Amount = 0; bReturning = true;
            Cycle.GrabOffset = P - Cycle.ContactLocal(0);
        }
    }
    if (Kind == 2 && bOut && !bReturning && Amount <= 0.10) { Amount = 0; Complete(); }
    SavePersistentState();
}

// KFWeapon.TimeWeaponReloading treats this scale as a duration multiplier:
// a faster perk returns a smaller value. Use the same rule for the remaining
// physical control, including a takeover partway through either stroke.
static function float AutomaticDuration(float ClipDuration, float ReloadScale)
{
    return FMax(ClipDuration * FMax(ReloadScale, 0.01), 0.08);
}

function UpdateAutomaticFinish()
{
    local float Duration;
    local VRReloadFinishCatalog.FinishProfile F;
    F = class'VRReloadFinishCatalog'.default.Profiles[Profile];
    bEngaged = false; Motion.Reset();
    if (AutoFinishAt == 0) { AutoFinishAt = Owner.Now(); AutoFinishAmount = Amount; }
    Duration = bReturning ? F.ReturnEnd - F.ReturnStart : F.EndTime - F.StartTime;
    Duration = AutomaticDuration(Duration, Gun.GetReloadRateScale());
    Amount = FMin(1, AutoFinishAmount + (Owner.Now() - AutoFinishAt) / Duration);
    if (Amount >= 1)
    {
        if (F.Kind == 2 && !bReturning && BackPaths.Length > 0)
        {
            bOut = true; bReturning = true; Cycle = BackPaths[0]; Amount = 0;
            AutoFinishAt = 0; PlayFinishSound(false);
        }
        else { Complete(); return; }
    }
    SavePersistentState();
}

function string ReloadPrompt(KFWeapon W)
{
    if (W != Gun || !NeedsAction() || !Bridge.bReloadHints || Owner.CluesAutomatic(W)) return "";
    return class'VRReloadFinishCatalog'.default.Profiles[Profile].Prompt;
}

function bool OwnSound(AkEvent Sound)
{
    if (Sound == None || Profile < 0) return false;
    return (PathName(Sound) ~= class'VRReloadFinishCatalog'.default.Profiles[Profile].Sound)
        || (PathName(Sound) ~= class'VRReloadFinishCatalog'.default.Profiles[Profile].ReturnSound)
        || (PathName(Sound) ~= class'VRReloadFinishCatalog'.default.Profiles[Profile].AcquireSound);
}

function ClaimSounds()
{
    local int I;
    if (Owner.Audio == None || Owner.Audio.Plan == None) return;
    for (I = 0; I < Owner.Audio.Plan.Events.Length; ++I)
        if (OwnSound(Owner.Audio.Plan.Events[I].Sound)) Owner.Audio.Plan.Events[I].bConsumed = true;
    for (I = Owner.Audio.Plan.Cues.Length - 1; I >= 0; --I)
        if (OwnSound(Owner.Audio.Plan.Cues[I].Sound)) Owner.Audio.Plan.Cues.Remove(I, 1);
    for (I = Owner.Audio.Pending.Length - 1; I >= 0; --I)
        if (OwnSound(Owner.Audio.Pending[I].Sound)) Owner.Audio.Pending.Remove(I, 1);
}

function PlayPath(string Path)
{
    local AkEvent Sound;
    if (Path == "") return;
    Sound = AkEvent(DynamicLoadObject(Path, class'AkEvent', true));
    if (Sound != None) Owner.Audio.QueueSound(Gun, Sound, class'VRReloadAudio'.static.NearField(Bridge, Contact()), 0);
}
function PlayFinishSound(bool bReturn)
{
    PlayPath(bReturn ? class'VRReloadFinishCatalog'.default.Profiles[Profile].ReturnSound
        : class'VRReloadFinishCatalog'.default.Profiles[Profile].Sound);
}

function Complete()
{
    local KFWeapon W;
    local name TailClip;
    local float TailTime;
    local bool bRecovered;
    W = Gun; TailClip = LiveClip; TailTime = LiveFinishTime; bRecovered = bRecoveredPaid;
    bComplete = true; bEngaged = false; bGripWasDown = true; Motion.Reset();
    if (Runtime != None && Runtime.FinishProfileToken == Profile + 1)
    { Runtime.FinishProfileToken = 0; Runtime.FinishModeMask = 0; }
    class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.BoltClose, 3);
    PlayFinishSound(class'VRReloadFinishCatalog'.default.Profiles[Profile].Kind == 2);
    if (LiveNode != None && LiveNode == Gun.WeaponAnimSeqNode && LiveNode.AnimSeq != None
        && LiveNode.AnimSeqName == LiveClip)
        LiveNode.SetPosition(FMin(LiveFinishTime, LiveNode.AnimSeq.SequenceLength), false);
    // Release every controlled linkage into the post-actuation stock pose.
    // Powered feed/spin/return remains authored, with no repeated manual stroke.
    PlaceVisuals(); Owner.ResumeStock();
    // A tube shotgun continues with ordinary independently gated shell steps.
    // Keeping this completed owner bound would bypass those timer gates.
    if (!bRecovered && W.Class == class'KFWeap_Shotgun_M4') Unbind();
    if (bRecovered)
    {
        // This magazine was already paid. Stay in Active and continue only
        // the authored powered tail, like the existing paid paired route.
        Owner.bRacked = true;
        Owner.Finish("paid-finish-recovered");
        if (W != None && !W.bDeleteMe && W.IsInState('Active') && TailClip != '')
        {
            W.PlayAnimation(TailClip, 0.0, false, 0.0);
            if (W.WeaponAnimSeqNode != None)
                W.WeaponAnimSeqNode.SetPosition(TailTime, false);
        }
    }
}

function PlaceVisuals()
{
    local int I;
    local vector P;
    local quat Q;
    local VRActionPath PartPath;
    if (Gun == None || Cycle == None || (bRecoveredPaid && !bPaidAdmitted)) return;
    for (I = 0; I < Parts.Length; ++I)
    {
        if (bComplete) { Parts[I].Control.SetSkelControlStrength(0, 0); continue; }
        PartPath = bReturning ? BackPaths[I] : OutPaths[I];
        PartPath.PoseAt(Amount, 0, P, Q);
        Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
}

function CancelHand(int Hand)
{
    bEngaged = false; bGripWasDown = true;
    if (Motion != None) Motion.Reset();
}
function SavePersistentState()
{
    // Begin precedes payment. An unpaid/rejected insert (including a paired
    // Piranha whose seat receipt has not arrived) must never create paid debt.
    if (Runtime == None || Gun == None || Runtime.Item != Gun || bComplete
        || !bPaidAdmitted || Owner == None || Owner.Gun != Gun
        || Owner.Runtime != Runtime || !Owner.bAmmoStepPaid) return;
    Runtime.FinishProfileToken = Profile + 1;
    // Independent of magazine-event masks: custom beams and non-ejecting
    // projectile feeds have the same paid control, even after settings/stow.
    Runtime.FinishModeMask = 1;
    if (Gun.GetAmmoType(1) == 0) Runtime.FinishModeMask = Runtime.FinishModeMask | 2;
    Runtime.FinishLiveClip = LiveClip;
    Runtime.FinishLiveStart = LiveStartTime; Runtime.FinishLiveEnd = LiveFinishTime;
    Runtime.FinishAmount = Amount; Runtime.bFinishOut = bOut;
    Runtime.bFinishReturning = bReturning; Runtime.bFinishAcquirePlayed = bAcquirePlayed;
    Runtime.bFinishWasEmpty = Owner.bEmptyStart;
}

function ConfirmPaid()
{
    bPaidAdmitted = true;
    SavePersistentState();
}
function Unbind()
{
    if (Tree != None && Owner != None && Owner.Audio != None && Owner.Audio.OwnsTree(Tree))
    {
        Owner.Audio.bSavedPooling = bSavedPooling;
        bSavedPooling = false;
    }
    super.Unbind(); Cycle = None; SampleRef = None; LiveNode = None; LiveClip = ''; Profile = -1;
    OutPaths.Length = 0; BackPaths.Length = 0;
    bComplete = false; bOut = false; bReturning = false; bAcquirePlayed = false; Amount = 0;
    LiveStartTime = 0; LiveFinishTime = 0;
    bRecoveredPaid = false;
    bPaidAdmitted = false;
    AutoFinishAt = 0;
    LastPressTime = 0; bPressArmed = false; PressOther = None;
}

defaultproperties
{
    Radius=8
    Profile=-1
}
