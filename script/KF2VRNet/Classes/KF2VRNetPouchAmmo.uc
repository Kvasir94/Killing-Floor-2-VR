// One owner-wide outstanding discard fences shared pair/currency pools as
// well as the exact gun. The weapon marker orders earlier stock reload sync;
// no later owner-channel payment may pass the acknowledged discard.
class KF2VRNetPouchAmmo extends Object;

var KF2VRNetChannel Source;
var KFWeapon LocalWeapon, ServerWeapon;
var VRWeaponRuntime LocalRuntime;
var int LocalWorld, LocalConnection, LocalPawn, LocalSerial, LocalCount, Predicted;
var byte LocalSlot;
var vector LocalAt, LocalVelocity, ServerAt, ServerVelocity;
var rotator LocalFacing, ServerFacing;
var float LocalScale, ServerScale;
var int ServerWorld, ServerConnection, ServerPawn, ServerSerial, ServerCount, LastServerSerial;
var byte ServerSlot;
var float Deadline, LocalQueuedAt;
var bool bReply;
var int ReplyActual, ReplyRevision, ReplyReserve;
var int CurrencyRevision, CurrencyWorld, CurrencyConnection, CurrencyPawn;
var float CurrencyScore, NextCurrencyUpdate;
var VRWeaponPair ReplyPair;

// Currency is quoted from this ordered owner-channel stream, never from
// potentially older PRI replication arriving on a different actor channel.
function UpdateCurrency(optional bool Force)
{
    local PlayerController PC;
    local float Score;
    if (Source == None || Source.Role != ROLE_Authority) return;
    if (!Force && Source.WorldInfo.RealTimeSeconds < NextCurrencyUpdate) return;
    NextCurrencyUpdate = Source.WorldInfo.RealTimeSeconds + 0.1;
    PC = PlayerController(Source.Owner);
    if (PC == None || PC.PlayerReplicationInfo == None) return;
    Score = PC.PlayerReplicationInfo.Score;
    if (CurrencyRevision > 0 && CurrencyWorld == Source.WorldEpoch
        && CurrencyConnection == Source.ConnectionEpoch && CurrencyPawn == Source.PawnEpoch
        && CurrencyScore == Score) return;
    ++CurrencyRevision; CurrencyScore = Score;
    CurrencyWorld = Source.WorldEpoch; CurrencyConnection = Source.ConnectionEpoch; CurrencyPawn = Source.PawnEpoch;
    Source.ClientPouchCurrency(CurrencyWorld, CurrencyConnection, CurrencyPawn, CurrencyRevision, Score);
}

function ReceiveCurrency(int WE, int CE, int PE, int Revision, float Score)
{
    // A reliable snapshot can precede epoch property replication. Keep it
    // pending; Dosh exposes it only when the channel epochs match.
    if (Revision <= CurrencyRevision || WE <= 0 || CE <= 0 || PE <= 0) return;
    CurrencyRevision = Revision; CurrencyScore = Score;
    CurrencyWorld = WE; CurrencyConnection = CE; CurrencyPawn = PE;
}

function int Dosh()
{
    if (CurrencyRevision <= 0 || CurrencyWorld != Source.WorldEpoch
        || CurrencyConnection != Source.ConnectionEpoch || CurrencyPawn != Source.PawnEpoch) return 0;
    return Max(int(CurrencyScore), 0);
}

function bool LocallyOwned(KFWeapon W)
{
    return Source != None && Source.HeldState.Human != None && Source.HeldState.Human.Health > 0
        && W != None && !W.bDeleteMe && W.Owner == Source.HeldState.Human
        && W.Instigator == Source.HeldState.Human && W.InvManager == Source.HeldState.Human.InvManager;
}

function bool Queue(KFWeapon W, int Count, byte Slot, vector At, rotator Facing, vector Velocity, float Scale)
{
    if (LocalWeapon != None || Source == None
        || Source.HeldState.NativePouchAmmoVersion != 3 || W == None
        || !LocallyOwned(W)
        || Count <= 0 || Count > class'VRPouchAmmo'.static.Limit(W, Slot)) return false;
    LocalWeapon = W; LocalCount = Count; LocalSlot = Slot;
    LocalAt = At; LocalFacing = Facing; LocalVelocity = Velocity; LocalScale = Scale;
    LocalWorld = Source.WorldEpoch; LocalConnection = Source.ConnectionEpoch; LocalPawn = Source.PawnEpoch;
    LocalSerial = 0; Predicted = 0; bReply = false;
    LocalQueuedAt = Source.WorldInfo.RealTimeSeconds;
    return true;
}

function ClearLocal()
{
    LocalWeapon = None; LocalRuntime = None; LocalSerial = 0;
    LocalCount = 0; Predicted = 0; bReply = false; ReplyPair = None;
}

function bool Pending()
{
    local KF2VRNetPlayerController PC;
    local VRHandsBridge Bridge;
    local bool bExpired;
    if (LocalWeapon == None) return false;
    if (Source == None || LocalWorld != Source.WorldEpoch || LocalConnection != Source.ConnectionEpoch
        || LocalPawn != Source.PawnEpoch || LocalWeapon.bDeleteMe
        || !LocallyOwned(LocalWeapon))
    { ClearLocal(); return false; }
    // While pending, every gun's reload is parked. An unsent discard costs
    // nothing to drop; a sent one settles as refused (prediction refunded)
    // or, with its reply in, without waiting longer for the marker.
    bExpired = Source.WorldInfo.RealTimeSeconds - LocalQueuedAt > class'KF2VRNetChannel'.const.OwnerReplyDeadline;
    if (bExpired)
        `log("KF2VRNet owner_wait phase=expired kind=pouch_discard serial=" $ LocalSerial @ "reply=" $ bReply
            @ "weapon=" $ LocalWeapon);
    if (LocalSerial == 0 && bExpired) { ClearLocal(); return false; }
    if (LocalSerial == 0)
    {
        if (!Source.CanRequestHeldWeapons() || !Source.OwnerActionsSettled(LocalWeapon, 0, true, true)) return true;
        PC = KF2VRNetPlayerController(Source.Owner);
        if (PC != None) Bridge = VRHandsBridge(PC.LocalVRBridge);
        if (Bridge == None || Bridge.HeldInventory == None) return true;
        LocalRuntime = Bridge.HeldInventory.RegisterItem(LocalWeapon);
        if (LocalRuntime == None || !LocalRuntime.IsCurrent() || LocalRuntime.NativeReady != 1) return true;
        LocalSerial = Source.NextWeaponActionSerial();
        if (LocalSerial <= 0) return true;
        if (LocalSlot == 0 && LocalWeapon.Role < ROLE_Authority && class'VRPouchAmmo'.static.Predictable(LocalWeapon))
            Predicted = class'VRPouchAmmo'.static.Discard(LocalWeapon, LocalCount, LocalSlot);
        LocalWeapon.SyncCurrentAmmoCount(255, LocalSerial);
        Source.ServerPouchDiscard(LocalWorld, LocalConnection, LocalPawn, LocalSerial, LocalWeapon, LocalCount, LocalSlot, LocalAt, LocalFacing, LocalVelocity, LocalScale);
    }
    if (!bExpired && (!bReply || ((ReplyActual > 0 || LocalSlot == 1) && LocalWeapon.Role < ROLE_Authority && LocalRuntime.WeaponReceiptSerial < LocalSerial))) return true;
    if (!bExpired && ReplyPair != None && ReplyPair.Revision < ReplyRevision) return true;
    if (!bReply) { ReplyActual = 0; ReplyReserve = -1; ReplyPair = None; }
    // Secondary drops are corrected exactly once before the weapon receipt,
    // including refusals. No prediction/refund may run after a newer pickup.
    if (LocalSlot == 0 && LocalWeapon.Role < ROLE_Authority && class'VRPouchAmmo'.static.Predictable(LocalWeapon))
        LocalWeapon.SpareAmmoCount[LocalSlot] += Predicted - ReplyActual;
    if (LocalSlot == 0 && LocalWeapon.Role < ROLE_Authority && !class'VRPouchAmmo'.static.Predictable(LocalWeapon)
        && ReplyPair == None && KFWeap_AssaultRifle_Doshinegun(LocalWeapon) == None && ReplyReserve >= 0 && LocalRuntime.WeaponReceiptSerial == LocalSerial)
        LocalWeapon.SpareAmmoCount[LocalSlot] = ReplyReserve;
    ClearLocal();
    return false;
}

function int Reserved(KFWeapon W, byte Slot)
{
    local VRWeaponPair Pair;
    if (LocalWeapon == None || Slot != LocalSlot || Predicted > 0) return 0;
    // The weapon correction has already removed these rounds even if the
    // owner-channel acknowledgement has not arrived yet.
    if (LocalSlot == 1 && LocalSerial > 0 && LocalRuntime != None
        && LocalRuntime.WeaponReceiptSerial >= LocalSerial) return 0;
    Pair = class'VRWeaponPair'.static.ForMember(LocalWeapon);
    return (W == LocalWeapon || (Slot == 0 && Pair != None && Pair.IsMember(W))) ? LocalCount : 0;
}

function Begin(int WE, int CE, int PE, int Serial, KFWeapon W, int Count, byte Slot, vector At, rotator Facing, vector Velocity, float Scale)
{
    if (Source == None || WE != Source.WorldEpoch || CE != Source.ConnectionEpoch || PE != Source.PawnEpoch
        || Serial <= 0 || Serial == MaxInt || Serial <= LastServerSerial || ServerWeapon != None) return;
    LastServerSerial = Serial;
    ServerWorld = WE; ServerConnection = CE; ServerPawn = PE;
    ServerSerial = Serial; ServerWeapon = W; ServerCount = Count; ServerSlot = Slot;
    ServerAt = At; ServerFacing = Facing; ServerVelocity = Velocity; ServerScale = Scale;
    Deadline = Source.WorldInfo.RealTimeSeconds + 3;
    UpdateServer();
}

function Finish(int Actual)
{
    local VRWeaponPair Pair;
    Pair = class'VRWeaponPair'.static.ForMember(ServerWeapon);
    if (ServerWeapon != None)
    {
        if (ServerSlot == 1 && class'VRWorldDropTransfer'.static.Owns(Source.HeldState.Human, ServerWeapon))
            class'VRSecondaryAmmoPools'.static.CorrectOwner(ServerWeapon);
        ServerWeapon.ClientForceAmmoUpdate(-255, ServerSerial);
    }
    UpdateCurrency(true);
    Source.ClientPouchDiscard(ServerWorld, ServerConnection, ServerPawn, ServerSerial, ServerWeapon,
        Actual, Pair, Pair != None ? Pair.Revision : 0, class'VRPouchAmmo'.static.Reserve(ServerWeapon, ServerSlot));
    ServerWeapon = None; ServerSerial = 0;
}

function UpdateServer()
{
    local KF2VRNetItemRuntime R;
    if (ServerSerial <= 0) return;
    if (ServerWorld != Source.WorldEpoch || ServerConnection != Source.ConnectionEpoch || ServerPawn != Source.PawnEpoch
        || Source.NativePouchAmmoVersion != 3 || !class'VRWorldDropTransfer'.static.Owns(Source.HeldState.Human, ServerWeapon)
        || ServerCount <= 0 || ServerCount > class'VRPouchAmmo'.static.Limit(ServerWeapon, ServerSlot))
    { Finish(0); return; }
    R = Source.WorldDropRuntime(ServerWeapon);
    if (R == None || R.NativeReady != 1 || Source.WorldInfo.RealTimeSeconds >= Deadline)
    { Finish(0); return; }
    if (R.WeaponBarrierSerial < ServerSerial) return;
    Finish(class'VRPouchAmmo'.static.Release(Source, Source.HeldState.Human, ServerWeapon, ServerCount, ServerSlot,
        ServerSerial, ServerAt, ServerFacing, ServerVelocity, ServerScale));
}

function Receive(int WE, int CE, int PE, int Serial, KFWeapon W, int Actual, VRWeaponPair Pair, int Revision, int Reserve)
{
    if ((LocalWeapon != W && (W != None || Actual != 0)) || LocalSerial != Serial || Serial <= 0 || bReply
        || WE != LocalWorld || CE != LocalConnection || PE != LocalPawn || Actual < 0 || Actual > LocalCount) return;
    bReply = true; ReplyActual = Actual; ReplyReserve = Reserve; ReplyPair = Pair; ReplyRevision = Revision;
}
