// Manual bolt and lever actions (MANUAL PUMP, independently of physical
// insertion), as the manual pump works the pump shotguns: after every shot that
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
var bool bCloseCued;
var int CycleProfile;
var AkEvent ShotSound;
var int ActionHand, ActionRevision;
var bool bPrimaryGripWasDown;
var bool bPrimaryGripBlocked;
var vector SupportRootOffset;
var quat SupportRootRotation;
var VRLeverHand LeverHand;
var bool bObservedStockLeverOpen;
var int StockLeverReloadRevision;
var float AutoCycleAt, AutoCycleFrom;
var VRLeverIntent PrimaryIntent;

function bool LeverAction() { return Cycle != None && Cycle.Bones[0] == 'RW_Finger_Lever'; }

static function bool PrimaryGripOnly(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_Rifle_Winchester1894'
        || W.Class == class'KFWeap_Rifle_CenterfireMB464');
}

function bool ReadyCycleAllowed()
{
    // Trigger-hand lever motion is only admitted for an owed cycle. Free
    // cycling must not turn ordinary two-hand aiming into lever ownership.
    return !PrimaryGripOnly(Gun) && super.ReadyCycleAllowed();
}

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

// Thermite's feed handle does not extract a cartridge or eject its loaded payload.
function bool EjectAtRear(int Hand)
{
    if (Gun != None && Gun.Class == class'KFWeap_RocketLauncher_ThermiteBore') return true;
    return super.EjectAtRear(Hand);
}

function bool BlocksFire(KFWeapon W)
{
    return Enabled() && W != None && W == Gun && W.HasAmmo(0) && (bNeedsPump || Amount > 0.05);
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local int I;
    if (PrimaryIntent != None) PrimaryIntent.Reset();
    Runtime = R;
    Gun = R.Item;
    EnsureSounds();
    GunHand = Hand;
    ActionHand = OffHand();
    LastAmmo = Gun.AmmoCount[0];
    bNeedsPump = R.bManualPumpPending;
    bEngaged = false;
    bOpened = class'VRPumpCatalog'.static.IsLever(Gun) && R.bLeverCycleOpen;
    Amount = class'VRPumpCatalog'.static.IsLever(Gun) ? FClamp(R.LeverCycleAmount, 0, 1) : 0.0;
    Motion.Reset();
    bTriggerWasDown = true;
    bGripWasDown = (Bridge.NativeGripActiveMask & (1 << OffHand())) == 0 || Owner.GripDown(OffHand());
    bPrimaryGripWasDown = (Bridge.NativeGripActiveMask & (1 << GunHand)) == 0 || Owner.GripDown(GunHand);
    bPrimaryGripBlocked = false;
    bOpenCued = bOpened; bCloseCued = false;
    bWasCarry = Carried();
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
    // Sample the wrist operating the action, independently of the loader.
    if (!Cycle.SampleClip(Bridge, Gun, RootBone, 'Shoot',
        Bridge.HandBone(class'VRCycleCatalog'.default.Profiles[CycleProfile].ActionHand),
        Cycle.Bones[0] == 'RW_Finger_Lever')) { Cycle = None; return false; }
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
    AutoCycleAt = 0;
    if (PrimaryIntent != None) PrimaryIntent.Reset();
    if (LeverHand != None) LeverHand.Cancel();
    bObservedStockLeverOpen = false;
    super.Unbind();
    Cycle = None;
    Amount = 0;
    bOpened = false;
}

function CancelHand(int Hand)
{
    if (Gun == None || (Hand != GunHand && Hand != OffHand())) return;
    if (PrimaryIntent != None) PrimaryIntent.Reset();
    if (LeverHand != None) LeverHand.Cancel();
    Motion.Reset();
    bEngaged = false;
    bGripWasDown = true;
    bPrimaryGripWasDown = true;
    // Reacquiring the primary stroke needs deliberate path travel again
    // (VRLeverIntent), never a main-grip release that Hold turns into a drop.
    bPrimaryGripBlocked = false;
    SavePersistentState();
}

function SavePersistentState()
{
    super.SavePersistentState();
    if (Runtime == None || Gun == None || !class'VRPumpCatalog'.static.IsLever(Gun)
        || (Owner.bActive && Owner.Gun == Gun && Owner.LeverPath != None)) return;
    Runtime.LeverCycleAmount = Amount;
    Runtime.bLeverCycleOpen = bOpened;
}

// A reload that opened and closed the action has cycled it.
function ReloadCompleted(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (PrimaryIntent != None) PrimaryIntent.Reset();
    super.ReloadCompleted(W);
    if (W != None && Owner != None && Owner.InputOwner != None && Owner.InputOwner.Inventory != None)
    {
        R = Owner.InputOwner.Inventory.Registry.FindItem(W);
        if (R != None)
        { R.LeverCycleAmount = 0; R.bLeverCycleOpen = false; }
    }
    if (Gun == W) { Amount = 0; bOpened = false; bObservedStockLeverOpen = false; }
}

function BeforeAnimation(KFWeapon W, name Sequence)
{
    local AnimNodeSequence N;
    // Observe the final old pose before stock replaces its open/load clip.
    if (W == Gun && bObservedStockLeverOpen) ObserveStockEmptyReload();
    super.BeforeAnimation(W, Sequence);
    // Frost Fang and Thermite record one combined cycle sound. Physical
    // opening owns it; Thermite's last-shot exhaust remains powered.
    if (W == Gun && (W.Class == class'KFWeap_Rifle_FrostShotgunAxe'
        || (W.Class == class'KFWeap_RocketLauncher_ThermiteBore'
            && InStr(Caps(string(Sequence)), "LAST") < 0))
        && RequiresManualCycle() && Left(string(Sequence), 5) == "Shoot"
        && PumpBackSound != None)
    {
        N = Bridge.ResolveLiveWeaponAnimNode(W);
        if (N != None && N == W.WeaponAnimSeqNode)
        { MutedNode = N; bMutedSaved = N.bNoNotifies; N.bNoNotifies = true; }
    }
}

function ObserveStockEmptyReload()
{
    local AnimNodeSequence N;
    local vector P;
    local quat Q, InvRoot;
    local float FullThrow, DistanceFromClosed;
    if (Gun == None || Runtime == None || !Runtime.IsCurrent()
        || (!Owner.Automatic(Runtime) && !Owner.AutoActionAllowed(Runtime))
        || !RequiresManualCycle() || !LeverAction() || Runtime.MechanismPending != 0
        || !Runtime.bManualPumpPending || !Gun.IsInState('Reloading')
        || (Runtime.PrimaryHand != GunHand && !Carried()))
    { bObservedStockLeverOpen = false; return; }
    N = Bridge.ResolveLiveWeaponAnimNode(Gun);
    // Only the empty open-and-load clip works this lever. Ordinary top-ups
    // and Reload_Close keep it shut and cannot discharge a spent action.
    if (N == None || (N.AnimSeqName != 'Reload_Open_Shell' && N.AnimSeqName != 'Reload_Open_Shell_Elite'))
    { bObservedStockLeverOpen = false; return; }
    if (bObservedStockLeverOpen && Runtime.OwnershipRevision != StockLeverReloadRevision)
    { bObservedStockLeverOpen = false; return; }
    Gun.MySkelMesh.ForceUpdate(false);
    InvRoot = QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(RootBone));
    P = QuatRotateVector(InvRoot, Gun.MySkelMesh.GetBoneLocation(Cycle.Bones[0])
        - Gun.MySkelMesh.GetBoneLocation(RootBone)) / GunScale();
    Q = QuatProduct(InvRoot, Gun.MySkelMesh.GetBoneQuaternion(Cycle.Bones[0]));
    FullThrow = Cycle.Distance(Cycle.Path[0].P[0], Cycle.Path[0].Q[0],
        Cycle.Path[Cycle.Path.Length - 1].P[0], Cycle.Path[Cycle.Path.Length - 1].Q[0]);
    DistanceFromClosed = Cycle.Distance(Cycle.Path[0].P[0], Cycle.Path[0].Q[0], P, Q);
    if (FullThrow <= 0.1) return;
    if (DistanceFromClosed >= FullThrow * OpenStop())
    { bObservedStockLeverOpen = true; StockLeverReloadRevision = Runtime.OwnershipRevision; }
    // Interrupting the stock empty-load clip transfers its actual action
    // position to the manual/busy-hand owner, including a reached rear stop.
    Amount = FClamp(DistanceFromClosed / FullThrow, 0, 1);
    bOpened = bObservedStockLeverOpen;
    SavePersistentState();
    // Payment alone is insufficient: see the actual lever return after its
    // open pose, while the same owned stock reload still holds the gun.
    if (bObservedStockLeverOpen && Gun.HasAmmo(0) && DistanceFromClosed <= FullThrow * CloseStop())
        ReloadCompleted(Gun);
}

function Update()
{
    local int Before, PreviousHand;
    local bool bPreviousCarry;
    Before = LastAmmo;
    PreviousHand = GunHand;
    bPreviousCarry = bWasCarry;
    // A paused automatic stroke resumes from its saved pose, not from an
    // old wall-clock origin after the opposite hand becomes busy again.
    if (Runtime == None || !Owner.InputOwner.ContextValid()
        || !((Owner.Automatic(Runtime) && Runtime.AutomaticReload.Stage == 5)
            || (Runtime.bManualPumpPending && OtherHandOccupied() && InHand()))) AutoCycleAt = 0;
    super.Update();
    if (!bEngaged && PrimaryIntent != None && (Gun == None || Gun.IsInState('Reloading')
        || (Owner.bActive && Owner.Gun == Gun))) PrimaryIntent.Reset();
    // Inventory has already observed a physical carry/regrip boundary. Its
    // placement transition discards engagement and rebases the next sample;
    // do not retain a blocker indexed to the previous meaning of GunHand.
    if (Gun != None && (GunHand != PreviousHand || bWasCarry != bPreviousCarry))
        bPrimaryGripBlocked = false;
    // Interactive opening/closing writes the same actor state. Its binding
    // temporarily owns the bones; importing it prevents a stale manual pose
    // from reopening or blocking a just-completed reload on the next frame.
    if (Runtime != None && class'VRPumpCatalog'.static.IsLever(Gun))
    {
        if (Owner.bActive && Owner.Gun == Gun && Owner.LeverPath != None)
        { Amount = Runtime.LeverCycleAmount; bOpened = Runtime.bLeverCycleOpen; }
        else SavePersistentState();
    }
    // The fire clip is muted: keep its after-shot ring.
    if (RequiresManualCycle() && Gun != None && Gun.AmmoCount[0] < Before && ShotSound != None)
        Gun.PlayAkEvent(ShotSound, true, false, false, class'VRReloadAudio'.static.NearField(Bridge, PumpRest()));
}

// A support-only rifle still has a free hand at its bolt or trigger/lever.
// Pump inertia cannot project that hand onto a bolt/lever's authored path.
function UpdateCarry()
{
    UpdateHand();
}

// Grip the handle and work it open and back along its stock throw.
function vector Contact() { return ContactAt(Amount); }
function vector ContactAt(float S) { return RootPos() + QuatRotateVector(RootQ(), Cycle.ContactLocal(S) * GunScale()); }

function float ContactDistance(int Hand)
{
    local vector P;
    local quat Q;
    Cycle.PoseAt(Amount, 0, P, Q);
    P = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
    // The glow is on the actual handle; accept its palm contact as well as
    // the sampled stock wrist, whose offset can be outside the wrist radius.
    return FMin(VSize(Bridge.Hands[Hand].Position - Contact()),
        VSize(Bridge.PalmPosition(Hand) - P));
}

function UpdateHand()
{
    local int Hand;
    local bool bGrip, bGripEdge, bPrimaryGrip, bPrimaryEdge, bOffGrip, bOffEdge;
    local vector P, HandLocal;
    local float Proposed;
    local VRWeaponRuntime Other;
    // A button may finish only this owed cycle. Merely drawing another gun
    // or freeing its hand never starts or cancels automatic work.
    Other = Owner.InputOwner.Inventory.GetHeldForHand(OffHand());
    if (Runtime != None && Runtime.MechanismPending == 0 && bNeedsPump
        && (Owner.Automatic(Runtime) || OtherHandOccupied()))
    { UpdateAutomaticCycle(); return; }
    AutoCycleAt = 0;
    bPrimaryGrip = Owner.GripDown(GunHand);
    if (!bPrimaryGrip) bPrimaryGripBlocked = false;
    bPrimaryEdge = bPrimaryGrip && !bPrimaryGripWasDown;
    bPrimaryGripWasDown = bPrimaryGrip;
    bOffGrip = Owner.GripDown(OffHand());
    bOffEdge = bOffGrip && !bGripWasDown;
    bGripWasDown = bOffGrip;
    if (!bEngaged && !bPrimaryGripBlocked && !LockedOpen() && (bPrimaryEdge || bPrimaryGrip) && PrimaryStrokeReady()
        && (bNeedsPump || ReadyCycleAllowed() || Amount > 0.05))
    {
        if (PrimaryIntent == None) PrimaryIntent = new(self) class'VRLeverIntent';
        if (!PrimaryIntent.Step(Bridge, Runtime, Cycle, GunHand, Amount, bOpened ? -1 : 1,
            bOpened ? CloseStop() : OpenStop(), GunScale(), Owner.Now(), Proposed)) return;
        SupportRootOffset = PrimaryIntent.RootOffset;
        SupportRootRotation = PrimaryIntent.RootRotation;
        ActionRevision = Runtime.OwnershipRevision;
        ActionHand = GunHand;
        bEngaged = true; bByGrip = true; bBySupport = false;
        Amount = Proposed;
        SavePersistentState();
        BeginLeverHand();
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << GunHand, 0.25, 0.02);
        // Process this very sample through the ordinary rear/front owner.
        // A fast admitted stroke may already have reached its endpoint.
    }
    if (!bEngaged && PrimaryIntent != None) PrimaryIntent.Reset();
    // These levers belong to the trigger grip. A support-only carry must
    // wait for primary regrip, never acquire the free hand as a lever grip.
    if (PrimaryGripOnly(Gun) && (!bEngaged || ActionHand != GunHand || !PrimaryStrokeReady()))
    {
        if (bEngaged) CancelHand(ActionHand);
        return;
    }
    Hand = bEngaged ? ActionHand : OffHand();
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (Hand == GunHand ? !PrimaryStrokeReady() : (Other != None && Other != Runtime))
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
        if (!(bGripEdge || (bGrip && bNeedsPump)) || (!bNeedsPump && !ReadyCycleAllowed() && Amount <= 0.05)
            || ContactDistance(Hand) > Radius || LockedOpen()) return;
        // The action grip replaces any support grip on the fore-end.
        if (Owner.InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime) Owner.InputOwner.Inventory.ReleaseHand(Hand);
        ActionHand = Hand;
        bEngaged = true; bByGrip = true; bBySupport = false;
        Cycle.Grab(HandLocal, Amount);
        BeginLeverHand();
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << Hand, 0.25, 0.02);
        return;
    }
    if (!Motion.Check(LocalHandPosition(), Owner.Now()))
    {
        // Neither hand may finish an old action from a rejected return sample.
        // Keep its physical pose and spent chamber, then require a fresh grip.
        CancelHand(Hand);
        return;
    }
    if (!bGrip) { CancelHand(Hand); return; }
    Amount = Cycle.ProjectGrab(HandLocal);
    // A lever reaches its stops by feel, as a slide's 0.9 rack does.
    // The spent case leaves as the action opens, not on the stock clock. A
    // refused live-round debit leaves the action unopened until it is accepted.
    if (!bOpened && Amount <= CloseStop()) bOpenCued = false;
    if (!bOpened && Amount >= OpenStop() && EjectAtRear(Hand))
    {
        bOpened = true;
        if (!bOpenCued)
        {
            PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Open, P);
            if (class'VRCycleCatalog'.default.Profiles[CycleProfile].Eject != "")
                PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Eject, P);
            class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.BoltRear, 3);
        }
        bOpenCued = true; bCloseCued = false;
    }
    if (LockedOpen()) { Amount = 1; CancelHand(Hand); return; }
    SavePersistentState();
    if (bOpened && Amount <= CloseStop()) Pumped();
}

// The last round has left: an opened lever stays at its rear stop until
// rounds are loaded, and the empty-tube reload starts from that open lever.
function bool LockedOpen()
{
    return bOpened && LeverAction() && Gun != None && !Gun.HasAmmo(0);
}

function UpdateAutomaticCycle()
{
    local float Duration;
    if (Cycle == None || !bNeedsPump) return;
    if (LeverHand != None) LeverHand.Cancel();
    bEngaged = false; Motion.Reset(); ActionHand = GunHand;
    if (AutoCycleAt == 0) { AutoCycleAt = Owner.Now(); AutoCycleFrom = Amount; }
    Duration = FMax((Cycle.OpenTime - Cycle.StartTime)
        / FMax(Cycle.RefSeq.AnimSeq.RateScale, 0.01), 0.08);
    if (!bOpened)
    {
        Amount = FMin(1, AutoCycleFrom + (Owner.Now() - AutoCycleAt) / Duration);
        if (Amount >= 1 && EjectAtRear(GunHand))
        {
            bOpened = true; AutoCycleAt = Owner.Now(); AutoCycleFrom = 1;
            if (!bOpenCued)
            {
                PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Open, Contact());
                PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Eject, Contact());
            }
            bOpenCued = true; bCloseCued = false;
        }
    }
    else if (LockedOpen()) { Amount = 1; SavePersistentState(); }
    else
    {
        Amount = FMax(0, AutoCycleFrom - (Owner.Now() - AutoCycleAt) / Duration);
        if (Amount <= 0) { AutoCycleAt = 0; Pumped(); }
    }
}

function float OpenStop() { return LeverAction() ? 0.85 : 0.90; }
function float CloseStop() { return LeverAction() ? 0.12 : 0.10; }

function BeginLeverHand()
{
    if (LeverHand == None) LeverHand = new(self) class'VRLeverHand';
    LeverHand.Begin(Bridge, Runtime, Cycle, ActionHand,
        class'VRCycleCatalog'.default.Profiles[CycleProfile].ActionHand, !LeverAction());
}

function CycleEjectRefused(VRWeaponRuntime R)
{
    local bool bWasPending;
    bWasPending = R != None && R == Runtime && R.Item == Gun && (bLiveEjectPending || R.CycleEjectOpen == 1);
    super.CycleEjectRefused(R);
    if (bWasPending)
    {
        bOpened = false;
        if (R != None) R.bLeverCycleOpen = false;
        SavePersistentState();
    }
}

// Fully closed after opening: the next round is chambered.
function Pumped()
{
    // The close is heard when the hand closes it, not when a networked
    // cycle receipt later lets the action finish (forward strokes were silent).
    if (!bCloseCued)
    {
        PlayList(class'VRCycleCatalog'.default.Profiles[CycleProfile].Close, Bridge.Hands[ActionHand].Position);
        bCloseCued = true;
    }
    if (Runtime != None && Runtime.MechanismPending != 0) return;
    if (PrimaryIntent != None) PrimaryIntent.Reset();
    if (LeverHand != None) LeverHand.Cancel();
    bLiveEjectPending = false;
    bOpened = false;
    bEngaged = false;
    Amount = 0;
    Motion.Reset();
    bNeedsPump = false;
    if (Runtime != None)
    {
        Runtime.bManualPumpPending = false;
        if (class'VRPumpCatalog'.static.IsLever(Gun))
        { Runtime.LeverCycleAmount = 0; Runtime.bLeverCycleOpen = false; }
    }
    Gun.ANIMNOTIFY_EnableAdditiveBob();
    class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.BoltClose, 3);
}

// After placement: the action held where the hand left it along its throw.
function PlaceVisuals()
{
    local int I;
    local vector P;
    local quat Q;
    local bool bHold;
    if (Gun == None || Tree == None || Gun.bDeleteMe || Gun.MySkelMesh == None || Cycle == None)
    { if (LeverHand != None) LeverHand.Cancel(); return; }
    // A stock empty-tube reload animates a locked-open lever itself; holding
    // it open would hide the close that completes the cycle.
    bHold = Enabled() && (RequiresManualCycle() || bEngaged || Amount > 0.05) && Owner.InputOwner.ContextValid()
        && !(LockedOpen() && Gun.IsInState('Reloading'))
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3 && InHand()
        && !(Owner.bActive && Owner.Gun == Gun && Owner.LeverPath != None);
    if (!bHold)
    {
        if (LeverHand != None) LeverHand.Cancel();
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
    if (LeverHand != None) LeverHand.Place(Cycle, Amount, RootPos(), RootQ(), GunScale(), bEngaged);
}

defaultproperties
{
    Radius=12
}
