// Physical input becomes explicit hand/item commands here. Inventory ownership
// is committed by VRHandInventory, so this layer can later submit the same
// requests to an authority without making controller side an item identity.
// X/A tap reloads; a double tap selects a physical secondary reload on supported
// guns. Hold modifies fire. Y/B selects or quick-swaps inventory,
// or toggles the head lamp when pressed beside the head.
class VRDualHandInput extends Object;

// UE3 stores bools as packed fields and rejects a direct fixed bool array.
struct VRDualHandState
{
    var bool bSelectorOpen;
    var bool bGripWasDown, bTriggerWasDown, bPhysicalTriggerWasDown;
    var bool bLowerWasDown, bUpperWasDown, bStickWasDown;
    var bool bLowerArmed, bUpperArmed, bStickArmed;
    var bool bUpperGesture, bUpperUsed, bUpperTapPending, bUpperDoubleTap, bLowerConsumed;
    var bool bParrying, bReloadPulse, bSelectorInitAttempted;
    var bool bSelectorTriggerArmed;
    var bool bSelectorConfirmPending;
    var bool bAxisArmed, bVerticalArmed, bSecondaryAction;
    // R20: this support hand fired the gun's secondary from its own trigger
    // grip; that mode stops when this trigger is released.
    var VRWeaponRuntime SupportFireRuntime;
    var int SupportFireMode;
    // A mode hold belongs to one uninterrupted physical press on this actor.
    var bool bModeTriggerReleased;
    var VRWeaponRuntime ModeHoldRuntime;
    var int ModeHoldOwnership, ModeHoldCalibration, ModeHoldRoomSpace;
    // Secondary-fed guns defer the primary tap until a second reload tap
    // can select their independent slot-one reload instead.
    var VRWeaponRuntime ReloadTapRuntime;
    var KFWeapon ReloadTapWeapon;
    var int ReloadTapOwnership, ReloadTapCalibration, ReloadTapRoomSpace;
    var float ReloadTapDeadline;
    var bool bReloadSecondPress;
    // A deliberate Deadbolt reload tap during shot recovery survives the
    // normal one-frame stock pulse, tied to this exact actor and ownership.
    var KFWeapon AuthoredReloadWeapon;
    var int AuthoredReloadOwnership;
    var float AuthoredReloadDeadline;
    var VRWeaponRuntime StockReloadRuntime;
    var KFWeapon StockReloadWeapon, StockReloadFinishedWeapon;
    var int StockReloadOwnership, StockReloadRequest, StockReloadSession, StockReloadCalibration;
    var float StockReloadDeadline;
    var bool bStockReloadStarted, bStockReloadInteractive;
};

var VRHandInventory Inventory;
var VRHandsBridge Bridge;
var VRHandSelector Selectors[2];
var VRDualHandState InputState[2];
var string SelectionMessage[2];
var KFWeapon LastWeapon[2];
var float UpperTime[2], LowerTime[2], UpperTapDeadline[2];
var float LastInputTime;
var VRWeaponRuntime CarryReleaseRuntime[2];
var float CarryReleaseDeadline[2];
var int CarryReleaseRevision[2], CarryReleaseCalibration[2], CarryReleaseRoom[2];
var int FireMode[2], PreviousToolButtons[2];
var bool bInitialized;
var bool bInteracting;
var int InteractHands;
var int InputSample;
var bool bSprintRequested;
var bool bSelectionClickWasDown, bSelectionArmed, bSelectionGesture, bSelectionUsed;
var float SelectionTime;
var VRPhysicalCrouch PhysicalCrouch;
var VRChestGrenade Grenade;
var VRTomahawks Tomahawks;
var VRTeleportLocomotion Teleport;
var VRSyringePouch Pouch;
var VRDoshWallet Wallet;
const DOSH_TOSS_SPEED = 400.0; // hand-aimed wheel toss before VRDoshThrow assistance (~800 uu/s out)
var VRDeployableHold Deployables;
var VRBrawlerBlast Brawler;
var VRDoorWelding Welding;
var VRInteractiveReload Reloads;
var VRCompoundBowInput Bow;
var VRArcFenceInput ArcFence;
var int NativeFocusRequested;
var float SprintResumeTime;
var float NextFireDiagTime[2];
// Raw turn-stick deflection that counts as the outer rim for a jump.
const JumpRimMagnitude = 0.95;
// Forty degrees to either side of up owns jump, including the approach to
// the rim. Use the same boundary for turn exclusion and jump admission.
const JumpUpSlope = 0.839100;

// A tap waits briefly before it swaps, so a second tap can deliberately open
// the hand instead of swapping once and then immediately stowing the result.
const UPPER_HOLD_SECONDS = 0.25;
const UPPER_DOUBLE_TAP_SECONDS = 0.24;
const RELOAD_DOUBLE_TAP_SECONDS = 0.25;

// Sprint is latched: a click starts it in any stick direction and it lasts
// until the movement stick returns to centre. Firing, stock reloading, drawing
// and the other actions pause it; accepted physical reloads keep locomotion.
function CancelSprint()
{
    if (Bridge != None) SprintResumeTime = Bridge.WorldInfo.RealTimeSeconds + 0.35;
    if (Bridge != None && Bridge.PC != None) Bridge.PC.bRun = 0;
    if (Inventory != None && Inventory.ContextValid()) Inventory.SetSprinting(false);
}

// Ends the request outright: context loss, teleport and calibration.
function EndSprint()
{
    bSprintRequested = false;
    CancelSprint();
}

// Anything that stops this hand being a free fist: a thrown or pocketed item.
function bool HandCarrying(int Hand)
{
    return (Grenade != None && Grenade.IsHeld(Hand)) || (Wallet != None && Wallet.IsBusy(Hand))
        || (Reloads != None && Reloads.Recovery != None && Reloads.Recovery.OwnsHand(Hand))
        || (Bow != None && Bow.OwnsHand(Hand));
}

// A hand beside the head, not in front of the face, so a pistol raised to the
// eye never counts. Y/B pressed here is the head lamp, for any weapon; an
// empty hand can also squeeze its grip here without taking another item.
function bool HandAtTemple(int Hand)
{
    local vector Offset, X, Y, Z;
    local rotator Facing;
    if ((Bridge.NativeValidMask & (1 << Hand)) == 0 || Bridge.NativeHeadTracked == 0) return false;
    Offset = Bridge.PalmPosition(Hand) - Bridge.HeadPosition;
    Facing = Bridge.PC.Rotation; Facing.Pitch = 0; Facing.Roll = 0;
    GetAxes(Facing, X, Y, Z);
    return VSize(Offset) <= 20 && (Offset dot X) < 8 && Abs(Offset dot Y) >= 5;
}

function bool QuickSwapHand(int Hand)
{
    local bool Accepted;
    local VRWeaponRuntime CurrentPrimary, OtherPrimary;
    local KFWeapon Target;
    if (Hand < 0 || Hand > 1 || !ContextValid()) return false;
    Target = Inventory.PreviousItem[Hand];
    CurrentPrimary = Inventory.Registry.GetPrimary(Hand);
    // An open hand is the fallback quick-switch target. This also covers a
    // just-redrawn weapon whose exact prior state was open: its history names
    // itself until another weapon replaces it. Keep a distinct remembered
    // weapon as the higher-priority A/B quick-swap path below.
    if (Target == None || (CurrentPrimary != None && CurrentPrimary.Item == Target))
    {
        if (CurrentPrimary == None && Inventory.Registry.GetSupport(Hand) == None
            && !Inventory.HasGauntletHand(Hand))
        {
            ModeFeedback(Hand, false);
            return false;
        }
        Accepted = Inventory.ReleaseHand(Hand);
        ModeFeedback(Hand, Accepted);
        if (Accepted) { CancelSprint(); RefreshWeapon(Hand); }
        return Accepted;
    }
    OtherPrimary = Inventory.Registry.GetPrimary(1 - Hand);
    if (OtherPrimary != None && OtherPrimary.Item == Target)
    {
        ModeFeedback(Hand, false);
        return false;
    }
    if (!Inventory.Registry.IsOwned(Target) || !Inventory.CanDraw(Target))
    {
        ModeFeedback(Hand, false);
        return false;
    }
    Accepted = Inventory.Draw(Hand, Target, false, 0, true);
    ModeFeedback(Hand, Accepted);
    if (Accepted) { CancelSprint(); RefreshWeapon(Hand); }
    return Accepted;
}

// Double tapping Y/B always reaches a free hand, even when its remembered
// item is drawable. The normal release path owns history, stow state, poses
// and charged-fist rearming, so this does not manufacture inventory state.
// A hand that is already open draws the syringe instead.
function bool OpenHand(int Hand)
{
    local bool Accepted;
    if (Hand < 0 || Hand > 1 || !ContextValid()) return false;
    if (Inventory.OpenGauntletOffhand(Hand))
    {
        ModeFeedback(Hand, true);
        return true;
    }
    if (Inventory.Registry.GetPrimary(Hand) == None && Inventory.Registry.GetSupport(Hand) == None)
        return DrawSyringe(Hand);
    Accepted = Inventory.ReleaseHand(Hand);
    ModeFeedback(Hand, Accepted);
    if (Accepted) { CancelSprint(); RefreshWeapon(Hand); }
    return Accepted;
}

// Quick heal: Y/B tap then press-and-hold draws the syringe into that hand
// from any state. The replaced item becomes the hand's previous item, so a
// single tap afterwards returns it.
function bool DrawSyringe(int Hand)
{
    local bool Accepted;
    local KFWeapon W, Syringe;
    if (Hand < 0 || Hand > 1 || !ContextValid()) return false;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (Syringe == None && W.IsA('KFWeap_Healer_Syringe') && Inventory.Registry.IsOwned(W)) Syringe = W;
    // Drawn by button, it latches like a quick swap until the next squeeze.
    Accepted = Syringe != None && Inventory.CanDraw(Syringe) && Inventory.Draw(Hand, Syringe, false, 0, true);
    ModeFeedback(Hand, Accepted);
    if (Accepted) { CancelSprint(); RefreshWeapon(Hand); }
    return Accepted;
}

// The turn-stick click opens the movement hand's latched wheel.
function OpenSelector(int Hand)
{
    if ((Bridge.NativeValidMask & (1 << Hand)) == 0 || Inventory.HasWorldGrab(Hand)
        || (Reloads != None && Reloads.OwnsHand(Hand))) return;
    InputState[Hand].bUpperTapPending = false;
    Inventory.CancelTransfer();
    StopWeapon(Hand);
    Bridge.Hands[Hand].bTriggerArmed = false;
    InputState[Hand].bSelectorOpen = true;
    InputState[Hand].bSelectorTriggerArmed = false;
    InputState[Hand].bSelectorConfirmPending = false;
    InputState[Hand].bSelectorInitAttempted = false;
    EnsureSelectors();
    if (Selectors[Hand] != None) Selectors[Hand].OpenSelection();
    Bridge.NativeSelectorCapture = Bridge.NativeSelectorCapture | (1 << Hand);
    NativeFocusRequested = 1;
    ModeFeedback(Hand, true);
}

function CloseSelector(int Hand)
{
    InputState[Hand].bSelectorOpen = false;
    InputState[Hand].bSelectorTriggerArmed = false;
    InputState[Hand].bSelectorConfirmPending = false;
    Bridge.Hands[Hand].bTriggerArmed = false;
}

// A real trigger edge reports existing fire gates, at most twice per second.
function LogBlockedTrigger(int Hand, VRWeaponRuntime R, KFWeapon W, bool bEdge)
{
    local bool bReady, bArmed, bReload, bState;
    if (!bEdge || W == None || W.bDeleteMe || W.IsA('KFWeap_MeleeBase')
        || Bridge.WorldInfo.RealTimeSeconds < NextFireDiagTime[Hand]) return;
    bReady = R != None && R.Presenter != None && R.Presenter.bCalibrated && R.Presenter.NativeWeaponReady != 0;
    bArmed = Bridge.Hands[Hand].bTriggerArmed;
    bReload = Reloads != None && Reloads.BlocksFire(W);
    bState = W.IsInState('Active') || W.IsInState('WeaponFiring') || W.IsInState('WeaponSingleFiring')
        || W.IsInState('WeaponBurstFiring') || W.IsInState('Reloading');
    if (bReady && bArmed && !bReload && bState && W.AmmoCount[0] > 0) return;
    NextFireDiagTime[Hand] = Bridge.WorldInfo.RealTimeSeconds + 0.5;
    `log("KF2VR_FIRE_BLOCKED hand=" $ Hand @ "weapon=" $ W.Class @ "state=" $ W.GetStateName()
        @ "ammo=" $ W.AmmoCount[0] @ "primary=" $ (R != None)
        @ "calibrated=" $ (R != None && R.Presenter != None && R.Presenter.bCalibrated)
        @ "ready=" $ ((R != None && R.Presenter != None) ? R.Presenter.NativeWeaponReady : -1)
        @ "armed=" $ bArmed @ "reload_blocks=" $ bReload
        @ "hip=" $ (Reloads != None && Reloads.DualCylinderOwns(W))
        @ "break=" $ (Reloads != None && Reloads.BreakAction != None && Reloads.BreakAction.Gun == W)
        @ "pump=" $ (Reloads != None && Reloads.Pump != None && Reloads.Pump.Gun == W)
        @ "reload_active=" $ (Reloads != None && Reloads.bActive && Reloads.Gun == W));
}

function bool IsSelectorOpen(int Hand)
{
    return Hand >= 0 && Hand < 2 && InputState[Hand].bSelectorOpen;
}

// A cleared native latch after tracking loss is not itself a release. The
// bounds also reject NaN, infinities and negative/unavailable analog samples.
function bool ToggleGripForHand(int Hand)
{
    if (Inventory.Registry.GetSupport(Hand) != None) return !Bridge.bHoldSupportGrip;
    return Bridge.bToggleGrip;
}

function bool GripReleased(int Hand)
{
    local float Value;
    local int Bit;
    if (Bridge == None || Hand < 0 || Hand > 1) return false;
    Bit = 1 << Hand;
    Value = Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
    return (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bit) != 0
        && (Bridge.NativeGripMask & Bit) == 0
        && Value == Value && Value >= 0 && Value <= 0.2;
}

function bool TriggerReleased(int Hand)
{
    local float Value;
    local int Bit;
    if (Bridge == None || Hand < 0 || Hand > 1) return false;
    Bit = 1 << Hand;
    Value = Hand == 0 ? Bridge.LeftTriggerValue : Bridge.RightTriggerValue;
    return (Bridge.NativeValidMask & Bridge.NativeTriggerActiveMask & Bit) != 0
        && (Bridge.NativeTriggerMask & Bit) == 0
        && Value == Value && Value >= 0 && Value <= 0.1;
}

function ClearModeHold(int Hand)
{
    InputState[Hand].ModeHoldRuntime = None;
}

function bool Initialize(VRHandInventory OwnerInventory)
{
    if (bInitialized || OwnerInventory == None || OwnerInventory.Bridge == None) return false;
    Inventory = OwnerInventory;
    Bridge = OwnerInventory.Bridge;
    FireMode[0] = -1;
    FireMode[1] = -1;
    LastInputTime = Bridge.WorldInfo.RealTimeSeconds;
    PhysicalCrouch = new(self) class'VRPhysicalCrouch';
    Bridge.CalibrationPanel = new(Bridge) class'VRCalibrationPanel';
    Bridge.CalibrationPanel.Bridge = Bridge;
    Grenade = new(self) class'VRChestGrenade';
    Grenade.Initialize(self);
    Tomahawks = new(self) class'VRTomahawks';
    Tomahawks.Initialize(self);
    Bridge.ValidateTeleportPreferences();
    Teleport = new(self) class'VRTeleportLocomotion';
    Teleport.Initialize(self);
    // The forearm syringe pouch and the hip dosh wallet are withdrawn from
    // play (post-playtest 2026-09-25): the syringe stays on the wheel and dosh
    // on the stock drop. Both classes stay in source; Pouch and Wallet remain
    // None, and every use below is guarded.
    Deployables = new(self) class'VRDeployableHold';
    Deployables.Initialize(self);
    Brawler = new(self) class'VRBrawlerBlast';
    Brawler.Initialize(self);
    Welding = new(self) class'VRDoorWelding';
    Welding.Initialize(self);
    Reloads = new(self) class'VRInteractiveReload';
    Reloads.Initialize(self);
    Bow = new(self) class'VRCompoundBowInput';
    Bow.Initialize(self);
    bInitialized = true;
    return true;
}

function bool ContextValid()
{
    return bInitialized && Inventory != None && Inventory.Registry != None
        && Bridge != None && !Bridge.bDeleteMe && Bridge.PC != None && Bridge.Human != None
        && Bridge.PC.Pawn == Bridge.Human && Bridge.Human.Health > 0
        && Bridge.NativeConnection > 0 && Bridge.NativeMenuActive == 0
        && Bridge.IsLocalVRContext()
        && Bridge.PC.UsingFirstPersonCamera()
        && (Bridge.PC.MyGFxManager == None
            || (!Bridge.PC.MyGFxManager.bMenusActive && !Bridge.PC.MyGFxManager.bMenusOpen
                && Bridge.PC.MyGFxManager.CurrentPopup == None));
}

// R20: a gun with a second trigger grip (the FAMAS shotgun grip, not its pump
// fore-end) fires its secondary from the support hand's own trigger, through
// the same gates as the lower-button secondary route. Returns true while this
// hand is supporting such a gun, which owns the hand's trigger.
// The gun whose shotgun trigger grip this hand holds: as the support of a
// rifle-grip primary, or (R20, Kvasir94 10-29) as the aiming primary itself when
// no hand is on the rifle grip.
function VRWeaponRuntime ShotgunGripRuntime(int Hand)
{
    local VRWeaponRuntime R;
    local name GripBone, GripClip;
    local float GripTime;
    R = Inventory.Registry.GetSupport(Hand);
    if (R == None || R.PrimaryHand < 0 || R.PrimaryHand == Hand || R.Presenter == None
        || R.Presenter.PumpSupportHeld())
    {
        R = Inventory.Registry.GetPrimary(Hand);
        if (R == None || R.Presenter == None || !R.Presenter.ShotgunGripHeld()) return None;
    }
    if (!R.IsCurrent() || R.Item == None || R.AlternateKind() < 2
        || !class'VRSecondaryReloadCatalog'.static.PumpGrip(R.Item.Class, GripBone, GripClip, GripTime))
        return None;
    return R;
}

function bool SupportTriggerFire(int Hand, bool Trigger, bool TriggerEdge)
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    local int Mode;
    if (InputState[Hand].SupportFireRuntime != None && (!Trigger
        || InputState[Hand].SupportFireRuntime != ShotgunGripRuntime(Hand)))
    {
        if (InputState[Hand].SupportFireRuntime.Item != None)
            InputState[Hand].SupportFireRuntime.Item.StopFire(byte(InputState[Hand].SupportFireMode));
        InputState[Hand].SupportFireRuntime = None;
    }
    R = ShotgunGripRuntime(Hand);
    if (R == None) return false;
    if (!Trigger) Bridge.Hands[Hand].bTriggerArmed = true;
    if (!TriggerEdge || !Bridge.Hands[Hand].bTriggerArmed
        || (!Bridge.Hands[Hand].bGrip && R.PrimaryHand != Hand)
        || InputState[Hand].SupportFireRuntime != None) return true;
    Bridge.Hands[Hand].bTriggerArmed = false;
    W = R.Item;
    Mode = R.SecondaryFireMode();
    CancelSprint();
    if (Reloads != None && Reloads.BlocksFire(W, true)) { Reloads.Pulse(1 << Hand, 0.08, 0.01); return true; }
    if (Reloads != None && Reloads.AutomaticButtonRequired(W) && Reloads.DryFireInstead(W, Mode)) return true;
    if (VRTrackedWeapon(W) != None) return true;
    R.StartAction(byte(Mode));
    InputState[Hand].SupportFireRuntime = R;
    InputState[Hand].SupportFireMode = Mode;
    return true;
}

function StopWeapon(int Hand)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    ClearModeHold(Hand);
    InputState[Hand].bModeTriggerReleased = false;
    if (Bow != None) Bow.CancelHand(Hand);
    ClearReloadTap(Hand);
    ClearStockPairedReload(Hand, true);
    InputState[Hand].AuthoredReloadWeapon = None;
    InputState[Hand].AuthoredReloadDeadline = 0;
    W = LastWeapon[Hand];
    if (W != None && !W.bDeleteMe && Inventory != None && Inventory.Registry != None
        && Inventory.Registry.IsOwned(W))
    {
        R = Inventory.Registry.FindItem(W);
        if (R != None) Inventory.StopItem(R, R.CarryPrimaryHand >= 0 && R.PrimaryHand < 0);
        else
        {
            if (VRTrackedWeapon(W) != None) VRTrackedWeapon(W).CancelTrackedInput();
            W.StopFire(0);
            W.StopFire(1);
            W.StopFire(2);
            W.StopFire(class'KFWeapon'.const.BASH_FIREMODE);
            if (W.IsA('KFWeap_MeleeBase')) W.StopFire(5);
        }
    }
    if (Deployables != None) Deployables.Cancel(Hand, true);
    FireMode[Hand] = -1;
    InputState[Hand].bSecondaryAction = false;
    InputState[Hand].bTriggerWasDown = false;
    InputState[Hand].bParrying = false;
    InputState[Hand].bReloadPulse = false;
    PreviousToolButtons[Hand] = 0;
    if (Bridge != None) Bridge.Hands[Hand].bTrigger = false;
}

// An enabled body rig and the chest grenade both hang off the torso, and both
// sets of offsets are configurable, so their zones can overlap: the default
// front slot sits about nine units from the default grenade anchor. Give a
// fresh grip to whichever anchor is nearer instead of fixing an order, which
// would let a re-tuned rig silently shadow the grenade or the reverse. A
// grenade zone that cannot currently retrieve never wins. Returns true when
// the body rig consumed the grip; VRBodySlots.Grip consumes its own refusals.
// A hand reaching into the syringe pouch, dosh pocket, chest grenade or a body
// slot means that item, even with a Zed clinching the player: a Clot's body
// sits inside the grab radius exactly when the syringe matters most. Geometry
// only, so an empty pouch still answers with its own refusal instead of
// falling through to a grab the player did not reach for.
function bool InBodyZone(int Hand)
{
    local vector P;
    P = Bridge.PalmPosition(Hand);
    if (Pouch != None && Pouch.Eligible(Hand)
        && VSize(P - Pouch.PouchPosition()) <= Pouch.GrabRadius()) return true;
    if (Wallet != None && VSize(P - Wallet.PocketPosition(Hand)) <= Wallet.PocketRadius) return true;
    if (Grenade != None && Grenade.InGrabZone(Hand)) return true;
    return Inventory.BodySlots != None && Inventory.BodySlots.Hover[Hand] >= 0;
}

// AS2's grab choice: where the controller points outweighs how far the
// target is (weights 0.5 and 0.35 for items in reach), unless the hand is
// already on top of a candidate (AS2's 0.1-0.2 m; 7.5 UU here), when
// distance alone decides. Scores are comparable only between candidates
// that are each within their own reach.
function float GrabScore(int Hand, vector Target, float Reach)
{
    local vector Offset;
    local float Distance, Facing;
    Offset = Target - Bridge.PalmPosition(Hand);
    Distance = VSize(Offset);
    if (Distance <= 0.01) return 1.0;
    Facing = (Normal(Offset) dot vector(Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation) + 1) * 0.5;
    return 0.5 * Facing + 0.35 * FClamp(1 - Distance / FMax(Reach, 1), 0, 1);
}

// True when the hand should take A rather than B.
function bool PrefersTarget(int Hand, vector A, float ReachA, vector B, float ReachB)
{
    local float DA, DB;
    DA = VSize(Bridge.PalmPosition(Hand) - A);
    DB = VSize(Bridge.PalmPosition(Hand) - B);
    if (DA <= 7.5 || DB <= 7.5) return DA <= DB;
    return GrabScore(Hand, A, ReachA) >= GrabScore(Hand, B, ReachB);
}

// The support-side sidearm holster shares its hip with the dosh pocket and
// the ammo pouch. The hovered holster takes the squeeze when the AS2-style
// choice above prefers it over the other target.
function bool BodySlotNearer(int Hand, vector Other, optional float OtherReach)
{
    local VRBodySlots Slots;
    Slots = Inventory != None ? Inventory.BodySlots : None;
    if (Slots == None || Hand < 0 || Hand > 1 || Slots.Hover[Hand] < 0) return false;
    if (OtherReach <= 0) OtherReach = Slots.SlotRadius;
    return PrefersTarget(Hand, Slots.Positions[Slots.Hover[Hand]], Slots.SlotRadius, Other, OtherReach);
}

// Reload reach may overlap a configured body contact. Compare only contacts
// that the hand actually reaches, using the same AS2 choice as body holsters.
function bool BodyContactPreferred(int Hand, vector Other, float OtherReach)
{
    local vector P;
    P = Bridge.PalmPosition(Hand);
    if (BodySlotNearer(Hand, Other, OtherReach)) return true;
    if (Pouch != None && Pouch.Eligible(Hand)
        && VSize(P - Pouch.PouchPosition()) <= Pouch.GrabRadius()
        && PrefersTarget(Hand, Pouch.PouchPosition(), Pouch.GrabRadius(), Other, OtherReach)) return true;
    if (Wallet != None && VSize(P - Wallet.PocketPosition(Hand)) <= Wallet.PocketRadius
        && PrefersTarget(Hand, Wallet.PocketPosition(Hand), Wallet.PocketRadius, Other, OtherReach)) return true;
    return Grenade != None && Grenade.Retrievable(Hand) && Grenade.InGrabZone(Hand)
        && PrefersTarget(Hand, Grenade.SlotGrabPosition(), Grenade.ChestGrabRadius(), Other, OtherReach);
}

// The ammo pouch sits at the hip, where a gun held low brings its fore-end.
// A free hand nearer the held gun's support grip than the pouch regrips the
// gun instead of taking ammo (#123). Every pouch grab arbitrates through here.
function bool PouchContactPreferred(int Hand, vector PouchAt, float Reach)
{
    local VRWeaponRuntime R;
    local vector Zone;
    local quat ZoneRotation;
    if (BodyContactPreferred(Hand, PouchAt, Reach)) return true;
    if (Inventory == None || Inventory.Registry == None || Hand < 0 || Hand > 1
        || Inventory.Registry.GetSupport(Hand) != None) return false;
    R = Inventory.Registry.GetPrimary(1 - Hand);
    return R != None && R.IsCurrent() && R.Presenter != None && Inventory.SupportGrabContact(R, Hand)
        && R.Presenter.GetSupportGripWorld(R.Item, Zone, ZoneRotation)
        && PrefersTarget(Hand, Zone, 18, PouchAt, Reach);
}

function bool TryBodyAnchor(int Hand)
{
    local VRBodySlots Slots;
    local int Slot;
    Slots = Inventory != None ? Inventory.BodySlots : None;
    if (Slots == None || Hand < 0 || Hand > 1) return false;
    Slot = Slots.Hover[Hand];
    if (Slot < 0 || Slot >= 5) return false;
    if (Grenade != None && Grenade.Retrievable(Hand)
        && PrefersTarget(Hand, Grenade.SlotGrabPosition(), Grenade.ChestGrabRadius(),
            Slots.Positions[Slot], Slots.SlotRadius)) return false;
    return Slots.Grip(Hand);
}

function CancelHand(int Hand)
{
    local int I;
    local VRWeaponRuntime R;
    if (Brawler != None) Brawler.Cancel(Hand);
    if (Inventory != None && Inventory.Registry != None)
        for (I = 0; I < Inventory.Registry.Items.Length; ++I)
        {
            R = Inventory.Registry.Items[I];
            if (R == None) continue;
            R.bCarrySawRelease = false; R.bCarryReleaseArmed = false; R.bCarrySupportReleaseArmed = false;
        }
    // Lost tracking or context cancels a world hold; the next grab needs a
    // real released sample before its edge can arm again.
    if (Inventory != None) Inventory.ReleaseWorldGrab(Hand, true);
    if (Grenade != None) Grenade.CancelHand(Hand);
    if (Tomahawks != None) Tomahawks.CancelHand(Hand);
    if (Wallet != None) Wallet.CancelHand(Hand);
    if (Pouch != None) Pouch.Forget(Hand);
    if (Reloads != None) Reloads.CancelHand(Hand);
    StopWeapon(Hand);
    if (Inventory != None) Inventory.CancelTransfer();
    InputState[Hand].bSelectorOpen = false;
    InputState[Hand].bSelectorTriggerArmed = false;
    InputState[Hand].bSelectorConfirmPending = false;
    SelectionMessage[Hand] = "";
    InputState[Hand].bLowerArmed = false;
    InputState[Hand].bUpperArmed = false;
    InputState[Hand].bStickArmed = false;
    InputState[Hand].bAxisArmed = false;
    InputState[Hand].bVerticalArmed = false;
    InputState[Hand].bUpperGesture = false;
    InputState[Hand].bUpperUsed = false;
    InputState[Hand].bUpperTapPending = false;
    InputState[Hand].bUpperDoubleTap = false;
    InputState[Hand].bLowerConsumed = true;
    InputState[Hand].bGripWasDown = false;
    InputState[Hand].bPhysicalTriggerWasDown = false;
    InputState[Hand].bLowerWasDown = false;
    InputState[Hand].bUpperWasDown = false;
    InputState[Hand].bStickWasDown = false;
    UpperTime[Hand] = 0;
    UpperTapDeadline[Hand] = 0;
    LowerTime[Hand] = 0;
    if (Bridge != None)
    {
        Bridge.Hands[Hand].bGripArmed = false;
        Bridge.Hands[Hand].bTriggerArmed = false;
    }
    if (Selectors[Hand] != None) Selectors[Hand].HideSelector();
}

// A menu or lost tracking cancels actions and disarms edges, but it does not
// manufacture a physical release. Hold-grip items stow after a valid released
// sample returns; toggle-grip items stay owned until a deliberate new press.
function Cancel()
{
    if (Bridge != None && Bridge.CalibrationPanel != None)
        Bridge.CalibrationPanel.CancelBaselineCapture();
    if (Inventory != None && Inventory.LocalDrops != None) Inventory.LocalDrops.ResetIntent();
    if (ArcFence != None) ArcFence.Cancel();
    if (bInteracting && Bridge != None && Bridge.PC != None && KFPlayerInput(Bridge.PC.PlayerInput) != None)
        Bridge.WorldInfo.TimerHelper.ClearTimer('InteractTimer', Bridge.PC.PlayerInput);
    bInteracting = false;
    InteractHands = 0;
    CancelHand(0);
    CancelHand(1);
    EndSprint();
    if (Welding != None) Welding.Cancel();
    NativeFocusRequested = 0;
    if (Teleport != None) Teleport.CancelTransaction();
    if (PhysicalCrouch != None) PhysicalCrouch.Cancel(Bridge);
    // Context loss returns before the equipment helpers' next update. Hide
    // their presentation here so an old tracked pose cannot remain in view.
    if (Pouch != None && Pouch.PocketMesh != None) Pouch.PocketMesh.SetHidden(true);
    if (Wallet != None && Wallet.PocketMesh != None) Wallet.PocketMesh.SetHidden(true);
    if (Grenade != None) Grenade.ReleaseZoneMarker();
    bSelectionArmed = false; bSelectionGesture = false; bSelectionClickWasDown = false;
    if (Bridge != None)
    {
        Bridge.NativeMoveX = 0; Bridge.NativeMoveY = 0; Bridge.NativeTurnX = 0;
        Bridge.NativeSelectorCapture = 0;
        if (Bridge.PC != None && Bridge.PC.PlayerInput != None) Bridge.PC.bRun = 0;
    }
}

// Preserve a short release/reach button window without leaving the old hand
// bound, firing, or able to redirect input to a different weapon.
function NoteCarryRelease(VRWeaponRuntime R, int Hand)
{
    CarryReleaseRuntime[Hand] = R;
    CarryReleaseDeadline[Hand] = Bridge.WorldInfo.RealTimeSeconds + 0.5;
    CarryReleaseRevision[Hand] = R.OwnershipRevision;
    CarryReleaseCalibration[Hand] = Bridge.NativeCalibrationEpoch;
    CarryReleaseRoom[Hand] = Bridge.NativeRoomSpaceEpoch;
}

function TryCarryReleaseButton(int Hand, bool Lower)
{
    local VRWeaponRuntime R;
    R = CarryReleaseRuntime[Hand];
    if (R == None) return;
    if (!R.IsCurrent() || R.PrimaryHand >= 0 || R.SupportHand != 1-Hand
        || Inventory.GetHeldForHand(1-Hand) != R || Inventory.GetHeldForHand(Hand) != None
        || R.OwnershipRevision != CarryReleaseRevision[Hand]
        || Bridge.NativeCalibrationEpoch != CarryReleaseCalibration[Hand]
        || Bridge.NativeRoomSpaceEpoch != CarryReleaseRoom[Hand]
        || Bridge.WorldInfo.RealTimeSeconds > CarryReleaseDeadline[Hand])
    { CarryReleaseRuntime[Hand] = None; return; }
    if (!Lower || InputState[Hand].bLowerWasDown || !InputState[Hand].bLowerArmed
        || InputState[Hand].bSelectorOpen || HandCarrying(Hand) || Reloads == None) return;
    CarryReleaseRuntime[Hand] = None;
    InputState[Hand].bLowerConsumed = true;
    if (!Reloads.bActive && R.CanEjectEmptyMagazine(Bridge.bAllowFullMagazineEject
        || R.CanStartReload() || R.Item.AmmoCount[0] < R.Item.MagazineCapacity[0]))
        Reloads.Begin(R, R.SupportHand, true);
}

function DisarmDrawInputs(int Hand)
{
    // A draw and a new squeeze may share one sample. Consume that squeeze so
    // UpdateHand cannot immediately toggle the just-drawn weapon back off.
    ClearModeHold(Hand);
    InputState[Hand].bModeTriggerReleased = false;
    InputState[Hand].bGripWasDown = (Bridge.NativeGripMask & (1 << Hand)) != 0;
    if (InputState[Hand].bGripWasDown) Bridge.Hands[Hand].bGripArmed = false;
    Bridge.Hands[Hand].bTriggerArmed = false;
    InputState[Hand].bUpperArmed = false;
    InputState[Hand].bLowerArmed = false;
    InputState[Hand].bLowerConsumed = true;
}

function RefreshWeapon(int Hand)
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    R = Inventory.Registry.GetPrimary(Hand);
    if (R != None && R.IsCurrent()) W = R.Item;
    if (LastWeapon[Hand] == W) return;
    StopWeapon(Hand);
    LastWeapon[Hand] = W;
    Bridge.Hands[Hand].bTriggerArmed = false;
    InputState[Hand].bLowerConsumed = true;
}

function Update(float DeltaTime)
{
    local int Hand;
    local float Now, InputDelta;
    if (Bridge == None) { Cancel(); return; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    InputDelta = FClamp(Now - LastInputTime, 0, 1);
    LastInputTime = Now;
    if (!ContextValid()) { Cancel(); return; }
    if (++InputSample == MaxInt) InputSample = 1;
    UpdateSelection(InputDelta);
    NativeFocusRequested = int(IsSelectorOpen(0) || IsSelectorOpen(1));
    PhysicalCrouch.Update(Bridge, InputDelta);
    if (Inventory.LocalDrops != None) Inventory.LocalDrops.SampleMotion();
    UpdateSupportCarry();
    if (Bow != None) Bow.Update(InputDelta);
    Grenade.Update(InputDelta);
    if (Tomahawks != None) Tomahawks.Update(InputDelta);
    if (Wallet != None) Wallet.Update(InputDelta);
    Deployables.Update(InputDelta);
    // Ahead of the hands: a reload that takes the off hand this frame must own
    // it before UpdateHand reads its trigger as a use press.
    Reloads.Update(InputDelta);
    // A reload this update completed notifies the authority before the shots below.
    if (Reloads != None) Reloads.WatchReloadEnds();
    UpdateStockPairedReloads();
    if (Inventory.LocalDrops != None) Inventory.LocalDrops.UpdateCatch();
    if (ArcFence == None) ArcFence = new(self) class'VRArcFenceInput';
    ArcFence.Update(self, InputDelta);
    UpdateLocomotion(InputDelta);
    // Stick clicks belong to locomotion even while a reload, world grab or
    // pending drop owns the hand. Consume their edges before those paths can
    // return from UpdateHand, or a held click repeats every frame.
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if ((Bridge.NativeValidMask & Bridge.NativeStickClickActiveMask & (1 << Hand)) == 0)
        {
            InputState[Hand].bStickWasDown = false;
            InputState[Hand].bStickArmed = false;
        }
        else
        {
            InputState[Hand].bStickWasDown = (Bridge.NativeStickClickMask & (1 << Hand)) != 0;
            if (!InputState[Hand].bStickWasDown) InputState[Hand].bStickArmed = true;
        }
    }
    // Selector gestures follow real time, including during KF2 Zed Time.
    for (Hand = 0; Hand < 2; ++Hand) UpdateHand(Hand, InputDelta);
    UpdateEmptyInteraction();
    if (Pouch != None) Pouch.Update(InputDelta);
    Welding.Update(InputDelta);
    EnsureSelectors();
    PlaceSelectors();
    Bridge.CalibrationPanel.Update();
}

function UpdateSupportCarry()
{
    local int I, Hand, Bit;
    local VRWeaponRuntime R;
    local float Value;
    if (Inventory.WorldDrops != None && Inventory.WorldDrops.Busy()) return;
    for (I = 0; I < Inventory.Registry.Items.Length; ++I)
    {
        R = Inventory.Registry.Items[I];
        if (R == None) continue;
        if (R.CarryArmCalibration != Bridge.NativeCalibrationEpoch
            || (R.PrimaryHand >= 0 && IsSelectorOpen(R.PrimaryHand))
            || (R.PrimaryHand < 0 && R.SupportHand >= 0 && IsSelectorOpen(R.SupportHand))
            || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
        {
            R.bCarrySawRelease = false; R.bCarryReleaseArmed = false;
            R.bCarrySupportReleaseArmed = false; R.CarryArmPrimaryToken = 0;
        }
        R.CarryArmCalibration = Bridge.NativeCalibrationEpoch;
        if ((R.PrimaryHand >= 0 && IsSelectorOpen(R.PrimaryHand))
            || (R.PrimaryHand < 0 && R.SupportHand >= 0 && IsSelectorOpen(R.SupportHand))
            || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3) continue;
        if (R.CarryPrimaryHand >= 0 && R.PrimaryHand < 0 && R.SupportHand >= 0)
        {
            Hand = R.SupportHand;
            Value = Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
            if (Bridge.bHoldSupportGrip || ((Bridge.NativeGripMask & (1 << Hand)) != 0 && Value >= 0 && Value <= 1))
                R.bCarrySupportReleaseArmed = true;
            continue;
        }
        if (R.Item.Class==class'KFWeap_SMG_G18' && R.SupportHand>=0)
        {
            Hand=R.SupportHand; Value=Hand==0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
            if (Bridge.bHoldSupportGrip || ((Bridge.NativeGripMask & (1<<Hand))!=0 && Value>=0.65 && Value<=1))
                R.bCarrySupportReleaseArmed=true;
        }
        // Items without a local drop (the syringe) still stow on Hold release.
        if (Inventory.LocalDrops == None || R.PrimaryHand < 0 || KFWeap_DualBase(R.Item) != None
            || (!Inventory.LocalDrops.Eligible(R) && Inventory.HasGauntletHand(R.PrimaryHand)))
        { R.bCarryReleaseArmed = false; R.CarryArmPrimaryToken = 0; continue; }
        // Hold is released by an open tracked hand, including normal draws.
        // Spawn equipment and quick swaps wait for their first squeeze.
        Hand = R.PrimaryHand; Bit = 1 << Hand;
        if (R.CarryArmPrimaryToken != Hand+1)
        { R.bCarryReleaseArmed = false; R.bCarrySawRelease = false; }
        R.CarryArmPrimaryToken = Hand+1;
        R.CarryArmRevision = R.OwnershipRevision;
        if (!Bridge.bToggleGrip && !Inventory.WaitsForFirstGrip(R, Hand))
            R.bCarryReleaseArmed = true;
        Value = Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
        if (GripReleased(Hand) && !R.bCarryReleaseArmed) R.bCarrySawRelease = true;
        if ((Bridge.NativeGripMask & Bit) != 0 && Value >= 0.65 && Value <= 1
            && (!Bridge.bToggleGrip || R.bCarrySawRelease))
            R.bCarryReleaseArmed = true;
        else if (GripReleased(Hand) && R.bCarryReleaseArmed)
        {
            if (R.Item.Class==class'KFWeap_SMG_G18' && !Bridge.bToggleGrip)
            {
                if (Inventory.ReleaseHand(Hand,true)) R.bCarryReleaseArmed=false;
            }
            else if (R.SupportHand >= 0 && (!Bridge.bHoldSupportGrip
                || (Bridge.NativeGripMask & (1 << R.SupportHand)) != 0))
            {
                if (Inventory.EnterSupportCarry(Hand)) R.bCarryReleaseArmed = false;
            }
            else if (!Bridge.bToggleGrip && (!Inventory.WorldDropsActive()
                    || !class'VRWorldDropGun'.static.HasWorldArt(R.Item))
                && Inventory.ReleaseHand(Hand, true)) R.bCarryReleaseArmed = false;
        }
    }
}

function UpdateLocomotion(float RealDelta)
{
    local int Hand, MoveHand, Bit;
    local float X, Y, Magnitude, Yaw, RawX;
    local vector Direction;
    local rotator Reference;
    local bool bTeleportMode, bRunNow, bSmoothTurn;
    local VRSessionUI Session;
    MoveHand = Clamp(Bridge.MovementHand, 0, 1);
    Session = Bridge.MenuSession();
    bSmoothTurn = Session != None && !Session.bSnapTurn;
    // Teleport replaces the walk, not the turn. The turn stick keeps working
    // throughout an aim, so a destination and an arrival facing stay separate
    // choices made with separate thumbs.
    bTeleportMode = Bridge.LocomotionMode == 1 && Teleport != None;
    // This caller stops updating the teleport helper in smooth mode, so clear
    // its transaction here rather than waiting for the helper's mode gate.
    if (!bTeleportMode && Teleport != None) Teleport.CancelTransaction();
    // Start neutral each frame. A turn-hand selector consumes its stick;
    // the movement stick can walk while its hand points at the wheel.
    Bridge.NativeMoveX = 0;
    Bridge.NativeMoveY = 0;
    Bridge.NativeTurnX = 0;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        if (IsSelectorOpen(Hand) && Hand != MoveHand)
        {
            // Releasing a latched selector with its stick still displaced
            // must not turn into a movement or turn edge.
            InputState[Hand].bAxisArmed = false;
            InputState[Hand].bVerticalArmed = false;
            continue;
        }
        X = Hand == 0 ? Bridge.LeftStickX : Bridge.RightStickX;
        Y = Hand == 0 ? Bridge.LeftStickY : Bridge.RightStickY;
        Magnitude = Sqrt(X*X + Y*Y);
        if ((Bridge.NativeValidMask & Bridge.NativeStickActiveMask & Bit) == 0
            || X != X || Y != Y || Abs(X) > 1 || Abs(Y) > 1)
        { InputState[Hand].bAxisArmed = false; InputState[Hand].bVerticalArmed = false; X = 0; Y = 0; Magnitude = 0; }
        else if (Magnitude <= 0.12)
        { InputState[Hand].bAxisArmed = true; InputState[Hand].bVerticalArmed = true; }
        RawX = X;
        if (!InputState[Hand].bAxisArmed || Magnitude <= 0.12) { X = 0; Y = 0; }
        else if (Magnitude > 1) { X /= Magnitude; Y /= Magnitude; }
        if (Hand == MoveHand)
        {
            // The teleport owner reads this stick itself, including the dead
            // zone and the release edge. Leaving the stock walk out of the
            // loop keeps one reader per stick in either mode.
            if (bTeleportMode) continue;
            Bridge.NativeMoveX = X; Bridge.NativeMoveY = Y;
            if (Bridge.bControllerRelativeMovement)
            {
                Reference = Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
                Yaw = float(NormalizeRotAxis(Reference.Yaw - Bridge.PC.Rotation.Yaw)) * Pi / 32768.0;
                Direction.X = Y * Cos(Yaw) - X * Sin(Yaw);
                Direction.Y = Y * Sin(Yaw) + X * Cos(Yaw);
                Bridge.NativeMoveX = Direction.Y; Bridge.NativeMoveY = Direction.X;
            }
            // Any direction starts and holds sprint; only centring the stick ends it.
            if (X*X + Y*Y <= 0.04) bSprintRequested = false;
            else if ((Bridge.NativeValidMask & Bridge.NativeStickClickActiveMask & Bridge.NativeStickClickMask & Bit) != 0
                && !InputState[Hand].bStickWasDown && InputState[Hand].bStickArmed)
            {
                // A sprint click also stands a button crouch up.
                bSprintRequested = true;
                PhysicalCrouch.StandUp(Bridge);
            }
        }
        else
        {
            Bridge.NativeTurnX = 0;
            if (InputState[Hand].bAxisArmed)
            {
                // The entire upward jump sector owns the approach and rim
                // push, so lateral thumb drift cannot also rotate the player.
                if (Y <= 0 || Abs(X) > Y * JumpUpSlope)
                {
                    if (bSmoothTurn)
                    {
                        // Full smooth turn outside the upward cone.
                        if (Abs(RawX) > 0.12) Bridge.NativeTurnX = RawX > 0 ? 1 : -1;
                    }
                    else if (Abs(X) > 0.12)
                        // Fade snap turn with vertical tilt; avoid a hard
                        // diagonal cutoff while the thumb wobbles.
                        Bridge.NativeTurnX = (X > 0 ? 1 : -1) * (Abs(X)-0.12)/0.88
                            * FClamp((Abs(X)/Magnitude - 0.3) / 0.4, 0, 1);
                }
                // Jump and crouch are deliberate pushes to the rim: the raw
                // deflection must reach JumpRimMagnitude, mostly vertical. 0.75
                // on Y alone made a relaxed thumb on the turn stick jump during
                // ordinary play. Down toggles a crouch for seated players; up
                // stands from it before it jumps.
                if (InputState[Hand].bVerticalArmed && Magnitude >= JumpRimMagnitude
                    && ((Y > 0 && Abs(X) <= Y * JumpUpSlope)
                        || (Y < 0 && Abs(Y) >= Magnitude * 0.85 && Abs(Y) > Abs(X))))
                {
                    if (Y < 0) { if (Bridge.bStickCrouch) PhysicalCrouch.ToggleButtonCrouch(Bridge); }
                    else if (PhysicalCrouch.bButtonCrouch) PhysicalCrouch.StandUp(Bridge);
                    else Bridge.PC.PlayerInput.Jump();
                    InputState[Hand].bVerticalArmed = false;
                }
            }
        }
    }
    // The turn click offers the welder at a door; elsewhere it toggles the
    // movement hand's wheel. The movement click still owns sprint/cancel.
    Hand = 1 - MoveHand;
    Bit = 1 << Hand;
    if ((Bridge.NativeValidMask & Bridge.NativeStickClickActiveMask & Bridge.NativeStickClickMask & Bit) != 0
        && !InputState[Hand].bStickWasDown && InputState[Hand].bStickArmed)
    {
        if (IsSelectorOpen(MoveHand)) CloseSelector(MoveHand);
        else if (!IsSelectorOpen(0) && !IsSelectorOpen(1))
        {
            if (Welding != None && Welding.WantsStickClick()) Welding.StickClick();
            else OpenSelector(MoveHand);
        }
    }
    if (bTeleportMode)
    {
        // VRTeleportLocomotion reads the movement stick directly. Do not let a
        // latched wheel on that hand preview, buffer or commit a teleport.
        if (IsSelectorOpen(MoveHand))
        {
            InputState[MoveHand].bAxisArmed = false;
            Teleport.CancelTransaction();
            return;
        }
        Teleport.Update(RealDelta);
        return;
    }
    if (Bridge.Human.bIsCrouched) bSprintRequested = false;
    // A busy weapon or a held trigger pauses the latched request; it resumes
    // on its own once both hands are free again.
    bRunNow = bSprintRequested && Bridge.WorldInfo.RealTimeSeconds >= SprintResumeTime;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Bridge.Hands[Hand].bTrigger && (Reloads == None || !Reloads.OwnsHand(Hand)))
        { bRunNow = false; SprintResumeTime = Bridge.WorldInfo.RealTimeSeconds + 0.35; }
        if (Inventory.Registry.GetPrimary(Hand) != None
            && !Inventory.ItemAllowsSprint(Inventory.Registry.GetPrimary(Hand))) bRunNow = false;
    }
    Bridge.PC.bRun = bRunNow ? 1 : 0;
    if (!bRunNow && Inventory != None && Inventory.ContextValid()) Inventory.SetSprinting(false);
}

function ModeFeedback(int Hand, bool Accepted)
{
    Bridge.QueueHandHaptic(1 << Hand, Accepted ? 0.25 : 0.08, Accepted ? 0.035 : 0.08);
}

// The stock item a hand would throw: what it holds, if stock lets it go
// (bCanThrow: not the knife, 9mm backup, welder, or a VR pair member).
function KFWeapon DroppableWeapon(int Hand)
{
    local VRWeaponRuntime R;
    R = Inventory.Registry.GetPrimary(Hand);
    if (Inventory.WorldDropsActive()) R = Inventory.GetHeldForHand(Hand);
    if (R == None || R.Item == None || R.Item.bDeleteMe || !R.IsCurrent()) return None;
    if (Inventory.WorldDropsActive()) return R.Item;
    if (class'VRWeaponPair'.static.ForMember(R.Item) != None || !R.Item.CanThrow()) return None;
    return R.Item;
}

// Throws the hand's item with stock ServerThrowOtherWeapon, which re-checks
// ownership and CanThrow on the authority and spawns the ordinary pickup a
// teammate can collect. Returns true to close the wheel.
function bool DropHeldWeapon(int Hand)
{
    local KFWeapon W;
    W = DroppableWeapon(Hand);
    if (W == None) { Inventory.Pulse(Hand); return false; }
    if (Inventory.WorldDropsActive()) return Inventory.WorldDrops.QueueMenuDrop(W, Hand);
    StopWeapon(Hand);
    Bridge.Hands[Hand].bTriggerArmed = false;
    Bridge.PC.ServerThrowOtherWeapon(W);
    return true;
}

function bool HasDosh()
{
    return Bridge.PC.PlayerReplicationInfo != None && Bridge.PC.PlayerReplicationInfo.Score >= 1;
}

// Wheel DROP > DROP DOSH: one stock toss (same amount, debit and pickup) from
// the wheel hand's palm, forward along that controller's aim.
function bool TossDosh(int Hand)
{
    local vector Position, Velocity;
    local bool Thrown;
    if (Hand < 0 || Hand > 1 || !ContextValid() || !HasDosh()) { Inventory.Pulse(Hand); return false; }
    Position = Bridge.PalmPosition(Hand);
    Velocity = vector(Bridge.Hands[Hand].AimRotation) * DOSH_TOSS_SPEED;
    Thrown = Bridge.RequestNetworkDosh(Position, Velocity);
    if (!Thrown) Thrown = class'VRDoshThrow'.static.Toss(Bridge, Bridge.Human, Position, Velocity, Bridge.HeadPosition);
    if (Thrown) ModeFeedback(Hand, true);
    else Inventory.Pulse(Hand);
    return Thrown;
}

function UpdateSelection(float DeltaTime)
{
    local int Hand, Bit, UpperBit;
    local bool Upper, Edge, HeldWheel;
    local float TriggerValue, Now;
    Bridge.NativeSelectorCapture = 0;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        UpperBit = Hand == 0 ? 2 : 4;
        if ((Bridge.NativeValidMask & Bit) == 0 || (Bridge.NativePhysicalButtonActiveMask & UpperBit) == 0
            || Inventory.HasWorldGrab(Hand) || (Reloads != None && Reloads.OwnsHand(Hand)))
        {
            InputState[Hand].bSelectorOpen = false;
            InputState[Hand].bUpperArmed = false;
            InputState[Hand].bUpperGesture = false;
            InputState[Hand].bUpperUsed = false;
            InputState[Hand].bUpperTapPending = false;
            InputState[Hand].bUpperDoubleTap = false;
            InputState[Hand].bUpperWasDown = false;
            InputState[Hand].bSelectorTriggerArmed = false;
            InputState[Hand].bSelectorConfirmPending = false;
            UpperTime[Hand] = 0;
            UpperTapDeadline[Hand] = 0;
            continue;
        }
        Upper = (Bridge.NativePhysicalButtonMask & UpperBit) != 0;
        Edge = Upper && !InputState[Hand].bUpperWasDown && InputState[Hand].bUpperArmed;
        if (!Upper) InputState[Hand].bUpperArmed = true;
        Now = Bridge.WorldInfo.RealTimeSeconds;
        // A first tap is held only for the double-tap window. Resolve it
        // before reading a later press, which keeps a late second tap as a
        // fresh gesture rather than an accidental open hand.
        if (InputState[Hand].bUpperTapPending && Now >= UpperTapDeadline[Hand])
        {
            InputState[Hand].bUpperTapPending = false;
            QuickSwapHand(Hand);
            RefreshWeapon(Hand);
            Bridge.Hands[Hand].bTriggerArmed = false;
        }
        if (Edge && !IsSelectorOpen(Hand) && HandAtTemple(Hand))
        {
            // Head lamp: the press is spent here, so neither the release
            // quick-swap nor the hold wheel follows it.
            Bridge.Human.ToggleEquipment();
            ModeFeedback(Hand, true);
            InputState[Hand].bUpperGesture = true;
            InputState[Hand].bUpperUsed = true;
            InputState[Hand].bUpperTapPending = false;
            InputState[Hand].bUpperDoubleTap = false;
            UpperTime[Hand] = 0;
        }
        else if (Edge)
        {
            InputState[Hand].bUpperGesture = true;
            InputState[Hand].bUpperUsed = IsSelectorOpen(Hand);
            InputState[Hand].bUpperDoubleTap = InputState[Hand].bUpperTapPending;
            InputState[Hand].bUpperTapPending = false;
            if (InputState[Hand].bUpperUsed)
            {
                InputState[Hand].bSelectorOpen = false;
                InputState[Hand].bSelectorTriggerArmed = false;
                InputState[Hand].bSelectorConfirmPending = false;
                Bridge.Hands[Hand].bTriggerArmed = false;
            }
            UpperTime[Hand] = 0;
        }
        if (Upper && InputState[Hand].bUpperGesture && !InputState[Hand].bUpperUsed)
        {
            UpperTime[Hand] += DeltaTime;
            if (UpperTime[Hand] >= UPPER_HOLD_SECONDS && InputState[Hand].bUpperDoubleTap)
            {
                // Tap then hold: quick heal rather than a second way to the wheel.
                StopWeapon(Hand);
                Bridge.Hands[Hand].bTriggerArmed = false;
                DrawSyringe(Hand);
                InputState[Hand].bUpperUsed = true;
            }
            else if (UpperTime[Hand] >= UPPER_HOLD_SECONDS)
            {
                InputState[Hand].bUpperTapPending = false;
                Inventory.CancelTransfer();
                StopWeapon(Hand);
                Bridge.Hands[Hand].bTriggerArmed = false;
                InputState[Hand].bSelectorOpen = true;
                InputState[Hand].bSelectorTriggerArmed = false;
                InputState[Hand].bSelectorConfirmPending = false;
                InputState[Hand].bSelectorInitAttempted = false;
                EnsureSelectors();
                if (Selectors[Hand] != None) Selectors[Hand].OpenSelection();
                InputState[Hand].bUpperUsed = true;
            }
        }
        if (IsSelectorOpen(Hand) && Selectors[Hand] != None)
        {
            HeldWheel = Selectors[Hand].MenuPage == 0 && !Selectors[Hand].bUtilities;
            TriggerValue = HeldWheel ? (Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue)
                : (Hand == 0 ? Bridge.LeftTriggerValue : Bridge.RightTriggerValue);
            // Pointing moves the wheel cursor, so an armed squeeze holds it
            // before the pull itself can tip the controller to a neighbour.
            if (!InputState[Hand].bSelectorConfirmPending)
                Selectors[Hand].ReadSelection(InputState[Hand].bSelectorTriggerArmed && TriggerValue > 0.3);
            if (((HeldWheel ? Bridge.NativeGripActiveMask : Bridge.NativeTriggerActiveMask) & Bit) == 0 || TriggerValue != TriggerValue
                || TriggerValue < 0 || TriggerValue > 1)
            {
                InputState[Hand].bSelectorTriggerArmed = false;
                InputState[Hand].bSelectorConfirmPending = false;
            }
            else if (TriggerValue <= 0.1 && ((HeldWheel ? Bridge.NativeGripMask : Bridge.NativeTriggerMask) & Bit) == 0)
            {
                if (InputState[Hand].bSelectorConfirmPending)
                {
                    // A full click confirms the hovered tile. Freeze it during
                    // the squeeze, and consume the release before weapon input.
                    InputState[Hand].bSelectorConfirmPending = false;
                    InputState[Hand].bSelectorOpen = false;
                    if (!Selectors[Hand].CommitSelection()) InputState[Hand].bSelectorOpen = true;
                    else Selectors[Hand].BeginCollapse();
                    Bridge.Hands[Hand].bTriggerArmed = false;
                }
                InputState[Hand].bSelectorTriggerArmed = true;
            }
            else if (TriggerValue >= (HeldWheel ? 0.65 : 0.55) && InputState[Hand].bSelectorTriggerArmed)
            {
                InputState[Hand].bSelectorTriggerArmed = false;
                if (HeldWheel && (Bridge.NativeGripMask & Bit) != 0)
                {
                    // Continuous-held wheel acts as a pocket: this squeeze
                    // admits the draw now. Its later release is a real toss.
                    InputState[Hand].bSelectorConfirmPending = false;
                    InputState[Hand].bSelectorOpen = false;
                    if (!Selectors[Hand].CommitSelection()) InputState[Hand].bSelectorOpen = true;
                    else Selectors[Hand].BeginCollapse();
                    DisarmDrawInputs(Hand); // consume confirm before catches/support
                }
                else if (!HeldWheel) InputState[Hand].bSelectorConfirmPending = true;
            }
        }
        if (!Upper && InputState[Hand].bUpperWasDown && InputState[Hand].bUpperGesture)
        {
            // Holding opens a latched wheel; releasing frees the thumb for
            // locomotion. A first short tap waits for a second, while the
            // second short tap explicitly opens the hand.
            if (!InputState[Hand].bUpperUsed)
            {
                if (InputState[Hand].bUpperDoubleTap)
                {
                    OpenHand(Hand);
                    Bridge.Hands[Hand].bTriggerArmed = false;
                }
                else
                {
                    InputState[Hand].bUpperTapPending = true;
                    UpperTapDeadline[Hand] = Now + UPPER_DOUBLE_TAP_SECONDS;
                }
            }
            InputState[Hand].bUpperGesture = false;
            InputState[Hand].bUpperDoubleTap = false;
        }
        if (InputState[Hand].bUpperGesture || IsSelectorOpen(Hand)) Bridge.NativeSelectorCapture = 1;
        // The gesture state owns its edge history, including frames where
        // weapon/grip dispatch returns early for another interaction.
        InputState[Hand].bUpperWasDown = Upper;
    }
}

function UpdateHand(int Hand, float DeltaTime)
{
    local int Bit, LowerBit, UpperBit, Buttons, ActiveButtons;
    local bool Grip, Trigger, Lower, Upper, GripEdge, Reload, Melee, PhysicalMelee, EffectiveTrigger, WantParry;
    local bool HadSelector, TriggerEdge, OwnershipCommand;
    local bool Physical, bReloadWasRunning;
    local bool bTriggerReleased, bPreviousTriggerReleased;
    local KFWeapon W;
    local VRWeaponRuntime R;
    Bit = 1 << Hand;
    LowerBit = Hand == 0 ? 1 : 8; // X / A
    UpperBit = Hand == 0 ? 2 : 4; // Y / B
    RefreshWeapon(Hand);
    if (Inventory.WorldDrops != None && Inventory.WorldDrops.OwnsHand(Hand))
    {
        ClearModeHold(Hand);
        InputState[Hand].bModeTriggerReleased = false;
        InputState[Hand].bLowerArmed = false;
        ClearReloadTap(Hand);
        Grip = (Bridge.NativeGripMask & Bit) != 0;
        Bridge.Hands[Hand].bGrip = Grip;
        Bridge.Hands[Hand].bGripArmed = false;
        Bridge.Hands[Hand].bTriggerArmed = false;
        InputState[Hand].bGripWasDown = Grip;
        InputState[Hand].bLowerConsumed = true;
        return;
    }
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bit) == 0)
    {
        CancelHand(Hand);
        return;
    }
    // A world grab is hand occupancy. While it holds, this hand runs nothing
    // else -- no weapon, selector, body slot or grenade path -- and the other
    // hand is unaffected. A world grab is hold-to-grab even under toggle grip.
    if (Inventory.HasWorldGrab(Hand))
    {
        Grip = (Bridge.NativeGripMask & Bit) != 0;
        if (!Grip)
        {
            Inventory.ReleaseWorldGrab(Hand);
            if (GripReleased(Hand)) Bridge.Hands[Hand].bGripArmed = true;
        }
        StopWeapon(Hand);
        Bridge.Hands[Hand].bTriggerArmed = false;
        Bridge.Hands[Hand].bGrip = Grip;
        InputState[Hand].bGripWasDown = Grip;
        InputState[Hand].bPhysicalTriggerWasDown = false;
        InputState[Hand].bLowerConsumed = true;
        return;
    }
    // Reload work owns the off hand the same way: its trigger is holding a
    // magazine or pinching the slide, never a use press or a draw.
    if (Reloads != None && Reloads.OwnsHand(Hand))
    {
        ClearModeHold(Hand);
        InputState[Hand].bModeTriggerReleased = false;
        InputState[Hand].bLowerArmed = false;
        ClearReloadTap(Hand);
        Grip = (Bridge.NativeGripMask & Bit) != 0;
        Bridge.Hands[Hand].bTriggerArmed = false;
        Bridge.Hands[Hand].bGrip = Grip;
        InputState[Hand].bGripWasDown = Grip;
        InputState[Hand].bPhysicalTriggerWasDown = true;
        InputState[Hand].bLowerConsumed = true;
        return;
    }
    Buttons = Bridge.NativePhysicalButtonMask;
    ActiveButtons = Bridge.NativePhysicalButtonActiveMask;
    Grip = (Bridge.NativeGripMask & Bit) != 0;
    Trigger = (Bridge.NativeTriggerMask & Bridge.NativeTriggerActiveMask & Bit) != 0;
    bTriggerReleased = TriggerReleased(Hand);
    bPreviousTriggerReleased = InputState[Hand].bModeTriggerReleased;
    InputState[Hand].bModeTriggerReleased = bTriggerReleased;
    TriggerEdge = Trigger && !InputState[Hand].bPhysicalTriggerWasDown;
    InputState[Hand].bPhysicalTriggerWasDown = Trigger;
    Lower = (Buttons & ActiveButtons & LowerBit) != 0;
    Upper = (Buttons & ActiveButtons & UpperBit) != 0;
    if (GripReleased(Hand))
        Bridge.Hands[Hand].bGripArmed = true;
    if ((Bridge.NativeTriggerActiveMask & Bit) == 0) Bridge.Hands[Hand].bTriggerArmed = false;
    else if (bTriggerReleased)
        Bridge.Hands[Hand].bTriggerArmed = true;
    if ((ActiveButtons & LowerBit) == 0)
    {
        ClearReloadTap(Hand);
        InputState[Hand].bLowerArmed = false;
        InputState[Hand].bLowerConsumed = true;
    }
    else if (!Lower) InputState[Hand].bLowerArmed = true;
    if ((ActiveButtons & UpperBit) == 0)
    {
        InputState[Hand].bUpperArmed = false;
        InputState[Hand].bUpperGesture = false;
    }
    else if (!Upper) InputState[Hand].bUpperArmed = true;

    if (!Lower || !InputState[Hand].bLowerArmed || !bTriggerReleased) ClearModeHold(Hand);

    HadSelector = InputState[Hand].bSelectorOpen;
    if (Lower && !InputState[Hand].bLowerWasDown && InputState[Hand].bLowerArmed)
    {
        LowerTime[Hand] = 0;
        InputState[Hand].bLowerConsumed = HadSelector;
    }
    TryCarryReleaseButton(Hand, Lower);
    if (Lower && InputState[Hand].bLowerWasDown) LowerTime[Hand] += DeltaTime;
    GripEdge = Grip && !InputState[Hand].bGripWasDown && Bridge.Hands[Hand].bGripArmed;
    if (ArcFence != None && ArcFence.Handle(self, Hand, Lower, TriggerEdge, GripEdge))
    {
        StopWeapon(Hand);
        InputState[Hand].bGripWasDown = Grip;
        InputState[Hand].bLowerWasDown = Lower;
        return;
    }
    // Returning to this carried gun's primary contact takes the fresh squeeze
    // before nearby headlamp, welder or world-grab acquisition zones.
    if (GripEdge && !HadSelector && Inventory.TryRegripCarry(Hand))
    { GripEdge = false; OwnershipCommand = true; }
    // The temple gesture owns only a fresh squeeze of a genuinely free hand.
    // Reload and world holds returned above; body contacts and transfers keep
    // their existing priority. Spend the edge until a real grip release.
    if (GripEdge && !HadSelector && Inventory.Registry.GetPrimary(Hand) == None
        && Inventory.Registry.GetSupport(Hand) == None && !Inventory.HasGauntletHand(Hand)
        && !Inventory.IsTransferPending(Hand) && !HandCarrying(Hand)
        && (Deployables == None || !Deployables.IsHeld(Hand))
        && !InBodyZone(Hand) && HandAtTemple(Hand))
    {
        Bridge.Human.ToggleEquipment();
        ModeFeedback(Hand, true);
        Bridge.Hands[Hand].bGripArmed = false;
        GripEdge = false;
    }
    // A free hand on the door's welder hologram takes the welder; the
    // hologram only shows near a weldable door, ahead of a nearby Zed grab.
    if (GripEdge && !HadSelector && Welding != None && !InBodyZone(Hand) && Welding.TryGrabHologram(Hand))
    {
        StopWeapon(Hand);
        Bridge.Hands[Hand].bGripArmed = false;
        Bridge.Hands[Hand].bTriggerArmed = false;
        GripEdge = false;
        OwnershipCommand = true;
    }
    // A fresh squeeze decides the world grab once, before the generic weapon,
    // body-slot and chest-grenade fallbacks below -- unless the hand is in one
    // of the player's own body zones, where the zone wins.
    if (GripEdge && !HadSelector && Inventory.Registry.GetPrimary(Hand) == None
        && Inventory.Registry.GetSupport(Hand) == None && !InBodyZone(Hand)
        && Inventory.TryWorldGrab(Hand))
    {
        StopWeapon(Hand);
        Bridge.Hands[Hand].bGripArmed = false;
        Bridge.Hands[Hand].bTriggerArmed = false;
        Bridge.Hands[Hand].bGrip = true;
        InputState[Hand].bGripWasDown = true;
        InputState[Hand].bLowerWasDown = Lower;
        InputState[Hand].bLowerConsumed = true;
        return;
    }
    // Then a highlighted floor item: the squeeze becomes a gravity-pull lock
    // rather than a fist. It holds the hand like a world grab until released.
    if (GripEdge && !HadSelector && Inventory.Registry.GetPrimary(Hand) == None
        && Inventory.Registry.GetSupport(Hand) == None && !InBodyZone(Hand)
        && Inventory.TryGravityLock(Hand))
    {
        StopWeapon(Hand);
        Bridge.Hands[Hand].bGripArmed = false;
        Bridge.Hands[Hand].bTriggerArmed = false;
        Bridge.Hands[Hand].bGrip = true;
        InputState[Hand].bGripWasDown = true;
        InputState[Hand].bLowerWasDown = Lower;
        InputState[Hand].bLowerConsumed = true;
        return;
    }
    if (GripEdge && !HadSelector)
    {
        if (Inventory.Registry.GetSupport(Hand) != None && !Bridge.bHoldSupportGrip)
        {
            R = Inventory.Registry.GetSupport(Hand);
            if (R.PrimaryHand < 0 && Inventory.WorldDropsActive())
                Inventory.WorldDrops.QueueMenuDrop(R.Item, Hand);
            else Inventory.ReleaseHand(Hand, true);
            OwnershipCommand = true;
        }
        else
        {
            OwnershipCommand = true;
            // A squeeze on the other gun's slide or handle racks it; the
            // support contact still wins wherever the hand is nearer it.
            if (Reloads != None && Reloads.ClaimIdleRack(Hand)) {}
            // An authored support contact takes priority when the weapon is
            // close enough to overlap the chest grenade zone.
            else if (!Inventory.TryGrab(Hand)
                && (Wallet == None || BodySlotNearer(Hand, Wallet.PocketPosition(Hand), Wallet.PocketRadius) || !Wallet.TryGrab(Hand))
                && (Pouch == None || (Grenade != None && Grenade.PrefersOver(Hand, Pouch.PouchPosition())) || !Pouch.TryGrab(Hand))
                && !TryBodyAnchor(Hand)) Grenade.TryGrab(Hand);
        }
    }
    if (GripReleased(Hand) && !HadSelector && Inventory.Registry.GetSupport(Hand) != None
        && Bridge.bHoldSupportGrip)
    {
        R = Inventory.Registry.GetSupport(Hand);
        if ((R.Item.Class!=class'KFWeap_SMG_G18' && R.CarryPrimaryHand < 0) || R.bCarrySupportReleaseArmed)
        { Inventory.ReleaseHand(Hand, true); OwnershipCommand = true; }
    }
    Bridge.Hands[Hand].bGrip = Grip || Inventory.Registry.GetPrimary(Hand) != None;
    // Binding invalidates the affected pose. Publish both items again before
    // either hand can fire, including support acquired by the other hand.
    if (OwnershipCommand) Inventory.PlaceAll();
    RefreshWeapon(Hand);
    InputState[Hand].bGripWasDown = Grip;
    // A hand-to-hand transfer lasts only while the receiving hand squeezes at
    // the grip. Re-check it every frame: an empty receiver that lets go never
    // reaches ReleaseHand, and the stale candidate disarmed the gun hand's
    // trigger for good (#145, a squeeze near a pistol slide after the rack).
    if (Inventory.IsTransferPending(Hand) && Inventory.ValidateTransferCandidate())
    {
        StopWeapon(Hand);
        Bridge.Hands[Hand].bTriggerArmed = false;
        InputState[Hand].bLowerConsumed = true;
        InputState[Hand].bLowerWasDown = Lower;
        return;
    }
    if (InputState[Hand].bSelectorOpen || HadSelector || HandCarrying(Hand))
    {
        StopWeapon(Hand);
        Bridge.Hands[Hand].bTriggerArmed = false;
        InputState[Hand].bLowerConsumed = true;
        InputState[Hand].bLowerWasDown = Lower;
        return;
    }

    // Support-only carry remains support until the player deliberately moves
    // to the primary grip and presses the trigger. That press claims a grip;
    // it cannot also fire a shot. The next shot requires a released trigger.
    R = Inventory.Registry.GetSupport(Hand);
    if (R != None && R.PrimaryHand < 0 && TriggerEdge && Bridge.Hands[Hand].bTriggerArmed
        && Bridge.Hands[Hand].bGrip && Inventory.TryPromoteSupport(Hand))
    {
        Inventory.PlaceAll();
        RefreshWeapon(Hand);
        Bridge.Hands[Hand].bTriggerArmed = false;
    }
    // A primary on the shotgun grip keeps the rest of its input below; only
    // its trigger belongs to the shotgun (EffectiveTrigger is withheld there).
    if (SupportTriggerFire(Hand, Trigger, TriggerEdge) && Inventory.Registry.GetPrimary(Hand) == None)
    {
        InputState[Hand].bLowerWasDown = Lower;
        return;
    }
    R = Inventory.GetHeldForHand(Hand);
    if (R != None && R.IsCurrent() && R.PrimaryHand < 0)
    {
        // The foregrip carries this exact actor without granting fire. Its
        // reload button still operates the shared magazine/action session.
        if (InputState[Hand].bReloadPulse)
        { R.Item.StopFire(2); InputState[Hand].bReloadPulse = false; }
        Reload = (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0
            && !Lower && InputState[Hand].bLowerWasDown && InputState[Hand].bLowerArmed
            && !InputState[Hand].bLowerConsumed && LowerTime[Hand] < 0.25;
        Reload = ResolveReloadTap(R, Hand, Reload, Lower);
        if (Reload)
        {
            DispatchReload(R, Hand);
            if (Reloads != None && Reloads.EnabledFor(R.Item) && !Reloads.bActive
                && R.Item != Reloads.RejectedGun && R.Item != Reloads.HandoffGun
                && Reloads.Supported(R.Item) && Reloads.MagazineReloading(R.Item))
            {
                if (InputState[Hand].bReloadPulse)
                { R.Item.StopFire(2); InputState[Hand].bReloadPulse = false; }
                Reloads.Begin(R, Hand);
            }
        }
        InputState[Hand].bLowerWasDown = Lower;
        return;
    }
    // Blast Brawlers: either gauntlet's trigger is its own blast, including the
    // implicit off-hand glove, which has no primary runtime below.
    if (Brawler != None) Brawler.UpdateHand(Hand, Trigger, TriggerEdge);
    R = Inventory.Registry.GetPrimary(Hand);
    W = LastWeapon[Hand];
    LogBlockedTrigger(Hand, R, W, TriggerEdge);
    if (R == None || W == None || R.Presenter == None
        || !R.Presenter.bCalibrated || R.Presenter.NativeWeaponReady == 0)
    {
        StopWeapon(Hand);
        // Empty/support-only hands still observe trigger release so a later
        // deliberate support promotion can be armed. Unready primaries may
        // never begin firing just because calibration finishes under a hold.
        if (W != None) Bridge.Hands[Hand].bTriggerArmed = false;
        InputState[Hand].bLowerConsumed = true;
        InputState[Hand].bLowerWasDown = Lower;
        return;
    }
    if (InputState[Hand].bReloadPulse) { W.StopFire(2); InputState[Hand].bReloadPulse = false; }
    Melee = W.IsA('KFWeap_MeleeBase');
    Physical = R.Presenter.PhysicalMelee != None;
    PhysicalMelee = Physical && R.Presenter.ActiveProfile >= 0
        && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length
        && !R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].bFirearm;
    EffectiveTrigger = Trigger && Bridge.Hands[Hand].bTriggerArmed && InputState[Hand].StockReloadWeapon == None;
    // R20: the shotgun-grip primary's trigger fired the shotgun above.
    if (ShotgunGripRuntime(Hand) == R) EffectiveTrigger = false;
    // A firearm trigger arriving during the axe's block exit must survive
    // that stock cooldown. Retry only while this physical trigger stays held.
    if (EffectiveTrigger && W.Class == class'KFWeap_Rifle_FrostShotgunAxe'
        && (W.IsInState('MeleeBlocking') || W.IsInState('BlockingCooldown')))
    { W.StopFire(1); EffectiveTrigger = false; }
    // VRBrawlerBlast owns the Brawlers' trigger; the stock attack never runs.
    if (class'VRBrawlerBlast'.static.Handles(W)) EffectiveTrigger = false;
    // The free hand pinches/draws the bow string. The riser trigger must not
    // start the desktop charge, including modifier/secondary fire paths.
    if (Bow != None && Bow.Handles(W)) EffectiveTrigger = false;
    if (InputState[Hand].ModeHoldRuntime != None
        && (InputState[Hand].ModeHoldRuntime != R || R.PrimaryHand != Hand || !R.HasModeInputPose()
            || R.OwnershipRevision != InputState[Hand].ModeHoldOwnership
            || Bridge.NativeCalibrationEpoch != InputState[Hand].ModeHoldCalibration
            || Bridge.NativeRoomSpaceEpoch != InputState[Hand].ModeHoldRoomSpace))
        ClearModeHold(Hand);
    if (Lower && !InputState[Hand].bLowerWasDown && InputState[Hand].bLowerArmed
        && !InputState[Hand].bLowerConsumed && !Physical && R.AlternateKind() == 1
        && bTriggerReleased && bPreviousTriggerReleased && R.HasModeInputPose())
    {
        InputState[Hand].ModeHoldRuntime = R;
        InputState[Hand].ModeHoldOwnership = R.OwnershipRevision;
        InputState[Hand].ModeHoldCalibration = Bridge.NativeCalibrationEpoch;
        InputState[Hand].ModeHoldRoomSpace = Bridge.NativeRoomSpaceEpoch;
    }
    if (Lower && InputState[Hand].bLowerArmed && LowerTime[Hand] >= 0.25)
    {
        // A long press never becomes a reload tap, including a rejected mode
        // change. Recovery may finish during this same hold; no request may
        // survive release, a trigger squeeze, input loss or a binding change.
        InputState[Hand].bLowerConsumed = true;
        if (InputState[Hand].ModeHoldRuntime == R && R.CanToggleMode())
        {
            ClearModeHold(Hand);
            // A selector detent needs a distinct mechanical click rather
            // than the lighter generic menu/hand-selection acknowledgement.
            if (R.ToggleMode(InputSample)) Bridge.QueueHandHaptic(1 << Hand, 0.5, 0.045);
        }
    }
    // Releasing the modifier ends secondary fire and requires trigger release.
    if (InputState[Hand].bSecondaryAction && Trigger
        && (!Lower || (!Melee && R.AlternateKind() == 2 && !TriggerEdge)))
    {
        Bridge.Hands[Hand].bTriggerArmed = false;
        EffectiveTrigger = false;
    }
    if (!Melee && R.AlternateKind() >= 2)
    {
        if (Lower && InputState[Hand].bLowerArmed && TriggerEdge && EffectiveTrigger)
        {
            InputState[Hand].bLowerConsumed = true;
            CancelSprint();
            FireMode[Hand] = R.SecondaryFireMode();
            InputState[Hand].bSecondaryAction = true;
            if (Reloads != None && Reloads.BlocksFire(W, true))
            { FireMode[Hand] = -1; Reloads.Pulse(1 << Hand, 0.08, 0.01); }
            else if (Reloads != None && Reloads.AutomaticButtonRequired(W)
                && Reloads.ClassicEmptyTrigger(W, FireMode[Hand]))
            { DispatchReload(R, Hand); FireMode[Hand] = -1; }
            else if (Reloads != None && Reloads.AutomaticButtonRequired(W)
                && Reloads.DryFireInstead(W, FireMode[Hand])) FireMode[Hand] = -1;
            else if (Reloads != None && Reloads.Vampire != None
                && Reloads.Vampire.TryEmptyFire(W, FireMode[Hand])) FireMode[Hand] = -1;
            else if (Reloads != None && Reloads.ServerMagazine != None
                && Reloads.ServerMagazine.TryEmptyFire(W, FireMode[Hand])) FireMode[Hand] = -1;
            else if (VRTrackedWeapon(W) == None) R.StartAction(byte(FireMode[Hand]));
        }
        if (InputState[Hand].bSecondaryAction)
        {
            EffectiveTrigger = EffectiveTrigger && Lower && InputState[Hand].bLowerArmed;
            if (R.AlternateKind() == 2) EffectiveTrigger = EffectiveTrigger && TriggerEdge;
        }
    }
    if (Physical) R.Presenter.PhysicalMelee.SetExplosiveIntent(EffectiveTrigger);
    // Ordinary physical melee owns contact and damage through its swept head;
    // stock DEFAULT/HEAVY attacks pin the desktop animation to the grip. A
    // trigger-charged physical weapon likewise owns its trigger through
    // SetExplosiveIntent. Firearm-melee profiles retain their stock/special
    // routes (Frost Fang, Mosin and Eviscerator included).
    if (!PhysicalMelee && (!Physical || !R.Presenter.PhysicalMelee.bTriggerCharge)
        && EffectiveTrigger && !InputState[Hand].bTriggerWasDown && !InputState[Hand].bSecondaryAction)
    {
        R.SyncStockMode();
        FireMode[Hand] = (R.AlternateKind() == 1 && !R.IsActionToggle()) ? int(R.SelectedMode) : 0;
        if (Melee && Lower && InputState[Hand].bLowerArmed && TriggerEdge)
        {
            // The Frost Fang, Mosin and Bladed Pistol have no heavy attack; their stock bash is the stab.
            FireMode[Hand] = (W.IsA('KFWeap_Rifle_FrostShotgunAxe') || W.IsA('KFWeap_Rifle_MosinNagant')
                || W.IsA('KFWeap_Pistol_Bladed')) ? class'KFWeapon'.const.BASH_FIREMODE : 5;
            InputState[Hand].bLowerConsumed = true;
            InputState[Hand].bSecondaryAction = true;
        }
        else if (W.IsA('KFWeap_Healer_Syringe')
            && VSize(Bridge.PalmPosition(Hand) - (Bridge.HeadPosition - vect(0,0,35))) < 32)
            FireMode[Hand] = 1;
        if (InputState[Hand].bParrying) { W.StopFire(1); InputState[Hand].bParrying = false; }
        // The stock reload must end before its one magazine-out chamber shot.
        if (Reloads != None) Reloads.PrepareMagazineOutFire(W, FireMode[Hand]);
        // Retry only while the physical trigger remains held. Do not send
        // fire across an unacknowledged paired reload cancellation.
        if (Reloads != None && Reloads.HipChamberShotWaiting(W))
        { EffectiveTrigger = false; FireMode[Hand] = -1; }
        // A deployable's trigger is held through the swing and thrown on release.
        else if (FireMode[Hand] == 0 && class'VRDeployableThrow'.static.Handles(W)) Deployables.Begin(Hand, W);
        // The trigger stops a shell reload; the owed cycle still withholds the shot.
        else if (Reloads != None && Reloads.StopShellReloadForCycle(W))
        { FireMode[Hand] = -1; Reloads.Pulse(1 << Hand, 0.08, 0.01); }
        // Manual pump: no shot until the fore-end has been worked. A faint
        // click says the press was heard; release has nothing to stop.
        else if (Reloads != None && Reloads.BlocksFire(W))
        {
            FireMode[Hand] = -1;
            Reloads.Pulse(1 << Hand, 0.08, 0.01);
        }
        // Button style is stock (R33): two different guns held take the
        // button's own automatic reload, exactly as X/A does.
        else if (Reloads != None && Reloads.AutomaticButtonRequired(W)
            && Reloads.ClassicEmptyTrigger(W, FireMode[Hand]))
        { DispatchReload(R, Hand); FireMode[Hand] = -1; }
        // Physical reloads: an empty gun clicks instead of starting the stock
        // automatic reload (X/A or the pouch reloads), or with EMPTY TRIGGER
        // RELOADS on the press is the X/A request itself, hand rules and all.
        else if (Reloads != None && Reloads.DryFireInstead(W, FireMode[Hand])) FireMode[Hand] = -1;
        else if (Reloads != None && Reloads.EmptyTriggerReloads() && Reloads.EmptyTriggerApplies(W, FireMode[Hand]))
        {
            Reloads.PlayDryFire(W, FireMode[Hand]);
            DispatchReload(R, Hand);
            FireMode[Hand] = -1;
        }
        // The button-only Husk Cannon keeps its stock empty-trigger reload in
        // every style (R10, #190) and falls through to StartAction below.
        else if (Reloads != None && Reloads.Enabled() && !Bridge.bEmptyTriggerReloads && !Reloads.UsesPhysicalReload(R)
            && W.Class != class'KFWeap_HuskCannon' && FireMode[Hand] >= 0 && FireMode[Hand] <= 1 && W.GetAmmoType(byte(FireMode[Hand])) == 0
            && !W.HasAmmo(byte(FireMode[Hand])) && W.CanReload())
        { Reloads.PlayDryFire(W, FireMode[Hand]); FireMode[Hand] = -1; }
        // Physical reloads off: an empty split-pair member's automatic reload
        // is the same authority-fenced stock request as its reload button.
        // The authority's fence otherwise refused it in Solo after the first
        // reload while a client still auto-reloaded online.
        else if (Reloads != None && !Reloads.UsesPhysicalReload(R)
            && class'VRInteractiveReload'.static.PairedAuthorityNeeded(W)
            && FireMode[Hand] >= 0 && FireMode[Hand] <= 1 && W.GetAmmoType(byte(FireMode[Hand])) == 0
            && !W.HasAmmo(byte(FireMode[Hand])) && W.CanReload() && class'VRWeaponRuntime'.static.StockIdle(W))
        {
            if (W.WeaponDryFireSnd.Length > 0) W.WeaponPlaySound(W.WeaponDryFireSnd[0]);
            TryStockPairedReload(R, Hand);
            FireMode[Hand] = -1;
        }
        else if (VRTrackedWeapon(W) == None) R.StartAction(byte(FireMode[Hand]));
    }
    if (!EffectiveTrigger && InputState[Hand].bTriggerWasDown)
    {
        if (Deployables.IsHeld(Hand)) Deployables.Release(Hand);
        if (VRTrackedWeapon(W) == None && FireMode[Hand] >= 0 && !(Bow != None && Bow.Handles(W))) W.StopFire(byte(FireMode[Hand]));
        FireMode[Hand] = -1;
        InputState[Hand].bSecondaryAction = false;
    }
    // A secondary action lasts one trigger pull. A pull the modifier gate
    // swallowed never set bTriggerWasDown, so without this the latch stayed on
    // and ate every later pull of an X/A+trigger gun (#145).
    if (!Trigger) InputState[Hand].bSecondaryAction = false;
    // The mode is latched at the trigger edge: releasing a modifier while
    // holding the trigger never starts an unexpected second action.
    WantParry = Melee && (!Physical || R.Presenter.PhysicalMelee.bButtonGuard) && Lower && InputState[Hand].bLowerArmed && !Trigger;
    // A loaded gauntlet (Blast Brawlers) reloads on the X/A tap; only a hold
    // past the tap window raises its guard (#82).
    if (WantParry && !InputState[Hand].bParrying && W.UsesAmmo() && LowerTime[Hand] < 0.25) WantParry = false;
    if (WantParry != InputState[Hand].bParrying)
    {
        if (WantParry) { R.StartAction(1); class'VRMeleeControls'.static.OpenButtonParry(Bridge, W, Hand); }
        else W.StopFire(1);
        InputState[Hand].bParrying = WantParry;
    }
    if (WantParry) InputState[Hand].bLowerConsumed = true;
    // Stock Ion Thruster maps reload to its charged ultimate. Preserve that
    // deliberate action while ordinary light/heavy cuts remain physical.
    Reload = (!Melee || W.UsesAmmo() || KFWeap_Edged_IonThruster(W) != None)
        && !Lower && InputState[Hand].bLowerWasDown && InputState[Hand].bLowerArmed
        && !InputState[Hand].bLowerConsumed && LowerTime[Hand] < 0.25;
    if (Bow != None && Bow.Handles(W) && Bow.Phase != 0) Reload = false;
    Reload = ResolveReloadTap(R, Hand, Reload, Lower);
    bReloadWasRunning = Bridge.PC.bRun != 0 && !EffectiveTrigger;
    if ((EffectiveTrigger && !InputState[Hand].bTriggerWasDown) || WantParry) CancelSprint();
    UpdateAuthoredReload(R, Hand);
    if (VRTrackedWeapon(W) != None) UpdateTrackedItem(R, Hand, EffectiveTrigger, Reload);
    else if (Reload) DispatchReload(R, Hand);
    if (Reload)
    {
        // Preflight now so a button reload preserves sprint only after the
        // physical path actually accepts it; rejected/alt/dual reloads pause.
        if (Reloads != None && Reloads.EnabledFor(W) && !Reloads.bActive
            && W != Reloads.RejectedGun && W != Reloads.HandoffGun
            && Reloads.Supported(W) && Reloads.MagazineReloading(W))
        {
            // Stock accepted this press. End its pulse before preflight can
            // complete or reject the physical session and reenter Active.
            if (InputState[Hand].bReloadPulse)
            { W.StopFire(2); InputState[Hand].bReloadPulse = false; }
            Reloads.Begin(R, Hand);
        }
        if (Reloads != None && Reloads.AllowsSprint(W))
        {
            // Stock WeaponSprinting.BeginFire can stop the pawn while it
            // starts the reload. Restore the existing run request immediately.
            if (bReloadWasRunning)
            { Bridge.PC.bRun = 1; Inventory.SetSprinting(true); }
        }
        else CancelSprint();
    }
    InputState[Hand].bTriggerWasDown = EffectiveTrigger;
    InputState[Hand].bLowerWasDown = Lower;
    Bridge.Hands[Hand].bTrigger = EffectiveTrigger;
}

function ClearReloadTap(int Hand)
{
    InputState[Hand].ReloadTapRuntime = None;
    InputState[Hand].ReloadTapWeapon = None;
    InputState[Hand].ReloadTapDeadline = 0;
    InputState[Hand].bReloadSecondPress = false;
}

// Both carrying roles use the same reload admission and stock payment paths.
function DispatchReload(VRWeaponRuntime R, int Hand)
{
    // Names the pressing controller and the gun it reloads, so a reported
    // cross-hand press can be read from the session log.
    if (R != None && R.Item != None)
        `log("KF2VR_RELOAD_PRESS hand=" $ Hand @ "button=" $ (Hand == 0 ? "X" : "A") @ "weapon=" $ R.Item.Class
            @ "primary=" $ R.PrimaryHand @ "support=" $ R.SupportHand @ "ammo=" $ R.Item.AmmoCount[0]
            @ "session=" $ ((Reloads != None && Reloads.bActive) ? string(Reloads.Gun.Class) : "none"));
    if (Reloads != None && Reloads.TryAutomaticReload(R, Hand)) return;
    if (!QueueAuthoredReload(R, Hand) && (Reloads == None
        || ((Reloads.Brawlers == None || !Reloads.Brawlers.TryBegin(R, Hand))
            && (Reloads.Vampire == None || !Reloads.Vampire.TryBegin(R, Hand))
            && (Reloads.ServerMagazine == None || !Reloads.ServerMagazine.TryBegin(R, Hand,, true))
            && !Reloads.TryRecoveredMagazineEject(R, Hand)
            && !Reloads.TryConfiguredMagazineEject(R, Hand)
            && !Reloads.TryDualCylinder(R, Hand)
            && !Reloads.TryPairedMagazineReload(R, Hand)
            && !Reloads.TryBreakAction(R, Hand) && !Reloads.TrySlideRelease(R, Hand))))
    {
        // No hand free (Kvasir94, 2026-10-28, replacing the 10-22 magazine
        // drop): the button performs the complete automatic stock reload,
        // paid once, through the same explicit owner two carried guns use.
        // A gun with a hip reload never takes this fallback: if its hip
        // reload (offered above) cannot start yet, the press waits and the
        // next one retries. Pair members keep their paired authority fence.
        if (Reloads != None && Reloads.UsesPhysicalReload(R) && Reloads.NoFreeHand(R)
            && !Reloads.HasHipReload(R)
            && !class'VRInteractiveReload'.static.PairedAuthorityNeeded(R.Item)
            && !Reloads.bActive && Reloads.CylinderAuthorityGun == None
            && Reloads.TryAutomaticReload(R, Hand,, true)) return;
        // A busy/rejected physical path consumes this press. Ordinary
        // free-hand physical reloads still enter stock for their preflight.
        // An alt-only stock reload needs no physical off-hand; preserve the
        // active-session guards and let stock BeginFire choose its ammo slot.
        if (!(Reloads != None && Reloads.UsesPhysicalReload(R)
            && ((Reloads.HandBusy(1 - Hand) && !R.CanStartStockSecondaryReload()
                    && !Reloads.BusyShellStockReload(R))
                || Reloads.bActive || Reloads.CylinderAuthorityGun != None))
            && !TryStockPairedReload(R, Hand))
        {
            // The stock alt reload this admits must reach the stock body.
            if (Reloads != None && Reloads.Secondary != None && Reloads.UsesPhysicalReload(R)
                && Reloads.HandBusy(1 - Hand) && R.CanStartStockSecondaryReload())
                Reloads.Secondary.StockFallbackGun = R.Item;
            R.StartAction(2, Reloads != None && Reloads.HandBusy(1 - Hand));
            if (Reloads != None && Reloads.Secondary != None) Reloads.Secondary.StockFallbackGun = None;
            InputState[Hand].bReloadPulse = true;
        }
    }
}

// A deferred single tap re-enters the existing primary reload path. A second
// tap consumes the pending request before asking slot one to begin, so even a
// rejected secondary request cannot eject or reset the primary magazine.
function bool ResolveReloadTap(VRWeaponRuntime R, int Hand, bool bTap, bool bLower)
{
    local float Now;
    if (Reloads == None || Reloads.Secondary == None || !Reloads.Enabled()
        || R == None || !class'VRSecondaryReloadCatalog'.static.Supported(R.Item))
    { ClearReloadTap(Hand); return bTap; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (InputState[Hand].ReloadTapWeapon != None
        && (InputState[Hand].ReloadTapRuntime != R || InputState[Hand].ReloadTapWeapon != R.Item
            || !R.IsCurrent() || Inventory.GetHeldForHand(Hand) != R
            || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0
            || R.OwnershipRevision != InputState[Hand].ReloadTapOwnership
            || Bridge.NativeCalibrationEpoch != InputState[Hand].ReloadTapCalibration
            || Bridge.NativeRoomSpaceEpoch != InputState[Hand].ReloadTapRoomSpace))
        ClearReloadTap(Hand);
    // A held modifier/trigger or long press owns its own gesture.
    if (bLower && InputState[Hand].bLowerConsumed) ClearReloadTap(Hand);
    if (InputState[Hand].ReloadTapWeapon != None)
    {
        // The second press owns the decision once it begins in the window.
        // Its short release can follow the first tap's deadline without the
        // intervening held samples starting a primary reload.
        if (bLower && !InputState[Hand].bLowerWasDown && InputState[Hand].bLowerArmed
            && !InputState[Hand].bLowerConsumed && Now <= InputState[Hand].ReloadTapDeadline)
            InputState[Hand].bReloadSecondPress = true;
        if (bTap && (InputState[Hand].bReloadSecondPress || Now <= InputState[Hand].ReloadTapDeadline))
        {
            ClearReloadTap(Hand);
            if (!Reloads.TryAutomaticReload(R, Hand, true)
                && !Reloads.Secondary.TryBegin(R, Hand)) Reloads.Pulse(1 << Hand, 0.08, 0.01);
            return false;
        }
        if (InputState[Hand].bReloadSecondPress && !bLower)
        { ClearReloadTap(Hand); return false; }
        if (!InputState[Hand].bReloadSecondPress && Now >= InputState[Hand].ReloadTapDeadline)
        { ClearReloadTap(Hand); return true; }
    }
    if (bTap)
    {
        InputState[Hand].ReloadTapRuntime = R;
        InputState[Hand].ReloadTapWeapon = R.Item;
        InputState[Hand].ReloadTapOwnership = R.OwnershipRevision;
        InputState[Hand].ReloadTapCalibration = Bridge.NativeCalibrationEpoch;
        InputState[Hand].ReloadTapRoomSpace = Bridge.NativeRoomSpaceEpoch;
        InputState[Hand].ReloadTapDeadline = Now + RELOAD_DOUBLE_TAP_SECONDS;
    }
    return false;
}

// Stock paired fallbacks also use the authority fence: an issued physical
// transaction must never be bypassed by a later ordinary reload RPC.
function bool TryStockPairedReload(VRWeaponRuntime R, int Hand)
{
    local int Request;
    local VRWeaponPair Pair;
    if (R == None || !class'VRInteractiveReload'.static.PairedAuthorityNeeded(R.Item)) return false;
    if (InputState[Hand].StockReloadWeapon != None) return true;
    if (Reloads != None && Reloads.UsesPhysicalReload(R))
    {
        // Failed hip/authority admission never requests bStock. Only retire
        // an unowned, unpaid automatic stock entry; keep accepted physical
        // sessions and already credited ammunition with their current owner.
        if (!(Reloads.bActive && Reloads.Gun == R.Item) && !Reloads.DualCylinderOwns(R.Item)
            && Reloads.CylinderAuthorityGun != R.Item && Reloads.HandoffGun != R.Item
            && (Reloads.Mechanism == None || !Reloads.Mechanism.HoldsPose(R.Item))
            && (Reloads.Vampire == None || !Reloads.Vampire.HoldsPose(R.Item))
            && class'VRInteractiveReload'.static.MagazineReloading(R.Item)
            && R.Item.ReloadAmountLeft == R.Item.InitialReloadAmount)
        {
            R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
            R.Item.ClearTimer('ReloadAmmoTimer'); R.Item.ClearTimer('ReloadStatusTimer');
            R.Item.AbortReload();
        }
        return true;
    }
    Pair = class'VRWeaponPair'.static.ForMember(R.Item);
    if (Pair == None || !Pair.IsMember(R.Item) || !ContextValid() || !Bridge.PairedReloadAvailable()
        || !R.IsCurrent() || R.PrimaryHand != Hand || Inventory.Registry.GetPrimary(Hand) != R
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0
        || (Reloads != None && (Reloads.DualCylinderOwns(R.Item) || Reloads.HoldsPose(R.Item)))) return true;
    Request = Bridge.PairedReloadBegin(R.Item, Hand, true, Reloads != None && Reloads.Realistic());
    if (Request <= 0) return true;
    R.Item.StopFire(0); R.Item.StopFire(1);
    InputState[Hand].StockReloadRuntime = R;
    InputState[Hand].StockReloadWeapon = R.Item;
    InputState[Hand].StockReloadOwnership = R.OwnershipRevision;
    InputState[Hand].StockReloadRequest = Request;
    InputState[Hand].StockReloadSession = 0;
    InputState[Hand].StockReloadCalibration = Bridge.NativeCalibrationEpoch;
    InputState[Hand].bStockReloadInteractive = Bridge.bInteractiveReloads;
    InputState[Hand].bStockReloadStarted = false;
    InputState[Hand].StockReloadDeadline = Bridge.WorldInfo.RealTimeSeconds + 5;
    return true;
}

function ClearStockPairedReload(int Hand, bool bCancel)
{
    local KFWeapon W;
    W = InputState[Hand].StockReloadWeapon;
    if (W != None) InputState[Hand].StockReloadFinishedWeapon = W;
    if (W != None && bCancel)
    {
        if (Bridge != None) Bridge.PairedReloadCancel(W, InputState[Hand].StockReloadRequest, InputState[Hand].StockReloadSession);
        if (!W.bDeleteMe && W.IsInState('Reloading')) W.AbortReload();
    }
    InputState[Hand].StockReloadWeapon = None;
    InputState[Hand].StockReloadRuntime = None;
    InputState[Hand].StockReloadRequest = 0;
    InputState[Hand].StockReloadSession = 0;
    InputState[Hand].bStockReloadStarted = false;
    InputState[Hand].StockReloadDeadline = 0;
}

function UpdateStockPairedReloads()
{
    local int Hand, Session, Ammo, Reserve;
    local byte Status;
    local KFWeapon W;
    local VRWeaponRuntime R;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        W = InputState[Hand].StockReloadWeapon;
        R = InputState[Hand].StockReloadRuntime;
        if (W != None)
        {
            if (W.bDeleteMe || R == None || R.Item != W || !R.IsCurrent() || R.PrimaryHand != Hand
                || Inventory.Registry.GetPrimary(Hand) != R || R.OwnershipRevision != InputState[Hand].StockReloadOwnership
                || !ContextValid() || !Bridge.PairedReloadAvailable() || IsSelectorOpen(Hand)
                || Bridge.NativeCalibrationEpoch != InputState[Hand].StockReloadCalibration
                || Bridge.bInteractiveReloads != InputState[Hand].bStockReloadInteractive
                || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0
                || Bridge.WorldInfo.RealTimeSeconds >= InputState[Hand].StockReloadDeadline)
            { ClearStockPairedReload(Hand, true); continue; }
            Session = 0; Status = 0;
            if (Bridge.PairedReloadRead(W, InputState[Hand].StockReloadRequest, Session, Status, Ammo, Reserve))
            {
                InputState[Hand].StockReloadSession = Session;
                // Status and weapon ammo replicate independently. Keep the
                // fire gate until the authoritative magazine has arrived.
                if ((Status == 2 && W.AmmoCount[0] == Ammo) || Status == 3)
                { ClearStockPairedReload(Hand, Status == 3); continue; }
                if (Status == 4 && !InputState[Hand].bStockReloadStarted
                    && (class'VRWeaponRuntime'.static.StockIdle(W) || W.IsInState('Reloading')))
                {
                    InputState[Hand].bStockReloadStarted = true;
                    InputState[Hand].StockReloadDeadline = Bridge.WorldInfo.RealTimeSeconds + 50;
                    // The server already owns stock timers and ammo. This
                    // pulse starts only the matching local presentation.
                    if (class'VRWeaponRuntime'.static.StockIdle(W)) { R.StartAction(2); InputState[Hand].bReloadPulse = true; }
                }
            }
            continue;
        }
        // Automatic stock reloads need the same fence when no physical
        // mechanism owns this member. Never adopt an active physical pose.
        R = Inventory.Registry.GetPrimary(Hand);
        if (InputState[Hand].StockReloadFinishedWeapon != None
            && (InputState[Hand].StockReloadFinishedWeapon.bDeleteMe
                || !InputState[Hand].StockReloadFinishedWeapon.IsInState('Reloading')))
            InputState[Hand].StockReloadFinishedWeapon = None;
        if (R != None && R.IsCurrent() && class'VRInteractiveReload'.static.PairedAuthorityNeeded(R.Item)
            && R.Item != InputState[Hand].StockReloadFinishedWeapon
            && class'VRInteractiveReload'.static.MagazineReloading(R.Item)
            && (Reloads == None || (!Reloads.DualCylinderOwns(R.Item) && !Reloads.HoldsPose(R.Item))))
            TryStockPairedReload(R, Hand);
    }
}

// Deadbolt's authored forge is a button reload in either global setting. A
// tap during its single-shot interval cannot be a one-frame PendingFire: the
// ordinary pulse clears that before Active. Retain only explicit intent;
// stock InitializeReload/PerformReload remain the ammunition authority.
function bool QueueAuthoredReload(VRWeaponRuntime R, int Hand)
{
    if (R == None || R.Item == None || !R.Item.IsA('BreacherDeadbolt')
        || !R.IsCurrent() || R.PrimaryHand != Hand
        || !R.Item.IsInState('WeaponSingleFiring') || !R.Item.CanReload()) return false;
    if (InputState[Hand].AuthoredReloadWeapon != R.Item)
    {
        InputState[Hand].AuthoredReloadWeapon = R.Item;
        InputState[Hand].AuthoredReloadOwnership = R.OwnershipRevision;
        // World time follows stock's fire timer, including Zed Time.
        InputState[Hand].AuthoredReloadDeadline = Bridge.WorldInfo.TimeSeconds + 1.5;
    }
    return true;
}

function UpdateAuthoredReload(VRWeaponRuntime R, int Hand)
{
    local KFWeapon W;
    W = InputState[Hand].AuthoredReloadWeapon;
    if (W == None) return;
    if (W.bDeleteMe || R == None || R.Item != W || !R.IsCurrent() || R.PrimaryHand != Hand
        || R.OwnershipRevision != InputState[Hand].AuthoredReloadOwnership
        || Bridge.WorldInfo.TimeSeconds > InputState[Hand].AuthoredReloadDeadline
        || (!class'VRWeaponRuntime'.static.StockIdle(W) && !W.IsInState('WeaponSingleFiring')))
    { InputState[Hand].AuthoredReloadWeapon = None; return; }
    if (!class'VRWeaponRuntime'.static.StockIdle(W)) return;
    InputState[Hand].AuthoredReloadWeapon = None;
    if (!R.CanStartReload()) return;
    CancelSprint();
    R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
    W.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
}

// Legacy tracked tools receive an item-local presentation context and action
// intent. Physical carry grip is restored immediately; it never becomes a
// continuously held secondary action merely because the player carries a tool.
function UpdateTrackedItem(VRWeaponRuntime R, int Hand, bool Trigger, bool Reload)
{
    local VRHandsBridge P;
    local bool SavedGrip, SavedGripArmed, SavedTrigger, SavedTriggerArmed;
    local int SavedTriggerMask, SavedButtons, SavedPrevious;
    P = R.Presenter;
    SavedGrip = P.Hands[Hand].bGrip;
    SavedGripArmed = P.Hands[Hand].bGripArmed;
    SavedTrigger = P.Hands[Hand].bTrigger;
    SavedTriggerArmed = P.Hands[Hand].bTriggerArmed;
    SavedTriggerMask = P.NativeTriggerMask;
    SavedButtons = P.NativeButtonMask;
    SavedPrevious = P.PreviousButtons;
    P.Hands[Hand].bGrip = Trigger && FireMode[Hand] == 1;
    P.Hands[Hand].bGripArmed = Bridge.Hands[Hand].bTriggerArmed;
    P.Hands[Hand].bTriggerArmed = Bridge.Hands[Hand].bTriggerArmed;
    P.NativeTriggerMask = (Trigger && FireMode[Hand] == 0) ? (1 << Hand) : 0;
    P.NativeButtonMask = Reload ? 1 : 0;
    P.PreviousButtons = PreviousToolButtons[Hand];
    VRTrackedWeapon(R.Item).UpdateTrackedInput(P);
    PreviousToolButtons[Hand] = Reload ? 1 : 0;
    P.Hands[Hand].bGrip = SavedGrip;
    P.Hands[Hand].bGripArmed = SavedGripArmed;
    P.Hands[Hand].bTrigger = SavedTrigger;
    P.Hands[Hand].bTriggerArmed = SavedTriggerArmed;
    P.NativeTriggerMask = SavedTriggerMask;
    P.NativeButtonMask = SavedButtons;
    P.PreviousButtons = SavedPrevious;
}

// Actor/material/texture creation is confined to the input game tick. The
// native late-placement callback may only position already-created surfaces.
function EnsureSelectors()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (ContextValid() && InputState[Hand].bSelectorOpen && Selectors[Hand] == None
            && !InputState[Hand].bSelectorInitAttempted && (Bridge.NativeValidMask & (1 << Hand)) != 0)
        {
            InputState[Hand].bSelectorInitAttempted = true;
            Selectors[Hand] = Bridge.Spawn(class'VRHandSelector', Bridge);
            if (Selectors[Hand] != None && !Selectors[Hand].InitializeSelector(self, Hand))
            {
                Selectors[Hand].Destroy();
                Selectors[Hand] = None;
            }
        }
    }
}

function UpdateEmptyInteraction()
{
    local int Hand, WantedMask;
    local bool bWanted;
    for (Hand = 0; Hand < 2; ++Hand)
        if (!IsSelectorOpen(0) && !IsSelectorOpen(1) && !HandCarrying(Hand)
            && !Inventory.IsTransferPending(Hand) && Inventory.Registry.GetPrimary(Hand) == None
            && Inventory.Registry.GetSupport(Hand) == None && Bridge.Hands[Hand].bTriggerArmed
            && (Reloads == None || !Reloads.OwnsHand(Hand))
            && (Bridge.NativeValidMask & Bridge.NativeTriggerActiveMask & Bridge.NativeTriggerMask & (1 << Hand)) != 0
            // A clenched fist's trigger charges a punch. It is not a use
            // press, whose stock hold also auto-buys at the trader and welds.
            // The same clench test as the charge, analog squeeze included, or
            // a partial squeeze would both charge and press use.
            && (Inventory.FistCharge == None || !Inventory.FistCharge.IsFistClosed(Hand)))
            WantedMask = WantedMask | (1 << Hand);
    bWanted = WantedMask != 0;
    if (bWanted != bInteracting && KFPlayerInput(Bridge.PC.PlayerInput) != None)
    {
        if (bWanted) KFPlayerInput(Bridge.PC.PlayerInput).Interact();
        else if ((Bridge.NativeValidMask & Bridge.NativeTriggerActiveMask & InteractHands) == InteractHands
            && (Bridge.NativeTriggerMask & InteractHands) == 0)
            KFPlayerInput(Bridge.PC.PlayerInput).InteractRelease();
        else Bridge.WorldInfo.TimerHelper.ClearTimer('InteractTimer', Bridge.PC.PlayerInput);
    }
    InteractHands = bWanted ? (InteractHands | WantedMask) : 0;
    bInteracting = bWanted;
}

// This method contains presentation only and may also run at late placement.
function PlaceSelectors()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Selectors[Hand] == None) continue;
        // A closed wheel keeps placing itself while it collapses into the hand.
        if (!ContextValid() || (Bridge.NativeValidMask & (1 << Hand)) == 0
            || (!InputState[Hand].bSelectorOpen && !Selectors[Hand].Collapsing()))
            Selectors[Hand].HideSelector();
        else Selectors[Hand].PlaceSelector();
    }
}

function DestroySelectors()
{
    local int Hand;
    Cancel();
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Selectors[Hand] != None) Selectors[Hand].Destroy();
        Selectors[Hand] = None;
        LastWeapon[Hand] = None;
    }
    if (Teleport != None) { Teleport.Shutdown(); Teleport = None; }
    if (Wallet != None) { Wallet.Shutdown(); Wallet = None; }
    if (Deployables != None) { Deployables.Shutdown(); Deployables = None; }
    Brawler = None;
    if (Welding != None) { Welding.Shutdown(); Welding = None; }
    if (Reloads != None) { Reloads.Shutdown(); Reloads = None; }
    if (Pouch != None) { Pouch.Shutdown(); Pouch = None; }
    Inventory = None;
    Bridge = None;
    bInitialized = false;
}
