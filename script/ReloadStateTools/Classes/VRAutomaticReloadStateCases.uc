// Explicit standalone diagnostic. Real stock actors and production button/owner
// policy, with an isolated hand registry. No live XR input is changed.
class VRAutomaticReloadStateCases extends Actor;

var int Checks, Failures;
var VRWeaponPresenter Bridge;
var VRHeldInventory Registry;
var VRHandInventory Hands;
var VRDualHandInput Input;
var VRInteractiveReload Reload;
var array<KFWeapon> Created;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) ++Failures;
    `log("KF2VR_AUTOMATIC_STATE case=" $ Label @ "passed=" $ Passed);
}

function VRWeaponRuntime MakeWeapon(class<KFWeapon> Kind)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    W = Registry.Human.InvManager.Spawn(Kind, Registry.Human);
    Check(W != None, string(Kind.Name) $ "-spawn");
    if (W == None) return None;
    Created.AddItem(W);
    Registry.Human.InvManager.AddInventory(W, true);
    R = new(self) class'VRWeaponRuntime';
    R.Inventory = Registry; R.Item = W; R.NativeReady = 1;
    R.OwnershipRevision = 1; R.PrimaryHand = -1; R.SupportHand = -1;
    Registry.Items.AddItem(R);
    W.GotoState('Active');
    return R;
}

function Hold(VRWeaponRuntime R, int Hand, optional bool SupportOnly)
{
    R.PrimaryHand = SupportOnly ? -1 : Hand;
    R.SupportHand = SupportOnly ? Hand : -1;
    if (Hand == 0)
    { Registry.LeftItem = SupportOnly ? None : R; Registry.LeftSupport = SupportOnly ? R : None; }
    else
    { Registry.RightItem = SupportOnly ? None : R; Registry.RightSupport = SupportOnly ? R : None; }
}

function ClearHand(int Hand)
{
    if (Hand == 0) { Registry.LeftItem = None; Registry.LeftSupport = None; }
    else { Registry.RightItem = None; Registry.RightSupport = None; }
}

function TestOwner(VRWeaponRuntime R, VRWeaponRuntime Other, int Hand, bool SupportOnly)
{
    local VRAutomaticReload A, Replacement;
    local int Loaded, Reserve, I;
    local string Tag;
    Tag = "hand" $ Hand $ "-support" $ SupportOnly $ "-";
    Hold(R, Hand, SupportOnly); Hold(Other, 1 - Hand);
    Check(class'VRAutomaticReload'.static.ButtonRequired(Reload, R), Tag $ "two-gun-button-policy");
    Check(R.AutomaticReload == None, Tag $ "drawing-second-gun-does-not-start");
    // Seed an already-admitted stock phase to test production ownership and
    // duplicate button dispatch independently of authored animation assets.
    A = new(R) class'VRAutomaticReload'; R.AutomaticReload = A;
    A.Owner = Reload; A.Runtime = R; A.Gun = R.Item; A.Hand = Hand;
    A.Revision = R.OwnershipRevision; A.Calibration = Bridge.NativeCalibrationEpoch;
    A.RoomEpoch = Bridge.NativeRoomSpaceEpoch; A.Stage = 2;
    Loaded = R.Item.AmmoCount[0]; Reserve = R.Item.SpareAmmoCount[0];
    Check(A.Owns() && Reload.Automatic(R), Tag $ "accepted-owner-current");
    for (I = 0; I < 8; ++I) Input.DispatchReload(R, Hand);
    Check(R.AutomaticReload == A && A.Stage == 2 && R.Item.AmmoCount[0] == Loaded
        && R.Item.SpareAmmoCount[0] == Reserve, Tag $ "duplicate-button-no-payment-or-restart");
    ClearHand(1 - Hand);
    Check(!class'VRAutomaticReload'.static.ButtonRequired(Reload, R)
        && A.Owns() && Reload.Automatic(R), Tag $ "free-other-hand-preserves-owner");
    Input.DispatchReload(R, Hand);
    Check(R.AutomaticReload == A && A.Stage == 2, Tag $ "button-after-other-hand-free-keeps-owner");
    ++R.OwnershipRevision; Check(!A.Owns(), Tag $ "ownership-change-invalidates"); --R.OwnershipRevision;
    ++Bridge.NativeCalibrationEpoch; Check(!A.Owns(), Tag $ "calibration-change-invalidates"); --Bridge.NativeCalibrationEpoch;
    ++Bridge.NativeRoomSpaceEpoch; Check(!A.Owns(), Tag $ "room-change-invalidates"); --Bridge.NativeRoomSpaceEpoch;
    R.WorldDropped = 1; Check(!A.Owns(), Tag $ "drop-invalidates"); R.WorldDropped = 0;
    ClearHand(Hand); Check(!A.Owns(), Tag $ "stow-invalidates"); Hold(R, Hand, SupportOnly);
    Replacement = new(R) class'VRAutomaticReload'; R.AutomaticReload = Replacement;
    Check(!A.Owns(), Tag $ "replacement-owner-rejects-old");
    A.Release(); Check(R.AutomaticReload == Replacement, Tag $ "old-release-does-not-clear-new");
    R.AutomaticReload = A; A.Stage = 2;
    Registry.Items.RemoveItem(R); Check(!A.Owns(), Tag $ "retired-runtime-rejected"); Registry.Items.AddItem(R);
    A.Release(); A.Release();
    Check(R.AutomaticReload == None && A.Stage == 0 && R.Item.AmmoCount[0] == Loaded
        && R.Item.SpareAmmoCount[0] == Reserve, Tag $ "repeated-release-conserves-ammo");
    ClearHand(0); ClearHand(1);
}

function RunCases(VRHandsBridge Live)
{
    local VRWeaponRuntime Rifle, Pistol;
    local int I, H;
    Check(Live != None && WorldInfo.NetMode == NM_Standalone && Role == ROLE_Authority
        && Live.Human != None && Live.Human.Health > 0 && Live.Human.InvManager != None,
        "standalone-player-precondition");
    if (Failures != 0) return;
    Bridge = Spawn(class'VRWeaponPresenter', self);
    Check(Bridge != None, "isolated-bridge");
    if (Bridge == None) return;
    Registry = new(self) class'VRHeldInventory'; Registry.Human = Live.Human; Registry.PC = Live.PC;
    Bridge.Human = Live.Human; Bridge.PC = Live.PC;
    Hands = new(self) class'VRHandInventory'; Hands.Registry = Registry; Hands.Bridge = Bridge;
    Input = new(self) class'VRDualHandInput'; Input.Inventory = Hands; Input.Bridge = Bridge; Hands.Input = Input;
    Reload = new(self) class'VRInteractiveReload'; Reload.InputOwner = Input; Reload.Bridge = Bridge; Input.Reloads = Reload;
    Rifle = MakeWeapon(class'KFWeap_AssaultRifle_SCAR'); Pistol = MakeWeapon(class'KFWeap_Pistol_9mm');
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
    {
        Check(class'VRAutomaticReload'.static.StockDualCapable(class'VRWeaponPair'.default.Families[I].SingleClass), "single-family" $ I);
        Check(class'VRAutomaticReload'.static.StockDualCapable(class'VRWeaponPair'.default.Families[I].MemberClass), "member-family" $ I);
        Check(class'VRAutomaticReload'.static.StockDualCapable(class'VRWeaponPair'.default.Families[I].DualClass), "aggregate-family" $ I);
    }
    Check(!class'VRAutomaticReload'.static.StockDualCapable(class'KFWeap_Pistol_Medic'), "medic-pistol-is-not-stock-dual");
    Check(!class'VRAutomaticReload'.static.StockDualCapable(class'KFWeap_AssaultRifle_SCAR'), "rifle-is-not-stock-dual");
    if (Rifle != None && Pistol != None)
    {
        Hold(Rifle, 0);
        Check(!class'VRAutomaticReload'.static.ButtonRequired(Reload, Rifle), "one-gun-no-auto-policy");
        Registry.RightSupport = Rifle; Rifle.SupportHand = 1;
        Check(!class'VRAutomaticReload'.static.ButtonRequired(Reload, Rifle), "bracing-is-not-two-guns");
        ClearHand(1); Hold(Pistol, 1);
        Check(!class'VRAutomaticReload'.static.ButtonRequired(Reload, Pistol), "stock-dual-retains-physical-policy");
        ClearHand(0); ClearHand(1);
        for (H = 0; H < 2; ++H) { TestOwner(Rifle, Pistol, H, false); TestOwner(Rifle, Pistol, H, true); }
    }
    Cleanup();
    `log("KF2VR_AUTOMATIC_STATE checks=" $ Checks @ "failures=" $ Failures @ "input=isolated_direct_state");
}

function Cleanup()
{
    local int I;
    for (I = 0; I < Created.Length; ++I) if (Created[I] != None && !Created[I].bDeleteMe) Created[I].Destroy();
    Created.Length = 0;
    if (Bridge != None && !Bridge.bDeleteMe) Bridge.Destroy();
    Bridge = None;
}

event Destroyed() { Cleanup(); super.Destroyed(); }

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
}
