// Manual pump action (VR CONTROLS > INTERACTIVE RELOADS: ON + MANUAL PUMP).
// After every shot the pump shotgun will not fire again until the off hand
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

var KFWeapon Gun;
var VRWeaponRuntime Runtime;
var int GunHand, LastAmmo;
var name RootBone;
var bool bNeedsPump, bEngaged, bBySupport, bByGrip, bPulledBack, bTriggerWasDown, bGripWasDown, bHolding;
var float Pull, StartX;

// Held parts: the idle pose relative to the root, and whether each travels
// back with the pump (the fore-end, bolt and action bar) or just stays put.
struct HeldPart
{
    var name Bone;
    var bool bTravels;
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
    if (W == None || W != Gun) return;
    RestoreFireClip();
    EnsureSounds();
    if (!Enabled() || Left(string(Sequence), 5) != "Shoot" || PumpBackSound == None || PumpForwardSound == None) return;
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
    return Bridge != None && Owner != None && Owner.Enabled() && Bridge.bManualPump;
}

static function bool Supported(KFWeapon W)
{
    return class'VRPumpCatalog'.static.PumpAction(W);
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
    Motion.Reset();
    bEngaged = false;
    bPulledBack = false;
    Pull = 0;
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
    return Enabled() && W != None && W == Gun && W.AmmoCount[0] > 0
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
    bPulledBack = false;
    Pull = 0;
}
function ReloadCompleted(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || Owner == None || Owner.InputOwner == None
        || Owner.InputOwner.Inventory == None || Owner.InputOwner.Inventory.Registry == None) return;
    R = Owner.InputOwner.Inventory.Registry.FindItem(W);
    if (R != None) R.bManualPumpPending = false;
    if (Gun != W) return;
    Motion.Reset();
    bNeedsPump = false;
    bEngaged = false;
    bPulledBack = false;
    Pull = 0;
    LastAmmo = W.AmmoCount[0];
}

// Gun states in which the hand, not the stock animation, owns the pump.
function bool InHand()
{
    return !Gun.IsInState('Reloading') && !Gun.IsInState('WeaponEquipping')
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
    local float AuthoredStroke;
    Runtime = R;
    Gun = R.Item;
    // Reset on every binding so an unmeasured rig cannot inherit this gun's
    // stroke; the authored fore-end travel uses the same scale as its pose.
    Travel = default.Travel;
    AuthoredStroke = class'VRPumpCatalog'.static.PumpStroke(Gun, false);
    if (AuthoredStroke > 0) Travel = AuthoredStroke * GunScale();
    EnsureSounds();
    GunHand = Hand;
    LastAmmo = Gun.AmmoCount[0];
    bNeedsPump = R.bManualPumpPending;
    bEngaged = false;
    bPulledBack = false;
    Motion.Reset();
    // A new hand/binding starts with the observed buttons already consumed;
    // a held grab cannot become a new pinch because the presentation changed.
    bTriggerWasDown = (Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0
        || Owner.TriggerDown(OffHand());
    bGripWasDown = (Bridge.NativeGripActiveMask & (1 << OffHand())) == 0
        || Owner.GripDown(OffHand());
    Pull = 0;
    Parts.Length = 0;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    // The idle pose the presenter already samples for the grips.
    if (R.Presenter != None) Ref = R.Presenter.GripPoseMesh;
    if (Ref == None || Ref.SkeletalMesh != Gun.MySkelMesh.SkeletalMesh || Ref.MatchRefBone(RootBone) < 0) return false;
    for (I = 0; I < TravelBones.Length; ++I) AddPart(Ref, TravelBones[I], true);
    // The fore-end must come first: it is the part the hand holds.
    if (Parts.Length == 0 || Parts[0].Bone != TravelBones[0]) { Parts.Length = 0; return false; }
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

function Unbind()
{
    local int I, J;
    local SkelControlBase Previous, Current;
    Motion.Reset();
    RestoreFireClip();
    // A shot may land after our last update and before an inventory change.
    // Save that spent chamber before discarding this presentation binding.
    if (Runtime != None && Gun != None && Runtime.Item == Gun)
    {
        if (!Gun.bDeleteMe && Gun.AmmoCount[0] < LastAmmo) bNeedsPump = true;
        Runtime.bManualPumpPending = bNeedsPump;
    }
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
    bHolding = false;
}

function Shutdown()
{
    Unbind();
    Owner = None;
    Bridge = None;
}

// ------------------------------------------------------------------ update

function Update()
{
    local VRWeaponRuntime R, Found;
    local int Hand, FoundHand;
    if (Bridge == None) return;
    FoundHand = -1;
    if (Enabled() && Owner.InputOwner.ContextValid())
        for (Hand = 0; Hand < 2; ++Hand)
        {
            R = Owner.InputOwner.Inventory.Registry.GetPrimary(Hand);
            if (R != None && R.IsCurrent() && Supported(R.Item) && R.Item.MySkelMesh != None)
            {
                Found = R;
                FoundHand = Hand;
                break;
            }
        }
    if (Found == None) { if (Gun != None) Unbind(); return; }
    // A new gun, the other hand, or a rebuilt AnimTree: bind afresh. Binding
    // waits (retried each frame) for the presenter's idle reference.
    if (Found.Item != Gun || FoundHand != GunHand || Tree == None || Gun.MySkelMesh.Animations != Tree)
    {
        if (Gun != None) Unbind();
        if (!Bind(Found, FoundHand)) { Parts.Length = 0; Gun = None; Runtime = None; return; }
    }
    if (Gun.AmmoCount[0] < LastAmmo)
    {
        bNeedsPump = true;
        Runtime.bManualPumpPending = true;
        bPulledBack = false;
    }
    LastAmmo = Gun.AmmoCount[0];
    // Starting or interrupting a reload cannot clear a spent chamber. The
    // reload owner confirms its closing rack through ReloadCompleted.
    if (Gun.IsInState('Reloading'))
    {
        Motion.Reset();
        bEngaged = false;
        bPulledBack = false;
        Pull = 0;
        return;
    }
    if (!InHand()) { Motion.Reset(); bEngaged = false; Pull = 0; return; }
    UpdateHand();
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

    if (!bEngaged)
    {
        // Locked forward until a shot owes a stroke. Only the support hand,
        // drawn gripping the fore-end, works it: a grip near the fore-end
        // becomes that support grip through the ordinary inventory first.
        if (!bNeedsPump || !bSupport) return;
        bBySupport = true;
        bByGrip = false;
        bEngaged = true;
        StartX = X;
        Pull = 0;
        bPulledBack = false;
        Motion.Begin(LocalHandPosition(), Owner.Now());
        return;
    }
    // A discontinuous sample is skipped, not treated as letting go: the grip
    // button and tracking validity decide release, never a noisy frame.
    if (!Motion.Check(LocalHandPosition(), Owner.Now()))
    {
        Motion.Begin(LocalHandPosition(), Owner.Now());
        return;
    }
    bHeld = bBySupport ? bSupport : (bByGrip ? bGrip : bTrigger);
    if (!bHeld)
    {
        // A pump needs a forward stroke; releasing it does not chamber a round.
        bPulledBack = false;
        bEngaged = false;
        Pull = 0;
        Motion.Reset();
        return;
    }
    // Drift forward re-anchors, so only travel back from the forward stop counts.
    if (X > StartX) StartX = X;
    Pull = FClamp((StartX - X) / ThrowScale, 0, Travel);
    if (!bPulledBack && Pull >= Travel * RearStop)
    {
        bPulledBack = true;
        PlayPumpSound(PumpBackSound);
        // The fired hull leaves at the rear stop, not at the stock clip time.
        Gun.ANIMNOTIFY_ShellEject();
        // The rear stop: a firm knock in the pumping hand, a lighter one
        // through the gun.
        Owner.Pulse(1 << Hand, 0.7, 0.045);
        Owner.Pulse(1 << GunHand, 0.3, 0.03);
    }
    // Keep the fore-end on the tracked pull after the rear latch, too.
    // Adding the remaining travel here made a small movement snap it backward.
    if (bPulledBack && (StartX - X) / ThrowScale <= Travel * ForwardLock) Pumped();
}

// A completed stroke chambers the round and locks the fore-end forward again.
function Pumped()
{
    bPulledBack = false;
    bEngaged = false;
    Pull = 0;
    Motion.Reset();
    PlayPumpSound(PumpForwardSound);
    bNeedsPump = false;
    if (Runtime != None) Runtime.bManualPumpPending = false;
    Gun.ANIMNOTIFY_EnableAdditiveBob();
    // The forward lock is the strongest cue of the action: both hands, full.
    Owner.Pulse(3, 1.0, 0.08);
}

// After placement (VRInteractiveReload.PlaceVisuals): hold every part at its
// idle place on the root, the travelling ones pulled back by the hand.
function PlaceVisuals()
{
    local int I;
    local vector Base, Back;
    local quat Q;
    local bool bHold;
    if (Gun == None || Tree == None || Gun.bDeleteMe || Gun.MySkelMesh == None) return;
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
    Base = RootPos();
    Q = RootQ();
    Back = -QuatRotateVector(Q, vect(1,0,0)) * Pull;
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control.BoneTranslation = Base + QuatRotateVector(Q, Parts[I].IdleLocal * GunScale())
            + (Parts[I].bTravels ? Back : vect(0,0,0));
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
    RearStop=0.95
    ForwardLock=0.05
    TravelBones(0)=RW_Pump
    TravelBones(1)=RW_Bolt
    TravelBones(2)=RW_Bolt_Slide
    StillBones(0)=RW_Bolt_Elevator
}
