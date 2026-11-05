// Portable availability/geometry only. Stock actors and authority transactions
// retain every loaded round, reserve pool, upgrade and cooldown deadline.
class VRWeaponDropState extends Object;

struct HandlingState
{
    var class<KFWeapon> Family;
    var bool bCycleOwed, bSlideLockPending;
    var byte PumpPortStage;
    var int FeedFlags, EmptyMagazineFlags, CylinderEmptyMask;
    var int M32ClosePending;
    var float M32CloseAmount;
};

static function class<KFWeapon> FamilyFor(class<KFWeapon> WeaponClass)
{
    local int I;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (WeaponClass == class'VRWeaponPair'.default.Families[I].MemberClass
            || WeaponClass == class'VRWeaponPair'.default.Families[I].DualClass)
            return class'VRWeaponPair'.default.Families[I].SingleClass;
    return WeaponClass;
}

static function bool HasSlideLock(class<KFWeapon> Family)
{
    local int Profile;
    Profile = class'VRReloadCatalog'.static.FindClass(Family);
    // Authority need not stream the first-person AnimTree/EmptyMagBlend node.
    return Profile >= 0 && class'VRReloadCatalog'.default.Profiles[Profile].bSlideLock;
}

// Stock treats 9mm/93R pickups as the recipient's existing secondary family.
// Only a completed inventory handoff may translate these equivalent closed-
// bolt availability flags; release validation still requires the exact family.
static function MatchTransferredFamily(KFWeapon W, out HandlingState Snapshot)
{
    local class<KFWeapon> TargetFamily;
    if (W == None) return;
    TargetFamily = FamilyFor(W.Class);
    if (class'VRWorldDropTransfer'.static.SecondaryPistol(Snapshot.Family)
        && class'VRWorldDropTransfer'.static.SecondaryPistol(TargetFamily)) Snapshot.Family = TargetFamily;
}

static function bool HasEmptyMagazine(class<KFWeapon> Family)
{
    local int Profile;
    Profile = class'VRReloadCatalog'.static.FindClass(Family);
    return !class'VRWeaponRuntime'.static.TracksMagazineFeedClass(Family) && Profile >= 0
        && !class'VRReloadCatalog'.default.Profiles[Profile].bNoEject
        && !class'VRReloadCatalog'.default.Profiles[Profile].bParkedLoaded;
}

static function int CylinderCapacity(class<KFWeapon> Family)
{
    local int Profile;
    Profile = class'VRBreakCatalog'.static.FindClass(Family);
    if (Profile < 0 || class'VRBreakCatalog'.default.Profiles[Profile].Capacity > 8) return 0;
    if (Family != class'KFWeap_Revolver_Rem1858' && Family != class'KFWeap_Revolver_SW500'
        && Family != class'KFWeap_Pistol_ChiappaRhino' && Family != class'KFWeap_HRG_Revolver_Buckshot'
        && Family != class'KFWeap_Pistol_Flare' && Family != class'KFWeap_Pistol_HRGWinterbite') return 0;
    return class'VRBreakCatalog'.default.Profiles[Profile].Capacity;
}

// Validate against exact catalog families and the ordered stock loaded count.
// This never infers an ammo credit/debit from a visual or availability flag.
static function bool Canonicalize(KFWeapon W, out HandlingState Snapshot)
{
    local int Profile, Capacity;
    local bool bFeed;
    if (W == None || W.bDeleteMe || Snapshot.Family == None || Snapshot.Family != FamilyFor(W.Class)
        || W.AmmoCount[0] < 0 || Snapshot.PumpPortStage > 2
        || Snapshot.FeedFlags < 0 || (Snapshot.FeedFlags & ~47) != 0
        || Snapshot.EmptyMagazineFlags < 0 || (Snapshot.EmptyMagazineFlags & ~7) != 0
        || Snapshot.CylinderEmptyMask < 0) return false;
    if (Snapshot.M32ClosePending < 0 || Snapshot.M32ClosePending > 1
        || (Snapshot.M32ClosePending != 0 && (W.Class != class'KFWeap_GrenadeLauncher_M32'
            || !(Snapshot.M32CloseAmount >= 0 && Snapshot.M32CloseAmount <= 1)))) return false;
    if (Snapshot.bCycleOwed && !class'VRPumpCatalog'.static.PumpAction(W)
        && !class'VRPumpCatalog'.static.CycleOnly(W)
        && !class'VRCycleCatalog'.static.Covers(W)) return false;
    if (Snapshot.PumpPortStage > 0)
    {
        if (!class'VRPumpCatalog'.static.PumpAction(W)) return false;
        Snapshot.PumpPortStage = W.AmmoCount[0] == 0 ? 1 : 2;
        Snapshot.bCycleOwed = true;
    }
    bFeed = class'VRWeaponRuntime'.static.TracksMagazineFeedClass(Snapshot.Family);
    if (Snapshot.FeedFlags != 0 && (!bFeed || (Snapshot.FeedFlags & 1) == 0)) return false;
    if (W.AmmoCount[0] == 0) Snapshot.FeedFlags = Snapshot.FeedFlags & ~4;
    if (Snapshot.EmptyMagazineFlags != 0 && !HasEmptyMagazine(Snapshot.Family)) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(Snapshot.Family);
    if ((Snapshot.EmptyMagazineFlags & 4) != 0
        && class'VRReloadCatalog'.static.ActionKindOf(Profile) != 1) return false;
    if (Snapshot.bSlideLockPending)
    {
        if (!HasSlideLock(Snapshot.Family)) return false;
        if (bFeed) Snapshot.FeedFlags = (Snapshot.FeedFlags | 9) & ~4;
        else if (HasEmptyMagazine(Snapshot.Family)) Snapshot.EmptyMagazineFlags = Snapshot.EmptyMagazineFlags | 2;
        else return false;
    }
    Capacity = CylinderCapacity(Snapshot.Family);
    if (Snapshot.CylinderEmptyMask != 0
        && (Capacity <= 0 || (Snapshot.CylinderEmptyMask & ~((1 << Capacity) - 1)) != 0)) return false;
    // Stock-counting cylinders may retain paid ammo while visibly empty.
    return true;
}

static function bool Capture(VRWeaponRuntime R, out HandlingState Snapshot, optional bool bRetiring)
{
    local HandlingState Empty;
    Snapshot = Empty;
    if (R == None || R.Item == None || R.Inventory == None || (!bRetiring && !R.IsCurrent())
        || R.MechanismPending != 0 || R.CycleEjectRequest != 0 || R.FinishProfileToken > 0
        || R.SecondaryMagazinePending != 0 || R.SecondaryMagazineFlags != 0
        || R.bPumpPortPredicted || R.bAmmoSyncPending || R.StockChamberBonus != 0
        || (R.MagazineFeedFlags & 16) != 0) return false;
    Snapshot.Family = FamilyFor(R.Item.Class);
    Snapshot.bCycleOwed = R.bManualPumpPending;
    Snapshot.bSlideLockPending = R.bSlideLockPending;
    Snapshot.PumpPortStage = R.PumpPortStage;
    Snapshot.FeedFlags = R.MagazineFeedFlags;
    Snapshot.EmptyMagazineFlags = R.EmptyMagazineFlags;
    Snapshot.CylinderEmptyMask = R.CylinderEmptyMask;
    Snapshot.M32ClosePending = R.M32ClosePending;
    Snapshot.M32CloseAmount = R.M32CloseAmount;
    // A paired magazine member has no separate retained-chamber ledger. Move
    // its empty-magazine availability into the resulting stock single's feed.
    if (Snapshot.Family != R.Item.Class
        && class'VRWeaponRuntime'.static.TracksMagazineFeedClass(Snapshot.Family)
        && Snapshot.EmptyMagazineFlags != 0)
    {
        Snapshot.FeedFlags = 1;
        if ((Snapshot.EmptyMagazineFlags & 1) != 0) Snapshot.FeedFlags = Snapshot.FeedFlags | 10;
        if ((Snapshot.EmptyMagazineFlags & 2) != 0) Snapshot.FeedFlags = Snapshot.FeedFlags | 8;
        Snapshot.EmptyMagazineFlags = 0;
    }
    // Retirement may be observed after Owner changed or Destroy marked the
    // old actor. Only availability flags are cached; the replacement's actual
    // owned actor and paid ammo validate them again before adoption.
    return bRetiring || Canonicalize(R.Item, Snapshot);
}

static function bool CaptureForReplacement(VRWeaponRuntime R, out HandlingState Snapshot)
{
    return Capture(R, Snapshot, true);
}

// Call after stock ownership/ammo receipts and before exposing a fresh held
// runtime. Recipient handling preferences decide which paid obligations apply.
static function bool ApplyToRuntime(VRWeaponRuntime R, HandlingState Snapshot,
    bool bManualCycles, bool bPhysicalHandling)
{
    if (R == None || !R.IsCurrent() || R.MechanismPending != 0 || R.CycleEjectRequest != 0
        || !Canonicalize(R.Item, Snapshot)) return false;
    R.bManualPumpPending = bManualCycles && Snapshot.bCycleOwed;
    R.PumpPortStage = (bManualCycles || bPhysicalHandling) ? Snapshot.PumpPortStage : 0;
    R.bPumpPortPredicted = false;
    R.bSlideLockPending = bPhysicalHandling && Snapshot.bSlideLockPending;
    R.MagazineFeedFlags = bPhysicalHandling ? Snapshot.FeedFlags : 0;
    R.EmptyMagazineFlags = bPhysicalHandling ? Snapshot.EmptyMagazineFlags : 0;
    R.MagazineFeedLastAmmo = R.Item.AmmoCount[0];
    R.MagazineFeedModeMask = 1;
    if (R.UsesMagazineAmmo(1)) R.MagazineFeedModeMask = R.MagazineFeedModeMask | 2;
    R.MagazineFeedShotMode = 0;
    R.bChamberShotLock = (R.MagazineFeedFlags & 3) == 3 && (R.MagazineFeedFlags & 4) == 0
        && (R.MagazineFeedFlags & 32) == 0 && HasSlideLock(Snapshot.Family);
    R.CylinderEmptyMask = bPhysicalHandling ? Snapshot.CylinderEmptyMask : 0;
    R.CylinderVisualAmmo = R.Item.AmmoCount[0];
    R.M32ClosePending = Snapshot.M32ClosePending;
    R.M32CloseAmount = Snapshot.M32CloseAmount;
    return true;
}
