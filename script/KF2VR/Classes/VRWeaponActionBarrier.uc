// Audited live-round counts and irreversible physical-cycle debit. Callers
// order stock handlers first and own the exact actor/held-revision fence.
class VRWeaponActionBarrier extends Object;

// Only audited closed-breech manual actions and live-cartridge pistol rigs.
static function int LiveRoundCount(KFWeapon W)
{
    if (W == None) return 0;
    if (W.Class == class'KFWeap_Rifle_M99' || class'VRCompoundBowAuthority'.static.Supports(W)) return 1;
    if (class'VRPumpCatalog'.static.PumpAction(W) || class'VRCycleCatalog'.static.Covers(W)) return 1;
    if (ClassIsChildOf(W.Class, class'KFWeap_Pistol_AF2011')) return 2;
    if (class'VRWeaponRuntime'.static.TracksWeaponMagazineFeed(W)) return 1;
    return 0;
}

// A rear/open crossing or deliberate paid-arrow drop removes a live round once. It creates no reserve credit
// or dropped-mag escrow and never performs stock reload payment.
static function bool Eject(KFWeapon W, int ExpectedAmmo, int Count)
{
    local VRWeaponPair Pair;
    if (W == None || W.bDeleteMe || W.Role != ROLE_Authority || !class'VRWeaponRuntime'.static.StockIdle(W)
        || Count <= 0
        || Count != Min(ExpectedAmmo, LiveRoundCount(W)) || ExpectedAmmo < Count || W.AmmoCount[0] != ExpectedAmmo) return false;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None) return Pair.EjectLiveRounds(W, ExpectedAmmo, Count);
    // Exact admission above precedes the synchronous paid payload export.
    // Spent cases never call this writer; only this accepted live debit does.
    if (!class'VRWorldMagazineRegistry'.static.PreserveLoadedRounds(W, KFPawn_Human(W.Instigator), W, Count, 1)) return false;
    W.AmmoCount[0] -= Count;
    W.bForceNetUpdate = true;
    return true;
}

