// Shared solo/server transaction for exact stock server-ammo weapons. Stock
// PerformReload(0) owns ammo, currency and perk rules; resources are never copied.
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
var private bool bLoseMagazine, bMagazineRemoved;

// The matching adapter acknowledges this exact owned authority callback.
// An unhooked or older adapter cannot arm an unsafe server timer hold.
function NativeVampireReloadGate() { NativeVersion = 0; }

static function bool Supports(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_HRG_Vampire'
        || W.Class == class'KFWeap_HRG_BlastBrawlers'
        || W.Class == class'KFWeap_HRG_BallisticBouncer'
        || W.Class == class'KFWeap_Mine_Reconstructor'
        || W.Class == class'KFWeap_AssaultRifle_Doshinegun')
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

function bool Begin(KFPawn_Human P, KFWeapon W, int NewSession, optional bool bStock, optional bool bLoseAmmo)
{
    local float Interrupt;
    local KFWeapon PreviousGun;
    local KFPawn_Human PreviousHuman;
    local KFPlayerController PreviousController;
    if (Status == Held || Status == Stock || NewSession <= SessionId || NewSession <= 0
        || NewSession == MaxInt || P == None || !Supports(W)) return false;
    // A rejected candidate must not replace the previous fenced identity.
    PreviousGun = Gun; PreviousHuman = Human; PreviousController = Controller;
    Human = P;
    Controller = KFPlayerController(P.Controller);
    Gun = W;
    if (!OwnsWeapon() || (!Gun.IsInState('Active') && !Gun.IsInState('WeaponSprinting')) || !Gun.CanReload(0) || Gun.MySkelMesh == None
        || KFInventoryManager(P.InvManager) == None
        || KFInventoryManager(P.InvManager).bServerTraderMenuOpen)
    {
        Gun = PreviousGun; Human = PreviousHuman; Controller = PreviousController;
        return false;
    }
    NativeVampireReloadGate();
    if (NativeVersion != 1)
    {
        Gun = PreviousGun; Human = PreviousHuman; Controller = PreviousController;
        return false;
    }
    SessionId = NewSession;
    Status = Cancelled;
    // Arm only after admission: an earlier unmanaged reload must retain its
    // stock payment when this first request is rejected as already reloading.
    // Once armed, persist across terminal states and rejected later requests:
    // a delayed stock RPC has no session ID to distinguish it from a new one.
    NativeFence = 1;
    Deadline = P.WorldInfo.RealTimeSeconds + TimeoutSeconds;
    // Admission alone removes nothing. The physical canister must actually
    // leave after the owner's asset/pose preflight before its rounds are lost.
    bMagazineRemoved = bStock || (Gun.Class != class'KFWeap_HRG_BallisticBouncer'
        && Gun.Class != class'KFWeap_Mine_Reconstructor');
    bLoseMagazine = bLoseAmmo && !bMagazineRemoved;
    // The busy-hand automatic reload (R5) drops the old canister at once:
    // the same loss and recoverable prop as a hand removal, before stock
    // sizes its refill from the emptied well.
    if (bStock && bLoseAmmo && Gun.AmmoCount[0] > 0
        && (Gun.Class == class'KFWeap_HRG_BallisticBouncer' || Gun.Class == class'KFWeap_Mine_Reconstructor'))
    {
        if (!class'VRWorldMagazineRegistry'.static.PreserveCylinder(Human, Human, Gun, Gun.AmmoCount[0]))
        { Status = Cancelled; return false; }
        Gun.AmmoCount[0] = 0;
        Gun.bForceNetUpdate = true;
    }
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

function bool RemoveMagazine(int ExpectedSession)
{
    if (ExpectedSession != SessionId || Status != Held || !Valid()
        || Gun.AmmoCount[0] != AmmoAtBegin) return false;
    if (bMagazineRemoved) return true;
    if (bLoseMagazine && !class'VRWorldMagazineRegistry'.static.PreserveCylinder(Human, Human, Gun, Gun.AmmoCount[0])) return false;
    bMagazineRemoved = true;
    if (bLoseMagazine)
    {
        Gun.AmmoCount[0] = 0;
        AmmoAtBegin = 0;
        Gun.ReloadAmountLeft = Min(Gun.MagazineCapacity[0], Gun.SpareAmmoCount[0]);
        Gun.InitialReloadAmount = Gun.ReloadAmountLeft;
        Gun.bForceNetUpdate = true;
    }
    return true;
}

function bool Commit(int ExpectedSession, optional int Maximum)
{
    local KFWeap_AssaultRifle_Doshinegun DoshGun;
    local int Added;
    if (ExpectedSession != SessionId || Status != Held || !bMagazineRemoved || !Valid()
        || Human.WorldInfo.TimeSeconds < NotBefore || Gun.AmmoCount[0] != AmmoAtBegin) return false;
    ClearReloadTimers();
    ClearQueuedFire();
    // Retire the transaction before either stock callback can reenter us.
    Status = Committed;
    NativePayment = 1;
    class'VRPouchAmmo'.static.ClampPayment(Gun, Maximum);
    DoshGun = KFWeap_AssaultRifle_Doshinegun(Gun);
    if (DoshGun != None && Maximum > 0 && !Gun.bInfiniteSpareAmmo)
    {
        // Stock Dosh ignores ReloadAmountLeft. Its currency payment must
        // also respect the notes physically taken out of the pouch.
        Added = Min(Maximum, Min(Gun.MagazineCapacity[0] - Gun.AmmoCount[0], class'VRPouchAmmo'.static.Reserve(Gun)));
        Gun.AmmoCount[0] += Added;
        if (DoshGun.KFPRI != None) DoshGun.KFPRI.AddDosh(-Added * Max(DoshGun.DoshCost, 1));
        Gun.ReloadAmountLeft = 0; DoshGun.ShotsHit = 0;
    }
    else if (Maximum > 0) class'VRPouchAmmo'.static.PerformPhysicalReload(Gun, Maximum);
    else Gun.PerformReload(0);
    NativePayment = 0;
    // Stock rechecks the real resource at payment (notably Dosh balance).
    // Keep this attempt terminal even if it credits nothing: a repeated seat
    // must not spend later resources or announce an unfilled magazine.
    if (Gun.AmmoCount[0] <= AmmoAtBegin) Status = Cancelled;
    Gun.ReloadComplete();
    Gun.bForceNetUpdate = true;
    // The owner learns a server-counted load (the Doshinegun has no client
    // ammo tracking) only from the authority, as VRCompoundBowAuthority does
    // for its committed arrow: stock's reliable correction. Without it the
    // owner sat at 0 against the server's 20 until the reload timed out (#146).
    if (Status == Committed && Human != None && !Human.IsLocallyControlled())
        Gun.ClientForceAmmoUpdate(Gun.AmmoCount[0], Gun.SpareAmmoCount[0]);
    // The intent was consumed exactly once; Status reports its outcome.
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
