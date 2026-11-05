// Manual pump action, independently configurable from physical ammunition.
// After its stock pump shot the shotgun will not fire again until the off hand
// works the fore-end back and forward. The fore-end, and the bolt it drives,
// follow the hand; the stock fire animation no longer pumps them by itself.
// See docs/VR_PHYSICAL_RELOAD.md.
//
// Firing stays stock: the gate only withholds the trigger press (single fire
// already needs a fresh press per shot), so the stock fire interval still caps
// the rate and nothing reaches the server that stock would not send. An empty
// gun is never gated, so its dry fire still starts the stock auto-reload.
// Entering a reload does not chamber a round: its physical closing stroke
// clears a pending pump only when the reload owner confirms it.
//
// The fore-end is locked forward unless a stroke is owed, and only the support
// hand (posed on the fore-end) works it. The shot clip's own PumpBack, shell
// eject and PumpForward notifies are muted on the live node only; the same
// stock events play at the physical rear stop and forward return instead.
//
// The parts are held through translation/rotation controls appended to this
// gun's own AnimTree instance (the VRRiotShield pattern), set in world space
// from the idle pose relative to the root bone each frame after placement.
// First pass: the starting pump shotgun only. Local presentation and input.
class VRManualPump extends Object;

var VRInteractiveReload Owner;
var VRHandsBridge Bridge;
var VRReloadMotionGuard Motion;
var VRPumpInertia Inertia;
var bool bWasCarry, bRebaseHand;
// Button reloads still own their stock ammo timers when physical insertion is
// disabled. Only their empty-port presentation and subsequent close are manual.
var bool bStockEmptyReload;
var int LastRoomSpaceEpoch;

var KFWeapon Gun;
var VRWeaponRuntime Runtime;
var int GunHand, LastAmmo;
var name RootBone;
var bool bNeedsPump, bEngaged, bBySupport, bByGrip, bPulledBack, bTriggerWasDown, bGripWasDown, bHolding;
// The open stroke's live-round debit was sent and its receipt is outstanding.
var bool bLiveEjectPending;
// This stroke already played its open sound and haptics. A refused debit
// asks again from the same stop without replaying them; home clears it.
var bool bOpenCued;
var float Pull, StartX;
var float AutomaticCycleAt, AutomaticCycleFrom;

// Held parts: the idle pose relative to the root, and whether each travels
// back with the pump (the fore-end, bolt and action bar) or just stays put.
struct HeldPart
{
    var name Bone;
    var bool bTravels;
    var float TravelScale;
    var vector IdleLocal;
    var quat IdleLocalQ;
    var SkelControlSingleBone Control;
};
var array<HeldPart> Parts;
var AnimTree Tree;
var bool bSavedPooling;

var array<name> TravelBones, StillBones;
var float Travel, Radius;
// A deliberate stroke owns the support hand (VRHandInventory will not revoke
// the support contact by distance) until the grip is released, tracking is
// lost or the inventory releases it. Distance is not a release while held:
// sideways pumping and the moving fore-end can both leave the grab volume.
// The rear stop engages at RearStop of the travel, the forward lock at
// ForwardLock: use the same near-endpoint convention as break actions.
var float RearStop, ForwardLock;
// Hand stroke per unit of fore-end travel, as on the reload pump.
var float ThrowScale;

// The shot clip whose notifies this pump replaces, and its original flag.
var AnimNodeSequence MutedNode;
var bool bMutedSaved;
var AkEvent PumpBackSound, PumpForwardSound;
var class<KFWeapon> SoundsFor;

function Initialize(VRInteractiveReload O)
{
    Owner = O;
    Bridge = O.Bridge;
    Motion = new(self) class'VRReloadMotionGuard';
    // A hard rack slams the hand at several metres per second relative to a
    // gun that is itself kicking; only a tracking jump exceeds this.
    Motion.SpeedLimit = 1500;
    Inertia = new(self) class'VRPumpInertia';
}

function bool Carried()
{
    return Runtime != None && Runtime.PrimaryHand < 0 && Runtime.SupportHand == GunHand
        && Runtime.CarryPrimaryHand >= 0;
}

function bool LoadingPort()
{
    return Owner.bActive && Owner.Gun == Gun && Owner.bPumpFirstShell;
}

function bool ReloadingPump()
{
    return Owner.bActive && Owner.Gun == Gun && class'VRPumpCatalog'.static.PumpAction(Gun);
}

function float VisualPull(KFWeapon W)
{
    if (!Enabled() || W == None || W != Gun || Tree == None) return 0.0;
    return Pull;
}

// 0 means inactive. Active values encode actual world UU, never an animation rate.
function int CarryVisualCode(int Hand)
{
    if (!Enabled() || !Carried() || Runtime.Presenter == None || Hand != GunHand || (!InHand() && !ReloadingPump())
        || (Owner.bActive && Owner.Gun == Gun && !ReloadingPump()) || !Runtime.Presenter.FreshCarryVisual(Hand)) return 0;
    return 1 + Clamp(Round(Pull * 64), 0, 4095);
}

// The bound gun's own pump sounds (VRPumpCatalog).
function EnsureSounds()
{
    if (Gun == None || SoundsFor == Gun.Class) return;
    SoundsFor = Gun.Class;
    PumpBackSound = class'VRPumpCatalog'.static.LoadSound(Gun.Class, 0);
    PumpForwardSound = class'VRPumpCatalog'.static.LoadSound(Gun.Class, 1);
}

// Before every stock weapon clip (VRHandsBridge.BeforeReloadAnimation): a shot
// clip on the bound gun is muted before it can issue its first notify; any
// other clip gets the original flag back first. Shared assets are untouched.
function BeforeAnimation(KFWeapon W, name Sequence)
{
    local AnimNodeSequence N;
    local VRWeaponRuntime R;
    // Record empty-start before rig/reference readiness can delay Bind beyond
    // stock's first-shell timer. This records debt; stock still pays the shell.
    if (W != None && RequiresManualCycle() && !Owner.Enabled()
        && class'VRPumpCatalog'.static.PumpAction(W) && W.AmmoCount[0] == 0
        && (Sequence == 'Reload_Open_Shell' || Sequence == 'Reload_Open_Shell_Elite')
        && Owner.InputOwner != None && Owner.InputOwner.Inventory != None
        && Owner.InputOwner.Inventory.Registry != None)
    {
        R = Owner.InputOwner.Inventory.Registry.FindItem(W);
        if (R != None && R.MechanismPending == 0 && !R.bPumpPortPredicted)
        {
            R.PumpPortStage = 1;
            R.bManualPumpPending = true;
        }
    }
    // Every manual action owes a cycle after a shot, including a perk-free
    // shot or one arriving before the presentation binds. HZ12 increments
    // its protected NumShotsFired in ConsumeAmmo, before
    // selecting this shot clip, even when a perk saves the shell. Its public
    // fire-last decision exposes that exact stock two-shot cadence. Capture
    // debt here, including before a delayed rig bind; ammo deltas cannot tell
    // a first shot, second shot, free shot or correction apart.
    if (W != None && RequiresManualCycle() && Supported(W)
        && Left(string(Sequence), 5) == "Shoot"
        && Owner.InputOwner != None && Owner.InputOwner.Inventory != None
        && Owner.InputOwner.Inventory.Registry != None)
    {
        R = Owner.InputOwner.Inventory.Registry.FindItem(W);
        if (R != None)
        {
            R.bManualPumpPending = class'VRPumpCatalog'.static.ShotOwesCycle(W, Sequence);
            if (W == Gun) { bNeedsPump = R.bManualPumpPending; bPulledBack = false; }
        }
    }
    if (W == None || W != Gun) return;
    RestoreFireClip();
    EnsureSounds();
    if (!RequiresManualCycle() || Left(string(Sequence), 5) != "Shoot" || PumpBackSound == None || PumpForwardSound == None
        || !class'VRPumpCatalog'.static.ShotOwesCycle(W, Sequence)) return;
    N = Bridge.ResolveLiveWeaponAnimNode(W);
    if (N == None || N != W.WeaponAnimSeqNode) return;
    MutedNode = N;
    bMutedSaved = N.bNoNotifies;
    N.bNoNotifies = true;
}

function RestoreFireClip()
{
    if (MutedNode != None) MutedNode.bNoNotifies = bMutedSaved;
    MutedNode = None;
}

function PlayPumpSound(AkEvent Sound)
{
    if (Sound != None && Gun != None && !Gun.bDeleteMe) Gun.PlayAkEvent(Sound, true, false, false, class'VRReloadAudio'.static.NearField(Bridge, PumpRest()));
}

function bool Enabled()
{
    return Bridge != None && Owner != None && (Bridge.bInteractiveReloads || Bridge.bFreeWeaponCycling || Owner.Enabled());
}

function bool RequiresManualCycle()
{
    return Bridge != None && Bridge.bInteractiveReloads;
}

function bool ReadyCycleAllowed()
{
    return Bridge != None && Bridge.bFreeWeaponCycling && Gun != None && class'VRWeaponRuntime'.static.StockIdle(Gun)
        && !class'VRPumpCatalog'.static.PumpAction(Gun) && !class'VRPumpCatalog'.static.CycleOnly(Gun);
}

// Only tube-fed pumps open their empty breech before the first shell.
// Manual cycling can be enabled independently of physical shell insertion.
function bool CanOpenEmptyPort()
{
    return Gun != None && class'VRPumpCatalog'.static.PumpAction(Gun) && !Gun.HasAmmo(0)
        && (Owner.Enabled() || RequiresManualCycle());
}

function SelectStroke()
{
    local float Authored;
    Travel = default.Travel;
    Authored = class'VRPumpCatalog'.static.PumpStroke(Gun,
        Runtime != None && (Runtime.PumpPortStage > 0 || ReloadingPump() || CanOpenEmptyPort()));
    if (Authored > 0) Travel = Authored * GunScale();
}

function bool CanStartStroke()
{
    return bNeedsPump || ReadyCycleAllowed() || (Runtime != None && Runtime.PumpPortStage > 0)
        || (ReloadingPump() && Owner.bAwaitRack)
        || CanOpenEmptyPort();
}

function bool EmptyPortLatched()
{
    return Runtime != None && Runtime.PumpPortStage == 1 && Gun != None && !Gun.HasAmmo(0)
        && EmptyPortStateLatched(Runtime.PumpPortStage, false,
            ReloadingPump() && Owner.bPartialShellClose && !Owner.bPumpFirstShell);
}

static function bool EmptyPortStateLatched(int PortStage, bool bHasAmmo, bool bPartialClose)
{
    return PortStage == 1 && !bHasAmmo && !bPartialClose;
}

static function bool Supported(KFWeapon W)
{
    return class'VRPumpCatalog'.static.PumpAction(W) || class'VRPumpCatalog'.static.CycleOnly(W);
}

function int OffHand() { return 1 - GunHand; }

function bool OwnsHand(int Hand)
{
    return Enabled() && Owner.InputOwner.ContextValid() && Gun != None
        && bEngaged && !bBySupport && Hand == OffHand();
}

// VRHandInventory asks this before revoking a support contact by distance:
// the fore-end moves under the hand during a stroke, so contact slack between
// the controller and the moving anchor is not a release.
function bool LatchesSupport(VRWeaponRuntime R, int Hand)
{
    return Enabled() && Owner.InputOwner.ContextValid() && Gun != None && R != None && R == Runtime
        && Hand == OffHand() && R.SupportHand == Hand;
}

// The fore-end grip as it moves with the stroke, or false before binding.
function bool ForeEndAnchor(out vector At)
{
    local quat Q;
    if (Runtime == None || Runtime.Presenter == None
        || !Runtime.Presenter.GetSupportGripWorld(Gun, At, Q)) return false;
    return At == At;
}

// Context/tracking loss must abandon a stroke, never finish it on recovery.
// Keep the spent chamber state: cancellation does not chamber another round.
function CancelHand(int Hand)
{
    if (Gun == None || (Hand != GunHand && Hand != OffHand())) return;
    if (Carried() && Hand != GunHand) return;
    Motion.Reset();
    bEngaged = false;
    // A tube-fed pump has no closing spring. Release or tracking loss keeps
    // the action where the player left it; only a later held stroke moves it.
    if (!class'VRPumpCatalog'.static.PumpAction(Gun))
    {
        bPulledBack = Runtime != None && Runtime.PumpPortStage > 0;
        Pull = bPulledBack ? Travel : 0.0;
    }
    bRebaseHand = Pull > 0 || bPulledBack;
    Inertia.Reset(Pull);
    bTriggerWasDown = true;
    bGripWasDown = true;
}

// The reload owner needs the spent chamber independently of the moving
// action's fire gate, including an empty gun that is allowed to auto-reload.
function bool RequiresPump(KFWeapon W)
{
    return Enabled() && W != None && W == Gun && bNeedsPump;
}

// The trigger press is withheld until the pump has been worked and returned
// to its forward stop. An empty gun still reaches stock dry fire/auto-reload.
function bool BlocksFire(KFWeapon W)
{
    return Enabled() && W != None && W == Gun && W.HasAmmo(0)
        && (bNeedsPump || Pull > Travel * 0.1);
}

// Called by the reload owner after a completed physical rack. Keep the exact
// actor's state correct even if its presentation was rebound in the meantime.
// A deliberately interrupted empty reload still owes its physical closing stroke.
function ReloadOpened(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (!Supported(W) || Owner == None || Owner.InputOwner == None
        || Owner.InputOwner.Inventory == None || Owner.InputOwner.Inventory.Registry == None) return;
    R = Owner.InputOwner.Inventory.Registry.FindItem(W);
    if (R != None) R.bManualPumpPending = true;
    if (Gun != W) return;
    bNeedsPump = true;
    Motion.Reset();
    bEngaged = false;
    if (!class'VRPumpCatalog'.static.PumpAction(Gun)) { bPulledBack = false; Pull = 0; }
    bRebaseHand = Pull > 0 || bPulledBack;
    Inertia.Reset(Pull);
}
function ReloadCompleted(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || Owner == None || Owner.InputOwner == None
        || Owner.InputOwner.Inventory == None || Owner.InputOwner.Inventory.Registry == None) return;
    R = Owner.InputOwner.Inventory.Registry.FindItem(W);
    if (R != None) { R.bManualPumpPending = false; R.PumpPortStage = 0; }
    if (Gun != W) return;
    Motion.Reset();
    Inertia.Reset(0);
    bNeedsPump = false;
    bLiveEjectPending = false;
    bEngaged = false;
    bPulledBack = false;
    Pull = 0;
    LastAmmo = W.AmmoCount[0];
}

// HZ12's stock PerformReload resets its two-shot counter. Call only after
// an accepted magazine payment: canceling an insertion does not reset a pair.
// Its tactical clip never pumps; an empty reload still owes the manual rack.
function MagazineReloadPaid(KFWeapon W, bool bEmptyReload)
{
    if (!class'VRPumpCatalog'.static.CycleOnly(W)) return;
    if (bEmptyReload) ReloadOpened(W);
    else ReloadCompleted(W);
}

// Gun states in which the hand, not the stock animation, owns the pump.
function bool InHand()
{
    return (RequiresManualCycle() || class'VRWeaponRuntime'.static.StockIdle(Gun))
        && (!Gun.IsInState('Reloading') || bStockEmptyReload) && !Gun.IsInState('WeaponEquipping')
        && !Gun.IsInState('WeaponPuttingDown') && !Gun.IsInState('Inactive');
}

function vector RootPos() { return Gun.MySkelMesh.GetBoneLocation(RootBone); }
function quat RootQ() { return Gun.MySkelMesh.GetBoneQuaternion(RootBone); }

function vector LocalHandPosition()
{
    return QuatRotateVector(QuatInvert(RootQ()), Bridge.Hands[OffHand()].Position - RootPos());
}

// Along the bore (+X of the root on the shipped rigs), in world units.
function float AlongBore(vector P)
{
    return (QuatRotateVector(QuatInvert(RootQ()), P - RootPos())).X;
}

function float GunScale()
{
    local float S;
    S = Gun.MySkelMesh.Scale * Gun.MySkelMesh.Scale3D.X * Gun.DrawScale * Gun.DrawScale3D.X;
    return (S > 0.01 && S < 100) ? S : 1.0;
}

function vector PumpRest()
{
    if (Parts.Length == 0) return RootPos();
    return RootPos() + QuatRotateVector(RootQ(), Parts[0].IdleLocal * GunScale());
}

// ------------------------------------------------------------------ binding

function AddPart(SkeletalMeshComponent Ref, name Bone, bool bTravels)
{
    local HeldPart Part;
    local quat InvRoot;
    if (Gun.MySkelMesh.MatchRefBone(Bone) < 0 || Ref.MatchRefBone(Bone) < 0) return;
    InvRoot = QuatInvert(Ref.GetBoneQuaternion(RootBone));
    Part.Bone = Bone;
    Part.bTravels = bTravels;
    Part.TravelScale = Bone == 'RW_Bolt' ? class'VRPumpCatalog'.static.BoltTravelScale(Gun) : 1.0;
    Part.IdleLocal = QuatRotateVector(InvRoot, Ref.GetBoneLocation(Bone) - Ref.GetBoneLocation(RootBone));
    Part.IdleLocalQ = QuatProduct(InvRoot, Ref.GetBoneQuaternion(Bone));
    Parts.AddItem(Part);
}

function SkelControlSingleBone AppendControl(name Bone)
{
    local SkelControlSingleBone Control;
    local SkelControlBase Tail;
    local AnimTree.SkelControlListHead Link;
    local int I;
    Control = new(Tree) class'SkelControlSingleBone';
    Control.ControlName = 'VRManualPump';
    Control.bApplyTranslation = true;
    Control.bAddTranslation = false;
    Control.BoneTranslationSpace = BCS_WorldSpace;
    Control.bApplyRotation = true;
    Control.bAddRotation = false;
    Control.BoneRotationSpace = BCS_WorldSpace;
    Control.bIgnoreWhenNotRendered = false;
    Control.bControlledByAnimMetada = false;
    Control.bSetStrengthFromAnimNode = false;
    Control.bPropagateSetActive = false;
    Control.ControlStrength = 0;
    Control.StrengthTarget = 0;
    for (I = 0; I < Tree.SkelControlLists.Length; ++I)
        if (Tree.SkelControlLists[I].BoneName == Bone) break;
    if (I < Tree.SkelControlLists.Length && Tree.SkelControlLists[I].ControlHead != None)
    {
        Tail = Tree.SkelControlLists[I].ControlHead;
        while (Tail.NextControl != None) Tail = Tail.NextControl;
        Tail.NextControl = Control;
    }
    else if (I < Tree.SkelControlLists.Length) Tree.SkelControlLists[I].ControlHead = Control;
    else
    {
        Link.BoneName = Bone;
        Link.ControlHead = Control;
        Tree.SkelControlLists.AddItem(Link);
    }
    return Control;
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local SkeletalMeshComponent Ref;
    local int I;
    Runtime = R;
    Gun = R.Item;
    // Reset on every binding so an unmeasured rig cannot inherit this gun's
    // stroke; the authored fore-end travel uses the same scale as its pose.
    SelectStroke();
    EnsureSounds();
    GunHand = Hand;
    LastAmmo = Gun.AmmoCount[0];
    bNeedsPump = R.bManualPumpPending;
    bLiveEjectPending = false;
    bEngaged = false;
    bPulledBack = R.PumpPortStage > 0;
    Pull = bPulledBack ? Travel : 0.0;
    bRebaseHand = bPulledBack;
    Motion.Reset();
    // A new hand/binding starts with the observed buttons already consumed;
    // a held grab cannot become a new pinch because the presentation changed.
    bTriggerWasDown = (Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0
        || Owner.TriggerDown(OffHand());
    bGripWasDown = (Bridge.NativeGripActiveMask & (1 << OffHand())) == 0
        || Owner.GripDown(OffHand());
    bWasCarry = Carried();
    bStockEmptyReload = false;
    LastRoomSpaceEpoch = Bridge.NativeRoomSpaceEpoch;
    Inertia.Reset(Pull);
    Parts.Length = 0;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    // The idle pose the presenter already samples for the grips.
    if (R.Presenter != None) Ref = R.Presenter.GripPoseMesh;
    if (Ref == None || Ref.SkeletalMesh != Gun.MySkelMesh.SkeletalMesh || Ref.MatchRefBone(RootBone) < 0) return false;
    // The fore-end must come first: it is the part the hand holds (the
    // Beluga's charging handle stands in for RW_Pump).
    AddPart(Ref, class'VRPumpCatalog'.static.PumpBoneForClass(Gun.Class), true);
    for (I = 1; I < TravelBones.Length; ++I) AddPart(Ref, TravelBones[I], true);
    if (Parts.Length == 0 || Parts[0].Bone != class'VRPumpCatalog'.static.PumpBoneForClass(Gun.Class))
    { Parts.Length = 0; return false; }
    for (I = 0; I < StillBones.Length; ++I) AddPart(Ref, StillBones[I], false);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    // An instance-only extension must never reach the shared stock template.
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate) { Tree = None; Parts.Length = 0; return false; }
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    bSavedPooling = Tree.bEnablePooling;
    Tree.bEnablePooling = false;
    Gun.MySkelMesh.InitSkelControls();
    bHolding = false;
    `log("KF2VR_MANUAL_PUMP bound weapon=" $ Gun.Class @ "hand=" $ Hand @ "parts=" $ Parts.Length
        @ "back_sound=" $ (PumpBackSound != None) @ "forward_sound=" $ (PumpForwardSound != None));
    return true;
}

// Export stable debt without releasing a hand or resetting stroke/motion data.
// A shot may land after Update and before a drop's ordered stock marker.
function SavePersistentState()
{
    if (Runtime == None || Gun == None || Runtime.Item != Gun) return;
    // The shot callback records debt on the actor even between presentation
    // ticks. Never overwrite it with this binding's older copy during stow.
    bNeedsPump = Runtime.bManualPumpPending;
    if (bPulledBack && Runtime.MechanismPending == 0 && Gun.AmmoCount[0] > 0
        && class'VRPumpCatalog'.static.PumpAction(Gun)) Runtime.PumpPortStage = 2;
}

function Unbind()
{
    local int I, J;
    local SkelControlBase Previous, Current;
    Motion.Reset();
    Inertia.Reset(0);
    bRebaseHand = false;
    RestoreFireClip();
    SavePersistentState();
    if (Tree != None)
    {
        for (J = 0; J < Parts.Length; ++J)
        {
            if (Parts[J].Control == None) continue;
            Parts[J].Control.SetSkelControlStrength(0, 0);
            for (I = Tree.SkelControlLists.Length - 1; I >= 0; --I)
            {
                Previous = None;
                Current = Tree.SkelControlLists[I].ControlHead;
                while (Current != None && Current != Parts[J].Control)
                {
                    Previous = Current;
                    Current = Current.NextControl;
                }
                if (Current == None) continue;
                if (Previous != None) Previous.NextControl = Current.NextControl;
                else Tree.SkelControlLists[I].ControlHead = Current.NextControl;
                if (Tree.SkelControlLists[I].ControlHead == None) Tree.SkelControlLists.Remove(I, 1);
                break;
            }
            Parts[J].Control.NextControl = None;
        }
        Tree.bEnablePooling = bSavedPooling;
        if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None && Gun.MySkelMesh.Animations == Tree)
            Gun.MySkelMesh.InitSkelControls();
    }
    Parts.Length = 0;
    Tree = None;
    Gun = None;
    Runtime = None;
    bEngaged = false;
    bNeedsPump = false;
    bLiveEjectPending = false;
    bHolding = false;
    bStockEmptyReload = false;
}

function Shutdown()
{
    Unbind();
    Owner = None;
    Bridge = None;
}

// ------------------------------------------------------------------ update

// Reconcile stock payment without becoming a second ammo writer. This is
// deliberately exact-pump-only: the bolt/lever owner inherits Update too.
function ObserveStockEmptyReload()
{
    local int Paid;
    if (Owner.Enabled() || !class'VRPumpCatalog'.static.PumpAction(Gun)
        || Runtime.MechanismPending != 0 || Runtime.bPumpPortPredicted)
    { bStockEmptyReload = false; return; }
    // Also recover a late first Bind during the same stock reload. A top-up
    // cannot pass: its current count exceeds the shells paid by this reload.
    if (RequiresManualCycle() && Runtime.PumpPortStage == 0 && Gun.IsInState('Reloading')
        && Gun.InitialReloadAmount > 0 && Gun.InitialReloadAmount <= Gun.MagazineCapacity[0]
        && Gun.ReloadAmountLeft >= 0 && Gun.ReloadAmountLeft <= Gun.InitialReloadAmount)
    {
        Paid = Gun.InitialReloadAmount - Gun.ReloadAmountLeft;
        if (Paid > 0 && Gun.AmmoCount[0] == Paid) Runtime.PumpPortStage = 1;
    }
    if (RequiresManualCycle() && Gun.IsInState('Reloading') && Gun.AmmoCount[0] == 0
        && (LastAmmo == 0 || Runtime.PumpPortStage > 0))
    {
        Runtime.PumpPortStage = 1;
        bStockEmptyReload = true;
    }
    // Include a rebind after the stock timer has already paid: LastAmmo may
    // then equal the current count, but an unpaid rear latch remains explicit.
    if (Runtime.PumpPortStage == 1 && Gun.AmmoCount[0] > 0)
    {
        if (RequiresManualCycle())
        {
            Runtime.PumpPortStage = 2;
            Runtime.bManualPumpPending = true;
            bNeedsPump = true;
        }
        else
        {
            Runtime.PumpPortStage = 0;
            Runtime.bManualPumpPending = false;
            bNeedsPump = false;
            bPulledBack = false;
            bEngaged = false;
            Pull = 0;
            Motion.Reset();
            Inertia.Reset(0);
        }
    }
    if (RequiresManualCycle() && Gun.IsInState('Reloading') && Runtime.PumpPortStage > 0)
        bStockEmptyReload = true;
    else bStockEmptyReload = false;
    if (Runtime.PumpPortStage > 0)
    {
        SelectStroke();
        if (!bPulledBack)
        {
            bPulledBack = true;
            Pull = Travel;
            bRebaseHand = true;
        }
    }
}

function Update()
{
    local VRWeaponRuntime R, Found;
    local int Hand, FoundHand, Priority, BestPriority;
    if (Bridge == None) return;
    FoundHand = -1;
    if (Enabled() && Owner.InputOwner.ContextValid())
        for (Hand = 0; Hand < 2; ++Hand)
        {
            R = Owner.InputOwner.Inventory.GetHeldForHand(Hand);
            if (R != None && R.IsCurrent() && Supported(R.Item) && R.Item.MySkelMesh != None)
            {
                // Lever stock empty reloads must be observed through their
                // real open/close pose. InHand still excludes stock loading,
                // so this binding cannot run a competing manual stroke.
                if (Owner.Automatic(R) && R.AutomaticReload.Stage != 5
                    && !(class'VRPumpCatalog'.static.IsLever(R.Item) && R.AutomaticReload.Stage == 2)) continue;
                // A primary grip alone cannot work its pump while the other
                // hand carries a different gun. Prefer a usable operating
                // grip, independently of left/right iteration order.
                Priority = 1;
                if ((R.PrimaryHand < 0 && R.SupportHand == Hand && R.CarryPrimaryHand >= 0)
                    || Owner.InputOwner.Inventory.Registry.GetSupport(1-Hand) == R) Priority = 3;
                else if (Owner.bActive && Owner.Gun == R.Item && !Owner.HandBusy(1-Hand)) Priority = 2;
                // One helper presents both hands. A ready retained binding
                // must yield to the other gun's spent cycle, while an engaged
                // physical stroke keeps its exact partial motion until release.
                // An empty lever locked open owes nothing until it is
                // loaded; the other hand's owed cycle takes the binding.
                if (R.bManualPumpPending)
                    Priority += (class'VRPumpCatalog'.static.IsLever(R.Item) && R.bLeverCycleOpen
                        && !R.Item.HasAmmo(0)) ? 2 : 4;
                if (R == Runtime && bEngaged) Priority += 8;
                // Equal candidates retain the current binding and partial stroke.
                if (Priority > BestPriority || (Priority == BestPriority && R == Runtime))
                { Found = R; FoundHand = Hand; BestPriority = Priority; }
            }
        }
    if (Found == None) { if (Gun != None) Unbind(); return; }
    // A new gun, the other hand, or a rebuilt AnimTree: bind afresh. Binding
    // waits (retried each frame) for the presenter's idle reference.
    if (Found.Item != Gun || Tree == None || Gun.MySkelMesh.Animations != Tree)
    {
        if (Gun != None) Unbind();
        if (!Bind(Found, FoundHand)) { Parts.Length = 0; Gun = None; Runtime = None; return; }
    }
    // A deliberate carry/regrip on this same actor keeps its physical stroke.
    // Rebase the hand only after the new root has received a placement frame.
    if (FoundHand != GunHand || bWasCarry != Carried())
    {
        GunHand = FoundHand;
        bWasCarry = Carried();
        Inertia.Reset(Pull);
        Motion.Reset();
        bRebaseHand = !bWasCarry;
        bEngaged = false;
        return;
    }
    ObserveStockEmptyReload();
    bNeedsPump = Runtime.bManualPumpPending;
    LastAmmo = Gun.AmmoCount[0];
    if ((Owner.Automatic(Runtime) && Runtime.AutomaticReload.Stage == 5)
        || (bNeedsPump && OtherHandOccupied() && !ReloadingPump() && InHand()))
    { UpdateAutomaticCycle(); return; }
    AutomaticCycleAt = 0;
    // Starting or interrupting a reload cannot clear a spent chamber. The
    // reload owner confirms its closing rack through ReloadCompleted.
    // One motion owner for every tube-pump stroke. While shell loading owns
    // the hand the action stays put; a required rack uses the retained stroke.
    // The reload session alone pays shells and confirms its closing rack.
    if (ReloadingPump())
    {
        if (!LoadingPort() && !Owner.bAwaitRack) CancelHand(GunHand);
        else if (Carried()) UpdateCarry();
        else UpdateHand();
        if (ReloadingPump()) Owner.RackPull = Pull;
        return;
    }
    if (Gun.IsInState('Reloading') || (Owner.bActive && Owner.Gun == Gun))
    {
        Motion.Reset();
        bEngaged = false;
        bPulledBack = Runtime.PumpPortStage > 0;
        Pull = bPulledBack ? Travel : 0.0;
        Inertia.Reset(Pull);
        return;
    }
    if (!InHand()) { CancelHand(GunHand); return; }
    if (Carried()) UpdateCarry();
    else UpdateHand();
}

function UpdateCarry()
{
    local quat RoomQ;
    local vector Position, Bore;
    local float PreviousPull;
    local int Mask;
    Mask = 1 << GunHand;
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bridge.NativeRoomMotionMask & Mask) != Mask
        || Runtime.Presenter == None || !Runtime.Presenter.bForegripCarryPose
        || Owner.InputOwner.IsSelectorOpen(GunHand)
        || (Bridge.bHoldSupportGrip && (Bridge.NativeGripMask & Mask) == 0))
    { CancelHand(GunHand); return; }
    if (!CanStartStroke()) { Inertia.Reset(0); Pull = 0; return; }
    if (!bEngaged) SelectStroke();
    if (EmptyPortLatched()) { Pull = Travel; Inertia.Reset(Pull); return; }
    if (LastRoomSpaceEpoch != Bridge.NativeRoomSpaceEpoch)
    { LastRoomSpaceEpoch = Bridge.NativeRoomSpaceEpoch; CancelHand(GunHand); return; }
    Position = GunHand == 0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
    RoomQ = QuatFromRotator(GunHand == 0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation);
    Bore = QuatRotateVector(QuatProduct(RoomQ, Runtime.Presenter.CarryRootRotation), vect(1,0,0));
    PreviousPull = Pull;
    Pull = Inertia.Step(Position, RoomQ, Bore, Owner.Now(), Bridge.NativeCalibrationEpoch,
        Travel, Bridge.WorldInfo.GetGravityZ());
    if (!Inertia.bContinuous)
    {
        // A rejected tracking sample cannot move the action or award a stop.
        if (Inertia.bInvalidated) { Pull = PreviousPull; Inertia.Reset(Pull); }
        return;
    }
    bEngaged = true;
    if (Pull <= Travel * ForwardLock) bOpenCued = false;
    if (!bPulledBack && Pull >= Travel * RearStop) RearReached(GunHand);
    if (bPulledBack && Pull <= Travel * ForwardLock) Pumped();
}

// An occupied opposite hand cannot operate a two-handed action. Preserve the
// stock cadence and debt, but perform its existing cycle without a reload press.
// Whether this owed stroke may run by itself. A carried gun, a live-round
// eject or an open port keep their manual owner; otherwise the shared
// reload-or-cycle rule (VRInteractiveReload.AutoActionAllowed) decides.
function bool OtherHandOccupied()
{
    if (Carried() || Runtime == None || Owner.InputOwner.Inventory == None
        || bLiveEjectPending || Runtime.CycleEjectOpen != 0 || Runtime.PumpPortStage != 0) return false;
    return Owner.AutoActionAllowed(Runtime, true);
}

function RearReached(int Hand)
{
    // A refused live-round debit is not a rear stop: the action stays
    // unlatched and the next frame at the rear asks again.
    if (!EjectAtRear(Hand)) return;
    bPulledBack = true;
    if (!bOpenCued) PlayPumpSound(PumpBackSound);
    if (CanOpenEmptyPort())
    {
        Runtime.PumpPortStage = 1;
        Pull = Travel;
        if (LoadingPort()) Owner.bAwaitRack = false;
    }
    if (!bOpenCued)
    {
        class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.PumpRear, Carried() ? (1 << Hand) : 3);
    }
    bOpenCued = true;
}

// Spent debt was already charged by firing. Ready cycles eject one live
// round through the ordered authority action; they never debit reserve.
// False: that debit was refused, so the stroke has not opened the action.
function bool PortShellOwnsRear()
{
    return Runtime != None && Runtime.PumpPortStage > 0;
}

// 0: no case, 1: spent case already paid by a shot, 2: live-round cycle.
static function byte RearEjectionKind(bool bPortShell, bool bSpentDebt, int Ammo)
{
    if (bPortShell) return 0;
    if (bSpentDebt) return 1;
    return Ammo > 0 ? 2 : 0;
}

function bool EjectAtRear(int Hand)
{
    local int Count, Before;
    local byte EjectionKind;
    // The port shell is already in the open action. Its closing stroke has
    // no spent case to eject, even though it carries the manual-cycle debt.
    if (PortShellOwnsRear()) return true;
    EjectionKind = RearEjectionKind(false, bNeedsPump, Gun.AmmoCount[0]);
    if (EjectionKind == 1) Gun.ANIMNOTIFY_ShellEject();
    else if (EjectionKind == 2)
    {
        Before = Gun.AmmoCount[0];
        Count = Min(Before, class'VRWeaponActionBarrier'.static.LiveRoundCount(Gun));
        if (Owner.CycleLosesRounds())
        {
            // Only a ready (Active) gun has a live chambered round to rack
            // out; reload-owned strokes keep their stock closing flow.
            if (Bridge.BeginCycleEject(Runtime, GunHand, Count))
            {
                bLiveEjectPending = true;
                Runtime.CycleEjectOpen = 1;
                if (class'VRPumpCatalog'.static.PumpAction(Gun) && Before <= Count)
                {
                    Runtime.PumpPortStage = 1;
                    Runtime.bPumpPortPredicted = Gun.Role < ROLE_Authority;
                }
            }
            else if (class'VRWeaponRuntime'.static.StockIdle(Gun)) return false;
        }
        else if (Owner.LiveRounds != None) Owner.LiveRounds.EmitWeapon(Bridge, Gun, Count);
        bNeedsPump = true;
        Runtime.bManualPumpPending = true;
        LastAmmo = Gun.AmmoCount[0];
    }
    return true;
}

// The authority refused (or lost) a live-round debit this stroke's open
// already showed. The round never left, so undo the open: no spent chamber
// is owed and the stroke cannot complete until a fresh rear crossing is
// accepted. The bridge has already restored the authoritative count. A
// binding made while the receipt was outstanding inherited the open through
// the runtime's spent-chamber debt, so it is undone here as well.
function CycleEjectRefused(VRWeaponRuntime R)
{
    if (R == None || Gun == None || R != Runtime || R.Item != Gun
        || (!bLiveEjectPending && R.CycleEjectOpen != 1)) return;
    bLiveEjectPending = false;
    bNeedsPump = false;
    Runtime.bManualPumpPending = false;
    bPulledBack = false;
    LastAmmo = Gun.AmmoCount[0];
}

function UpdateHand()
{
    local int Hand;
    local bool bTrigger, bTriggerActive, bGrip, bSupport, bHeld;
    local vector P;
    local float X;
    Hand = OffHand();
    bSupport = Owner.InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime;
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || Owner.InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand)
        || (Owner.InputOwner.Inventory.Registry.GetSupport(Hand) != None && !bSupport))
    {
        CancelHand(Hand);
        return;
    }
    P = Bridge.Hands[Hand].Position;
    bTriggerActive = (Bridge.NativeTriggerActiveMask & (1 << Hand)) != 0;
    if (bEngaged && !bBySupport && !bByGrip && !bTriggerActive)
    {
        CancelHand(Hand);
        return;
    }
    bTrigger = Owner.TriggerDown(Hand);
    bTriggerWasDown = bTriggerActive ? bTrigger : true;
    bGrip = Owner.GripDown(Hand);
    bGripWasDown = bGrip;
    X = AlongBore(P);

    if (bRebaseHand)
    {
        bRebaseHand = false;
        if (!CanStartStroke() || !bSupport) { CancelHand(GunHand); return; }
        bBySupport = true; bByGrip = false; bEngaged = true;
        StartX = X + Pull * ThrowScale;
        Motion.Begin(LocalHandPosition(), Owner.Now());
        return;
    }

    if (!bEngaged)
    {
        SelectStroke();
        // Locked forward until a shot owes a stroke. Only the support hand,
        // drawn gripping the fore-end, works it: a grip near the fore-end
        // becomes that support grip through the ordinary inventory first.
        if (!CanStartStroke() || !bSupport || Runtime.MechanismPending != 0) return;
        bBySupport = true;
        bByGrip = false;
        bEngaged = true;
        // Regripping starts at the retained physical position, never at the
        // forward stop. The completed rear stroke also survives a release.
        StartX = X + Pull * ThrowScale;
        Motion.Begin(LocalHandPosition(), Owner.Now());
        return;
    }
    // A rejected sample abandons the stroke while retaining the spent chamber.
    // Rebasing at that position could turn a rejected jump to the forward stop
    // into a completed pump on the next stationary frame.
    if (!Motion.Check(LocalHandPosition(), Owner.Now()))
    {
        CancelHand(Hand);
        return;
    }
    bHeld = bBySupport ? bSupport : (bByGrip ? bGrip : bTrigger);
    if (!bHeld)
    {
        // The action stays where released; regripping rebases from this pull.
        bEngaged = false;
        Motion.Reset();
        return;
    }
    if (EmptyPortLatched()) { Pull = Travel; return; }
    // Drift forward re-anchors, so only travel back from the forward stop counts.
    if (X > StartX) StartX = X;
    Pull = FClamp((StartX - X) / ThrowScale, 0, Travel);
    if (Pull <= Travel * ForwardLock) bOpenCued = false;
    if (!bPulledBack && Pull >= Travel * RearStop)
    {
        RearReached(Hand);
    }
    // Keep the fore-end on the tracked pull after the rear latch, too.
    // Adding the remaining travel here made a small movement snap it backward.
    if (bPulledBack && (StartX - X) / ThrowScale <= Travel * ForwardLock) Pumped();
}

// The reload button can settle a spent pump on a full gun. Reuse the rear
// stop and forward-lock writers; a ready gun never reaches this path.
function UpdateAutomaticCycle()
{
    local float Duration;
    if (!bNeedsPump || Runtime == None || Runtime.MechanismPending != 0) return;
    bEngaged = false; Motion.Reset();
    if (AutomaticCycleAt == 0) { AutomaticCycleAt = Owner.Now(); AutomaticCycleFrom = Pull; }
    Duration = FMax(Gun.MySkelMesh.GetAnimLength('Shoot') * 0.5, 0.08);
    if (!bPulledBack)
    {
        Pull = FMin(Travel, AutomaticCycleFrom + Travel * (Owner.Now() - AutomaticCycleAt) / Duration);
        if (Pull >= Travel)
        {
            RearReached(GunHand);
            if (bPulledBack) { AutomaticCycleAt = Owner.Now(); AutomaticCycleFrom = Travel; }
        }
    }
    else
    {
        Pull = FMax(0, AutomaticCycleFrom - Travel * (Owner.Now() - AutomaticCycleAt) / Duration);
        if (Pull <= 0) { AutomaticCycleAt = 0; Pumped(); }
    }
}

// A completed stroke chambers the round and locks the fore-end forward again.
function bool ForwardBlocked()
{
    return EmptyPortLatched() || (Runtime != None && Runtime.MechanismPending != 0);
}

function Pumped()
{
    if (ForwardBlocked()) return;
    if (ReloadingPump()) { Owner.Rack(); return; }
    if (Runtime != None) Runtime.PumpPortStage = 0;
    SelectStroke();
    bPulledBack = false;
    bEngaged = false;
    Pull = 0;
    Motion.Reset();
    Inertia.Reset(0);
    PlayPumpSound(PumpForwardSound);
    bNeedsPump = false;
    bLiveEjectPending = false;
    if (Runtime != None) Runtime.bManualPumpPending = false;
    Gun.ANIMNOTIFY_EnableAdditiveBob();
    // The forward lock is the strongest cue of the action: both hands, full.
    class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.PumpForward, Carried() ? (1 << GunHand) : 3);
}

// After placement (VRInteractiveReload.PlaceVisuals): hold every part at its
// idle place on the root, the travelling ones pulled back by the hand.
function PlaceVisuals()
{
    local int I;
    local vector Base, Back;
    local quat Q;
    local bool bHold, bPort;
    if (Gun == None || Tree == None || Gun.bDeleteMe || Gun.MySkelMesh == None) return;
    bPort = ReloadingPump();
    bHold = Enabled() && (bPort || RequiresManualCycle() || bEngaged || CanStartStroke()) && Owner.InputOwner.ContextValid()
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (Carried() ? (1 << GunHand) : 3))
            == (Carried() ? (1 << GunHand) : 3) && (InHand() || bPort);
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
    Base = RootPos();
    Q = RootQ();
    Back = -QuatRotateVector(Q, vect(1,0,0)) * Pull;
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control.BoneTranslation = Base + QuatRotateVector(Q, Parts[I].IdleLocal * GunScale())
            + (Parts[I].bTravels ? Back * Parts[I].TravelScale : vect(0,0,0));
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(Q, Parts[I].IdleLocalQ));
        if (!bHolding) Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    bHolding = true;
    // A world-space target is baked into component space when the skeleton is
    // evaluated; re-evaluate against this frame's placement, then carry the
    // support hand attached to the fore-end along.
    Gun.MySkelMesh.ForceSkelUpdate();
    Gun.MySkelMesh.ForceUpdate(true);
}

defaultproperties
{
    Travel=7
    Radius=12
    ThrowScale=1.0
    RearStop=0.90
    ForwardLock=0.10
    TravelBones(0)=RW_Pump
    TravelBones(1)=RW_Bolt
    TravelBones(2)=RW_Bolt_Slide
    StillBones(0)=RW_Bolt_Elevator
}
