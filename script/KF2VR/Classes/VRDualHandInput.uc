// Physical input becomes explicit hand/item commands here. Inventory ownership
// is committed by VRHandInventory, so this layer can later submit the same
// requests to an authority without making controller side an item identity.
// X/A tap reloads; hold modifies fire. Y/B selects or quick-swaps inventory,
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
};

var VRHandInventory Inventory;
var VRHandsBridge Bridge;
var VRHandSelector Selectors[2];
var VRDualHandState InputState[2];
var string SelectionMessage[2];
var KFWeapon LastWeapon[2];
var float UpperTime[2], LowerTime[2], UpperTapDeadline[2];
var float LastInputTime;
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
var VRDeployableHold Deployables;
var VRDoorWelding Welding;
var VRInteractiveReload Reloads;
var int NativeFocusRequested;
var float SprintResumeTime;
// Raw turn-stick deflection that counts as the outer rim for a jump.
const JumpRimMagnitude = 0.95;

// A tap waits briefly before it swaps, so a second tap can deliberately open
// the hand instead of swapping once and then immediately stowing the result.
const UPPER_HOLD_SECONDS = 0.25;
const UPPER_DOUBLE_TAP_SECONDS = 0.24;

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
    return (Grenade != None && Grenade.IsHeld(Hand)) || (Wallet != None && Wallet.IsBusy(Hand));
}

// A hand beside the head, not in front of the face, so a pistol raised to the
// eye never counts. Y/B pressed here is the head lamp, for any weapon.
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
    Accepted = Inventory.Draw(Hand, Target);
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
    local KFWeapon W, Syringe;
    if (Hand < 0 || Hand > 1 || !ContextValid()) return false;
    if (Inventory.OpenGauntletOffhand(Hand))
    {
        ModeFeedback(Hand, true);
        return true;
    }
    if (Inventory.Registry.GetPrimary(Hand) == None && Inventory.Registry.GetSupport(Hand) == None)
    {
        foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
            if (Syringe == None && W.IsA('KFWeap_Healer_Syringe') && Inventory.Registry.IsOwned(W)) Syringe = W;
        Accepted = Syringe != None && Inventory.Draw(Hand, Syringe);
        ModeFeedback(Hand, Accepted);
        if (Accepted) { CancelSprint(); RefreshWeapon(Hand); }
        return Accepted;
    }
    Accepted = Inventory.ReleaseHand(Hand);
    ModeFeedback(Hand, Accepted);
    if (Accepted) { CancelSprint(); RefreshWeapon(Hand); }
    return Accepted;
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
    Welding = new(self) class'VRDoorWelding';
    Welding.Initialize(self);
    Reloads = new(self) class'VRInteractiveReload';
    Reloads.Initialize(self);
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

function StopWeapon(int Hand)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    W = LastWeapon[Hand];
    if (W != None && !W.bDeleteMe && Inventory != None && Inventory.Registry != None
        && Inventory.Registry.IsOwned(W))
    {
        R = Inventory.Registry.FindItem(W);
        if (R != None) Inventory.StopItem(R);
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
    if (bInteracting && Bridge != None && Bridge.PC != None && KFPlayerInput(Bridge.PC.PlayerInput) != None)
        Bridge.WorldInfo.TimerHelper.ClearTimer('InteractTimer', Bridge.PC.PlayerInput);
    bInteracting = false;
    InteractHands = 0;
    CancelHand(0);
    CancelHand(1);
    EndSprint();
    if (Welding != None) Welding.Cancel();
    NativeFocusRequested = 0;
    if (Teleport != None) Teleport.Cancel();
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

function DisarmDrawInputs(int Hand)
{
    // A draw and a new squeeze may share one sample. Consume that squeeze so
    // UpdateHand cannot immediately toggle the just-drawn weapon back off.
    InputState[Hand].bGripWasDown = (Bridge.NativeGripMask & (1 << Hand)) != 0;
    if (InputState[Hand].bGripWasDown) Bridge.Hands[Hand].bGripArmed = false;
    Bridge.Hands[Hand].bTriggerArmed = false;
    InputState[Hand].bUpperArmed = false;
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
    Grenade.Update(InputDelta);
    if (Tomahawks != None) Tomahawks.Update(InputDelta);
    if (Wallet != None) Wallet.Update(InputDelta);
    Deployables.Update(InputDelta);
    // Ahead of the hands: a reload that takes the off hand this frame must own
    // it before UpdateHand reads its trigger as a use press.
    Reloads.Update(InputDelta);
    UpdateLocomotion(InputDelta);
    // Selector gestures follow real time, including during KF2 Zed Time.
    for (Hand = 0; Hand < 2; ++Hand) UpdateHand(Hand, InputDelta);
    UpdateEmptyInteraction();
    if (Pouch != None) Pouch.Update(InputDelta);
    Welding.Update(InputDelta);
    EnsureSelectors();
    PlaceSelectors();
    Bridge.CalibrationPanel.Update();
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
    // Start neutral each frame. A selector consumes only the stick that owns
    // it; the other hand keeps its ordinary move/turn role.
    Bridge.NativeMoveX = 0;
    Bridge.NativeMoveY = 0;
    Bridge.NativeTurnX = 0;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        if (IsSelectorOpen(Hand))
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
                // Reserve a narrow +/-10 degree cone around straight up for
                // jump, including the push toward the rim. Keep turn neutral
                // there without enlarging the centre deadzone.
                if (Y <= 0 || Abs(X) > Y * 0.176327)
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
                    && Abs(Y) >= Magnitude * 0.85 && Abs(Y) > Abs(X))
                {
                    if (Y < 0) { if (Bridge.bStickCrouch) PhysicalCrouch.ToggleButtonCrouch(Bridge); }
                    else if (PhysicalCrouch.bButtonCrouch) PhysicalCrouch.StandUp(Bridge);
                    else Bridge.PC.PlayerInput.Jump();
                    InputState[Hand].bVerticalArmed = false;
                }
            }
        }
    }
    // The non-movement click offers the welder. The movement click belongs to
    // sprint/cancel in either handedness; it cannot also equip a tool.
    Hand = 1 - MoveHand;
    Bit = 1 << Hand;
    if ((Bridge.NativeValidMask & Bridge.NativeStickClickActiveMask & Bridge.NativeStickClickMask & Bit) != 0
        && !InputState[Hand].bStickWasDown && InputState[Hand].bStickArmed
        && !IsSelectorOpen(0) && !IsSelectorOpen(1)) Welding.StickClick();
    if (bTeleportMode)
    {
        // VRTeleportLocomotion reads the movement stick directly. Do not let a
        // latched wheel on that hand preview, buffer or commit a teleport.
        if (IsSelectorOpen(MoveHand))
        {
            Teleport.ClearBuffer();
            if (Teleport.Phase == 0) Teleport.Cancel();
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
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (1 << Hand);
    Bridge.NativeHapticStrength = Accepted ? 0.25 : 0.08;
    Bridge.NativeHapticDuration = Accepted ? 0.035 : 0.08;
}

// The stock item a hand would throw: what it holds, if stock lets it go
// (bCanThrow: not the knife, 9mm backup, welder, or a VR pair member).
function KFWeapon DroppableWeapon(int Hand)
{
    local VRWeaponRuntime R;
    R = Inventory.Registry.GetPrimary(Hand);
    if (R == None || R.Item == None || R.Item.bDeleteMe || !R.IsCurrent()) return None;
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
    StopWeapon(Hand);
    Bridge.Hands[Hand].bTriggerArmed = false;
    Bridge.PC.ServerThrowOtherWeapon(W);
    return true;
}

function UpdateSelection(float DeltaTime)
{
    local int Hand, Bit, UpperBit;
    local bool Upper, Edge;
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
            if (UpperTime[Hand] >= UPPER_HOLD_SECONDS)
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
            TriggerValue = Hand == 0 ? Bridge.LeftTriggerValue : Bridge.RightTriggerValue;
            // Pointing moves the wheel cursor, so an armed squeeze holds it
            // before the pull itself can tip the controller to a neighbour.
            if (!InputState[Hand].bSelectorConfirmPending)
                Selectors[Hand].ReadSelection(InputState[Hand].bSelectorTriggerArmed && TriggerValue > 0.3);
            if ((Bridge.NativeTriggerActiveMask & Bit) == 0 || TriggerValue != TriggerValue
                || TriggerValue < 0 || TriggerValue > 1)
            {
                InputState[Hand].bSelectorTriggerArmed = false;
                InputState[Hand].bSelectorConfirmPending = false;
            }
            else if (TriggerValue <= 0.1 && (Bridge.NativeTriggerMask & Bit) == 0)
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
            else if (TriggerValue >= 0.55 && InputState[Hand].bSelectorTriggerArmed)
            {
                InputState[Hand].bSelectorTriggerArmed = false;
                InputState[Hand].bSelectorConfirmPending = true;
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
    local bool HadSelector, TriggerEdge, Stick, OwnershipCommand;
    local bool Physical, bReloadWasRunning;
    local KFWeapon W;
    local VRWeaponRuntime R;
    Bit = 1 << Hand;
    LowerBit = Hand == 0 ? 1 : 8; // X / A
    UpperBit = Hand == 0 ? 2 : 4; // Y / B
    RefreshWeapon(Hand);
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
    TriggerEdge = Trigger && !InputState[Hand].bPhysicalTriggerWasDown;
    InputState[Hand].bPhysicalTriggerWasDown = Trigger;
    Lower = (Buttons & ActiveButtons & LowerBit) != 0;
    Upper = (Buttons & ActiveButtons & UpperBit) != 0;
    Stick = (Bridge.NativeStickClickMask & Bridge.NativeStickClickActiveMask & Bit) != 0;
    InputState[Hand].bStickWasDown = Stick;
    if ((Bridge.NativeStickClickActiveMask & Bit) == 0) InputState[Hand].bStickArmed = false;
    else if (!Stick) InputState[Hand].bStickArmed = true;
    if (GripReleased(Hand))
        Bridge.Hands[Hand].bGripArmed = true;
    if ((Bridge.NativeTriggerActiveMask & Bit) == 0) Bridge.Hands[Hand].bTriggerArmed = false;
    else if (!Trigger && (Hand == 0 ? Bridge.LeftTriggerValue : Bridge.RightTriggerValue) <= 0.1)
        Bridge.Hands[Hand].bTriggerArmed = true;
    if ((ActiveButtons & LowerBit) == 0)
    {
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

    HadSelector = InputState[Hand].bSelectorOpen;
    if (Lower && !InputState[Hand].bLowerWasDown && InputState[Hand].bLowerArmed)
    {
        LowerTime[Hand] = 0;
        InputState[Hand].bLowerConsumed = HadSelector;
    }
    if (Lower && InputState[Hand].bLowerWasDown) LowerTime[Hand] += DeltaTime;
    GripEdge = Grip && !InputState[Hand].bGripWasDown && Bridge.Hands[Hand].bGripArmed;
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
    if (GripEdge && !HadSelector)
    {
        if (Inventory.Registry.GetSupport(Hand) != None && !Bridge.bHoldSupportGrip)
        {
            Inventory.ReleaseHand(Hand);
            OwnershipCommand = true;
        }
        else
        {
            OwnershipCommand = true;
            // An authored support contact takes priority when the weapon is
            // close enough to overlap the chest grenade zone.
            if (!Inventory.TryGrab(Hand)
                && (Wallet == None || BodySlotNearer(Hand, Wallet.PocketPosition(Hand), Wallet.PocketRadius) || !Wallet.TryGrab(Hand))
                && (Pouch == None || (Grenade != None && Grenade.PrefersOver(Hand, Pouch.PouchPosition())) || !Pouch.TryGrab(Hand))
                && !TryBodyAnchor(Hand)) Grenade.TryGrab(Hand);
        }
    }
    if (GripReleased(Hand) && !HadSelector && Inventory.Registry.GetSupport(Hand) != None && Bridge.bHoldSupportGrip)
    {
        Inventory.ReleaseHand(Hand);
        OwnershipCommand = true;
    }
    Bridge.Hands[Hand].bGrip = Grip || Inventory.Registry.GetPrimary(Hand) != None;
    // Binding invalidates the affected pose. Publish both items again before
    // either hand can fire, including support acquired by the other hand.
    if (OwnershipCommand) Inventory.PlaceAll();
    RefreshWeapon(Hand);
    InputState[Hand].bGripWasDown = Grip;
    if (Inventory.IsTransferPending(Hand))
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
    R = Inventory.Registry.GetPrimary(Hand);
    if (R == None) R = Inventory.Registry.GetSupport(Hand);
    R = Inventory.Registry.GetPrimary(Hand);
    W = LastWeapon[Hand];
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
        && !R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].bFirearm
        // The default Brawlers trigger is the ammo-consuming shotgun sequence.
        // Untriggered punches still use their physical contacts.
        && KFWeap_HRG_BlastBrawlers(W) == None;
    EffectiveTrigger = Trigger && Bridge.Hands[Hand].bTriggerArmed;
    if (Lower && InputState[Hand].bLowerArmed && !InputState[Hand].bLowerConsumed
        && LowerTime[Hand] >= 0.25)
    {
        InputState[Hand].bLowerConsumed = true;
        if (!Physical && R.AlternateKind() == 1)
        {
            if (!Trigger && !InputState[Hand].bTriggerWasDown)
                ModeFeedback(Hand, R.ToggleMode(InputSample));
            else ModeFeedback(Hand, false);
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
        // A deployable's trigger is held through the swing and thrown on release.
        if (FireMode[Hand] == 0 && class'VRDeployableThrow'.static.Handles(W)) Deployables.Begin(Hand, W);
        // Manual pump: no shot until the fore-end has been worked. A faint
        // click says the press was heard; release has nothing to stop.
        else if (Reloads != None && Reloads.BlocksFire(W))
        {
            FireMode[Hand] = -1;
            Reloads.Pulse(1 << Hand, 0.08, 0.01);
        }
        // Physical reloads: an empty magazine gun clicks instead of starting
        // the stock automatic reload. X/A or the pouch ejects the magazine.
        else if (Reloads != None && Reloads.DryFireInstead(W, FireMode[Hand])) FireMode[Hand] = -1;
        else if (VRTrackedWeapon(W) == None) R.StartAction(byte(FireMode[Hand]));
    }
    if (!EffectiveTrigger && InputState[Hand].bTriggerWasDown)
    {
        if (Deployables.IsHeld(Hand)) Deployables.Release(Hand);
        if (VRTrackedWeapon(W) == None && FireMode[Hand] >= 0) W.StopFire(byte(FireMode[Hand]));
        FireMode[Hand] = -1;
        InputState[Hand].bSecondaryAction = false;
    }
    // The mode is latched at the trigger edge: releasing a modifier while
    // holding the trigger never starts an unexpected second action.
    WantParry = Melee && (!Physical || R.Presenter.PhysicalMelee.bButtonGuard) && Lower && InputState[Hand].bLowerArmed && !Trigger;
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
    bReloadWasRunning = Bridge.PC.bRun != 0 && !EffectiveTrigger;
    if ((EffectiveTrigger && !InputState[Hand].bTriggerWasDown) || WantParry) CancelSprint();
    if (VRTrackedWeapon(W) != None) UpdateTrackedItem(R, Hand, EffectiveTrigger, Reload);
    else if (Reload && (Reloads == None
        || (!Reloads.TryBreakAction(R, Hand) && !Reloads.TrySlideRelease(R, Hand))))
    { R.StartAction(2); InputState[Hand].bReloadPulse = true; }
    if (Reload)
    {
        // Preflight now so a button reload preserves sprint only after the
        // physical path actually accepts it; rejected/alt/dual reloads pause.
        if (Reloads != None && Reloads.Enabled() && !Reloads.bActive
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
    if (Welding != None) { Welding.Shutdown(); Welding = None; }
    if (Reloads != None) { Reloads.Shutdown(); Reloads = None; }
    if (Pouch != None) { Pouch.Shutdown(); Pouch = None; }
    Inventory = None;
    Bridge = None;
    bInitialized = false;
}
