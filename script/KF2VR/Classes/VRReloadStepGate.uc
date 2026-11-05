// Last-chance ownership at stock timer dispatch. Ordinary near-notify pausing
// keeps the authored presentation; this gate prevents a long frame from
// letting payment or the next shell outrun the hand's completed insertion.
class VRReloadStepGate extends Object;

var VRInteractiveReload Owner;
var bool bDeferredAmmo, bDeferredStatus, bDeferredClosing, bPaidForStep;
var bool bDeferredAction;
// An unseated magazine session kept in stock Reloading (tanks, containers,
// launchers, and wells resumed with the magazine already out).
var bool bDeferredMagazineAmmo, bDeferredMagazineStatus;

function Initialize(VRInteractiveReload O) { Owner = O; }

function Reset()
{
    bDeferredAmmo = false; bDeferredStatus = false;
    bDeferredClosing = false; bPaidForStep = false;
    bDeferredAction = false;
    bDeferredMagazineAmmo = false; bDeferredMagazineStatus = false;
}

function bool ClosingHeld(KFWeapon W)
{
    return Owner.LeverHold != 0 || Owner.bAwaitRack
        || (Owner.bShells && class'VRPumpCatalog'.static.PumpAction(W)
            && !Owner.bRacked && (Owner.bEmptyStart || Owner.Pump.RequiresPump(W)));
}

function bool Owns(KFWeapon W)
{
    return Owner != None && Owner.bActive && W != None && W == Owner.Gun
        && !W.bDeleteMe && Owner.MagazineReloading(W) && !Owner.bBreakInspection
        && W != Owner.CylinderAuthorityGun
        && (Owner.bShells || (Owner.BreakAction != None && Owner.BreakAction.Gun == W)
            || (Owner.FinishAction != None && Owner.FinishAction.Gun == W));
}

// A physical lever round is ammunition once seated, even if the player
// interrupts before the stock notify. Retain the current step's paid flag
// so its later ammo/status callbacks cannot load that round a second time.
function bool PayLeverInsert()
{
    local KFWeapon W;
    local int Before;
    W = Owner.Gun;
    if (!Owns(W) || !class'VRPumpCatalog'.static.IsLever(W) || Owner.Credits != 1
        || bPaidForStep || Owner.Bridge.PouchAmmoPending()) return false;
    Before = W.AmmoCount[0];
    class'VRPouchAmmo'.static.PerformPhysicalReload(W, 1, Owner.Runtime);
    if (W.AmmoCount[0] != Before + 1) return false;
    --Owner.Credits;
    bPaidForStep = true;
    Owner.bAmmoStepPaid = true;
    Owner.bAwaitAmmo = false;
    bDeferredAmmo = false;
    W.ClearTimer('ReloadAmmoTimer');
    return true;
}

// 0 = ammo timer, 1 = status timer. Called before the stock body executes.
function int BeforeTimer(KFWeapon W, int Kind)
{
    local VRWeaponRuntime R;
    // Observe the actual terminal call before Reloading.EndState clears
    // ReloadStatus. Payment followed by AbortReload is not completion.
    if (Kind == 3 || Kind == 4 || Kind == 5)
    {
        // Observe closure before stock leaves Reloading or replaces its
        // final empty-load clip; a top-up still cannot retire this debt.
        if (Kind != 5 && Owner != None && Owner.ManualAction != None && Owner.ManualAction.Gun == W)
            Owner.ManualAction.ObserveStockEmptyReload();
        if (Owner != None && Owner.InputOwner != None && Owner.InputOwner.Inventory != None)
        {
            R = Owner.InputOwner.Inventory.Registry.FindItem(W);
            if (Owner.Automatic(R))
            {
                if (Kind == 5) R.AutomaticReload.ObservePayment();
                else R.AutomaticReload.ObserveStockEnd(Kind == 3);
            }
        }
        return 0;
    }
    // A primary magazine removal can remain suspended while its secondary
    // feed reloads/fires. A later stock reload must wait for that same seat,
    // even when its callback arrives before the next presentation update.
    if (Owner != None && Owner.bActive && W != None && W == Owner.Gun
        && !W.bDeleteMe && Owner.bDetachedMagazineSession && !Owner.bSeated
        && !Owner.bRecoveredMagazineSession && Owner.MagazineReloading(W)
        && (Kind == 0 || Kind == 1))
    {
        if (Kind == 0) bDeferredMagazineAmmo = true;
        else bDeferredMagazineStatus = true;
        Owner.PauseStock();
        return 1;
    }
    // The same wait for a magazine session that stays in stock Reloading.
    // Only the near-notify pause protected it, which a long frame or an open
    // menu (no presentation update) skips: stock then refilled the absent
    // magazine and left a gun that could neither fire nor reload.
    if (Owner != None && Owner.bActive && W != None && W == Owner.Gun && !W.bDeleteMe
        && (Kind == 0 || Kind == 1) && Owner.MagazineReloading(W)
        && Owner.MagazineProfileIndex >= 0 && !Owner.bShells && !Owner.bSeated && !Owner.bAmmoStepPaid
        && !Owner.bDetachedMagazineSession && !Owner.bRecoveredMagazineSession
        && !Owner.bLoadedBowCarry && !Owner.bBreakInspection && W != Owner.CylinderAuthorityGun
        && (Owner.BreakAction == None || Owner.BreakAction.Gun != W)
        && (Owner.FinishAction == None || Owner.FinishAction.Gun != W)
        && (Owner.ServerMagazine == None || !Owner.ServerMagazine.Owns(W)))
    {
        if (Kind == 0) bDeferredMagazineAmmo = true;
        else bDeferredMagazineStatus = true;
        Owner.bAwaitAmmo = true;
        Owner.PauseStock();
        return 1;
    }
    if (!Owns(W) || (Kind != 0 && Kind != 1)) return 0;
    if (Owner.Bridge.PouchAmmoPending())
    {
        if (Kind == 0) bDeferredAmmo = true;
        else bDeferredStatus = true;
        Owner.PauseStock();
        return 1;
    }
    if (Owner.FinishAction != None && Owner.FinishAction.Gun == W)
    {
        if (Kind == 0 && bPaidForStep) return 1;
        if (Kind == 1 && Owner.FinishAction.NeedsAction())
        {
            bDeferredAction = true;
            Owner.PauseStock();
            return 1;
        }
        return 0;
    }
    if (Kind == 1 && Owner.M32Action != None && Owner.M32Action.Gun == W
        && Owner.M32Action.NeedsAction())
    {
        bDeferredAction = true;
        Owner.PauseStock();
        return 1;
    }
    // The initial M32 callback opens/ejects only; it consumes no grenade.
    if (Owner.M32Action != None && Owner.M32Action.Gun == W
        && Owner.M32Action.OpeningStockPending()) return 0;
    if (Kind == 1 && class'VRPumpCatalog'.static.IsLever(W))
    {
        if (Owner.LeverHold != 0)
        {
            bDeferredClosing = true;
            Owner.PauseStock();
            return 1;
        }
        // A fast final insert can seat during the no-ammo opening clip.
        // Stock's unconditional opening -> insert transition would then
        // wait for a nonexistent additional round in an already full gun.
        if (bPaidForStep && W.ReloadStatus == RS_OpeningBolt && W.ReloadAmountLeft <= 0)
            W.ReloadStatus = RS_Reloading;
    }
    if (Kind == 1 && W.ReloadStatus == RS_Reloading
        && Owner.bPumpFirstShell && Owner.bAmmoStepPaid && !bPaidForStep)
    {
        // Status beat the ammo notify; its reserved credit still buys only
        // the port shell, not permission to skip the subsequent rack.
        bDeferredStatus = true;
        Owner.PauseStock();
        return 1;
    }
    if (Kind == 1 && Owner.bPumpFirstShell && bPaidForStep)
    {
        // A first port shell must be chambered before the stock status can
        // start the next tube insert. Keep its paid observation for GateTimers.
        Owner.bAmmoStepPaid = true;
        bDeferredClosing = true;
        Owner.PauseStock();
        return 1;
    }
    if (Kind == 1 && W.ReloadStatus != RS_Reloading)
    {
        if (W.ReloadStatus == RS_ClosingBolt && ClosingHeld(W))
        {
            bDeferredClosing = true;
            // This one-shot is already suppressed. GateTimers must remain
            // able to bind the rack before it pauses the closing animation.
            return 1;
        }
        bPaidForStep = false;
        Owner.bAmmoStepPaid = false;
        return 0;
    }
    // The generic presentation clears bAmmoStepPaid when the ammo timer
    // disappears. Retain our payment until the status callback advances.
    if (Kind == 0 && bPaidForStep) return 1;
    // The original infinite-reserve callback fills the entire tube. Route
    // both timer orders through the same bounded physical payment below.
    if (W.bInfiniteSpareAmmo && !bPaidForStep
        && (Kind == 0 || W.ReloadStatus == RS_Reloading))
    {
        if (Kind == 0) bDeferredAmmo = true;
        else bDeferredStatus = true;
        Owner.PauseStock();
        return 1;
    }
    if (bPaidForStep || Owner.bAmmoStepPaid)
    {
        if (Kind == 1 && bPaidForStep) W.ClearTimer('ReloadAmmoTimer');
        bPaidForStep = Kind == 0;
        if (Kind == 1)
        {
            Owner.bAmmoStepPaid = false;
            bDeferredAmmo = false; bDeferredStatus = false;
        }
        return 0;
    }
    if (Kind == 0) bDeferredAmmo = true;
    else bDeferredStatus = true;
    Owner.bAwaitAmmo = true;
    Owner.PauseStock();
    return 1;
}

// A dispatched one-shot timer cannot be paused from inside its callback.
// Save that obligation and discharge it once, on a later owner update, using
// stock PerformReload. Never reconstruct or predict ammunition amounts.
function bool Update()
{
    local int Cost;
    local bool Ready, Advance;
    local KFWeapon W;
    if (Owner.Bridge.PouchAmmoPending()) return true;
    if (bDeferredMagazineAmmo || bDeferredMagazineStatus)
    {
        W = Owner.Gun;
        if (!Owner.bActive || W == None || W.bDeleteMe || !Owner.MagazineReloading(W))
        { bDeferredMagazineAmmo = false; bDeferredMagazineStatus = false; return false; }
        // CreditMagazine pays the seat itself; until then the stock stays held.
        if (!Owner.bAmmoStepPaid) { Owner.bAwaitAmmo = true; Owner.PauseStock(); return true; }
        bDeferredMagazineAmmo = false;
        if (bDeferredMagazineStatus)
        {
            // The status callback that was due has been consumed: advance
            // the paid reload now, as stock would have.
            bDeferredMagazineStatus = false;
            W.ClearTimer('ReloadStatusTimer');
            Owner.ResumeStock();
            W.ReloadStatusTimer();
            return true;
        }
    }
    if (!bDeferredAmmo && !bDeferredStatus && !bDeferredClosing && !bDeferredAction) return false;
    W = Owner.Gun;
    if (!Owns(W) || !Owner.StillValid()) { Cancel(); return true; }
    if (Owner.M32Action != None && Owner.M32Action.Gun == W && Owner.M32Action.OpeningStockPending())
    {
        // A long frame may have dispatched the opening one-shots before the
        // hand opened the hinge. Drain that no-ammo obligation exactly once.
        Advance = bDeferredAction || bDeferredStatus;
        if (bDeferredAmmo || Advance)
        {
            W.ClearTimer('ReloadAmmoTimer');
            if (!KFWeap_GrenadeLauncher_CylinderBase(W).bInitialReloadIsOpenOnly) W.PerformReload();
        }
        bDeferredAmmo = false; bDeferredStatus = false; bDeferredAction = false;
        Owner.bAwaitAmmo = false;
        Owner.ResumeStock();
        if (Advance)
        { W.ClearTimer('ReloadStatusTimer'); W.ReloadStatusTimer(); }
        return true;
    }
    if (bDeferredAction)
    {
        if (Owner.M32Action != None && Owner.M32Action.Gun == W && Owner.M32Action.NeedsAction()) return true;
        if (Owner.FinishAction != None && Owner.FinishAction.Gun == W && Owner.FinishAction.NeedsAction()) return true;
        bDeferredAction = false;
        if (W.Class == class'KFWeap_Shotgun_M4')
        { bPaidForStep = false; Owner.bAmmoStepPaid = false; }
        W.ClearTimer('ReloadStatusTimer');
        Owner.ResumeStock();
        W.ReloadStatusTimer();
        return true;
    }
    if (bDeferredClosing)
    {
        // Let ordinary GateTimers bind the rack, and UpdateHand work it.
        // This obligation has no ammo payment and consumes no insert credit.
        if (ClosingHeld(W)) return false;
        bDeferredClosing = false;
        W.ClearTimer('ReloadStatusTimer');
        Owner.ResumeStock();
        W.ReloadStatusTimer();
        return true;
    }
    if (bPaidForStep && class'VRPumpCatalog'.static.IsLever(W))
    {
        // Seating already paid this shell. Drain only the deferred status;
        // the ordinary callback gate retires its paid flag for the next step.
        Advance = bDeferredStatus;
        bDeferredAmmo = false; bDeferredStatus = false;
        if (Advance)
        {
            W.ClearTimer('ReloadStatusTimer');
            Owner.ResumeStock();
            W.ReloadStatusTimer();
        }
        return true;
    }
    Cost = 1; Ready = true;
    if (Owner.BreakAction != None && Owner.BreakAction.Gun == W)
    {
        Cost = Owner.BreakAction.RequiredShells;
        Ready = Owner.BreakAction.bClosed;
    }
    if (Owner.bPumpFirstShell && (Owner.Runtime == None || Owner.Runtime.PumpPortStage != 1)) return true;
    if (Owner.LeverHold != 0 || !Ready || (!Owner.bAmmoStepPaid && Owner.Credits < Cost)) return true;
    // Near-notify GateTimers may already have consumed this step's credit.
    if (!Owner.bAmmoStepPaid) Owner.Credits -= Cost;
    Owner.bAmmoStepPaid = true;
    bPaidForStep = true;
    Owner.bAwaitAmmo = false;
    Advance = bDeferredStatus;
    bDeferredAmmo = false; bDeferredStatus = false;
    // A deferred status may have arrived before the separate ammo callback.
    // Remove that remaining callback before the sole stock payment.
    W.ClearTimer('ReloadAmmoTimer');
    if (Advance) W.ClearTimer('ReloadStatusTimer');
    Owner.ResumeStock();
    class'VRPouchAmmo'.static.PerformPhysicalReload(W, Cost, Owner.Runtime);
    if (Advance && Owner.MagazineReloading(W)) W.ReloadStatusTimer();
    // Preserve the first-shell port/rack transition in ordinary GateTimers.
    // Its paid flag must survive any status advance above until that branch.
    if (Owner.bPumpFirstShell) { Owner.bAmmoStepPaid = true; return false; }
    return true;
}

function Cancel()
{
    local KFWeapon W;
    W = Owner.Gun;
    if ((bDeferredMagazineAmmo || bDeferredMagazineStatus) && W != None && !W.bDeleteMe
        && Owner.MagazineReloading(W) && !Owner.bAmmoStepPaid && Owner.Bridge != None
        && W.Owner == Owner.Bridge.Human && W.Instigator == Owner.Bridge.Human)
    {
        W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
        W.AbortReload();
    }
    // Leaving an incomplete physical shell/action session must not hand an
    // uninserted stock step back to a timer after tracking or ownership loss.
    if (Owns(W) && Owner.Bridge != None && W.Owner == Owner.Bridge.Human
        && W.Instigator == Owner.Bridge.Human)
    {
        W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
        W.AbortReload();
    }
    Reset();
}

// A button explicitly transferred this same stock reload to automatic
// ownership. A suppressed one-shot no longer exists on the actor; re-arm
// it exactly once, keeping paid shell/magazine steps out of the ammo path.
function HandBackToStock()
{
    local KFWeapon W;
    local bool Paid;
    W = Owner.Gun;
    if (W != None && !W.bDeleteMe && Owner.MagazineReloading(W))
    {
        Paid = bPaidForStep || (!Owner.bShells && Owner.bAmmoStepPaid);
        if (Paid) W.ClearTimer('ReloadAmmoTimer');
        else if (bDeferredAmmo || bDeferredMagazineAmmo)
            W.SetTimer(0.01, false, 'ReloadAmmoTimer');
        if (bDeferredStatus || bDeferredMagazineStatus || bDeferredAction || bDeferredClosing)
            W.SetTimer(0.02, false, 'ReloadStatusTimer');
    }
    Reset();
}
