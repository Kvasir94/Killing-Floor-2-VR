// Stock underbarrels keep a remote authority total instead of maintaining
// SpareAmmoCount[1] on every reload/pickup. Read it before owner identity is
// lost, and normalize both representations when moving the paid pool.
class VRSecondaryAmmoPools extends Object;

static function bool HasTotal(KFWeapon W)
{
    return KFWeap_AssaultRifle_M16M203(W) != None
        || KFWeap_AssaultRifle_MedicRifleGrenadeLauncher(W) != None
        || KFWeap_AssaultRifle_FAMAS(W) != None || KFWeap_Shotgun_S12(W) != None;
}

static function int Total(KFWeapon W)
{
    if (KFWeap_AssaultRifle_M16M203(W) != None) return KFWeap_AssaultRifle_M16M203(W).ServerTotalAltAmmo;
    if (KFWeap_AssaultRifle_MedicRifleGrenadeLauncher(W) != None) return KFWeap_AssaultRifle_MedicRifleGrenadeLauncher(W).ServerTotalAltAmmo;
    if (KFWeap_AssaultRifle_FAMAS(W) != None) return KFWeap_AssaultRifle_FAMAS(W).ServerTotalAltAmmo;
    if (KFWeap_Shotgun_S12(W) != None) return KFWeap_Shotgun_S12(W).ServerTotalAltAmmo;
    return 0;
}

// bRemoteStockDrop follows stock SetOriginalValuesFromPickup for an exact
// KFDroppedPickup received by a remote owner. It must not be inferred for a
// factory spawn or a public escrow: their explicit spare pool is normalized.
static function int Reserve(KFWeapon W, optional bool bRemoteStockDrop)
{
    if (W == None) return -1;
    if (W.Role == ROLE_Authority && HasTotal(W)
        && (bRemoteStockDrop || (W.Instigator != None && !W.Instigator.IsLocallyControlled())))
        return Total(W) - W.AmmoCount[1];
    return W.SpareAmmoCount[1];
}

static function Write(KFWeapon W, int Loaded, int Spare)
{
    if (W == None || W.Role != ROLE_Authority) return;
    W.AmmoCount[1] = Loaded; W.SpareAmmoCount[1] = Spare;
    if (KFWeap_AssaultRifle_M16M203(W) != None) KFWeap_AssaultRifle_M16M203(W).ServerTotalAltAmmo = Loaded + Spare;
    else if (KFWeap_AssaultRifle_MedicRifleGrenadeLauncher(W) != None) KFWeap_AssaultRifle_MedicRifleGrenadeLauncher(W).ServerTotalAltAmmo = Loaded + Spare;
    else if (KFWeap_AssaultRifle_FAMAS(W) != None) KFWeap_AssaultRifle_FAMAS(W).ServerTotalAltAmmo = Loaded + Spare;
    else if (KFWeap_Shotgun_S12(W) != None) KFWeap_Shotgun_S12(W).ServerTotalAltAmmo = Loaded + Spare;
    W.bNetDirty = true; W.bForceNetUpdate = true;
}

// Version-nine native peers decode this reserved weapon-channel message as
// slot-one counts. Send before the receipt marker, never replay on its reply:
// later stock secondary pickups must see and extend the corrected reserve.
static function CorrectOwner(KFWeapon W)
{
    local int Loaded, Spare;
    if (W == None || W.Role != ROLE_Authority || !class'VRSecondaryReloadCatalog'.static.Supported(W)) return;
    Loaded = W.AmmoCount[1]; Spare = Reserve(W);
    if (Loaded < 0 || Loaded > MaxInt - 256 || Spare < 0 || Spare > MaxInt - Loaded) return;
    W.ClientForceAmmoUpdate(-256 - Loaded, Spare);
}
