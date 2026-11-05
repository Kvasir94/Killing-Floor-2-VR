// Husk Cannon's telescoping pipes are a mechanism, not a removable magazine.
// A fresh off-hand grip drives the authored outward and return paths. Only a
// completed cycle calls stock PerformReload, followed by stock ReloadComplete;
// KFWeapon's client-tracked reload accounting remains the sole ammo ledger.
//
// VRVampireReload reuses this pipe presentation with a separate acknowledged
// server transaction. This base remains the Husk client-tracked ammo path.
//
// Inherits only the instance-control plumbing and root/scale helpers. It never
// calls the manual pump's Update/Bind or writes its chamber state.
class VRMechanismReload extends VRManualPump;

var VRActionPath Outward, ReturnPath;
var VRReloadHandPose ActionPose;
var AnimNodeSequence HeldNode;
var SkeletalMeshComponent HeldMesh;
var bool bActive, bReturning, bSavedPause, bSavedNotifies, bPaid, bControlsBound, bAnimationHeld;
var bool bBindPermanentFailure;
var int BoundRevision, AmmoAtBegin;
var float Amount, EntryTime, TurnTime, ReturnTime, HintSince;
var vector GrabOffset;
var KFWeapon RejectedGun;
var AkEvent ExtendSound, RetractSound, CompleteSound, CompleteLayerSound;
var VRReloadPartGlow PipeHints[2];

function Initialize(VRInteractiveReload O)
{
    local int I;
    super.Initialize(O);
    ActionPose = new(self) class'VRReloadHandPose';
    for (I = 0; I < ArrayCount(PipeHints); ++I)
    {
        PipeHints[I] = new(self) class'VRReloadPartGlow';
        PipeHints[I].Initialize(O);
    }
}

// Husk Cannon and HRG Vampire reload with the button only (Kvasir94,
// 2026-10-22: no pipe grab). Their stock reload runs as in the flat game;
// the Vampire's still goes through its acknowledged authority transport.
function bool Enabled()
{
    return false;
}

static function bool Supported(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_HuskCannon' && W.bAllowClientAmmoTracking;
}

// The server-owned Vampire reuses the authored pipe presentation, but has a
// separate acknowledged transaction instead of this client timer/accounting path.
function bool AcceptsGun(KFWeapon W) { return Supported(W); }
function bool ReadyForBind()
{
    // Do not take over a stock reload after its ammo has already been paid.
    // Stock initializes this counter from finite reserve even in infinite
    // mode. A zero reserve must not let the timers bypass the pipe stroke.
    return Gun.IsTimerActive('ReloadAmmoTimer') && Gun.IsTimerActive('ReloadStatusTimer')
        && (Gun.ReloadAmountLeft > 0 || (Gun.bInfiniteSpareAmmo
            && Gun.AmmoCount[0] < Gun.MagazineCapacity[0]));
}

function bool SessionValid()
{
    return bActive && Enabled() && Owner.InputOwner.ContextValid()
        && Gun != None && !Gun.bDeleteMe && Runtime != None && Runtime.IsCurrent()
        && Runtime.Item == Gun && GunHand >= 0 && GunHand <= 1
        && Runtime.OwnershipRevision == BoundRevision
        && Owner.InputOwner.Inventory.GetHeldForHand(GunHand) == Runtime
        && Owner.InputOwner.Inventory.GetHeldForHand(OffHand()) == None
        && Gun.MySkelMesh == HeldMesh && HeldMesh.Animations == Tree
        && Gun.WeaponAnimSeqNode == HeldNode && Gun.IsInState('Reloading')
        && !Gun.IsInState('AltReloading');
}

function bool FreeActionHand()
{
    local VRWeaponRuntime S;
    if (Owner.InputOwner.Inventory.Registry.GetPrimary(OffHand()) != None
        || Owner.InputOwner.Inventory.HasWorldGrab(OffHand())
        || Owner.InputOwner.IsSelectorOpen(OffHand())
        || Owner.InputOwner.HandCarrying(OffHand())) return false;
    S = Owner.InputOwner.Inventory.Registry.GetSupport(OffHand());
    return S == None || S == Runtime;
}

function bool OwnsHand(int Hand)
{
    return Hand == OffHand() && bEngaged && SessionValid();
}

function bool CoversHand(int Hand)
{
    return Hand == OffHand() && bActive && ActionPose != None && ActionPose.bVisible;
}

function bool LatchesSupport(VRWeaponRuntime R, int Hand) { return false; }
function bool BlocksFire(KFWeapon W) { return bActive && W == Gun; }
function bool HoldsPose(KFWeapon W) { return bActive && W == Gun; }

// The two pipes share geometry in all reload variants. Use the normal Half
// clip as the physical mechanism reference, avoiding the empty clip's special
// last-shot pipe pose and the elite clip's automatic flourish. Live stock
// reload selection, perk rate and accounting are left intact.
function bool SampleMechanism()
{
    local AnimSequence Clip;
    local AnimNotify_AkEvent Event;
    local vector P, BestP, Contact;
    local quat Q, ContactQ;
    local float ForwardAt, BackAt, FinishAt, T, MaxX, MinX;
    local int I;
    local bool bOk;
    Outward = new(self) class'VRActionPath';
    ReturnPath = new(self) class'VRActionPath';
    Outward.Bones[0] = 'RW_Barrel01'; Outward.Bones[1] = 'RW_Barrel02';
    Outward.BoneCount = 2;
    ReturnPath.Bones[0] = Outward.Bones[0]; ReturnPath.Bones[1] = Outward.Bones[1];
    ReturnPath.BoneCount = 2;
    if (!Outward.PrepareRef(Bridge, Gun, RootBone)
        || Outward.Ref.MatchRefBone('RW_Barrel01') < 0
        || Outward.Ref.MatchRefBone('RW_Barrel02') < 0) return false;
    Bridge.AttachComponent(Outward.Ref);
    Outward.RefSeq.SetAnim('Reload_Half');
    Clip = Outward.RefSeq.AnimSeq;
    if (Clip == None || Clip.SequenceLength <= 0)
    { Bridge.DetachComponent(Outward.Ref); return false; }
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        Event = AnimNotify_AkEvent(Clip.Notifies[I].Notify);
        if (Event == None || Event.AkEvent == None) continue;
        if (InStr(string(Event.AkEvent), "Reload_Pipe_FWD") >= 0)
        { ForwardAt = Clip.Notifies[I].Time; ExtendSound = Event.AkEvent; }
        else if (InStr(string(Event.AkEvent), "Reload_Pipe_Back") >= 0)
        { BackAt = Clip.Notifies[I].Time; RetractSound = Event.AkEvent; }
        else if (InStr(string(Event.AkEvent), "Reload_FWD") >= 0)
        { FinishAt = Clip.Notifies[I].Time; CompleteSound = Event.AkEvent; }
        else if (Event.AkEvent.Name == 'Play_WEP_Husk_Cannon_Flame_Full')
            CompleteLayerSound = Event.AkEvent;
    }
    if (!(ForwardAt > 0 && BackAt > ForwardAt && FinishAt > BackAt))
    { Bridge.DetachComponent(Outward.Ref); return false; }
    // Find the retracted approach, first extension stop, and first return.
    // Bounds come from the pipe's own sound events, not whole-clip extrema.
    MinX = 1000000;
    for (I = 0; I <= 64; ++I)
    {
        T = ForwardAt * float(I) / 64.0;
        Outward.PoseRef(T); Outward.RefRelative('RW_Barrel01', P, Q);
        if (P.X < MinX) { MinX = P.X; EntryTime = T; BestP = P; }
    }
    MaxX = MinX;
    for (I = 0; I <= 64; ++I)
    {
        T = ForwardAt + (BackAt - ForwardAt) * float(I) / 64.0;
        Outward.PoseRef(T); Outward.RefRelative('RW_Barrel01', P, Q);
        if (P.X > MaxX) { MaxX = P.X; TurnTime = T; }
    }
    MinX = 1000000;
    for (I = 0; I <= 64; ++I)
    {
        T = TurnTime + (FinishAt - TurnTime) * float(I) / 64.0;
        Outward.PoseRef(T); Outward.RefRelative('RW_Barrel01', P, Q);
        if (P.X < MinX) { MinX = P.X; ReturnTime = T; }
    }
    bOk = EntryTime < TurnTime && TurnTime < ReturnTime && MaxX - BestP.X > 5
        && MaxX - MinX > 5 && Abs(MinX - BestP.X) < 3;
    Bridge.DetachComponent(Outward.Ref);
    if (!bOk || !ActionPose.Build(Bridge, Gun.MySkelMesh, 'Reload_Half',
        'RW_Barrel01', EntryTime, EntryTime, OffHand(), 0)) return false;
    // The approach wrist/fingers come from the authored clip. Making that
    // approach operate the pipe is a VR interaction adaptation: stock lets
    // the left hand move away while the mechanism runs automatically.
    ActionPose.GetFrame(0, Contact, ContactQ);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Contact) || VSize(Contact) > 30) return false;
    Bridge.AttachComponent(Outward.Ref);
    bOk = SampleSpan(Outward, EntryTime, TurnTime, Contact)
        && SampleSpan(ReturnPath, TurnTime, ReturnTime, Contact);
    Bridge.DetachComponent(Outward.Ref);
    return bOk;
}

function bool SampleSpan(VRActionPath Target, float First, float Last, vector Contact)
{
    local VRActionPath.PathPose Pose;
    local int I, J;
    local float Total;
    Target.Path.Length = 0; Target.PathS.Length = 0;
    for (I = 0; I <= 32; ++I)
    {
        Outward.PoseRef(First + (Last - First) * float(I) / 32.0);
        for (J = 0; J < 2; ++J)
        {
            Outward.RefRelative(Target.Bones[J], Pose.P[J], Pose.Q[J]);
            if (!class'VRReloadMotionGuard'.static.ValidPosition(Pose.P[J])
                || !class'VRReloadHandPose'.static.ValidQ(Pose.Q[J])) return false;
        }
        Pose.C = Pose.P[0] + QuatRotateVector(Pose.Q[0], Contact);
        if (I > 0) Total += VSize(Pose.C - Target.Path[I - 1].C);
        Target.Path.AddItem(Pose); Target.PathS.AddItem(Total);
    }
    if (!(Total > 5 && Total < 60)) return false;
    for (I = 0; I < Target.PathS.Length; ++I) Target.PathS[I] /= Total;
    Target.Length = Total;
    return true;
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local int I;
    bBindPermanentFailure = false;
    if (R == None || !AcceptsGun(R.Item) || R.Item.MySkelMesh == None
        || !R.Item.IsInState('Reloading') || R.Item.IsInState('AltReloading')) return false;
    Runtime = R; Gun = R.Item; GunHand = Hand;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    HeldMesh = Gun.MySkelMesh;
    HeldNode = Bridge.ResolveLiveWeaponAnimNode(Gun);
    Tree = AnimTree(HeldMesh.Animations);
    if (!FreeActionHand() || Tree == None || Tree == HeldMesh.AnimTreeTemplate
        || HeldNode == None || HeldNode != Gun.WeaponAnimSeqNode || HeldNode.bIsIssuingNotifies
        || HeldMesh.SkeletalMesh == None || Bridge.Arms == None || Bridge.FreeHandPose == None
        || !Bridge.FreeHandPose.bReady || !ReadyForBind()) return false;
    if (!SampleMechanism()) { bBindPermanentFailure = true; return false; }
    // All sampling/asset validation precedes timer or live-control mutation.
    Parts.Length = 0;
    for (I = 0; I < 2; ++I)
    {
        AddPart(Outward.Ref, Outward.Bones[I], true);
        if (Parts.Length != I + 1) { bBindPermanentFailure = true; return false; }
    }
    bSavedPooling = Tree.bEnablePooling;
    bControlsBound = true;
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control = AppendControl(Parts[I].Bone);
        if (Parts[I].Control == None) { bBindPermanentFailure = true; return false; }
    }
    Tree.bEnablePooling = false;
    HeldMesh.InitSkelControls();
    bSavedPause = HeldMesh.bPauseAnims;
    bSavedNotifies = HeldNode.bNoNotifies;
    bAnimationHeld = true;
    HeldNode.bNoNotifies = true;
    HeldMesh.bPauseAnims = true;
    Gun.PauseTimer(true, 'ReloadAmmoTimer');
    Gun.PauseTimer(true, 'ReloadStatusTimer');
    AmmoAtBegin = Gun.AmmoCount[0];
    BoundRevision = Runtime.OwnershipRevision;
    Amount = 0; bReturning = false; bEngaged = false; bPaid = false;
    bGripWasDown = Owner.GripDown(OffHand());
    Owner.HideVisuals();
    Owner.UpdateParts(None, false, false, false);
    bActive = true; HintSince = Owner.Now();
    return true;
}

function VRActionPath CurrentPath() { return bReturning ? ReturnPath : Outward; }

function vector Contact()
{
    return RootPos() + QuatRotateVector(RootQ(), CurrentPath().ContactLocal(Amount) * GunScale());
}

function PlayPumpSound(AkEvent Sound)
{
    if (Sound != None && bActive && Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None)
        Gun.PlayAkEvent(Sound, true, false, false, class'VRReloadAudio'.static.NearField(Bridge, Contact()));
}

// A released/discontinuous sample ends the grab, not the incomplete mechanism.
// Progress stays where the hand left it; reacquisition needs a real release.
function CancelHand(int Hand)
{
    if (!bActive || (Hand != GunHand && Hand != OffHand())) return;
    // Input cancels and returns before Update when its context is lost.
    // Abort here too, or a menu would leave the stock reload paused forever.
    // Tracking-only loss with valid context still preserves physical progress.
    if (Owner == None || Owner.InputOwner == None || !Owner.InputOwner.ContextValid())
    { Abort(); return; }
    bEngaged = false; bGripWasDown = true;
    Motion.Reset();
    if (ActionPose != None) ActionPose.Cancel();
}

function Update()
{
    local VRWeaponRuntime R;
    local int Hand;
    if (RejectedGun != None && (RejectedGun.bDeleteMe || !RejectedGun.IsInState('Reloading')))
        RejectedGun = None;
    if (!bActive)
    {
        if (!Enabled() || Owner.bActive || !Owner.InputOwner.ContextValid()) return;
        for (Hand = 0; Hand < 2; ++Hand)
        {
            R = Owner.InputOwner.Inventory.GetHeldForHand(Hand);
            if (R == None || !R.IsCurrent() || R.Item == RejectedGun || !Supported(R.Item)
                || !R.Item.IsInState('Reloading')) continue;
            if (!Bind(R, Hand))
            {
                // Live nodes and hand rigs can become ready on a later tick.
                // Only invalid assets retire this reload from physical binding.
                if (bBindPermanentFailure) RejectedGun = R.Item;
                Unbind();
            }
            break;
        }
    }
    if (!bActive) return;
    // Context/role/actor changes abort before restoring timers. Unpausing an
    // abandoned stock reload would refill a gun without the physical stroke.
    if (!SessionValid() || Owner.bActive || Gun.AmmoCount[0] != AmmoAtBegin)
    { Abort(); return; }
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { CancelHand(OffHand()); return; }
    UpdateHand();
}

function UpdateHand()
{
    local bool Grip, Edge;
    local vector P, LocalPosition;
    local VRActionPath Path;
    Grip = Owner.GripDown(OffHand());
    Edge = Grip && !bGripWasDown;
    bGripWasDown = Grip;
    if (!FreeActionHand()) { Abort(); return; }
    Path = CurrentPath();
    P = Bridge.Hands[OffHand()].Position;
    LocalPosition = QuatRotateVector(QuatInvert(RootQ()), P - RootPos());
    if (!bEngaged)
    {
        if (!Edge || VSize(P - Contact()) > Radius) return;
        if (Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime)
            Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        BoundRevision = Runtime.OwnershipRevision;
        GrabOffset = LocalPosition / GunScale() - Path.ContactLocal(Amount);
        if (!Motion.Begin(LocalPosition, Owner.Now())) return;
        bEngaged = true;
        Bridge.Hands[OffHand()].bGripArmed = false;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02);
        return;
    }
    // Validate before interpreting either a release or a terminal stroke.
    if (!Motion.Check(LocalPosition, Owner.Now())) { CancelHand(OffHand()); return; }
    if (!Grip) { bEngaged = false; Motion.Reset(); return; }
    Amount = Path.Project(LocalPosition / GunScale() - GrabOffset);
    if (VSize(LocalPosition / GunScale() - GrabOffset - Path.ContactLocal(Amount)) * GunScale() > Radius * 1.5)
    { CancelHand(OffHand()); return; }
    if (Amount < 0.95) return;
    if (!bReturning)
    {
        bReturning = true; Amount = 0;
        GrabOffset = LocalPosition / GunScale() - ReturnPath.ContactLocal(0);
        PlayPumpSound(ExtendSound);
        Owner.Pulse(1 << OffHand(), 0.7, 0.04);
        return;
    }
    Complete();
}

function Complete()
{
    local KFWeapon W;
    local vector SoundAt;
    if (bPaid || !SessionValid() || !bEngaged || !bReturning || Amount < 0.95) return;
    bPaid = true;
    W = Gun;
    SoundAt = Contact();
    PlayPumpSound(RetractSound);
    // Pay once through stock accounting. Infinite reserve still needs the
    // ordered client count restatement after stock's reload-end bookkeeping.
    W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
    RestoreAnimation();
    class'VRPouchAmmo'.static.PerformPhysicalReload(W,
        Max(W.MagazineCapacity[0] - W.AmmoCount[0], 0), Runtime);
    W.ReloadComplete();
    if (W.IsInState('Active') && W.IdleAnims.Length > 0)
    {
        W.PlayAnimation(W.IdleAnims[0], 0.0, true, 0.0);
        W.ToggleAdditiveBobAnim(!W.bUsingSights);
    }
    if (CompleteSound != None) W.PlayAkEvent(CompleteSound, true, false, false,
        class'VRReloadAudio'.static.NearField(Bridge, SoundAt));
    if (CompleteLayerSound != None) W.PlayAkEvent(CompleteLayerSound, true, false, false,
        class'VRReloadAudio'.static.NearField(Bridge, SoundAt));
    Owner.Pulse(3, 1.0, 0.08);
    Unbind();
}

function RestoreAnimation()
{
    if (!bAnimationHeld) return;
    bAnimationHeld = false;
    if (HeldNode != None) HeldNode.bNoNotifies = bSavedNotifies;
    if (HeldMesh != None) HeldMesh.bPauseAnims = bSavedPause;
}

function Abort()
{
    local KFWeapon W;
    W = Gun;
    if (bActive && W != None && !W.bDeleteMe)
    {
        if (W.IsInState('Reloading'))
        { W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer'); }
        RestoreAnimation();
        if (W.IsInState('Reloading')) W.AbortReload();
    }
    Unbind();
}

function Unbind()
{
    RestoreAnimation();
    bActive = false;
    if (ActionPose != None) ActionPose.Cancel();
    HidePipeHints();
    // Do not run VRManualPump's ammunition/chamber bookkeeping.
    Runtime = None;
    // A failed preflight never installed controls or owned this AnimTree.
    if (!bControlsBound) { Tree = None; Parts.Length = 0; }
    super.Unbind();
    bControlsBound = false;
    Outward = None; ReturnPath = None; HeldNode = None; HeldMesh = None;
    ExtendSound = None; RetractSound = None; CompleteSound = None; CompleteLayerSound = None;
    bReturning = false; Amount = 0;
}

function PlaceVisuals()
{
    local VRActionPath Path;
    local vector P, At;
    local quat Q, WristQ;
    local int I;
    if (!SessionValid())
    {
        HidePipeHints();
        if (ActionPose != None) ActionPose.Cancel();
        return;
    }
    Path = CurrentPath();
    for (I = 0; I < Parts.Length; ++I)
    {
        Path.PoseAt(Amount, I, P, Q);
        Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    HeldMesh.ForceSkelUpdate(); HeldMesh.ForceUpdate(true);
    Path.PoseAt(Amount, 0, P, Q);
    At = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
    Q = QuatProduct(RootQ(), Q);
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3 && FreeActionHand())
    {
        WristQ = Bridge.FreeHandPose.WristRotation(OffHand(), OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
        ActionPose.Place(Owner.Now(), bEngaged, 0, 1, Bridge.Hands[OffHand()].Position,
            WristQ, At, Q, GunScale());
    }
    else ActionPose.Cancel();
    PlaceHint();
}

function HidePipeHints()
{
    local int I;
    for (I = 0; I < ArrayCount(PipeHints); ++I)
        if (PipeHints[I] != None) PipeHints[I].Hide();
}

// Both original pipe surfaces carry the same amber action cue as a bolt or
// lever. Each follows its own live bone throughout extension and return.
function PlaceHint()
{
    local float Phase, Alpha;
    if (!Bridge.bReloadHints || bEngaged || Owner.Now() - HintSince < Owner.HintDelay)
    { HidePipeHints(); return; }
    Phase = ((Owner.Now() - HintSince - Owner.HintDelay) / FMax(Owner.GlowPulse, 0.05)) % 2.0;
    Alpha = Owner.GlowAlpha * (0.35 + 0.65 * (0.5 - 0.5 * Cos(Phase * Pi)));
    PipeHints[0].Place(Gun, "Pipe1", 'RW_Barrel01', Alpha, true);
    PipeHints[1].Place(Gun, "Pipe2", 'RW_Barrel02', Alpha, true);
}

function string ReloadPrompt(KFWeapon W)
{
    if (W != Gun || !AcceptsGun(W) || !SessionValid() || !Bridge.bReloadHints) return "";
    if (!bEngaged) return "GRIP PIPE";
    return bReturning ? "RETURN PIPE" : "EXTEND PIPE";
}

function Shutdown()
{
    local int I;
    Abort();
    if (ActionPose != None) { ActionPose.Destroy(); ActionPose = None; }
    for (I = 0; I < ArrayCount(PipeHints); ++I)
        if (PipeHints[I] != None) { PipeHints[I].Shutdown(); PipeHints[I] = None; }
    Owner = None; Bridge = None;
}

defaultproperties
{
    Radius=12
}
