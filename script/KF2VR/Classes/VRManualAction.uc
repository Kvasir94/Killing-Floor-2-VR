// Manual bolt and lever actions (VR CONTROLS > INTERACTIVE RELOADS: ON + MANUAL
// PUMP), as the manual pump works the pump shotguns: after every shot that
// leaves a round, the gun will not fire again until a hand works its
// action open (ejecting the spent case) and closed (chambering the next round).
// The action follows the hand along the motion the stock fire clip gives it
// (VRCycleCatalog, VRActionPath sampled from Shoot); that clip's own cycle
// notifies are muted on the live node and the same stock events play at the
// physical open and close instead. Firing stays stock: only the trigger press
// is withheld, an empty gun still dry fires into its auto-reload, and the
// reload's own open and close (break action, lever) count as a cycle. The lever
// actions also admit the primary hand while the other hand supports the rifle.
class VRManualAction extends VRManualPump;

var VRActionPath Cycle;
var float Amount;
var bool bOpened;
var int CycleProfile;
var AkEvent ShotSound;
var int ActionHand, ActionRevision;
var bool bPrimaryGripWasDown;
var vector SupportRootOffset;
var quat SupportRootRotation;

function bool LeverAction() { return Cycle != None && Cycle.Bones[0] == 'RW_Finger_Lever'; }

// The support role carries the same rifle while its primary hand works the
// lever. Keep that role; no inventory transfer or stow is part of the stroke.
function bool PrimaryStrokeReady()
{
    return LeverAction() && Runtime != None && Runtime.IsCurrent() && InHand()
        && Runtime.PrimaryHand == GunHand && Runtime.SupportHand == OffHand()
        && Owner.InputOwner.Inventory.Registry.GetPrimary(GunHand) == Runtime
        && Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3
        && (!Bridge.bHoldSupportGrip || Owner.GripDown(OffHand()))
        && !Owner.InputOwner.IsSelectorOpen(0) && !Owner.InputOwner.IsSelectorOpen(1)
        && (!bEngaged || ActionHand != GunHand || Runtime.OwnershipRevision == ActionRevision);
}

function quat SupportQ()
{
    return QuatFromRotator(OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
}

function vector RootPos()
{
    if (bEngaged && ActionHand == GunHand && PrimaryStrokeReady())
        return Bridge.Hands[OffHand()].Position + QuatRotateVector(SupportQ(), SupportRootOffset);
    return super.RootPos();
}

function quat RootQ()
{
    if (bEngaged && ActionHand == GunHand && PrimaryStrokeReady()) return QuatProduct(SupportQ(), SupportRootRotation);
    return super.RootQ();
}

function vector LocalHandPosition()
{
    return QuatRotateVector(QuatInvert(RootQ()), Bridge.Hands[ActionHand].Position - RootPos());
}

// Called by the normal placement solve, including native late placement, so
// locomotion/turning follows the support controller while primary motion only
// drives the lever. Losing either role/tracking immediately restores placement.
function bool PrimaryRoot(KFWeapon W, out vector At, out quat Q)
{
    if (!Enabled() || !Owner.InputOwner.ContextValid() || W != Gun
        || !bEngaged || ActionHand != GunHand || !PrimaryStrokeReady()) return false;
    At = RootPos(); Q = RootQ();
    return true;
}

function bool OwnsHand(int Hand)
{
    return Enabled() && Owner.InputOwner.ContextValid() && Gun != None
        && bEngaged && Hand == ActionHand
        && (ActionHand != GunHand || PrimaryStrokeReady());
}

function bool LatchesSupport(VRWeaponRuntime R, int Hand)
{
    return Enabled() && Owner.InputOwner.ContextValid() && R == Runtime
        && bEngaged && ActionHand == GunHand && Hand == OffHand() && PrimaryStrokeReady();
}

static function bool Supported(KFWeapon W)
{
    return class'VRCycleCatalog'.static.Covers(W);
}

function EnsureSounds()
{
    local int I;
    if (Gun == None || SoundsFor == Gun.Class) return;
    SoundsFor = Gun.Class;
    I = class'VRCycleCatalog'.static.FindClass(Gun.Class);
    if (I < 0) return;
    // The fire clip is muted only when the physical events can replace it.
    PumpBackSound = class'VRBreakCatalog'.static.LoadSound(Gun.Class, class'VRCycleCatalog'.default.Profiles[I].Open);
    PumpForwardSound = class'VRBreakCatalog'.static.LoadSound(Gun.Class, class'VRCycleCatalog'.default.Profiles[I].Close);
    ShotSound = class'VRBreakCatalog'.static.LoadSound(Gun.Class, class'VRCycleCatalog'.default.Profiles[I].Shot);
}

// '|' list: the first sound now, the rest 0.12 s apart.
function PlayList(string List, vector At)
{
    local array<string> Paths;
    local AkEvent Sound;
    local int I;
    ParseStringIntoArray(List, Paths, "|", true);
    for (I = 0; I < Paths.Length; ++I)
    {
        Sound = AkEvent(DynamicLoadObject(Paths[I], class'AkEvent', true));
        if (Sound != None) Owner.Audio.QueueSound(Gun, Sound, class'VRReloadAudio'.static.NearField(Bridge, At), 0.12 * I);
    }
}

function bool BlocksFire(KFWeapon W)
{
    return Enabled() && W != None && W == Gun && W.AmmoCount[0] > 0 && (bNeedsPump || Amount > 0.05);
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local int I;
    Runtime = R;
    Gun = R.Item;
    EnsureSounds();
    GunHand = Hand;
    ActionHand = OffHand();
    LastAmmo = Gun.AmmoCount[0];
    bNeedsPump = R.bManualPumpPending;
    bEngaged = false;
    bOpened = false;
    Amount = 0;
    Motion.Reset();
    bTriggerWasDown = true;
    bGripWasDown = (Bridge.NativeGripActiveMask & (1 << OffHand())) == 0 || Owner.GripDown(OffHand());
    bPrimaryGripWasDown = (Bridge.NativeGripActiveMask & (1 << GunHand)) == 0 || Owner.GripDown(GunHand);
    Parts.Length = 0;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    CycleProfile = class'VRCycleCatalog'.static.FindClass(Gun.Class);
    if (CycleProfile < 0) return false;
    Cycle = new(self) class'VRActionPath';
    for (I = 0; I < 3; ++I)
    {
        Cycle.Bones[I] = class'VRCycleCatalog'.default.Profiles[CycleProfile].Bones[I];
        if (Cycle.Bones[I] != '') Cycle.BoneCount = I + 1;
    }
    // Winchester/SPX Shoot is authored around the right wrist on the lever;
    // the left wrist stays on the fore-end. Sampling it made the contact path
    // follow the support grip instead of the hand which operates the part.
    if (!Cycle.SampleClip(Bridge, Gun, RootBone, 'Shoot', Bridge.HandBone(LeverAction() ? 1 : 0))) { Cycle = None; return false; }
    for (I = 0; I < Cycle.BoneCount; ++I) AddPart(Cycle.Ref, Cycle.Bones[I], true);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Parts.Length != Cycle.BoneCount)
    { Tree = None; Parts.Length = 0; Cycle = None; return false; }
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    bSavedPooling = Tree.bEnablePooling;
    Tree.bEnablePooling = false;
    Gun.MySkelMesh.InitSkelControls();
    bHolding = false;
    `log("KF2VR_MANUAL_ACTION bound weapon=" $ Gun.Class @ "hand=" $ Hand @ "length=" $ Cycle.Length
        @ "open=" $ Cycle.OpenTime @ "start=" $ Cycle.StartTime);
    return true;
}

function Unbind()
{
    super.Unbind();
    Cycle = None;
    Amount = 0;
    bOpened = false;
}

function CancelHand(int Hand)
{
    if (Gun == None || (Hand != GunHand && Hand != OffHand())) return;
    Motion.Reset();
    bEngaged = false;
    bGripWasDown = true;
    bPrimaryGripWasDown = true;
}

// A reload that opened and closed the action has cycled it.
function ReloadCompleted(KFWeapon W)
{
    super.ReloadCompleted(W);
    if (Gun == W) { Amount = 0; bOpened = false; }
}

function Update()
{
    local int Before;
    Before = LastAmmo;
    super.Update();
    // The fire clip is muted: keep its after-shot ring.
    if (Gun != None && Gun.AmmoCount[0] < Before && ShotSound != None)
        Gun.PlayAkEvent(ShotSound, true, false, false, class'VRReloadAudio'.static.NearField(Bridge, PumpRest()));
}

// Grip the handle and work it open and back along its stock throw.
function UpdateHand()
{
    local int Hand;
    local bool bGrip, bGripEdge, bPrimaryGrip, bPrimaryEdge, bOffGrip, bOffEdge;
    local vector P, HandLocal;
    local quat InvSupport;
    bPrimaryGrip = Owner.GripDown(GunHand);
    bPrimaryEdge = bPrimaryGrip && !bPrimaryGripWasDown;
    bPrimaryGripWasDown = bPrimaryGrip;
    bOffGrip = Owner.GripDown(OffHand());
    bOffEdge = bOffGrip && !bGripWasDown;
    bGripWasDown = bOffGrip;
    if (!bEngaged && bPrimaryEdge && PrimaryStrokeReady() && (bNeedsPump || Amount > 0.05)
        && VSize(Bridge.Hands[GunHand].Position
            - (RootPos() + QuatRotateVector(RootQ(), Cycle.ContactLocal(Amount) * GunScale()))) <= Radius)
    {
        InvSupport = QuatInvert(SupportQ());
        SupportRootOffset = QuatRotateVector(InvSupport, RootPos() - Bridge.Hands[OffHand()].Position);
        SupportRootRotation = QuatProduct(InvSupport, RootQ());
        ActionRevision = Runtime.OwnershipRevision;
        ActionHand = GunHand;
        bEngaged = true; bByGrip = true; bBySupport = false;
        Cycle.GrabOffset = LocalHandPosition() / GunScale() - Cycle.ContactLocal(Amount);
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << GunHand, 0.25, 0.02);
        return;
    }
    Hand = bEngaged ? ActionHand : OffHand();
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (Hand == GunHand ? !PrimaryStrokeReady() : Owner.InputOwner.Inventory.Registry.GetPrimary(Hand) != None)
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand) || Cycle == None)
    {
        CancelHand(Hand);
        return;
    }
    P = Bridge.Hands[Hand].Position;
    HandLocal = QuatRotateVector(QuatInvert(RootQ()), P - RootPos()) / GunScale();
    bGrip = Owner.GripDown(Hand);
    bGripEdge = Hand == OffHand() && bOffEdge;
    if (!bEngaged)
    {
        if (!bGripEdge || (!bNeedsPump && Amount <= 0.05)
            || VSize(P - (RootPos() + QuatRotateVector(RootQ(), Cycle.ContactLocal(Amount) * GunScale()))) > Radius) return;
        // The action grip replaces any support grip on the fore-end.
        if (Owner.InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime) Owner.InputOwner.Inventory.ReleaseHand(Hand);
        ActionHand = Hand;
        bEngaged = true; bByGrip = true; bBySupport = false;
        Cycle.GrabOffset = HandLocal - Cycle.ContactLocal(Amount);
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << Hand, 0.25, 0.02);
        return;
    }
    if (!Motion.Check(LocalHandPosition(), Owner.Now()))
    {
        if (Hand == GunHand) CancelHand(Hand);
        else Motion.Begin(LocalHandPosition(), Owner.Now());
        return;
    }
    if (!bGrip) { bEngaged = false; Motion.Reset(); return; }
    Amount = Cycle.Project(HandLocal - Cycle.GrabOffset);
    if (!bOpened && Amount >= 0.95)
    {
        bOpened = true;
        PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Open, P);
        // The spent case leaves as the action opens, not on the stock clock.
        if (bNeedsPump && (Gun.MuzzleFlash == None || !Gun.MuzzleFlash.bAutoActivateShellEject)) Gun.ANIMNOTIFY_ShellEject();
        if (class'VRCycleCatalog'.default.Profiles[CycleProfile].Eject != "")
            PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Eject, P);
        Owner.Pulse(1 << Hand, 0.7, 0.045);
        Owner.Pulse(1 << GunHand, 0.3, 0.03);
    }
    if (bOpened && Amount <= 0.05) Pumped();
}

// Fully closed after opening: the next round is chambered.
function Pumped()
{
    bOpened = false;
    bEngaged = false;
    Amount = 0;
    Motion.Reset();
    PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Close, Bridge.Hands[ActionHand].Position);
    bNeedsPump = false;
    if (Runtime != None) Runtime.bManualPumpPending = false;
    Gun.ANIMNOTIFY_EnableAdditiveBob();
    Owner.Pulse(3, 1.0, 0.08);
}

// After placement: the action held where the hand left it along its throw.
function PlaceVisuals()
{
    local int I;
    local vector P;
    local quat Q;
    local bool bHold;
    if (Gun == None || Tree == None || Gun.bDeleteMe || Gun.MySkelMesh == None || Cycle == None) return;
    bHold = Enabled() && Owner.InputOwner.ContextValid()
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3 && InHand();
    if (!bHold)
    {
        if (bHolding)
        {
            for (I = 0; I < Parts.Length; ++I) Parts[I].Control.SetSkelControlStrength(0, 0);
            bHolding = false;
            Gun.MySkelMesh.ForceSkelUpdate();
        }
        return;
    }
    for (I = 0; I < Parts.Length; ++I)
    {
        Cycle.PoseAt(Amount, I, P, Q);
        Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
        if (!bHolding) Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    bHolding = true;
    Gun.MySkelMesh.ForceSkelUpdate();
    Gun.MySkelMesh.ForceUpdate(true);
}

defaultproperties
{
    Radius=12
}
