// Optional SDK fixture. Exercises production decisions and per-session state;
// it does not claim authored animation, stock payment or headset acceptance.
class VRShotgunStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL shotgun " $ Label); }
}

function CheckGravityReceipts()
{
    local VRCylinderSession Left, Right;
    local VRRevolverEjection Ledger;
    local VRWeaponRuntime L, R;
    Left = new(self) class'VRCylinderSession';
    Right = new(self) class'VRCylinderSession';
    Left.AuthoritySession = 11; Right.AuthoritySession = 12;
    Check(!Left.GravityReceiptAccepted(11, 1, 0, 3, 3), "submission without extraction is not accepted");
    Check(!Left.GravityReceiptAccepted(11, 0, 1, 3, 3), "pending status cannot seat");
    Check(!Left.GravityReceiptAccepted(11, 3, 0, 3, 3), "rejected extraction cannot seat");
    Check(!Left.GravityReceiptAccepted(11, 3, 1, 0, 0), "cancelled accepted extraction cannot resume seating");
    Check(!Left.GravityReceiptAccepted(11, 2, 1, 0, 0), "completed transaction cannot seat again");
    Check(!Left.GravityReceiptAccepted(12, 1, 1, 3, 3), "other hand receipt cannot seat");
    Check(!Left.GravityReceiptAccepted(11, 1, 1, 0, 3), "accepted loss waits for local ammo convergence");
    Check(Left.GravityReceiptAccepted(11, 1, 1, 0, 0), "accepted loss permits next phase");
    Check(Left.GravityReceiptAccepted(11, 1, 1, 3, 3), "accepted no-loss retains rounds");
    Check(Right.GravityReceiptAccepted(12, 1, 1, 4, 4), "dual partner accepts only own token");
    Check(!class'VRRevolverEjection'.static.ReceiptReady(11, 12, 3, 1, 0, 0), "durable ledger rejects foreign token");
    Check(!class'VRRevolverEjection'.static.ReceiptReady(11, 11, 1, 0, 3, 3), "ledger waits for unaccepted ejection");
    Check(class'VRRevolverEjection'.static.ReceiptReady(11, 11, 3, 0, 3, 3), "rejection can drain pending ledger");
    Check(!class'VRRevolverEjection'.static.ReceiptReady(11, 11, 3, 1, 0, 3), "late accepted cancellation waits for ammo");
    Check(class'VRRevolverEjection'.static.ReceiptReady(11, 11, 3, 1, 0, 0), "late accepted cancellation preserves loss");
    Check(class'VRRevolverEjection'.static.ReceiptMask(24, 5, 0, true) == 24, "rejection restores original mask");
    Check(class'VRRevolverEjection'.static.ReceiptMask(24, 5, 1, false) == 24, "no-loss conserves occupied slots");
    Check(class'VRRevolverEjection'.static.ReceiptMask(24, 5, 1, true) == 31, "accepted discard empties all slots");
    Check(class'VRRevolverEjection'.static.HipReceiptVisibility(0, true, false, true), "rejected hip extraction cannot hide live rounds");
    Check(!class'VRRevolverEjection'.static.HipReceiptVisibility(1, true, false, true), "accepted extraction hides until seat");
    Check(class'VRRevolverEjection'.static.HipReceiptVisibility(1, true, true, false), "seated own cylinder shows preview");
    Check(class'VRRevolverEjection'.static.HipReceiptVisibility(1, false, false, true), "other hip cannot hide this runtime");
    Ledger = new(self) class'VRRevolverEjection';
    L = new(self) class'VRWeaponRuntime'; R = new(self) class'VRWeaponRuntime';
    Ledger.Pending[0].Runtime = L; Ledger.Pending[0].Request = 3; Ledger.Pending[0].Session = 11;
    Ledger.Pending[1].Runtime = R; Ledger.Pending[1].Request = 4; Ledger.Pending[1].Session = 12;
    Check(Ledger.PendingForHand(0) && Ledger.PendingForHand(1), "both durable receipt slots populated");
    Ledger.ClearPending(0);
    Check(!Ledger.PendingForHand(0) && Ledger.Pending[0].Request == 0 && Ledger.Pending[0].Session == 0,
        "drained slot retains no request or token");
    Check(Ledger.PendingForHand(1) && Ledger.Pending[1].Session == 12, "draining left preserves right");
    Ledger.ClearPending(-1); Ledger.ClearPending(2);
    Check(Ledger.PendingForHand(1), "invalid hand clear is a no-op");
    Check(class'VRBreakCatalog'.static.ProfileClass(class'VRWeap_PairedBuckshot') == class'KFWeap_HRG_Revolver_Buckshot',
        "paired Buckshot keeps exact gravity profile");
}

function CheckPumpBoundaries()
{
    local VRManualPump P;
    local VRWeaponRuntime R;
    P = new(self) class'VRManualPump'; R = new(self) class'VRWeaponRuntime'; P.Runtime = R;
    Check(!class'VRReloadAudio'.static.OwnsStockShellEject(class'KFWeap_Shotgun_MB500'), "SG500 stock opening/insertion cannot duplicate rear case");
    Check(class'VRReloadAudio'.static.OwnsStockShellEject(class'KFWeap_Shotgun_M4'), "M4 retains stock eject notify");
    Check(class'VRReloadAudio'.static.OwnsStockShellEject(class'KFWeap_Shotgun_DoubleBarrel'), "break shotgun retains stock eject notify");
    Check(class'VRManualPump'.static.RearEjectionKind(false, false, 0) == 0, "empty rear stroke has no phantom case");
    Check(class'VRManualPump'.static.RearEjectionKind(false, true, 0) == 1, "final fired shot still has a spent case");
    Check(class'VRManualPump'.static.RearEjectionKind(true, true, 1) == 0, "first port shell closing cannot eject a spent case");
    Check(class'VRManualPump'.static.RearEjectionKind(false, false, 1) == 2, "deliberate live cycling stays a live-round action");
    Check(class'VRManualPump'.static.EmptyPortStateLatched(1, false, false), "empty rear port cannot close before shell");
    Check(!class'VRManualPump'.static.EmptyPortStateLatched(1, true, false), "first paid shell permits forward stroke");
    Check(!class'VRManualPump'.static.EmptyPortStateLatched(2, true, false), "paid port stage permits forward stroke");
    Check(!class'VRManualPump'.static.EmptyPortStateLatched(1, false, true), "explicit partial close preserves its exception");
    Check(!class'VRManualPump'.static.EmptyPortStateLatched(0, false, false), "closed bottom loading is not empty-port latch");
    R.PumpPortStage = 1; P.bNeedsPump = true; P.Pull = 7;
    Check(P.EjectAtRear(0) && P.Pull == 7 && P.bNeedsPump && R.PumpPortStage == 1,
        "actual rear method preserves port shell/debt without weapon dispatch");
    R.PumpPortStage = 2;
    Check(P.EjectAtRear(1) && R.PumpPortStage == 2, "paid port rear revisit cannot dispatch another ejection");
    R.PumpPortStage = 0; R.MechanismPending = 5;
    Check(P.ForwardBlocked(), "pending mechanism receipt blocks forward completion");
    P.Pumped();
    Check(P.Pull == 7 && P.bNeedsPump && R.MechanismPending == 5, "actual forward method cannot clear debt before receipt");
    R.MechanismPending = 0;
    Check(!P.ForwardBlocked(), "settled receipt releases forward fence");
}

function CheckBreakAcquisition()
{
    local bool Allowed;
    Allowed = class'VRBreakAction'.static.GripHandleClassAllowed(class'KFWeap_Shotgun_DoubleBarrel');
    Check(!Allowed, "Boomstick support grip is ordinary handling");
    Check(!class'VRBreakAction'.static.GripHandleClassAllowed(class'KFWeap_Shotgun_ElephantGun'), "Doomstick support grip is ordinary handling");
    Check(!class'VRBreakAction'.static.GripHandleClassAllowed(None), "missing weapon cannot acquire action");
    Check(class'VRBreakAction'.static.GripHandleClassAllowed(class'KFWeap_GrenadeLauncher_HX25'), "deliberate launcher handle preserved");
    Check(!class'VRBreakAction'.static.AcquisitionEdge(Allowed, false, false, true, false), "support squeeze cannot open idle or active hinge");
    Check(!class'VRBreakAction'.static.AcquisitionEdge(Allowed, false, false, true, true), "held support movement cannot open hinge");
    Check(class'VRBreakAction'.static.AcquisitionEdge(Allowed, true, false, true, true), "fresh trigger contact remains deliberate action edge");
    Check(!class'VRBreakAction'.static.AcquisitionEdge(Allowed, true, true, true, true), "held trigger cannot synthesize new action");
    Check(!class'VRBreakAction'.static.AcquisitionEdge(Allowed, false, true, false, true), "release is a no-op");
}

function RunCases()
{
    Checks = 0; Failures = 0;
    CheckGravityReceipts(); CheckPumpBoundaries(); CheckBreakAcquisition();
    `log("KF2VR_RELOAD_STATE shotgun checks=" $ Checks @ "failures=" $ Failures);
}
