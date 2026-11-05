// Shared authority-side release seam. Physical drawing stays outside stock
// CompoundBowCharge; only an admitted release enters it synchronously.
class VRCompoundBowAuthority extends Object;

// Captured at string acquisition, shared by local input and owner transport.
struct VRBowReleaseIdentity
{
    var int Revision, WorldEpoch, ConnectionEpoch, PawnEpoch;
    var int CalibrationEpoch, ReferenceEpoch;
};

const Releasing = 1;
const Committed = 2;
const Rejected = 3;

var KFPawn_Human Human;
var KFPlayerController Controller;
var KFWeap_Bow_CompoundBow Gun;
var int RequestId, Status;
var int NativeVersion, NativeFence, NativePermit, NativeEntered, NativeShotCount, NativeFault;
var vector ReleaseOrigin;
var rotator ReleaseRotation;
var private float NotBefore;

// Exact callbacks are acknowledged only by a matching local/server adapter.
function NativeBowReleaseGate() { NativeVersion = 0; }

function NativeBowReleaseShot()
{
    if (NativePermit == 1 && NativeEntered == 1 && Status == Releasing)
        Gun.HandleFinishedFiring();
}

static function bool Supports(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_Bow_CompoundBow';
}

function bool OwnsWeapon()
{
    local KFWeapon W;
    if (Human == None || Human.Role != ROLE_Authority || Human.bDeleteMe
        || Human.Health <= 0 || Controller == None || Controller.bDeleteMe
        || Human.Controller != Controller || Controller.Pawn != Human
        || Gun == None || Gun.bDeleteMe || Gun.Role != ROLE_Authority
        || Gun.Owner != Human || Gun.Instigator != Human
        || Human.InvManager == None || Gun.InvManager != Human.InvManager) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (W == Gun) return true;
    return false;
}

function bool Available()
{
    if (!OwnsWeapon() || !Supports(Gun)) return false;
    NativeVersion = 0;
    NativeBowReleaseGate();
    return NativeVersion == 1;
}

// Stock reload synchronization may credit the arrow before its server-side
// animation tail leaves Reloading. This reports readiness without paying it.
function bool Ready()
{
    return NativeVersion == 1 && OwnsWeapon() && Supports(Gun)
        && (Gun.IsInState('Active') || Gun.IsInState('Reloading'))
        && !Gun.bWeaponPutDown && !Human.bNoWeaponFiring && Gun.AmmoCount[0] == 1
        && !Gun.IsTimerActive('RefireCheckTimer') && !Gun.IsTimerActive('ForceReload')
        && Human.WorldInfo.TimeSeconds >= NotBefore
        && KFInventoryManager(Human.InvManager) != None
        && !KFInventoryManager(Human.InvManager).bServerTraderMenuOpen;
}

function ClearQueuedFire()
{
    local int Mode;
    for (Mode = 0; Mode < Gun.GetPendingFireLength(); ++Mode)
        Gun.ClearPendingFire(byte(Mode));
    Gun.StartFireModeAfterReload = class'KFWeapon'.const.FIREMODE_NONE;
    Gun.ClearTimer('Timer_StartFireAfterReload');
}

// Never StopFire/finish an uncommitted charge: both can release its arrow.
function AbortEntry()
{
    NativePermit = 0;
    if (!OwnsWeapon()) return;
    ClearQueuedFire();
    if (Gun.IsInState('CompoundBowCharge'))
    {
        Gun.ClearTimer('RefireCheckTimer');
        Gun.ChargeTime = 0;
        Gun.bIsFullyCharged = false;
        Gun.GotoState('Active');
    }
}

// Caller admits the immutable nocked-arrow identity, hand/pose revisions and
// context first. This layer owns stock state, charge, cooldown and payment.
function bool ClearArrowPath(vector Origin, vector Head)
{
    local vector HitLocation, HitNormal;
    return class'VRGrenadeThrow'.static.Bounded(Origin - Human.Location, 240)
        && class'VRGrenadeThrow'.static.Bounded(Head - Human.Location, 160)
        && Gun.Trace(HitLocation, HitNormal, Origin, Head, false) == None;
}

function bool Release(int NewRequest, byte Mode, vector Origin, rotator Aim, float Tension, vector Head)
{
    local float RefireRate, ReloadDelay;
    if (Status == Releasing || NewRequest <= RequestId || NewRequest <= 0
        || NewRequest == MaxInt) return false;
    RequestId = NewRequest;
    Status = Rejected;
    if (!Available() || !Ready() || Mode > 1 || !(Tension >= 0 && Tension <= 1)
        || !(Origin.X >= -10000000 && Origin.X <= 10000000
            && Origin.Y >= -10000000 && Origin.Y <= 10000000
            && Origin.Z >= -10000000 && Origin.Z <= 10000000)
        || Aim.Pitch < -32768 || Aim.Pitch > 65535
        || Aim.Yaw < -32768 || Aim.Yaw > 65535 || Aim.Roll < -32768 || Aim.Roll > 65535
        || !Gun.HasAmmo(Mode)
        || !ClearArrowPath(Origin, Head)) return false;

    if (Gun.IsInState('Reloading'))
    {
        // The existing weapon-channel sync already supplied this one arrow.
        // End only its tail; never call PerformReload or manufacture a sync.
        ClearQueuedFire();
        Gun.ReloadComplete();
        if (!OwnsWeapon() || !Gun.IsInState('Active')) return false;
    }

    ReleaseOrigin = Origin; ReleaseRotation = Aim;
    NativeFence = 1;
    NativeEntered = 0; NativeShotCount = 0; NativeFault = 0;
    ClearQueuedFire();
    Gun.SendToFiringState(Mode);
    RefireRate = Gun.GetTimerRate('RefireCheckTimer');
    if (!OwnsWeapon() || !Gun.IsInState('CompoundBowCharge')
        || !(Gun.StateMaxChargeTime > 0 && Gun.StateMaxChargeTime < 45)
        || !(Gun.StateValueIncreaseTime > 0 && Gun.StateValueIncreaseTime < 45)
        || !(RefireRate > 0 && RefireRate < 45))
    { AbortEntry(); return false; }

    ReloadDelay = Gun.HasSpareAmmo() ? Gun.GetForceReloadDelay() : 0.0;
    if (ReloadDelay > 0) RefireRate = FMax(RefireRate, ReloadDelay + Gun.GetFireInterval(Mode));
    if (!(RefireRate > 0 && RefireRate < 45)) { AbortEntry(); return false; }
    Gun.ChargeTime = Tension * Gun.StateMaxChargeTime;
    Gun.bIsFullyCharged = Tension >= 1;
    Status = Releasing;
    NativePermit = 1;
    NativeBowReleaseShot();
    NativePermit = 0;
    if (NativeEntered != 1 || NativeShotCount != 1)
    { Status = Rejected; AbortEntry(); return false; }

    // Completed stock firing consumes ammunition even when stock Spawn fails.
    // A late native fault must also retire this request, never invite a retry.
    Status = Committed;
    if (OwnsWeapon())
    {
        // Manual nocking owns the next reload in both solo and multiplayer.
        Gun.ClearTimer('ForceReload');
        NotBefore = Human.WorldInfo.TimeSeconds + RefireRate;
        Gun.bForceNetUpdate = true;
        Gun.ClientForceAmmoUpdate(Gun.AmmoCount[0], Gun.SpareAmmoCount[0]);
    }
    return true;
}
