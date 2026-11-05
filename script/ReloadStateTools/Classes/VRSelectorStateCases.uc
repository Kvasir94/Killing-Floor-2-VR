// Explicit nonshipping fixture: real UpdateHand, ToggleMode and haptic queue.
// Input/pose snapshots are synthetic and isolated from the live XR bridge.
// This proves dispatch and queue state, not controller hardware sensation.
class VRSelectorStateCases extends Actor;

var int Checks, Failures;
var VRWeaponPresenter FixtureBridge;
var VRHandInventory FixtureInventory;
var VRHeldInventory FixtureRegistry;
var VRDualHandInput Input;
var VRWeaponRuntime Runtime;
var KFWeapon Weapon;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) ++Failures;
    `log("KF2VR_SELECTOR_STATE case=" $ Label @ "passed=" $ Passed);
}

function ClearQueue()
{
    FixtureBridge.NativeHandHapticMask = 0;
    // Deliberately retain values, as the native consumer does. A cleared mask
    // must prevent old amplitudes from becoming a new request.
}

function bool DetentQueued(int Hand)
{
    if (FixtureBridge.NativeHandHapticMask != (1 << Hand)) return false;
    if (Hand == 0)
        return Abs(FixtureBridge.NativeLeftHapticStrength - 0.5) < 0.0001
            && Abs(FixtureBridge.NativeLeftHapticDuration - 0.045) < 0.0001;
    return Abs(FixtureBridge.NativeRightHapticStrength - 0.5) < 0.0001
        && Abs(FixtureBridge.NativeRightHapticDuration - 0.045) < 0.0001;
}

function SetupHand(int Hand, optional bool SupportOnly)
{
    Input = new(self) class'VRDualHandInput';
    Input.Bridge = FixtureBridge; Input.Inventory = FixtureInventory;
    FixtureInventory.Input = Input;
    Input.FireMode[0] = -1; Input.FireMode[1] = -1;
    Runtime.PrimaryHand = SupportOnly ? -1 : Hand;
    Runtime.SupportHand = SupportOnly ? Hand : -1;
    Runtime.CarryPrimaryHand = -1;
    FixtureRegistry.LeftItem = None; FixtureRegistry.RightItem = None;
    FixtureRegistry.LeftSupport = None; FixtureRegistry.RightSupport = None;
    if (SupportOnly)
    {
        if (Hand == 0) FixtureRegistry.LeftSupport = Runtime;
        else FixtureRegistry.RightSupport = Runtime;
    }
    else
    {
        if (Hand == 0) FixtureRegistry.LeftItem = Runtime;
        else FixtureRegistry.RightItem = Runtime;
        Input.LastWeapon[Hand] = Weapon;
    }
    Runtime.NativePoseReady = 1;
    Runtime.PoseOwnershipRevision = Runtime.OwnershipRevision;
    Runtime.PoseSequence = FixtureRegistry.PoseSequence;
    Runtime.LastModeInputSample = -1;
    Weapon.GotoState('Active');
    Runtime.SyncStockMode();
    FixtureBridge.NativeValidMask = 3;
    FixtureBridge.NativeGripActiveMask = 3;
    FixtureBridge.NativeTriggerActiveMask = 3;
    FixtureBridge.NativeGripMask = 1 << Hand;
    FixtureBridge.LeftGripValue = Hand == 0 ? 1 : 0;
    FixtureBridge.RightGripValue = Hand == 1 ? 1 : 0;
    FixtureBridge.NativeTriggerMask = 0;
    FixtureBridge.LeftTriggerValue = 0; FixtureBridge.RightTriggerValue = 0;
    FixtureBridge.NativePhysicalButtonActiveMask = 15;
    FixtureBridge.NativePhysicalButtonMask = 0;
    Input.InputState[Hand].bGripWasDown = true;
    FixtureBridge.Hands[Hand].bGripArmed = false;
    FixtureBridge.Hands[Hand].bTriggerArmed = false;
    ClearQueue();
}

function Sample(int Hand, bool Lower, float DeltaTime)
{
    FixtureBridge.NativePhysicalButtonMask = Lower ? (Hand == 0 ? 1 : 8) : 0;
    ++Input.InputSample;
    Input.UpdateHand(Hand, DeltaTime);
}

function Press(int Hand)
{
    // Both current and previous trigger samples must be released before a
    // new selector hold may arm; no preseeded mode latch bypasses this gate.
    Sample(Hand, false, 0.01);
    Sample(Hand, false, 0.01);
    Sample(Hand, true, 0.01);
}

function TestHand(int Hand)
{
    local bool Previous;
    local string Label;
    Label = "hand" $ Hand $ "-";
    SetupHand(Hand);
    Previous = Weapon.bUseAltFireMode;
    Press(Hand);
    Check(FixtureBridge.NativeHandHapticMask == 0 && Weapon.bUseAltFireMode == Previous,
        Label $ "neutral-and-short-press-no-detent");
    Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode != Previous && Runtime.SelectedMode == byte(Weapon.bUseAltFireMode),
        Label $ "accepted-stock-mode-changed");
    Check(DetentQueued(Hand), Label $ "accepted-half-strength-45ms-only-own-hand");
    Check(Input.InputState[Hand].ModeHoldRuntime == None, Label $ "accepted-hold-consumed");
    Previous = Weapon.bUseAltFireMode; ClearQueue();
    Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode == Previous && FixtureBridge.NativeHandHapticMask == 0,
        Label $ "continued-hold-no-repeat-or-stale-pulse");
    Sample(Hand, false, 0.01);
    Check(FixtureBridge.NativeHandHapticMask == 0, Label $ "release-no-detent");

    SetupHand(Hand); Press(Hand);
    FixtureBridge.QueueHandHaptic(1 << Hand, 0.1, 0.009);
    Sample(Hand, true, 0.26);
    FixtureBridge.QueueHandHaptic(1 << Hand, 0.1, 0.009);
    Check(DetentQueued(Hand), Label $ "same-frame-weak-before-and-after-preserves-detent");

    SetupHand(Hand); Runtime.NativePoseReady = 0;
    Previous = Weapon.bUseAltFireMode; Press(Hand); Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode == Previous && FixtureBridge.NativeHandHapticMask == 0,
        Label $ "unready-pose-rejected-without-pulse");

    SetupHand(Hand); Press(Hand); ++Runtime.OwnershipRevision;
    Previous = Weapon.bUseAltFireMode; Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode == Previous && FixtureBridge.NativeHandHapticMask == 0,
        Label $ "ownership-change-cancels-without-pulse");

    SetupHand(Hand); Press(Hand); Weapon.GotoState('Inactive');
    Previous = Weapon.bUseAltFireMode; Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode == Previous && FixtureBridge.NativeHandHapticMask == 0,
        Label $ "inactive-weapon-rejected-without-pulse");

    SetupHand(Hand); Press(Hand);
    Runtime.LastModeInputSample = Input.InputSample + 1;
    Previous = Weapon.bUseAltFireMode; Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode == Previous && FixtureBridge.NativeHandHapticMask == 0
        && Input.InputState[Hand].ModeHoldRuntime == None,
        Label $ "duplicate-runtime-sample-rejected-without-pulse");

    SetupHand(Hand, true); Previous = Weapon.bUseAltFireMode;
    Press(Hand); Sample(Hand, true, 0.26);
    Check(Runtime.PrimaryHand < 0 && Weapon.bUseAltFireMode == Previous
        && FixtureBridge.NativeHandHapticMask == 0, Label $ "support-carry-no-mode-or-detent");

    SetupHand(1 - Hand); Runtime.SupportHand = Hand;
    if (Hand == 0) FixtureRegistry.LeftSupport = Runtime;
    else FixtureRegistry.RightSupport = Runtime;
    FixtureBridge.NativeGripMask = 3;
    FixtureBridge.LeftGripValue = 1; FixtureBridge.RightGripValue = 1;
    Input.InputState[Hand].bGripWasDown = true;
    Previous = Weapon.bUseAltFireMode; Press(Hand); Sample(Hand, true, 0.26);
    Check(Weapon.bUseAltFireMode == Previous && FixtureBridge.NativeHandHapticMask == 0,
        Label $ "bracing-support-no-mode-or-detent");
}

function RunCases(VRHandsBridge Live)
{
    local int Hand;
    Check(Live != None && WorldInfo.NetMode == NM_Standalone && Role == ROLE_Authority
        && Live.Human != None && Live.Human.Health > 0 && Live.Human.InvManager != None
        && Live.Human.InvManager.Instigator == Live.Human
        && Live.PC != None && Live.PC.Pawn == Live.Human,
        "standalone-owned-player-precondition");
    if (Failures != 0) return;
    // The live registry, XR fields and pending haptics are never modified.
    // Stock spawn still receives the real owner/instigator before PostBeginPlay.
    Weapon = Live.Human.InvManager.Spawn(class'KFWeap_LMG_MG3', Live.Human);
    FixtureBridge = Spawn(class'VRWeaponPresenter', self);
    Check(Weapon != None && FixtureBridge != None, "stock-weapon-and-isolated-bridge-created");
    if (Weapon == None || FixtureBridge == None) { Cleanup(); return; }
    Live.Human.InvManager.AddInventory(Weapon, true);
    FixtureRegistry = new(self) class'VRHeldInventory';
    FixtureRegistry.PC = Live.PC; FixtureRegistry.Human = Live.Human;
    FixtureRegistry.PoseSequence = 1;
    Runtime = new(self) class'VRWeaponRuntime';
    Runtime.Inventory = FixtureRegistry; Runtime.Item = Weapon; Runtime.NativeReady = 1;
    Runtime.Presenter = FixtureBridge;
    FixtureRegistry.Items.AddItem(Runtime);
    FixtureBridge.PC = Live.PC; FixtureBridge.Human = Live.Human;
    FixtureBridge.bCalibrated = true; FixtureBridge.NativeWeaponReady = 1;
    FixtureBridge.ActiveProfile = FixtureBridge.FindWeaponProfile(Weapon);
    FixtureInventory = new(self) class'VRHandInventory';
    FixtureInventory.Registry = FixtureRegistry; FixtureInventory.Bridge = FixtureBridge;
    Check(Runtime.IsCurrent() && Weapon.Instigator == Live.Human
        && Runtime.UsesStockToggle() && Runtime.AlternateKind() == 1,
        "real-stock-selector-profile");
    if (Failures == 0) for (Hand = 0; Hand < 2; ++Hand) TestHand(Hand);
    Cleanup();
    `log("KF2VR_SELECTOR_STATE checks=" $ Checks @ "failures=" $ Failures
        @ "input=synthetic_direct_UpdateHand hardware_acceptance=not_tested");
}

function Cleanup()
{
    if (Weapon != None && !Weapon.bDeleteMe) Weapon.Destroy();
    Weapon = None;
    if (FixtureBridge != None && !FixtureBridge.bDeleteMe) FixtureBridge.Destroy();
    FixtureBridge = None;
}

event Destroyed()
{
    Cleanup();
    super.Destroyed();
}

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
}
