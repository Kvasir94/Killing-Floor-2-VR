// Shared solo/server transaction for the exact stock Vampire actor. Stock
// PerformReload(0) remains the only ammunition writer; blood is never touched.
class VRVampireReloadAuthority extends Object;

const Idle = 0;
const Held = 1;
const Committed = 2;
const Cancelled = 3;
const Stock = 4;
const TimeoutSeconds = 45.0;

var KFPawn_Human Human;
var KFPlayerController Controller;
var KFWeapon Gun;
var int SessionId;
var int Status;
var int NativeFence, NativePayment, NativeVersion;
var private float Deadline, NotBefore;
var private int AmmoAtBegin;

// The matching adapter acknowledges this exact owned authority callback.
// An unhooked or older adapter cannot arm an unsafe server timer hold.
function NativeVampireReloadGate() { NativeVersion = 0; }

static function bool Supports(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_HRG_Vampire'
        && !W.bAllowClientAmmoTracking && W.GetAmmoType(0) == 0;
}

function bool OwnsWeapon()
{
    local KFWeapon W;
    if (Human == None || Human.Role != ROLE_Authority || Human.bDeleteMe
        || Human.Health <= 0 || Controller == None || Controller.bDeleteMe
        || Controller.Pawn != Human || Human.Controller != Controller
        || Gun == None || Gun.bDeleteMe || Gun.Role != ROLE_Authority
        || Gun.Owner != Human || Gun.Instigator != Human
        || Human.InvManager == None || Gun.InvManager != Human.InvManager) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (W == Gun) return true;
    }
    return false;
}

function bool Valid()
{
    return (Status == Held || Status == Stock) && OwnsWeapon() && Supports(Gun)
        && Gun.IsInState('Reloading') && !Gun.IsInState('AltReloading')
        && Human.CanReloadWeapon()
        && KFInventoryManager(Human.InvManager) != None
        && !KFInventoryManager(Human.InvManager).bServerTraderMenuOpen
        && Human.WorldInfo.RealTimeSeconds < Deadline;
}

function ClearReloadTimers()
{
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
}

function ClearQueuedFire()
{
    local int Mode;
    for (Mode = 0; Mode < Gun.GetPendingFireLength(); ++Mode)
        Gun.ClearPendingFire(byte(Mode));
}

function bool Begin(KFPawn_Human P, KFWeapon W, int NewSession, optional bool bStock)
{
    local float Interrupt;
    if (Status == Held || Status == Stock || NewSession <= SessionId || NewSession <= 0
        || NewSession == MaxInt || P == None || !Supports(W)) return false;
    Human = P;
    Controller = KFPlayerController(P.Controller);
    Gun = W;
    if (!OwnsWeapon()) return false;
    NativeVampireReloadGate();
    if (NativeVersion != 1) return false;
    SessionId = NewSession;
    Status = Cancelled;
    if (!Gun.IsInState('Active') || !Gun.CanReload(0) || Gun.MySkelMesh == None
        || KFInventoryManager(P.InvManager) == None
        || KFInventoryManager(P.InvManager).bServerTraderMenuOpen) return false;
    // Arm only after admission: an earlier unmanaged reload must retain its
    // stock payment when this first request is rejected as already reloading.
    // Once armed, persist across terminal states and rejected later requests:
    // a delayed stock RPC has no session ID to distinguish it from a new one.
    NativeFence = 1;
    Deadline = P.WorldInfo.RealTimeSeconds + TimeoutSeconds;
    AmmoAtBegin = Gun.AmmoCount[0];
    Status = bStock ? Stock : Held;
    // Clear queued fire before entering or leaving stock Active. Dedicated
    // SendToFiringState does not InitializeReload for a remote instigator.
    ClearQueuedFire();
    Gun.InitializeReload();
    Gun.SendToFiringState(class'KFWeapon'.const.RELOAD_FIREMODE);
    // Read the rate in Reloading: stock chooses primary versus alternate
    // upgrade rates using the current weapon state.
    Interrupt = Gun.GetReloadRateScale() * Gun.MySkelMesh.GetAnimInterruptTime(
        Gun.GetReloadAnimName(Gun.UseTacticalReload()));
    NotBefore = P.WorldInfo.TimeSeconds + Interrupt;
    // This completes synchronously before the transport can acknowledge Held.
    if (!bStock) ClearReloadTimers();
    if (!Valid() || !(Interrupt > 0 && Interrupt < TimeoutSeconds))
    { Cancel(SessionId); return false; }
    return true;
}

function bool Commit(int ExpectedSession)
{
    if (ExpectedSession != SessionId || Status != Held || !Valid()
        || Human.WorldInfo.TimeSeconds < NotBefore || Gun.AmmoCount[0] != AmmoAtBegin) return false;
    ClearReloadTimers();
    ClearQueuedFire();
    // Retire the transaction before either stock callback can reenter us.
    Status = Committed;
    NativePayment = 1;
    Gun.PerformReload(0);
    NativePayment = 0;
    Gun.ReloadComplete();
    Gun.bForceNetUpdate = true;
    return true;
}

// A retired inventory identity can already have been reacquired. Its new
// owner's state must not be changed by cleanup of this old transaction.
function bool Cancel(int ExpectedSession, optional bool bAbandonWeapon)
{
    if (ExpectedSession != SessionId || (Status != Held && Status != Stock)) return false;
    Status = Cancelled;
    if (!bAbandonWeapon && OwnsWeapon() && Gun.IsInState('Reloading'))
    {
        ClearReloadTimers();
        ClearQueuedFire();
        Gun.AbortReload();
        Gun.bForceNetUpdate = true;
    }
    return true;
}

function Tick()
{
    if (Status == Stock && OwnsWeapon() && !Gun.IsInState('Reloading'))
    {
        Status = Gun.AmmoCount[0] > AmmoAtBegin ? Committed : Cancelled;
        return;
    }
    if ((Status == Held || Status == Stock) && (!Valid()
        || (Status == Held && Gun.AmmoCount[0] != AmmoAtBegin))) Cancel(SessionId);
}

// Native ingress guard uses this exact identity, never weapon class alone.
function bool SuppressesStock(KFWeapon W)
{
    return Status == Held && W != None && W == Gun && NativePayment != 1;
}
