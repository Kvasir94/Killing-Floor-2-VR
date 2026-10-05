// Manual bolt and lever actions (VR CONTROLS > INTERACTIVE RELOADS: ON + MANUAL
// PUMP), as the manual pump works the pump shotguns: after every shot that
// leaves a round, the gun will not fire again until the off hand works its
// action open (ejecting the spent case) and closed (chambering the next round).
// The action follows the hand along the motion the stock fire clip gives it
// (VRCycleCatalog, VRActionPath sampled from Shoot); that clip's own cycle
// notifies are muted on the live node and the same stock events play at the
// physical open and close instead. Firing stays stock: only the trigger press
// is withheld, an empty gun still dry fires into its auto-reload, and the
// reload's own open and close (break action, lever) count as a cycle.
class VRManualAction extends VRManualPump;

var VRActionPath Cycle;
var float Amount;
var bool bOpened;
var int CycleProfile;
var AkEvent ShotSound;

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
    LastAmmo = Gun.AmmoCount[0];
    bNeedsPump = R.bManualPumpPending;
    bEngaged = false;
    bOpened = false;
    Amount = 0;
    Motion.Reset();
    bTriggerWasDown = true;
    bGripWasDown = (Bridge.NativeGripActiveMask & (1 << OffHand())) == 0 || Owner.GripDown(OffHand());
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
    if (!Cycle.SampleClip(Bridge, Gun, RootBone, 'Shoot', Bridge.HandBone(0))) { Cycle = None; return false; }
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
    local bool bGrip, bGripEdge;
    local vector P, HandLocal;
    Hand = OffHand();
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || Owner.InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand) || Cycle == None)
    {
        CancelHand(Hand);
        return;
    }
    P = Bridge.Hands[Hand].Position;
    HandLocal = LocalHandPosition() / GunScale();
    bGrip = Owner.GripDown(Hand);
    bGripEdge = bGrip && !bGripWasDown;
    bGripWasDown = bGrip;
    if (!bEngaged)
    {
        if (!bGripEdge || (!bNeedsPump && Amount <= 0.05)
            || VSize(P - (RootPos() + QuatRotateVector(RootQ(), Cycle.ContactLocal(Amount) * GunScale()))) > Radius) return;
        // The action grip replaces any support grip on the fore-end.
        if (Owner.InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime) Owner.InputOwner.Inventory.ReleaseHand(Hand);
        bEngaged = true; bByGrip = true; bBySupport = false;
        Cycle.GrabOffset = HandLocal - Cycle.ContactLocal(Amount);
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << Hand, 0.25, 0.02);
        return;
    }
    if (!Motion.Check(LocalHandPosition(), Owner.Now())) { Motion.Begin(LocalHandPosition(), Owner.Now()); return; }
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
    PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Close, Bridge.Hands[OffHand()].Position);
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
