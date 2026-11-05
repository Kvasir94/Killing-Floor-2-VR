// One button request on one held actor. This owner survives the OTHER hand
// becoming free; it never changes a player setting or creates ammunition.
class VRAutomaticReload extends Object;

var VRInteractiveReload Owner;
var VRWeaponRuntime Runtime;
var KFWeapon Gun;
var int Hand, Revision, Calibration, RoomEpoch;
var byte Stage; // 1 admission, 2 stock, 3 paid action, 4 paid rack, 5 spent cycle, 6 old magazine dropping, 7 shot finishing
var bool bSecondary, bSawReload, bPaid, bActionDone, bStockCompleted, bNoFreeHandPress;
var int InitialAmmo;
var float BeganAt, ActionAt, ActionFrom, ActionDuration, AuthoredUntil;
var bool bReturning;

static function bool StockDualCapable(class<KFWeapon> WeaponClass)
{
    local int I;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (WeaponClass == class'VRWeaponPair'.default.Families[I].SingleClass
            || WeaponClass == class'VRWeaponPair'.default.Families[I].MemberClass
            || WeaponClass == class'VRWeaponPair'.default.Families[I].DualClass) return true;
    return false;
}

static function bool ButtonRequired(VRInteractiveReload O, VRWeaponRuntime R)
{
    local VRWeaponRuntime Left, Right;
    if (O == None || R == None || R.Item == None || StockDualCapable(R.Item.Class)
        || O.InputOwner == None || O.InputOwner.Inventory == None) return false;
    // The paired shield occupies a real hand even though both components
    // share one inventory actor. Reloading the pistol must keep that owner.
    if (R.Item.Class == class'KFWeap_SMG_G18' && R.PrimaryHand >= 0 && R.SupportHand >= 0)
        return O.InputOwner.Inventory.Registry.GetPrimary(R.PrimaryHand) == R
            && O.InputOwner.Inventory.Registry.GetSupport(R.SupportHand) == R;
    // Any other gun with a hip reload (pistol families, one-handed SMGs)
    // reloads at the hip while the other hand is busy (Kvasir94, 2026-10-28).
    if (O.HasHipReload(R)) return false;
    Left = O.InputOwner.Inventory.GetHeldForHand(0);
    Right = O.InputOwner.Inventory.GetHeldForHand(1);
    return Left != None && Right != None && Left.IsCurrent() && Right.IsCurrent()
        && Left != Right && Left.Item != Right.Item
        && (Left == R || Right == R);
}

function bool Owns()
{
    return Stage != 0 && Owner != None && Owner.Bridge != None && Owner.InputOwner != None
        && Owner.InputOwner.Inventory != None
        && Runtime != None && Runtime.IsCurrent() && Runtime.Item == Gun
        && Runtime.AutomaticReload == self && Runtime.OwnershipRevision == Revision
        && Gun != None && !Gun.bDeleteMe && Runtime.WorldDropped == 0
        && Owner.Bridge.NativeCalibrationEpoch == Calibration
        && Owner.Bridge.NativeRoomSpaceEpoch == RoomEpoch
        && Hand >= 0 && Hand < 2 && Owner.InputOwner.Inventory.GetHeldForHand(Hand) == Runtime;
}

// bNoFreeHand: the reload button pressed while no hand can do the physical
// reload (Kvasir94, 2026-10-28). It latches this same explicit owner.
function bool TryBegin(VRInteractiveReload O, VRWeaponRuntime R, int H, optional bool Secondary,
    optional bool bNoFreeHand)
{
    if (Owns()) return true;
    if (!ButtonRequired(O, R) && !(bNoFreeHand && O != None && O.NoFreeHand(R))) return false;
    // A rejected button consumes no hand or ammunition and cannot leave a
    // latent request which starts after an unrelated transaction completes.
    if (!R.IsCurrent() || H < 0 || H > 1 || O.InputOwner.Inventory.GetHeldForHand(H) != R
        || !O.InputOwner.ContextValid() || R.WorldDropped != 0 || R.MechanismPending != 0
        || O.DedicatedReloadBusy(R.Item) || O.Bridge.PouchAmmoPending()) return true;
    Owner = O; Runtime = R; Gun = R.Item; Hand = H;
    Revision = R.OwnershipRevision; Calibration = O.Bridge.NativeCalibrationEpoch;
    RoomEpoch = O.Bridge.NativeRoomSpaceEpoch; bSecondary = Secondary;
    Stage = 1; BeganAt = O.Now(); bSawReload = false; bPaid = false; bActionDone = false; bStockCompleted = false;
    ActionAt = 0; bReturning = false;
    AuthoredUntil = 0;
    // Preserve the existing Deadbolt button queue while its single-shot
    // interval still owns the state. The explicit owner is already latched,
    // so freeing the other hand cannot change this accepted reload's mode.
    if (Gun.IsA('BreacherDeadbolt') && Gun.IsInState('WeaponSingleFiring') && Gun.CanReload())
        AuthoredUntil = O.Bridge.WorldInfo.TimeSeconds + 1.5;
    InitialAmmo = Gun.AmmoCount[Secondary ? 1 : 0];
    bNoFreeHandPress = bNoFreeHand;
    // A press while the last shot's fire state still runs waits for it to
    // end: stock would drop the reload request, and the drop needs an idle
    // gun (the Tommy Boom, #195).
    if (AuthoredUntil == 0 && Gun.IsInState('WeaponFiring'))
    { Stage = 7; Update(); return true; }
    Admit();
    Update();
    return true;
}

function Admit()
{
    // Busy-hand X/A with the ammunition rules on behaves like a hand reload
    // (spec R5, Kvasir94 2026-10-29): the old magazine first drops through the
    // same paid removal a hand reload uses, so LOSE, RECOVER and KEEP
    // CHAMBERED apply and the authority receipts it. With them off the
    // magazine never leaves. Stock then reloads the empty well, paid once.
    // Server-ammo magazines (Bouncer, Reconstructor, Doshinegun) leave only
    // through their own transaction, which this owner hands them below.
    // A second gun in the other hand reaches here through ButtonRequired
    // without bNoFreeHand; its hand is just as busy (#195).
    Stage = 1;
    if ((bNoFreeHandPress || Owner.NoFreeHand(Runtime)) && !bSecondary && DropsOldMagazine(Owner, Runtime)
        && !class'VRServerMagazineReload'.static.Supports(Gun))
    {
        Stage = 6;
        Owner.Begin(Runtime, Hand, true);
        // The well reads out only once the receipt lands; a removal still in
        // flight is not a refused drop (#195).
        if (!(Owner.bActive && Owner.Runtime == Runtime) && !Runtime.MagazineOut() && !RemovalPending()) Stage = 1;
        InitialAmmo = Gun.AmmoCount[0];
    }
}

// The removal's receipt is still in flight. Starting stock first would let
// that receipt clear the kept chamber's StockChamberBonus (KEEP, #195).
function bool RemovalPending()
{
    local int H;
    for (H = 0; H < 2; ++H)
        if (Owner.MagazineRemovals[H] != None && Owner.MagazineRemovals[H].Gun == Gun
            && Owner.MagazineRemovals[H].Status == 1) return true;
    return false;
}

static function bool DropsOldMagazine(VRInteractiveReload O, VRWeaponRuntime R)
{
    return O.Bridge != None && (O.Bridge.bLoseReloadAmmo || O.Bridge.bRecoverMagazineAmmo || O.Bridge.bKeepChamberedRound)
        && !R.MagazineOut() && R.CanStartReload()
        // A part-full tank or cassette leaves through the same paid whole-load
        // removal as a hand reload, so LOSE takes its rounds (R5, #192).
        && R.CanEjectEmptyMagazine(true, O.PaidMagazineRemoval(R, false))
        && !O.HasHipReload(R) && !class'VRInteractiveReload'.static.PairedAuthorityNeeded(R.Item);
}

// Owning the gun while its old magazine drops would make the eject session
// see an automatic owner and stand down.
function bool Dropping() { return Stage == 6; }

function Release()
{
    Stage = 0;
    if (Runtime != None && Runtime.AutomaticReload == self) Runtime.AutomaticReload = None;
}

function SettleAction()
{
    Runtime.bSlideLockPending = false;
    Runtime.M32ClosePending = 0;
    Runtime.RestoreEmptyMagazineGeometry();
    Runtime.MagazineFeedEvent(2); Runtime.EmptyMagazineEvent(1);
    Runtime.MagazineFeedEvent(3); Runtime.EmptyMagazineEvent(2);
    if (Owner.Pump != None && !class'VRPumpCatalog'.static.IsLever(Gun)) Owner.Pump.ReloadCompleted(Gun);
    // A lever top-up never moves the action. Its actual stock empty-load
    // stroke is observed separately; otherwise finish the owed stroke below.
    // A completed stock reload which started empty includes its open/load/
    // close sequence even if presentation bound too late to sample it. An
    // interrupted reload never reaches this settlement.
    if (Owner.ManualAction != None && (!class'VRPumpCatalog'.static.IsLever(Gun)
        || (InitialAmmo == 0 && bStockCompleted)))
        Owner.ManualAction.ReloadCompleted(Gun);
}

function ObservePayment()
{
    // These stock counters outlive Reloading. Read them only while this
    // accepted request is in that state, never after a failed new admission.
    if (!Gun.IsInState('Reloading') && !(bSecondary && Gun.IsInState('AltReloading'))) return;
    bSawReload = true;
    if (Gun.InitialReloadAmount <= Gun.ReloadAmountLeft
        && Gun.AmmoCount[bSecondary ? 1 : 0] <= InitialAmmo) return;
    if (!bPaid && !bSecondary)
    {
        Runtime.RestoreEmptyMagazineGeometry();
        Runtime.MagazineFeedEvent(2); Runtime.EmptyMagazineEvent(1);
    }
    bPaid = true;
}

// Called synchronously by the existing native stock-callback dispatcher.
// Reloading.EndState resets status before an ordinary frame can observe it.
function ObserveStockEnd(bool Completed)
{
    if (!Owns() || Stage != 2 || (!Gun.IsInState('Reloading') && !(bSecondary && Gun.IsInState('AltReloading')))
        || Gun.IsInState('AltReloading') != bSecondary) return;
    ObservePayment();
    if (Completed)
    {
        bStockCompleted = true;
        // The kept chamber (KEEP, #195): stock's credit clamped at capacity
        // after charging for the chamber too. Add it as the reload ends, so
        // the gun never shows Active one round short.
        if (!bSecondary && Runtime.StockChamberBonus > 0 && Owner.Realistic()
            && Gun.ReloadAmountLeft == 0 && Gun.AmmoCount[0] == Gun.MagazineCapacity[0])
        {
            Gun.AmmoCount[0] += Runtime.StockChamberBonus;
            if (Gun.Role < ROLE_Authority) Gun.SyncCurrentAmmoCount(0, Gun.AmmoCount[0]);
            Runtime.StockChamberBonus = 0;
        }
    }
    else Release();
}

function Update()
{
    if (Stage == 0) return;
    if (!Owns() || !Owner.InputOwner.ContextValid() || Owner.Now() - BeganAt > 50)
    { Release(); return; }
    if (Stage == 6)
    {
        // The removal's receipt settles first; a refused drop still reloads.
        if ((Owner.bActive && Owner.Runtime == Runtime) || Owner.OwnRemovalStatus() == 1 || RemovalPending()) return;
        Stage = 1; InitialAmmo = Gun.AmmoCount[0];
    }
    if (Stage == 7)
    {
        if (Gun.IsInState('WeaponFiring'))
        {
            if (Owner.Now() - BeganAt > 2) Release();
            return;
        }
        if (!class'VRWeaponRuntime'.static.StockIdle(Gun)) { Release(); return; }
        InitialAmmo = Gun.AmmoCount[0];
        Admit();
        if (Stage == 6) return;
    }
    if (Stage == 1) { Start(); return; }
    if (Stage == 3)
    {
        // Paid finish and M32 closure run their existing sampled path. No
        // InitializeReload/CanReload call is needed on a full magazine.
        if (Runtime.FinishProfileToken > 0 || Runtime.M32ClosePending > 0) return;
        if (Owner.bActive && Owner.Runtime == Runtime) Owner.HandBackAutomatic();
        Stage = 2;
        bSawReload = Gun.IsInState('Reloading');
        bPaid = true; bActionDone = true;
    }
    if (Stage == 4) { UpdateRack(); return; }
    if (Stage == 5)
    {
        if (Runtime.bManualPumpPending) return;
        Release(); return;
    }
    if (Stage != 2) return;
    if (Owner.Secondary != None && Owner.Secondary.OwnsAutomatic(Gun)) return;
    if ((Owner.ServerMagazine != None && Owner.ServerMagazine.Owns(Gun))
        || (Owner.Vampire != None && Owner.Vampire.Gun == Gun && Owner.Vampire.Busy())
        || (Owner.Brawlers != None && Owner.Brawlers.Gun == Gun && Owner.Brawlers.Busy())) return;
    ObservePayment();
    if (Gun.IsInState('Reloading') || (bSecondary && Gun.IsInState('AltReloading')))
    {
        bSawReload = true;
        return;
    }
    if (!bSawReload && Owner.Now() - BeganAt < 0.25) return;
    // A paid insert followed by AbortReload still owes its unplayed action.
    // Only stock's completed status, or our completed paid stroke, retires it.
    if (bPaid && !bSecondary && (bActionDone || bStockCompleted))
    {
        SettleAction();
        if (class'VRPumpCatalog'.static.IsLever(Gun) && Runtime.bManualPumpPending)
        { Stage = 5; return; }
    }
    Release();
}

function Start()
{
    local name Clip;
    local float Position;
    local bool Detached;
    if (AuthoredUntil > 0)
    {
        if (Owner.Bridge.WorldInfo.TimeSeconds > AuthoredUntil
            || (!class'VRWeaponRuntime'.static.StockIdle(Gun) && !Gun.IsInState('WeaponSingleFiring')))
        { Release(); return; }
        if (!class'VRWeaponRuntime'.static.StockIdle(Gun)) return;
        AuthoredUntil = 0;
    }
    if (Owner.OwnRemovalStatus() == 1 && Owner.Runtime == Runtime) return;
    if (bSecondary)
    {
        Stage = 2;
        if (Owner.Secondary == None || !Owner.Secondary.BeginAutomatic(Runtime, Hand))
        { Release(); return; }
        bSawReload = Gun.IsInState('AltReloading');
        return;
    }
    if (class'VRServerMagazineReload'.static.Supports(Gun))
    { Stage = 2; if (!Owner.ServerMagazine.BeginAutomatic(Runtime, Hand)) Release(); return; }
    if (Owner.Brawlers != None && Owner.Brawlers.AcceptsGun(Gun))
    { Stage = 2; if (!Owner.Brawlers.BeginAutomatic(Runtime, Hand)) Release(); return; }
    if (Owner.Vampire != None && Owner.Vampire.AcceptsGun(Gun))
    { Stage = 2; if (!Owner.Vampire.BeginAutomatic(Runtime, Hand)) Release(); return; }
    if (Runtime.FinishProfileToken > 0 || (Runtime.M32ClosePending > 0
        && !(Owner.bActive && Owner.Runtime == Runtime && Owner.MagazineReloading(Gun))))
    {
        Stage = 3;
        if (!Owner.bActive) Owner.Begin(Runtime, Hand, false, true);
        if (!Owner.bActive || Owner.Runtime != Runtime) Release();
        return;
    }
    if (!Runtime.MagazineOut() && Gun.AmmoCount[0] > 0
        && (Runtime.MagazineNeedsRack() || Runtime.bSlideLockPending
            || (Runtime.EmptyMagazineFlags & 3) == 2))
    {
        Stage = 4;
        if (!Owner.bActive) Owner.Begin(Runtime, Hand, false, true);
        if (!Owner.bActive || Owner.Runtime != Runtime) { Release(); return; }
        ActionAt = Owner.Now();
        ActionFrom = FClamp(Owner.RackPull / FMax(Owner.RackTravel(), 0.01), 0, 1);
        bReturning = Owner.bPulledBack || Owner.bSlideLock;
        ActionDuration = class'VRReloadFinishAction'.static.AutomaticDuration(
            FMax(Gun.MySkelMesh.GetAnimLength(Owner.InsertAnim) - Owner.RigSample.SeatTime, 0.16) * 0.5,
            Gun.GetReloadRateScale());
        return;
    }
    if (Owner.bActive && Owner.Runtime == Runtime)
    {
        Detached = !Owner.MagazineReloading(Gun);
        Clip = Owner.InsertAnim;
        Position = Owner.InsertTime + (Owner.InsertEndTime - Owner.InsertTime) * Owner.InsertGuide.InsertFraction();
        bPaid = Owner.bAmmoStepPaid && !Owner.bShells;
        Owner.HandBackAutomatic();
        if (!Detached) { Stage = 2; bSawReload = true; return; }
    }
    if (Runtime.bManualPumpPending && Gun.AmmoCount[0] > 0 && !Gun.CanReload(0))
    { Stage = 5; return; }
    if (Runtime.CanStartStockSecondaryReload())
    {
        bSecondary = true; InitialAmmo = Gun.AmmoCount[1];
        Start(); return;
    }
    Stage = 2;
    Runtime.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE, true);
    Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    bSawReload = Gun.IsInState('Reloading');
    // The magazine already left: resume the stock insert at its retained
    // guide position instead of replaying extraction or requesting payment.
    if (Detached && bSawReload && Clip != '' && Gun.WeaponAnimSeqNode != None
        && Gun.WeaponAnimSeqNode.AnimSeqName == Clip)
    {
        Gun.WeaponAnimSeqNode.SetPosition(Position, false);
        if (Gun.IsTimerActive('ReloadAmmoTimer'))
            Gun.SetTimer(FMax(0.01, Gun.GetRemainingTimeForTimer('ReloadAmmoTimer')
                - Position * Gun.GetReloadRateScale()), false, 'ReloadAmmoTimer');
        if (Gun.IsTimerActive('ReloadStatusTimer'))
            Gun.SetTimer(FMax(0.02, Gun.GetRemainingTimeForTimer('ReloadStatusTimer')
                - Position * Gun.GetReloadRateScale()), false, 'ReloadStatusTimer');
    }
}

function UpdateRack()
{
    local float Amount;
    if (!Owner.bActive || Owner.Runtime != Runtime) { Release(); return; }
    Owner.PauseStock();
    if (!bReturning)
    {
        Amount = FMin(1, ActionFrom + (Owner.Now() - ActionAt) / ActionDuration);
        if (Amount >= 1 && Owner.bOpenBolt)
        {
            Owner.CockOpenBolt(true);
            if (Owner.bActive && Owner.Runtime == Runtime) Owner.HandBackAutomatic();
            bPaid = true; bActionDone = true; Stage = 2; bSawReload = Gun.IsInState('Reloading');
            return;
        }
        if (Amount >= 1) { bReturning = true; ActionAt = Owner.Now(); ActionFrom = 1; }
    }
    else Amount = FMax(0, ActionFrom - (Owner.Now() - ActionAt) / ActionDuration);
    Owner.RackPull = Amount * Owner.RackTravel(); Owner.SetRackPull(Owner.RackPull);
    if (!bReturning || Amount > 0) return;
    Owner.Rack(true, true);
    if (Owner.bActive && Owner.Runtime == Runtime) Owner.HandBackAutomatic();
    bPaid = true; bActionDone = true; Stage = 2; bSawReload = Gun.IsInState('Reloading');
}
