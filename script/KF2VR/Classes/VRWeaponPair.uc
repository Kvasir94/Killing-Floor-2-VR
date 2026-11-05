// One authority-owned pair transaction in both solo and network play.
// Members are real stock-derived inventory actors; this replicated owner is
// the single reserve pool. The original stock actor is restored for trading.
class VRWeaponPair extends ReplicationInfo;

var VRHandInventory Hands;
var KFPawn_Human Human;
var KFInventoryManager Manager;
var KFWeap_DualBase StockItem;
var KFWeapon Members[2];
var byte MemberPresentationInitialized[2];
var private byte MemberSkinApplied[2];
var int PairState; // 0=new, 1=preparing, 2=members own ammo, 3=restored/aborted
var int SourceMagazine, SourceReserve, SourceUpgrade, SourceSkin, SourceWeight;
var int SourceMagazineCapacity, SourceReserveCapacity, CarryBefore;
var bool bSourceGivenAtStart, bFailed;
var int Reserve, Revision;
// A released member owns a frozen stock-style single allocation. Reserve is
// only the pool still available to members in the owner's hands/inventory.
// Loaded rounds stay on their exact physical actors throughout this split.
var int WorldDropToken[2], WorldDropReserve[2], WorldDropUpgrade[2];
var private int LastWorldDropToken[2];
var bool bWorldSplit;
var private bool bWorldRestoring;
var KFWeapon AmmoBorrower;
var int AmmoDepth;
// Per-member physical transactions; terminal fences reject late stock RPCs.
var int PhysicalTokens[2], PhysicalStatuses[2];
var byte PhysicalFences[2];
var private int PhysicalAmmoAtBegin[2];
var private byte PhysicalSwingOut[2], PhysicalDiscardCylinder[2];
// LOSE DROPPED / EJECTED AMMO on a cylinder replaced whole (1858, flare guns)
// or loaded at the hip: its old live rounds are lost when the client reports
// the visible ejection (EjectPhysicalCylinder), else when the reload commits.
var private byte PhysicalDiscardLoad[2];
var byte PhysicalCylinderEjected[2];
// Realistic ammo: the chambered round(s) a member kept when its magazine left
// at Begin, credited under a full magazine at Commit; -1 counts like stock.
var private int PhysicalChamber[2];
// Realistic ammo, a stock (button or automatic) member reload: the chambered
// round(s) stock's capacity clamp drops, added from the reserve when it ends.
var private int StockChamber[2];
// Exact detachable-magazine escrow belongs to one physical session, even
// before its prop is exported.
var private int PhysicalRemovedRounds[2], PhysicalRemovalKept[2];
var private byte PhysicalRemovalEligible[2], PhysicalRemovalExported[2], PhysicalRemovalLose[2];
var private int PhysicalMagazineToken[2];
var private float PhysicalDeadline[2];
var KFWeapon PhysicalReloadPermit;
var string Failure;
var bool bSourceWasActive;
var private KFPlayerController PresentationPC;
var private bool bHidAggregate;
var private bool bPreparedWorldMerge;

// Stock duals that convert into two paired members. The single is checked
// too: a stock dual whose single class differs is not the audited family.
struct VRPairFamily
{
    var class<KFWeap_DualBase> DualClass;
    var class<KFWeapon> SingleClass;
    var class<KFWeapon> MemberClass;
};
var array<VRPairFamily> Families;

// Stock trader/death restoration replaces both wrappers directly. The live
// world binder must retire their props and return each escrow before that swap.
delegate bool RetireWorldDrops(VRWeaponPair SourcePair) { return false; }

// The server removes the aggregate from its chain, but the owning client's
// stock equip/content callbacks can still reattach its first-person mesh.
// Suppress only this retired receipt in the local view, regardless of callback
// order. The real member actors keep their normal presenters and gameplay.
simulated function UpdateAggregatePresentation()
{
    local KFPlayerController LocalPC;
    if (WorldInfo.NetMode == NM_DedicatedServer) return;
    if (PairState == 2 && StockItem != None && Human != None)
    {
        foreach WorldInfo.LocalPlayerControllers(class'KFPlayerController', LocalPC)
            if (LocalPC.Pawn == Human)
            {
                PresentationPC = LocalPC;
                if (LocalPC.HiddenActors.Find(StockItem) == INDEX_NONE)
                {
                    LocalPC.HiddenActors.AddItem(StockItem);
                    bHidAggregate = true;
                }
            }
    }
    else RestoreAggregatePresentation();
}

simulated function RestoreAggregatePresentation()
{
    if (bHidAggregate && PresentationPC != None)
        PresentationPC.HiddenActors.RemoveItem(StockItem);
    bHidAggregate = false;
    PresentationPC = None;
}

simulated event Destroyed()
{
    RestoreAggregatePresentation();
    Super.Destroyed();
}

replication
{
    if (Role == ROLE_Authority && bNetOwner)
        Human, StockItem, Members, PairState, SourceWeight, SourceMagazineCapacity,
        SourceReserveCapacity, Reserve, Revision, PhysicalTokens, PhysicalStatuses, PhysicalFences, PhysicalCylinderEjected,
        WorldDropToken, WorldDropReserve, WorldDropUpgrade, bWorldSplit;
}

simulated function bool Owns(KFWeapon W)
{
    local KFWeapon Candidate;
    if (Human == None || Human.InvManager == None || W == None || W.bDeleteMe
        || W.Instigator != Human || W.InvManager != Human.InvManager) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

static function VRWeaponPair ForMember(KFWeapon W)
{
    if (VRWeap_Paired9mm(W) != None) return VRWeap_Paired9mm(W).Pair;
    if (VRWeap_Paired1858(W) != None) return VRWeap_Paired1858(W).Pair;
    if (VRWeap_PairedDeagle(W) != None) return VRWeap_PairedDeagle(W).Pair;
    if (VRWeap_PairedSW500(W) != None) return VRWeap_PairedSW500(W).Pair;
    if (VRWeap_PairedAF2011(W) != None) return VRWeap_PairedAF2011(W).Pair;
    if (VRWeap_Paired93R(W) != None) return VRWeap_Paired93R(W).Pair;
    if (VRWeap_PairedColt1911(W) != None) return VRWeap_PairedColt1911(W).Pair;
    if (VRWeap_PairedFlare(W) != None) return VRWeap_PairedFlare(W).Pair;
    if (VRWeap_PairedWinterbite(W) != None) return VRWeap_PairedWinterbite(W).Pair;
    if (VRWeap_PairedG18C(W) != None) return VRWeap_PairedG18C(W).Pair;
    if (VRWeap_PairedChiappaRhino(W) != None) return VRWeap_PairedChiappaRhino(W).Pair;
    if (VRWeap_PairedBuckshot(W) != None) return VRWeap_PairedBuckshot(W).Pair;
    if (VRWeap_PairedBladed(W) != None) return VRWeap_PairedBladed(W).Pair;
    return None;
}

simulated function bool Fail(string Reason)
{
    bFailed = true;
    Failure = Reason;
    `log("KF2VR_PAIR phase=failure reason=" $ Reason @ "state=" $ PairState);
    return false;
}

simulated function bool ContextValid()
{
    return Human != None && !Human.bDeleteMe && Human.InvManager != None
        && (Hands == None || Hands.ContextValid());
}

simulated function bool IsMember(KFWeapon W)
{
    return PairState == 2 && ContextValid() && W != None && !W.bDeleteMe
        && (W == Members[0] || W == Members[1]) && Owns(W);
}

simulated function int PhysicalMemberIndex(KFWeapon W)
{
    if (W != None && W == Members[0]) return 0;
    if (W != None && W == Members[1]) return 1;
    return -1;
}

simulated function bool PhysicalReloadManaged(KFWeapon W)
{
    local int I;
    I = PhysicalMemberIndex(W);
    return I >= 0 && PhysicalFences[I] != 0;
}

simulated function bool AllowsReloadStart(KFWeapon W)
{
    if (WorldReleased(W)) return false;
    return Role < ROLE_Authority || !PhysicalReloadManaged(W) || PhysicalReloadPermit == W;
}

simulated function bool AllowsReloadPayment(KFWeapon W)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (WorldReleased(W)) return false;
    return Role < ROLE_Authority || I < 0 || PhysicalFences[I] == 0
        || PhysicalReloadPermit == W || PhysicalStatuses[I] == 4;
}

simulated function bool BlocksPhysicalFire(KFWeapon W, byte Mode)
{
    local int I;
    if (WorldReleased(W)) return true;
    if (Role < ROLE_Authority || PhysicalReloadPermit == W) return false;
    I = PhysicalMemberIndex(W);
    return I >= 0 && PhysicalFences[I] != 0
        && (PhysicalStatuses[I] == 1 || Mode == class'KFWeapon'.const.RELOAD_FIREMODE);
}

function ClearPhysicalReloadTimers(KFWeapon W)
{
    local int Mode;
    W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
    for (Mode = 0; Mode < W.GetPendingFireLength(); ++Mode) W.ClearPendingFire(byte(Mode));
}

// A manual rear stroke debits only this member's loaded rounds. The common
// action barrier has already checked the exact chamber count and stock marker.
function bool EjectLiveRounds(KFWeapon W, int ExpectedAmmo, int Count)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || !IsMember(W) || WorldReleased(W)
        || Human.Health <= 0 || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || AmmoDepth != 0 || AmmoBorrower != None || PhysicalReloadPermit != None
        || PhysicalStatuses[I] == 1 || PhysicalStatuses[I] == 4 || Revision == MaxInt
        || !class'VRWeaponRuntime'.static.StockIdle(W) || Count <= 0 || Count > ExpectedAmmo
        || W.AmmoCount[0] != ExpectedAmmo) return false;
    if (!class'VRWorldMagazineRegistry'.static.PreserveLoadedRounds(self, Human, W, Count, 1)) return false;
    W.AmmoCount[0] -= Count;
    ++Revision;
    W.bForceNetUpdate = true; bForceNetUpdate = true;
    return true;
}

// Chambered rounds of a closed-bolt magazine member, 0 for cylinders, flare
// guns and break actions (they keep stock counting). A loaded member always
// has its chamber fed (members keep no separate chamber ledger); the AF2011
// holds a pair, one per barrel.
static function int MemberChamberRounds(KFWeapon W)
{
    if (W == None) return 0;
    if (ClassIsChildOf(W.Class, class'KFWeap_Pistol_AF2011')) return 2;
    if (ClassIsChildOf(W.Class, class'KFWeap_Pistol_9mm') || ClassIsChildOf(W.Class, class'KFWeap_Pistol_Deagle')
        || ClassIsChildOf(W.Class, class'KFWeap_Pistol_Colt1911') || ClassIsChildOf(W.Class, class'KFWeap_Pistol_G18C')
        || ClassIsChildOf(W.Class, class'KFWeap_HRG_93R')) return 1;
    return 0;
}

// The shared reserve and the audited chamber capacity admit physical top-ups
// that stock rejects at its aggregate magazine capacity. No count is credited
// here; actual retained rounds are fixed by the subsequent removal escrow.
simulated function bool PhysicalTopUp(KFWeapon W, bool bRealistic)
{
    return bRealistic && W != None && IsMember(W) && W.bCanBeReloaded
        && MemberChamberRounds(W) > 0 && W.MagazineCapacity[0] > 0
        && W.AmmoCount[0] >= W.MagazineCapacity[0]
        && W.AmmoCount[0] < W.MagazineCapacity[0] + MemberChamberRounds(W)
        && (W.bInfiniteSpareAmmo || SharedReserve(W) > 0);
}

function bool BeginPhysicalReload(KFWeapon W, int Token, optional bool bStock, optional bool bRealistic,
    optional bool bSwingOut, optional bool bLoseAmmo)
{
    local int I, TopUpAmmo;
    local bool bAlreadyReloading, bExistingMagazineWell, bTopUp;
    I = PhysicalMemberIndex(W);
    bSwingOut = bSwingOut && !bStock && class'VRBreakCatalog'.static.SwingOutCylinder(W);
    if (Role != ROLE_Authority || I < 0 || !IsMember(W) || WorldReleased(W) || Human.Health <= 0
        || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || Manager == None || Manager.bServerTraderMenuOpen || !Human.CanReloadWeapon()
        || Token <= PhysicalTokens[I] || Token <= 0 || Token == MaxInt
        || PhysicalStatuses[I] == 1 || PhysicalStatuses[I] == 4
        || (!class'VRWeaponRuntime'.static.StockIdle(W) && !W.IsInState('Reloading'))
        || (!bSwingOut && !W.CanReload(0) && !PhysicalTopUp(W, bRealistic)) || W.MySkelMesh == None) return false;
    bAlreadyReloading = W.IsInState('Reloading');
    // A canceled/stowed open well belongs to the exact physical member. A
    // restarted reload may replace its session, never its retained-count or
    // loss policy, until a real magazine has been installed.
    bExistingMagazineWell = PhysicalStatuses[I] == 3 && PhysicalRemovalExported[I] != 0
        && PhysicalMagazineToken[I] > 0 && W.AmmoCount[0] >= 0
        && W.AmmoCount[0] <= PhysicalRemovalKept[I];
    PhysicalTokens[I] = Token;
    PhysicalStatuses[I] = bStock ? 4 : 1;
    PhysicalFences[I] = 1;
    PhysicalSwingOut[I] = byte(bSwingOut);
    PhysicalDiscardCylinder[I] = byte(bSwingOut && bLoseAmmo);
    PhysicalDiscardLoad[I] = byte(bLoseAmmo && !bStock && !bSwingOut && MemberChamberRounds(W) == 0
        && class'VRBreakCatalog'.static.CylinderReload(W));
    PhysicalCylinderEjected[I] = 0;
    if (!bExistingMagazineWell)
    {
        PhysicalRemovalEligible[I] = byte(!bStock && class'VRMagazineCarryRecipe'.static.Supports(W));
        PhysicalRemovalExported[I] = 0; PhysicalMagazineToken[I] = 0;
        PhysicalRemovalLose[I] = byte(bLoseAmmo);
        PhysicalRemovalKept[I] = bRealistic ? Clamp(W.AmmoCount[0], 0, MemberChamberRounds(W)) : 0;
        PhysicalRemovedRounds[I] = bLoseAmmo ? Max(0, W.AmmoCount[0] - PhysicalRemovalKept[I]) : 0;
    }
    // Realistic ammo (the owning VR player's setting): the leaving magazine
    // takes its rounds; only the chamber stays, and nothing returns to reserve.
    PhysicalChamber[I] = -1;
    StockChamber[I] = (bRealistic && bStock) ? Clamp(W.AmmoCount[0], 0, MemberChamberRounds(W)) : 0;
    if (!bExistingMagazineWell && (bRealistic || bLoseAmmo) && !bStock && MemberChamberRounds(W) > 0)
    {
        PhysicalChamber[I] = bRealistic ? Clamp(W.AmmoCount[0], 0, MemberChamberRounds(W)) : 0;
        if (bLoseAmmo && W.AmmoCount[0] > PhysicalChamber[I])
        {
            // Detachable magazines debit only when their bounded ledger
            // registration succeeds. A refused pull/cancel loses nothing.
            if (PhysicalRemovalEligible[I] == 0)
            {
                W.AmmoCount[0] = PhysicalChamber[I];
                W.bForceNetUpdate = true;
            }
        }
    }
    // A member magazine with no chamber ledger that is no pickup (the Bladed
    // Pistol's container) loses its whole load as it leaves.
    else if (!bExistingMagazineWell && bLoseAmmo && !bStock && MemberChamberRounds(W) == 0
        && PhysicalRemovalEligible[I] == 0 && W.bReloadFromMagazine
        && !class'VRBreakCatalog'.static.CylinderReload(W) && class'VRBreakCatalog'.static.FindClass(W.Class) < 0
        && W.AmmoCount[0] > 0)
    {
        // Lost only when the owner reports it visibly leaving
        // (EjectPhysicalCylinder), so a reload cancelled before the drop
        // keeps its load. The eject also resizes the reload from empty.
        PhysicalDiscardLoad[I] = 1;
    }
    if (bExistingMagazineWell && !bStock) PhysicalChamber[I] = W.AmmoCount[0];
    PhysicalAmmoAtBegin[I] = W.AmmoCount[0];
    PhysicalDeadline[I] = WorldInfo.RealTimeSeconds + 45.0;
    // Adopt an early stock automatic reload without replaying its start.
    // Stock admission keeps its timers; physical admission pauses them below.
    bTopUp = !W.CanReload(0) && PhysicalTopUp(W, bRealistic);
    if (!bAlreadyReloading && (W.CanReload(0) || bTopUp))
    {
        ClearPhysicalReloadTimers(W);
        PhysicalReloadPermit = W;
        if (bTopUp) { TopUpAmmo = W.AmmoCount[0]; W.AmmoCount[0] = W.MagazineCapacity[0] - 1; }
        W.InitializeReload();
        W.SendToFiringState(class'KFWeapon'.const.RELOAD_FIREMODE);
        if (bTopUp)
        {
            W.AmmoCount[0] = TopUpAmmo;
            W.ReloadAmountLeft = 0; W.InitialReloadAmount = 0;
        }
        PhysicalReloadPermit = None;
    }
    if (!bStock) { W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer'); }
    if (!W.IsInState('Reloading') && !(bSwingOut && class'VRWeaponRuntime'.static.StockIdle(W)))
    { CancelPhysicalReload(W, Token); return false; }
    bForceNetUpdate = true;
    return true;
}

// Trusted removal binder preflights both this session and its bounded ledger
// before registering. Export applies the exact pending removal only once.
function bool CanExportPhysicalMagazine(KFWeapon W, int Session, int Kept, bool bLose,
    out int Removed)
{
    local int I;
    Removed = 0;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || !IsMember(W) || WorldReleased(W)
        || Human.Health <= 0 || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || Manager == None || Manager.bServerTraderMenuOpen
        || AmmoDepth != 0 || AmmoBorrower != None || PhysicalReloadPermit != None
        || Revision == MaxInt || Reserve < 0) return false;
    // Direct ejection needs no reserve or stock reload animation. The same
    // bounded payload ledger owns the actual magazine rounds, and the exact
    // exported well token fences every later insertion or repeated removal.
    if (Session == 0)
    {
        if (!class'VRWeaponRuntime'.static.StockIdle(W) || !W.bCanBeReloaded || !Human.CanReloadWeapon()
            || !class'VRMagazineCarryRecipe'.static.Supports(W)
            || PhysicalStatuses[I] == 1 || PhysicalStatuses[I] == 4
            || PhysicalRemovalExported[I] != 0 || PhysicalMagazineToken[I] != 0
            || W.AmmoCount[0] < 0 || Kept < 0 || Kept > Min(W.AmmoCount[0], MemberChamberRounds(W))
            || (!bLose && W.AmmoCount[0] - Kept > MaxInt - Reserve)) return false;
        Removed = bLose ? W.AmmoCount[0] - Kept : 0;
        return true;
    }
    if (Session < 0 || PhysicalTokens[I] != Session || PhysicalStatuses[I] != 1
        || PhysicalRemovalEligible[I] == 0 || PhysicalRemovalExported[I] != 0
        || PhysicalRemovalLose[I] != byte(bLose) || Kept > PhysicalRemovalKept[I]
        || W.AmmoCount[0] != PhysicalAmmoAtBegin[I]
        || Kept < 0 || Kept > W.AmmoCount[0]
        || (!bLose && W.AmmoCount[0] - Kept > MaxInt - Reserve)) return false;
    // The exact owner feed may have an empty chamber even with stock rounds
    // still in its magazine. Keeping fewer than the maximum chamber count
    // cannot create ammunition: the existing actor total splits into exactly
    // Kept plus Removed (or returned reserve). The exported Kept replaces the
    // admission estimate before any replacement can be paid.
    Removed = bLose ? W.AmmoCount[0] - Kept : 0;
    return true;
}

function ExportPhysicalMagazine(KFWeapon W, int Session, int Kept, bool bLose, int Token)
{
    local int I, Removed;
    if (!CanExportPhysicalMagazine(W, Session, Kept, bLose, Removed)) return;
    I = PhysicalMemberIndex(W);
    if (Session == 0)
    {
        PhysicalStatuses[I] = 3; PhysicalFences[I] = 1;
        PhysicalRemovalEligible[I] = 1;
        PhysicalRemovalKept[I] = 0; PhysicalRemovedRounds[I] = 0;
        PhysicalRemovalLose[I] = byte(bLose);
        PhysicalSwingOut[I] = 0;
    }
    PhysicalRemovalKept[I] = Kept;
    PhysicalRemovedRounds[I] = Removed;
    // No-loss magazines are empty paid payloads: their old rounds return to
    // the same shared reserve, preserving owned rounds across perk changes.
    if (!bLose) Reserve += W.AmmoCount[0] - Kept;
    W.AmmoCount[0] = Kept;
    PhysicalAmmoAtBegin[I] = Kept;
    // Replacing a completely returned no-loss magazine still loads a full
    // magazine; stock's original ReloadAmountLeft described only its top-up.
    PhysicalChamber[I] = Kept;
    PhysicalRemovalExported[I] = 1;
    PhysicalMagazineToken[I] = Token;
    ++Revision;
    W.bForceNetUpdate = true; bForceNetUpdate = true;
}

// The paid external magazine completes this exact open session. No stock
// PerformReload, reserve borrowing or reload notify may pay for it again.
function bool SeatPhysicalMagazine(KFWeapon W, int ExpectedRetained, int Rounds,
    optional bool bAllowOverCapacity)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || !IsMember(W) || WorldReleased(W)
        || Human.Health <= 0 || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || Manager == None || Manager.bServerTraderMenuOpen
        || (PhysicalStatuses[I] != 1 && PhysicalStatuses[I] != 3) || PhysicalRemovalExported[I] == 0
        || PhysicalMagazineToken[I] <= 0 || PhysicalSwingOut[I] != 0
        || AmmoDepth != 0 || AmmoBorrower != None || PhysicalReloadPermit != None
        || Revision == MaxInt || ExpectedRetained < 0 || Rounds < 0
        || ExpectedRetained > PhysicalRemovalKept[I] || W.AmmoCount[0] != ExpectedRetained
        || Rounds > MaxInt - ExpectedRetained || W.MagazineCapacity[0] <= 0
        || (!bAllowOverCapacity && Rounds > W.MagazineCapacity[0])) return false;
    ClearPhysicalReloadTimers(W);
    PhysicalStatuses[I] = 2;
    ClosePhysicalMagazineWell(I);
    PhysicalReloadPermit = W;
    W.AmmoCount[0] = ExpectedRetained + Rounds;
    W.ReloadComplete();
    PhysicalReloadPermit = None;
    ++Revision;
    W.bForceNetUpdate = true; bForceNetUpdate = true;
    return true;
}

function bool MagazineWellOpen(KFWeapon W)
{
    local int I;
    I = PhysicalMemberIndex(W);
    return Role == ROLE_Authority && I >= 0 && PhysicalRemovalExported[I] != 0
        && PhysicalMagazineToken[I] > 0;
}

// Trusted handoff state only: this new member still lacks the same physical
// magazine. The synthetic marker owns an opening, never rounds or a payload.
function bool AdoptPhysicalMagazineWell(KFWeapon W, int Retained)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || !IsMember(W) || WorldReleased(W)
        || !class'VRMagazineCarryRecipe'.static.Supports(W)
        || Retained < 0 || Retained > MemberChamberRounds(W) || W.AmmoCount[0] != Retained
        || PhysicalStatuses[I] == 1 || PhysicalStatuses[I] == 4
        || AmmoDepth != 0 || AmmoBorrower != None || PhysicalReloadPermit != None
        || Revision == MaxInt) return false;
    if (MagazineWellOpen(W)) return Retained <= PhysicalRemovalKept[I];
    PhysicalStatuses[I] = 3; PhysicalFences[I] = 1;
    PhysicalRemovalEligible[I] = 1; PhysicalRemovalExported[I] = 1;
    PhysicalRemovalKept[I] = Retained; PhysicalRemovedRounds[I] = 0;
    PhysicalRemovalLose[I] = 0;
    PhysicalMagazineToken[I] = 1;
    PhysicalAmmoAtBegin[I] = Retained; PhysicalChamber[I] = Retained;
    PhysicalSwingOut[I] = 0;
    ++Revision;
    bForceNetUpdate = true;
    return true;
}

private function ClosePhysicalMagazineWell(int I)
{
    PhysicalMagazineToken[I] = 0;
    PhysicalRemovalExported[I] = 0;
    PhysicalRemovalEligible[I] = 0;
}

// The physical ejection phase owns irreversible cylinder loss: a swing-out's
// extraction, or the moment a replaced (1858, flare gun) or hip-loaded cylinder
// visibly leaves. The paid 1858 cylinder is exported before the debit; a
// cancelled reload retains that payload, and opening alone discards nothing.
function bool EjectPhysicalCylinder(KFWeapon W, int Token)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || Token != PhysicalTokens[I] || PhysicalStatuses[I] != 1
        || (PhysicalSwingOut[I] == 0 && PhysicalDiscardLoad[I] == 0 && PhysicalCylinderEjected[I] == 0)) return false;
    if (!IsMember(W) || Human.Health <= 0 || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || Manager.bServerTraderMenuOpen || WorldInfo.RealTimeSeconds >= PhysicalDeadline[I]
        || (!W.IsInState('Reloading') && !class'VRWeaponRuntime'.static.StockIdle(W))
        || W.AmmoCount[0] != PhysicalAmmoAtBegin[I])
    { CancelPhysicalReload(W, Token); return false; }
    if (PhysicalCylinderEjected[I] == 0)
    {
        if (PhysicalDiscardCylinder[I] != 0 || PhysicalDiscardLoad[I] != 0)
        {
            if (class'VRBreakCatalog'.static.SwingOutCylinder(W))
            {
                if (!class'VRWorldMagazineRegistry'.static.PreserveLoadedRounds(self, Human, W, W.AmmoCount[0], 1)) return false;
            }
            else if (!class'VRWorldMagazineRegistry'.static.PreserveCylinder(self, Human, W, W.AmmoCount[0])) return false;
            W.AmmoCount[0] = 0;
        }
        // Paid once, here: the commit then fills the emptied cylinder.
        PhysicalDiscardLoad[I] = 0;
        PhysicalAmmoAtBegin[I] = W.AmmoCount[0];
        PhysicalCylinderEjected[I] = 1;
    }
    PhysicalReloadPermit = W;
    // Borrowing in the member override sizes this against the shared reserve.
    // Existing stock timers remain held; replacement payment still waits for close.
    if (W.IsInState('Reloading') || W.CanReload(0))
    {
        W.InitializeReload();
        if (class'VRWeaponRuntime'.static.StockIdle(W)) W.SendToFiringState(class'KFWeapon'.const.RELOAD_FIREMODE);
        ClearPhysicalReloadTimers(W);
    }
    PhysicalReloadPermit = None;
    W.bForceNetUpdate = true; bForceNetUpdate = true;
    return true;
}

simulated function bool CylinderWasEjected(KFWeapon W, int Token)
{
    local int I;
    I = PhysicalMemberIndex(W);
    return I >= 0 && Token == PhysicalTokens[I] && PhysicalCylinderEjected[I] != 0;
}

function bool CommitPhysicalReload(KFWeapon W, int Token, optional bool bNoLoad, optional int Maximum)
{
    local int I, Before, Available, After;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || Token != PhysicalTokens[I] || PhysicalStatuses[I] != 1) return false;
    if (!IsMember(W) || Human.Health <= 0 || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || (!W.IsInState('Reloading') && !(PhysicalSwingOut[I] != 0 && bNoLoad && class'VRWeaponRuntime'.static.StockIdle(W)))
        || WorldInfo.RealTimeSeconds >= PhysicalDeadline[I]
        || W.AmmoCount[0] != PhysicalAmmoAtBegin[I]) { CancelPhysicalReload(W, Token); return false; }
    if (bNoLoad && PhysicalSwingOut[I] == 0) return false;
    if (PhysicalSwingOut[I] != 0 && !bNoLoad && PhysicalCylinderEjected[I] == 0) return false;
    ClearPhysicalReloadTimers(W);
    // A replacement seat can reach authority without an earlier visible-eject
    // report. Use the same paid export/debit as that report, rather than
    // discarding the old cylinder here without a recoverable payload. Refusal
    // leaves the old load and this session intact for retry/cancellation.
    if (PhysicalDiscardLoad[I] != 0 && !bNoLoad && PhysicalChamber[I] < 0 && W.AmmoCount[0] > 0
        && (W.bInfiniteSpareAmmo || SharedReserve(W) > 0))
    {
        if (!EjectPhysicalCylinder(W, Token)) return false;
        W.ReloadAmountLeft = W.MagazineCapacity[0];
    }
    // Legacy normal completion still performs its own pending removal loss.
    // A magazine already exported to a paid payload must never pay it twice.
    if (PhysicalRemovalEligible[I] != 0 && PhysicalRemovalExported[I] == 0
        && PhysicalRemovalLose[I] != 0)
        W.AmmoCount[0] = PhysicalRemovalKept[I];
    Before = W.AmmoCount[0];
    Available = W.bInfiniteSpareAmmo ? W.MagazineCapacity[0] : SharedReserve(W);
    if (Maximum > 0)
    {
        Available = Min(Available, Maximum);
        class'VRPouchAmmo'.static.ClampPayment(W, Maximum);
    }
    PhysicalStatuses[I] = 2;
    PhysicalReloadPermit = W;
    if (bNoLoad)
    {
        if (W.IsInState('Reloading')) W.AbortReload();
        PhysicalReloadPermit = None;
        W.bForceNetUpdate = true; bForceNetUpdate = true;
        return true;
    }
    if (PhysicalChamber[I] >= 0)
    {
        // A full magazine under the kept chamber: capacity + 1 tactical,
        // capacity empty. The shared reserve pays exactly the rounds added.
        After = Min(Before + Min(W.MagazineCapacity[0], Available),
            W.MagazineCapacity[0] + PhysicalChamber[I]);
        if (After > Before && !W.bInfiniteSpareAmmo) After = Before - AddReserve(W, Before - After);
        W.AmmoCount[0] = Max(After, Before);
    }
    else if (Maximum > 0) class'VRPouchAmmo'.static.PerformPhysicalReload(W, Maximum);
    else W.PerformReload(0);
    W.ReloadComplete();
    // A concurrent member may have spent the final shared round after Begin.
    // Zero credit is a rejected seat, regardless of reserve remaining now.
    if (W.AmmoCount[0] <= Before) PhysicalStatuses[I] = 3;
    PhysicalReloadPermit = None;
    if (PhysicalStatuses[I] == 2) ClosePhysicalMagazineWell(I);
    W.bForceNetUpdate = true; bForceNetUpdate = true;
    return PhysicalStatuses[I] == 2;
}

// Rounds a realistic physical reload of W would take out with its magazine
// (all but the chamber); revolvers and stock reloads take none.
static function int MagazineLostRounds(KFWeapon W, optional bool bKeepChamber = true)
{
    local int Chamber;
    Chamber = MemberChamberRounds(W);
    return (W != None && Chamber > 0) ? Max(W.AmmoCount[0] - (bKeepChamber ? Chamber : 0), 0) : 0;
}

// Room left in the shared reserve (replicated inputs, so a client can predict).
simulated function int ReserveRoom()
{
    if (Members[0] == None || Members[1] == None) return 0;
    return Max(0, SourceMagazineCapacity + SourceReserveCapacity
        - Members[0].AmmoCount[0] - Members[1].AmmoCount[0] - Reserve - WorldEscrow());
}

// A completed stock member reload filled to capacity: put the kept chamber
// back on top of it, paid from the shared reserve (15+1, not 15+0).
function KeepStockChamber(int I)
{
    local KFWeapon W;
    local int Add;
    W = Members[I];
    Add = StockChamber[I];
    StockChamber[I] = 0;
    if (Add <= 0 || W.AmmoCount[0] != W.MagazineCapacity[0]) return;
    if (!W.bInfiniteSpareAmmo) Add = -AddReserve(W, -Min(Add, SharedReserve(W)));
    if (Add <= 0) return;
    W.AmmoCount[0] += Add;
    W.bForceNetUpdate = true;
}

function CancelPhysicalReload(KFWeapon W, int Token)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || Token != PhysicalTokens[I]
        || (PhysicalStatuses[I] != 1 && PhysicalStatuses[I] != 4)) return;
    PhysicalStatuses[I] = 3;
    if (IsMember(W))
    {
        ClearPhysicalReloadTimers(W);
        if (W.IsInState('Reloading')) W.AbortReload();
        W.bForceNetUpdate = true;
    }
    bForceNetUpdate = true;
}

simulated function int PhysicalReloadStatus(KFWeapon W, int Token)
{
    local int I;
    I = PhysicalMemberIndex(W);
    if (I < 0 || Token != PhysicalTokens[I]) return 0;
    return PhysicalStatuses[I];
}

function TickPhysicalReloads()
{
    local int I;
    for (I = 0; I < 2; ++I)
    {
        if (PhysicalStatuses[I] != 1 && PhysicalStatuses[I] != 4) continue;
        if (!IsMember(Members[I]) || Human.Health <= 0 || Manager.bServerTraderMenuOpen
            || !class'VRPhysicalInteraction'.static.Allowed(Human)
            || WorldInfo.RealTimeSeconds >= PhysicalDeadline[I])
            CancelPhysicalReload(Members[I], PhysicalTokens[I]);
        else if (PhysicalStatuses[I] == 4 && !Members[I].IsInState('Reloading'))
        {
            if (Members[I].AmmoCount[0] > PhysicalAmmoAtBegin[I]) KeepStockChamber(I);
            PhysicalStatuses[I] = Members[I].AmmoCount[0] > PhysicalAmmoAtBegin[I] ? 2 : 3;
            if (PhysicalStatuses[I] == 2) ClosePhysicalMagazineWell(I);
            bForceNetUpdate = true;
        }
        else if (PhysicalStatuses[I] == 1 && ((!Members[I].IsInState('Reloading')
            && !(PhysicalSwingOut[I] != 0 && class'VRWeaponRuntime'.static.StockIdle(Members[I])))
            || Members[I].AmmoCount[0] != PhysicalAmmoAtBegin[I]))
            CancelPhysicalReload(Members[I], PhysicalTokens[I]);
    }
}

simulated function int MemberWeight(KFWeapon W)
{
    if (PairState != 2) return 0; // preparation has no inventory weight side effects
    if (W == Members[0]) return (SourceWeight + 1) / 2;
    if (W == Members[1]) return SourceWeight / 2;
    return 0;
}

simulated function string MemberLabel(KFWeapon W)
{
    if (StockItem == None) return "PAIR MEMBER";
    return StockItem.SingleClass.default.ItemName $ (W == Members[0] ? " 1" : " 2");
}

function bool SourceUnchanged()
{
    return ContextValid() && StockItem != None && !StockItem.bDeleteMe
        && Owns(StockItem)
        && StockItem.IsInState('Inactive')
        && StockItem.AmmoCount[0] == SourceMagazine && StockItem.SpareAmmoCount[0] == SourceReserve
        && StockItem.AmmoCount[1] == 0 && StockItem.SpareAmmoCount[1] == 0
        && StockItem.MagazineCapacity[0] == SourceMagazineCapacity
        && StockItem.SpareAmmoCapacity[0] == SourceReserveCapacity
        && StockItem.CurrentWeaponUpgradeIndex == SourceUpgrade && StockItem.SkinItemId == SourceSkin
        && StockItem.bGivenAtStart == bSourceGivenAtStart && StockItem.GetModifiedWeightValue() == SourceWeight;
}

// Allocation/content loading occurs while the original actor still owns every
// round and every carry block. No await, timer or event publishes half a pair.
function bool Begin(VRHandInventory OwnerHands, KFWeap_DualBase Source)
{
    if (PairState != 0 || OwnerHands == None || !OwnerHands.ContextValid()) return false;
    Hands = OwnerHands;
    return BeginForPawn(Hands.Registry.Human, Source);
}

function bool BeginForPawn(KFPawn_Human P, KFWeap_DualBase Source)
{
    local class<KFWeapon> MemberClass;
    if (Role != ROLE_Authority || PairState != 0 || P == None || P.Health <= 0) return false;
    Human = P;
    Manager = KFInventoryManager(Human.InvManager);
    if (Manager == None || Manager.bServerTraderMenuOpen || Source == None
        || !Owns(Source) || (Hands != None && (!Source.IsInState('Inactive')
        || Hands.Registry.FindItem(Source) != None))) return Fail("source_not_quiescent");
    MemberClass = MemberClassFor(Source);
    if (MemberClass == None) return Fail("unsupported_family");
    // The server owns the stock equip state. Cancel it only after validating
    // the family and ownership, before capturing its ammunition receipt.
    bSourceWasActive = Human.Weapon == Source && !Source.IsInState('Inactive');
    Source.ForceEndFire();
    Source.GotoState('Inactive');
    if (PrepareMembers(Source, MemberClass)) return true;
    if (bSourceWasActive && Owns(Source) && Human.Health > 0) Source.Activate();
    return false;
}

static function class<KFWeapon> MemberClassFor(KFWeap_DualBase Source)
{
    local int I;
    if (Source == None) return None;
    for (I = 0; I < default.Families.Length; ++I)
        if (Source.Class == default.Families[I].DualClass && Source.SingleClass == default.Families[I].SingleClass)
            return default.Families[I].MemberClass;
    return None;
}

// A VR pair member class (the split halves a stock dual becomes), by the
// same family table that creates them, never by class-name text.
static function bool IsMemberClass(class<KFWeapon> WeaponClass)
{
    local int I;
    if (WeaponClass == None) return false;
    for (I = 0; I < default.Families.Length; ++I)
        if (WeaponClass == default.Families[I].MemberClass) return true;
    return false;
}

// The trader asks by name, before any weapon exists. Same table, so a dual
// is offered exactly when picking it up would convert it.
static function bool ConvertsDual(name DualClassName, name SingleClassName)
{
    local int I;
    if (DualClassName == '' || SingleClassName == '') return false;
    for (I = 0; I < default.Families.Length; ++I)
        if (default.Families[I].DualClass.Name == DualClassName
            && default.Families[I].SingleClass.Name == SingleClassName)
            return true;
    return false;
}

// Two representative families for the short network smoke test.
static function class<KFWeap_DualBase> StockClassForIndex(int Index)
{
    switch (Index)
    {
        case 0: return class'KFWeap_Revolver_DualRem1858';
        case 1: return class'KFWeap_Pistol_Dual9mm';
    }
    return None;
}

function bool PrepareMembers(KFWeap_DualBase Source, class<KFWeapon> MemberClass)
{
    local int I;
    if (Source.AmmoCount[0] < 0 || Source.AmmoCount[0] > Source.MagazineCapacity[0]
        || Source.SpareAmmoCount[0] < 0 || Source.AmmoCount[1] != 0 || Source.SpareAmmoCount[1] != 0)
        return Fail("invalid_source_ammo");
    StockItem = Source;
    SourceMagazine = Source.AmmoCount[0]; SourceReserve = Source.SpareAmmoCount[0];
    SourceMagazineCapacity = Source.MagazineCapacity[0]; SourceReserveCapacity = Source.SpareAmmoCapacity[0];
    SourceUpgrade = Source.CurrentWeaponUpgradeIndex; SourceSkin = Source.SkinItemId;
    bSourceGivenAtStart = Source.bGivenAtStart;
    SourceWeight = Source.GetModifiedWeightValue(); CarryBefore = Manager.CurrentCarryBlocks;
    PairState = 1;
    for (I = 0; I < 2; ++I)
    {
        Members[I] = AllocateMember(MemberClass, I);
        if (Members[I] == None) { AbortPreparation(); return Fail("member_spawn"); }
        if (VRWeap_Paired9mm(Members[I]) != None) VRWeap_Paired9mm(Members[I]).Pair = self;
        else if (VRWeap_Paired1858(Members[I]) != None) VRWeap_Paired1858(Members[I]).Pair = self;
        else if (VRWeap_PairedDeagle(Members[I]) != None) VRWeap_PairedDeagle(Members[I]).Pair = self;
        else if (VRWeap_PairedSW500(Members[I]) != None) VRWeap_PairedSW500(Members[I]).Pair = self;
        else if (VRWeap_PairedAF2011(Members[I]) != None) VRWeap_PairedAF2011(Members[I]).Pair = self;
        else if (VRWeap_Paired93R(Members[I]) != None) VRWeap_Paired93R(Members[I]).Pair = self;
        else if (VRWeap_PairedColt1911(Members[I]) != None) VRWeap_PairedColt1911(Members[I]).Pair = self;
        else if (VRWeap_PairedFlare(Members[I]) != None) VRWeap_PairedFlare(Members[I]).Pair = self;
        else if (VRWeap_PairedWinterbite(Members[I]) != None) VRWeap_PairedWinterbite(Members[I]).Pair = self;
        else if (VRWeap_PairedG18C(Members[I]) != None) VRWeap_PairedG18C(Members[I]).Pair = self;
        else if (VRWeap_PairedChiappaRhino(Members[I]) != None) VRWeap_PairedChiappaRhino(Members[I]).Pair = self;
        else if (VRWeap_PairedBuckshot(Members[I]) != None) VRWeap_PairedBuckshot(Members[I]).Pair = self;
        else if (VRWeap_PairedBladed(Members[I]) != None) VRWeap_PairedBladed(Members[I]).Pair = self;
        else { AbortPreparation(); return Fail("member_class"); }
        Members[I].Instigator = Human;
        Members[I].InvManager = Manager;
        // SkinItemId is const and its setters are private natives, so a
        // member keeps its own (usually zero) id; ApplyMemberSkin dresses its
        // first-person mesh and VisibleSkin reports the pair's skin to others.
        Members[I].bGivenAtStart = bSourceGivenAtStart;
        Members[I].SetWeaponUpgradeLevel(SourceUpgrade);
        Members[I].GivenTo(Human, true);
        Members[I].GotoState('Inactive');
        Members[I].SetHidden(true);
    }
    return true;
}

function bool Ready()
{
    local int I;
    if (PairState != 1 || !SourceUnchanged()) return false;
    // Dedicated servers do not stream first-person meshes. Presentation is a
    // client readiness condition, never a server inventory prerequisite.
    if (WorldInfo.NetMode == NM_DedicatedServer || bPreparedWorldMerge)
        return Members[0] != None && Members[1] != None && Members[0].MagazineCapacity[0] > 0
            && Members[1].MagazineCapacity[0] > 0;
    if (!StockItem.WeaponContentLoaded || StockItem.MySkelMesh == None) return false;
    for (I = 0; I < 2; ++I)
        if (Members[I] == None || Members[I].bDeleteMe || !Members[I].WeaponContentLoaded
            || Members[I].MySkelMesh == None) return false;
    return true;
}

// Allocate the recipient's exact member actors before a sharing transaction
// removes either paid single. No inventory/weight is published in this phase.
function bool BeginPreparedWorldMerge(KFPawn_Human P, KFWeap_DualBase Source)
{
    local class<KFWeapon> MemberClass;
    if (Role != ROLE_Authority || PairState != 0 || !class'VRWorldDropTransfer'.static.ValidBody(P)
        || Source == None || Source.bDeleteMe || Source.Owner != None || Source.InvManager != None
        || Source.Instigator != None || Source.Inventory != None || Source.WorldInfo != P.WorldInfo) return false;
    MemberClass = MemberClassFor(Source);
    if (MemberClass == None) return false;
    Human = P; Manager = KFInventoryManager(P.InvManager);
    if (Manager.bServerTraderMenuOpen) return false;
    bPreparedWorldMerge = true;
    if (!PrepareMembers(Source, MemberClass)) return false;
    return PreparedWorldMergeCompatible();
}

function bool PreparedWorldMergeCompatible()
{
    return bPreparedWorldMerge && PairState == 1 && StockItem != None && !StockItem.bDeleteMe
        && Members[0] != None && !Members[0].bDeleteMe && Members[1] != None && !Members[1].bDeleteMe
        && Members[0].MagazineCapacity[0] > 0 && Members[1].MagazineCapacity[0] > 0
        && Members[0].MagazineCapacity[0] == Members[1].MagazineCapacity[0]
        && Members[0].MagazineCapacity[0] <= MaxInt - Members[1].MagazineCapacity[0]
        && Members[0].MagazineCapacity[0] + Members[1].MagazineCapacity[0] == SourceMagazineCapacity
        && Members[0].CurrentWeaponUpgradeIndex == SourceUpgrade
        && Members[1].CurrentWeaponUpgradeIndex == SourceUpgrade;
}

function bool CommitPreparedWorldMerge(int RetainedLoaded, int IncomingLoaded, int CombinedReserve)
{
    if (!bPreparedWorldMerge || PairState != 1 || RetainedLoaded < 0 || IncomingLoaded < 0
        || RetainedLoaded > MaxInt - IncomingLoaded || CombinedReserve < 0
        || CombinedReserve != SourceReserve
        || SourceMagazine != Min(RetainedLoaded + IncomingLoaded, SourceMagazineCapacity)) return false;
    if (!Commit()) return false;
    // Stock's aggregate has no per-pistol history. This trusted preparation
    // does: the existing held pistol remains member0, the catch is member1.
    Members[0].AmmoCount[0] = RetainedLoaded;
    Members[1].AmmoCount[0] = IncomingLoaded;
    Reserve = CombinedReserve;
    ++Revision;
    Members[0].bForceNetUpdate = true; Members[1].bForceNetUpdate = true;
    bPreparedWorldMerge = false;
    bForceNetUpdate = true;
    return true;
}

// Virtual allocation seam lets the replay exercise an actual second-spawn
// failure, without adding a failure switch to production input or inventory.
function KFWeapon AllocateMember(class<KFWeapon> MemberClass, int Index)
{
    return Spawn(MemberClass, Human);
}

// The skin a player sees on this weapon: its own, or for a paired member the
// stock pair's, whose id the stock skin system set on this machine.
static function int VisibleSkin(KFWeapon W)
{
    local VRWeaponPair P;
    if (W == None) return 0;
    if (W.SkinItemId > 0) return W.SkinItemId;
    P = ForMember(W);
    if (P != None && P.StockItem != None && !P.StockItem.bDeleteMe) return P.StockItem.SkinItemId;
    return 0;
}

// Stock ClientSetFirstPersonSkin is private native, so dress the member's 1P
// mesh with the pair's 1P skin materials once, then rebuild the blood MICs on
// top of them as stock ClientWeaponSet does for a skinned weapon.
simulated function ApplyMemberSkin(KFWeapon W, int Index)
{
    local array<string> Paths;
    local MaterialInterface Surface;
    local int Skin, I;
    if (MemberSkinApplied[Index] != 0 || WorldInfo.NetMode == NM_DedicatedServer
        || W.SkinItemId > 0 || W.Mesh == None || !W.WeaponContentLoaded) return;
    MemberSkinApplied[Index] = 1;
    Skin = VisibleSkin(W);
    if (Skin <= 0) return;
    Paths = class'KFWeaponSkinList'.static.GetWeaponSkinPaths(Skin, WST_FirstPerson);
    for (I = 0; I < Paths.Length && I < W.Mesh.GetNumElements(); ++I)
    {
        if (Paths[I] == "") continue;
        Surface = MaterialInterface(DynamicLoadObject(Paths[I], class'MaterialInterface'));
        if (Surface != None) W.Mesh.SetMaterial(I, Surface);
    }
    for (I = 0; I < W.NumBloodMapMaterials && I < W.Mesh.GetNumElements(); ++I)
    {
        if (I < W.WeaponMICs.Length) W.WeaponMICs[I] = W.Mesh.CreateAndSetMaterialInstanceConstant(I);
        else W.WeaponMICs.AddItem(W.Mesh.CreateAndSetMaterialInstanceConstant(I));
    }
    if (class'KFWeaponSkinList'.static.SkinNeedsCodeUpdates(Skin))
    {
        W.Timer_UpdateWeaponSkin();
        W.SetTimer(0.5, true, 'Timer_UpdateWeaponSkin');
    }
    `log("KF2VR_PAIR phase=skin member=" $ Index @ "skin=" $ Skin @ "materials=" $ Paths.Length);
}

// The aggregate stock magazine has no per-gun visual history. Establish one
// deterministic initial state once the member's own animation tree is ready.
// Later shots, reloads, stows and transfers retain their stock instance state.
simulated function InitializeMemberPresentation(KFWeapon W)
{
    local KFWeap_PistolBase P;
    local int Index, I, Used;
    if (!IsMember(W)) return;
    Index = W == Members[0] ? 0 : 1;
    ApplyMemberSkin(W, Index);
    if (MemberPresentationInitialized[Index] != 0 || W.WeaponAnimSeqNode == None) return;
    P = KFWeap_PistolBase(W);
    if (P == None) return;
    if (P.bRevolver)
    {
        if (P.CylinderRotInfo.Control == None || P.UsedBulletMeshTemplate == None
            || P.UnusedBulletMeshTemplate == None
            || P.BulletMeshComponents.Length != P.MagazineCapacity[0]) return;
        for (I = 0; I < P.BulletMeshComponents.Length; ++I)
            if (P.BulletMeshComponents[I] == None) return;
    }
    // Skeletal mesh updates may deliver animation callbacks synchronously.
    MemberPresentationInitialized[Index] = 1;
    if (P.bRevolver)
    {
        Used = P.MagazineCapacity[0] - P.AmmoCount[0];
        for (I = 0; I < P.BulletMeshComponents.Length; ++I)
            P.BulletMeshComponents[I].SetSkeletalMesh(I < Used ? P.UsedBulletMeshTemplate : P.UnusedBulletMeshTemplate);
        P.CylinderRotInfo.PrevDegrees = Used * P.CylinderRotInfo.Inc;
        P.CylinderRotInfo.NextDegrees = P.CylinderRotInfo.PrevDegrees;
        P.CylinderRotInfo.State = class'KFWeap_PistolBase'.const.CYLINDERSTATE_READY;
        P.CylinderRotInfo.Timer = 0;
        P.SetCylinderRotation(P.CylinderRotInfo, P.CylinderRotInfo.NextDegrees);
    }
    if (P.EmptyMagBlendNode != None) P.EmptyMagBlendNode.SetBlendTarget(P.AmmoCount[0] == 0 ? 1 : 0, 0);
}

function bool Commit()
{
    local Inventory Previous, Link;
    local VRWeaponRuntime First, Second;
    if (!Ready() || Manager.bServerTraderMenuOpen) return false;
    // Fail closed on a perk's asymmetric rounding rather than discarding a
    // loaded round or silently moving it to reserve.
    if (Members[0].MagazineCapacity[0] + Members[1].MagazineCapacity[0] != SourceMagazineCapacity
        || Members[0].MagazineCapacity[0] != Members[1].MagazineCapacity[0]
        || Members[0].CurrentWeaponUpgradeIndex != SourceUpgrade || Members[1].CurrentWeaponUpgradeIndex != SourceUpgrade
        || (Hands != None && (Hands.Registry.NextItemId <= 0 || Hands.Registry.NextItemId >= MaxInt - 2)))
        return Fail("member_metadata_capacity_or_identity");
    for (Link = Manager.InventoryChain; Link != None && Link != StockItem; Link = Link.Inventory)
        Previous = Link;
    if (Link != StockItem) return Fail("source_missing");
    StockItem.ForceEndFire();
    StockItem.GotoState('Inactive');
    StockItem.DetachWeapon();
    StockItem.SetHidden(true);
    StockItem.ClearAllTimers();
    Members[0].AmmoCount[0] = (SourceMagazine + 1) / 2;
    Members[1].AmmoCount[0] = SourceMagazine / 2;
    Reserve = SourceReserve;
    StockItem.AmmoCount[0] = 0;
    StockItem.SpareAmmoCount[0] = 0;
    // The single existing inventory chain changes once; there is no second
    // authoritative chain and the unowned stock receipt has no ammunition.
    Members[0].Inventory = Members[1];
    Members[1].Inventory = StockItem.Inventory;
    if (Previous == None) Manager.InventoryChain = Members[0];
    else Previous.Inventory = Members[0];
    StockItem.Inventory = None;
    if (Human.Weapon == StockItem) Human.Weapon = None;
    if (Human.MyKFWeapon == StockItem) Human.MyKFWeapon = None;
    if (Manager.PendingWeapon == StockItem) Manager.PendingWeapon = None;
    if (Manager.PreviousEquippedWeapons[0] == StockItem) Manager.PreviousEquippedWeapons[0] = None;
    if (Manager.PreviousEquippedWeapons[1] == StockItem) Manager.PreviousEquippedWeapons[1] = None;
    StockItem.SetOwner(None); StockItem.InvManager = None; StockItem.Instigator = None;
    PairState = 2;
    UpdateAggregatePresentation();
    Revision = 1;
    if (Hands != None)
    {
        First = Hands.Registry.RegisterItem(Members[0]);
        Second = Hands.Registry.RegisterItem(Members[1]);
        if (First == None || Second == None || First.ItemId == Second.ItemId)
        {
            Restore();
            return Fail("member_registration");
        }
    }
    InitializeMemberPresentation(Members[0]);
    InitializeMemberPresentation(Members[1]);
    return true;
}

simulated function bool WorldReleased(KFWeapon W)
{
    local int I;
    I = PhysicalMemberIndex(W);
    return I >= 0 && WorldDropToken[I] > 0;
}

simulated function int WorldEscrow()
{
    return WorldDropReserve[0] + WorldDropReserve[1];
}

// The release binder calls this only after the weapon-channel marker and all
// pair reloads have settled. No stock loaded-count split is performed here.
function bool BeginWorldRelease(KFWeapon W, int Token)
{
    local int I, J, Capacity, Kept;
    I = PhysicalMemberIndex(W);
    if (Role != ROLE_Authority || I < 0 || !IsMember(W) || !IsMember(Members[1 - I])
        || Token <= 0 || Token == MaxInt || Token <= LastWorldDropToken[I]
        || WorldDropToken[I] != 0 || AmmoDepth != 0 || AmmoBorrower != None
        || PhysicalReloadPermit != None || bWorldRestoring || Reserve < 0 || Revision == MaxInt) return false;
    for (J = 0; J < 2; ++J)
        if (PhysicalStatuses[J] == 1 || PhysicalStatuses[J] == 4
            || Members[J].IsInState('Reloading') || Members[J].SpareAmmoCount[0] != 0) return false;
    if (!bWorldSplit)
    {
        // Match stock SetupDroppedPickup: the retained single's capacity is
        // calculated at upgrade zero for the source perk, before its upgrade
        // is restored. The wrapper inherits that exact stock single's rules.
        Members[1 - I].ModifySpareAmmoCapacity(Capacity, 0, 0, Human.GetPerk());
        if (Capacity < 0) return false;
        Kept = Min(Reserve, Capacity);
        WorldDropReserve[I] = Reserve - Kept;
        Reserve = Kept;
        WorldDropUpgrade[I] = 0;
        WorldDropUpgrade[1 - I] = SourceUpgrade;
        bWorldSplit = true;
    }
    else
    {
        // The other member is already a dropped single. This member carries
        // its own whole remaining pool; never split or downgrade it again.
        if (WorldDropToken[1 - I] <= 0) return false;
        WorldDropReserve[I] = Reserve;
        Reserve = 0;
    }
    WorldDropToken[I] = Token;
    LastWorldDropToken[I] = Token;
    ++Revision;
    bForceNetUpdate = true;
    return true;
}

// Own catch, recall and failed-release rollback consume an exact escrow once.
// While the other pistol is still dropped only this returned pool is usable.
function bool ReturnWorldRelease(KFWeapon W, int Token)
{
    local int I;
    I = PhysicalMemberIndex(W);
    // Teardown/death may invalidate local input context before the authority
    // restores stock inventory. Exact ownership/token still authorizes return.
    if (Role != ROLE_Authority || PairState != 2 || I < 0 || !Owns(W) || Token <= 0
        || WorldDropToken[I] != Token || AmmoDepth != 0 || AmmoBorrower != None
        || WorldDropReserve[I] < 0 || Reserve < 0 || WorldDropReserve[I] > MaxInt - Reserve
        || Revision == MaxInt) return false;
    Reserve += WorldDropReserve[I];
    WorldDropReserve[I] = 0;
    WorldDropToken[I] = 0;
    if (WorldDropToken[0] == 0 && WorldDropToken[1] == 0)
    {
        SourceUpgrade = Max(SourceUpgrade, Max(WorldDropUpgrade[0], WorldDropUpgrade[1]));
        WorldDropUpgrade[0] = SourceUpgrade;
        WorldDropUpgrade[1] = SourceUpgrade;
        bWorldSplit = false;
    }
    ++Revision;
    bForceNetUpdate = true;
    return true;
}

// Prepared cross-owner extraction is the only live path that consumes both
// wrappers without restoring their combined stock receipt. Keep PairState=2
// until both stock removals have charged their real per-member weight.
function byte CommitWorldExtraction(VRWorldDropPairTransfer Request)
{
    local KFInventoryManager RecipientInventory;
    local int SourceCarry, RecipientCarry, KeptWeight, CaughtWeight;
    if (Request == None || Request.Pair != self || bWorldRestoring || !Request.StillPrepared()) return 0;
    RecipientInventory = KFInventoryManager(Request.Catcher.InvManager);
    SourceCarry = Manager.CurrentCarryBlocks;
    RecipientCarry = RecipientInventory.CurrentCarryBlocks;
    KeptWeight = Request.KeptWeapon.GetModifiedWeightValue();
    CaughtWeight = Request.PreparedMerge != None ? Request.PreparedMerge.CarryDelta()
        : Request.CaughtWeapon.GetModifiedWeightValue();
    Request.bMutationStarted = true;
    bWorldRestoring = true;
    if (!RemoveExtractionMembers()) { bWorldRestoring = false; return 2; }
    ClearExtractionPools();
    if (!InstallExtractionSingle(Request.KeptWeapon, Human, Request.RetainedAmmo[0],
        Request.KeptReserve, Request.KeptUpgrade)) return 2;
    if (Request.PreparedMerge != None)
    {
        if (Request.PreparedMerge.Commit() != 1) return 2;
        Request.CaughtWeapon = Request.PreparedMerge.ResultWeapon;
    }
    else if (!InstallExtractionSingle(Request.CaughtWeapon, Request.Catcher, Request.DepartingAmmo[0],
        Request.CaughtReserve, Request.CaughtUpgrade)) return 2;
    if (Manager.CurrentCarryBlocks != SourceCarry - SourceWeight + KeptWeight
        || RecipientInventory.CurrentCarryBlocks != RecipientCarry + CaughtWeight) return 2;
    return 1;
}

private function bool RemoveExtractionMembers()
{
    local int I;
    if (Hands != None) Hands.CancelTransfer();
    for (I = 0; I < 2; ++I)
    {
        Members[I].ForceEndFire();
        Members[I].ClearTimer('ReloadAmmoTimer'); Members[I].ClearTimer('ReloadStatusTimer');
        Members[I].GotoState('Inactive');
        RetireRuntime(Members[I]);
    }
    for (I = 0; I < 2; ++I)
    {
        Manager.RemoveFromInventory(Members[I]);
        if (Members[I] == None || Members[I].bDeleteMe || Owns(Members[I])
            || Manager.ItemIsInInventory(Members[I])) return false;
        if (Human.MyKFWeapon == Members[I]) Human.MyKFWeapon = None;
        if (Hands != None && (Hands.Selected[0] == Members[I] || Hands.Selected[1] == Members[I]))
        {
            if (Hands.Selected[0] == Members[I]) Hands.Selected[0] = None;
            if (Hands.Selected[1] == Members[I]) Hands.Selected[1] = None;
        }
    }
    return true;
}

private function ClearExtractionPools()
{
    local int I;
    Reserve = 0;
    for (I = 0; I < 2; ++I)
    {
        WorldDropToken[I] = 0; WorldDropReserve[I] = 0; WorldDropUpgrade[I] = 0;
        PhysicalStatuses[I] = 3; PhysicalFences[I] = 1;
        ClosePhysicalMagazineWell(I);
    }
    bWorldSplit = false;
    PairState = 3;
    bWorldRestoring = false;
    for (I = 0; I < 2; ++I)
    {
        Members[I].Inventory = None; Members[I].InvManager = None;
        Members[I].AmmoCount[0] = 0; Members[I].AmmoCount[1] = 0;
        Members[I].SpareAmmoCount[0] = 0; Members[I].SpareAmmoCount[1] = 0;
        Members[I].SetOwner(None); Members[I].Instigator = None;
        Members[I].Destroy();
    }
    // The original dual was an empty, unowned receipt, never another weapon.
    RestoreAggregatePresentation();
    StockItem.Destroy();
    bForceNetUpdate = true;
}

private function bool InstallExtractionSingle(KFWeapon W, KFPawn_Human Body,
    int Loaded, int Spare, int Upgrade)
{
    local KFInventoryManager Inventory;
    Inventory = KFInventoryManager(Body.InvManager);
    W.SetOwner(Body); W.Instigator = Body; W.InvManager = Inventory;
    W.CacheKFPlayerController();
    W.InitializeAmmoCapacity(); W.SetWeaponUpgradeLevel(Upgrade);
    if (!Inventory.AddInventory(W, true) || W.bDeleteMe || W.Owner != Body
        || W.Instigator != Body || W.InvManager != Inventory || !Inventory.ItemIsInInventory(W)) return false;
    W.AmmoCount[0] = Loaded; W.AmmoCount[1] = 0;
    W.SpareAmmoCount[0] = Spare; W.SpareAmmoCount[1] = 0;
    W.bForceNetUpdate = true;
    return true;
}

// The pre-death binder remaps both old identities before it detaches any
// registered world props. Health is already zero here; exact manager/chain
// ownership, not live input context, authorizes this one-time split.
function bool ExtractDeathSingles(out KFWeapon First, out KFWeapon Second)
{
    local KFWeapon Singles[2];
    local int Loaded[2], Spare[2], Upgrade[2];
    local int I, CurrentIndex;
    First = None; Second = None;
    if (Role != ROLE_Authority || PairState != 2 || bWorldRestoring
        || Human == None || Human.bDeleteMe || Human.Health > 0
        || Manager == None || Manager != Human.InvManager || Manager.bPendingDelete
        || AmmoDepth != 0 || AmmoBorrower != None || PhysicalReloadPermit != None
        || !bWorldSplit || (WorldDropToken[0] == 0 && WorldDropToken[1] == 0)
        || Reserve < 0 || (WorldDropToken[0] > 0 && WorldDropToken[1] > 0 && Reserve != 0)
        || StockItem == None || StockItem.bDeleteMe || StockItem.SingleClass == None
        || StockItem.Owner != None || StockItem.InvManager != None || StockItem.Instigator != None
        || StockItem.Inventory != None || StockItem.AmmoCount[0] != 0 || StockItem.SpareAmmoCount[0] != 0)
        return false;
    for (I = 0; I < 2; ++I)
    {
        if (!Owns(Members[I]) || Members[I].Class != MemberClassFor(StockItem)
            || Members[I].AmmoCount[0] < 0 || Members[I].AmmoCount[1] != 0
            || Members[I].SpareAmmoCount[0] != 0 || Members[I].SpareAmmoCount[1] != 0
            || WorldDropReserve[I] < 0 || WorldDropUpgrade[I] < 0
            || (WorldDropToken[I] == 0 && WorldDropReserve[I] > MaxInt - Reserve)) return false;
        Loaded[I] = Members[I].AmmoCount[0];
        Spare[I] = WorldDropReserve[I] + (WorldDropToken[I] == 0 ? Reserve : 0);
        Upgrade[I] = WorldDropUpgrade[I];
    }
    for (I = 0; I < 2; ++I)
    {
        Singles[I] = Spawn(StockItem.SingleClass);
        if (Singles[I] == None || Singles[I].MedicCompClass != None || Singles[I].TargetingCompClass != None)
        {
            if (Singles[0] != None) Singles[0].Destroy();
            if (Singles[1] != None) Singles[1].Destroy();
            return false;
        }
        Singles[I].SetOwner(None); Singles[I].Inventory = None; Singles[I].InvManager = None;
        Singles[I].Instigator = Human; Singles[I].CacheKFPlayerController();
        Singles[I].SetWeaponUpgradeLevel(Upgrade[I]);
        Singles[I].bGivenAtStart = bSourceGivenAtStart;
        Singles[I].AmmoCount[0] = Loaded[I]; Singles[I].AmmoCount[1] = 0;
        Singles[I].SpareAmmoCount[0] = Spare[I]; Singles[I].SpareAmmoCount[1] = 0;
        Singles[I].GotoState('Inactive'); Singles[I].SetHidden(true);
        Singles[I].Instigator = None; Singles[I].CacheKFPlayerController();
    }
    CurrentIndex = Human.Weapon == Members[0] ? 0 : (Human.Weapon == Members[1] ? 1 : -1);
    bWorldRestoring = true;
    if (!RemoveExtractionMembers())
    {
        // The pre-death binder sees the prepared actors on a post-boundary
        // fault, rather than refunding or spawning another paid copy.
        First = Singles[0]; Second = Singles[1];
        bWorldRestoring = false;
        return false;
    }
    ClearExtractionPools();
    First = Singles[0]; Second = Singles[1];
    if (!InstallExtractionSingle(First, Human, Loaded[0], Spare[0], Upgrade[0])
        || !InstallExtractionSingle(Second, Human, Loaded[1], Spare[1], Upgrade[1])) return false;
    if (CurrentIndex >= 0) { Human.Weapon = Singles[CurrentIndex]; Human.MyKFWeapon = Singles[CurrentIndex]; }
    return true;
}

simulated function int SharedReserve(optional KFWeapon W)
{
    if (W != None && WorldReleased(W)) return 0;
    return AmmoBorrower != None ? AmmoBorrower.SpareAmmoCount[0] : Reserve;
}

simulated function int ReserveCapacity(KFWeapon W)
{
    if (W == None || !IsMember(W) || WorldReleased(W)) return 0;
    return bWorldSplit ? W.SpareAmmoCapacity[0] : SourceReserveCapacity;
}

simulated function int TotalRounds()
{
    if (PairState != 2 || Members[0] == None || Members[1] == None) return -1;
    return Members[0].AmmoCount[0] + Members[1].AmmoCount[0] + SharedReserve() + WorldEscrow();
}

// Stock reload notifies are synchronous. Move reserve into exactly one caller
// for its Super call, then move it back, including nested calls on that item.
// Reload A and B in one tick therefore cannot spend the same reserve twice.
simulated function bool BorrowAmmo(KFWeapon W)
{
    if (!IsMember(W) || WorldReleased(W) || (AmmoBorrower != None && AmmoBorrower != W)) return false;
    if (AmmoDepth == 0)
    {
        if (W.SpareAmmoCount[0] != 0) return Fail("unexpected_member_reserve");
        AmmoBorrower = W;
        W.SpareAmmoCount[0] = Reserve;
        Reserve = 0;
    }
    ++AmmoDepth;
    return true;
}

simulated function ReturnAmmo(KFWeapon W)
{
    if (AmmoBorrower != W || AmmoDepth <= 0) { Fail("ammo_scope_mismatch"); return; }
    --AmmoDepth;
    if (AmmoDepth == 0)
    {
        Reserve = W.SpareAmmoCount[0];
        W.SpareAmmoCount[0] = 0;
        AmmoBorrower = None;
        ++Revision;
    }
}

function int AddReserve(KFWeapon W, int Amount)
{
    local int OldReserve, NewReserve, Limit;
    if (!IsMember(W) || WorldReleased(W) || AmmoDepth != 0) return 0;
    OldReserve = Reserve;
    Limit = Max(0, SourceMagazineCapacity + SourceReserveCapacity
        - Members[0].AmmoCount[0] - Members[1].AmmoCount[0] - WorldEscrow());
    if (bWorldSplit) Limit = Min(Limit, W.SpareAmmoCapacity[0]);
    // Widened/overflowing requests are rejected before arithmetic.
    if (Amount > MaxInt - OldReserve || Amount < -OldReserve) return 0;
    // A capacity/perk change does not confiscate already owned rounds.
    // Only new positive credits are limited; debits pay their exact request.
    NewReserve = OldReserve + Amount;
    if (Amount > 0) NewReserve = OldReserve + Min(Amount, Max(0, Limit - OldReserve));
    Reserve = Max(0, NewReserve);
    ++Revision;
    return Reserve - OldReserve;
}

function RemoveLink(Inventory Target)
{
    local Inventory Link, Previous;
    Previous = None;
    for (Link = Manager.InventoryChain; Link != None; Link = Link.Inventory)
    {
        if (Link == Target)
        {
            if (Previous == None) Manager.InventoryChain = Link.Inventory;
            else Previous.Inventory = Link.Inventory;
            Link.Inventory = None;
            return;
        }
        Previous = Link;
    }
}

function RetireRuntime(KFWeapon W)
{
    local VRWeaponRuntime R;
    local int I;
    if (Hands == None) return;
    R = Hands.Registry.FindItem(W);
    if (R == None) return;
    if (R.PrimaryHand >= 0) Hands.ReleaseHand(R.PrimaryHand);
    if (R.SupportHand >= 0) Hands.ReleaseHand(R.SupportHand);
    Hands.Stow(R);
    Hands.Registry.Revoke(R);
    if (R.Presenter != None) { R.Presenter.Abandon(); R.Presenter.Destroy(); }
    if (R.EffectsAttachment != None) R.EffectsAttachment.Destroy();
    R.NativeReady = 0;
    I = Hands.Registry.Items.Find(R);
    if (I != INDEX_NONE) Hands.Registry.Items.Remove(I, 1);
}

// Restores the exact original stock actor with the CURRENT remaining ammo.
// It never refunds fired rounds. The replay removes its explicit fixture grant.
function bool Restore()
{
    local Inventory Previous, Link;
    local int I, Loaded, Remaining;
    local bool bWasCurrent;
    if (PairState == 3) return true;
    if (PairState == 1) { AbortPreparation(); return true; }
    if (Role != ROLE_Authority || PairState != 2 || Human == None || Human.bDeleteMe
        || Human.InvManager != Manager || AmmoDepth != 0 || StockItem == None || StockItem.bDeleteMe
        || StockItem.Owner != None || StockItem.InvManager != None || StockItem.Instigator != None
        || StockItem.AmmoCount[0] != 0 || StockItem.SpareAmmoCount[0] != 0
        || !Owns(Members[0]) || !Owns(Members[1])) return Fail("restore_precondition");
    if (WorldDropToken[0] > 0 || WorldDropToken[1] > 0)
    {
        bWorldRestoring = true;
        if (!RetireWorldDrops(self) || WorldDropToken[0] != 0 || WorldDropToken[1] != 0)
        {
            bWorldRestoring = false;
            return Fail("restore_world_drop_retirement");
        }
        bWorldRestoring = false;
    }
    Loaded = Members[0].AmmoCount[0] + Members[1].AmmoCount[0];
    Remaining = Reserve + WorldEscrow();
    // Realistic chambers can hold a round per member above the stock dual's
    // magazine; those rounds return to its reserve rather than vanishing.
    if (Loaded > SourceMagazineCapacity && Remaining >= 0 && Loaded - SourceMagazineCapacity <= MaxInt - Remaining)
    {
        Remaining += Loaded - SourceMagazineCapacity;
        Loaded = SourceMagazineCapacity;
    }
    if (Loaded < 0 || Loaded > SourceMagazineCapacity || Remaining < 0) return Fail("restore_ammo");
    bWasCurrent = Human.Weapon == Members[0] || Human.Weapon == Members[1];
    if (Hands != None) Hands.CancelTransfer();
    for (I = 0; I < 2; ++I)
    {
        Members[I].ForceEndFire();
        Members[I].GotoState('Inactive');
        RetireRuntime(Members[I]);
    }
    // Preserve unrelated inventory links even if another item was inserted
    // between the members after conversion.
    RemoveLink(Members[1]);
    for (Link = Manager.InventoryChain; Link != None && Link != Members[0]; Link = Link.Inventory)
        Previous = Link;
    if (Link != Members[0]) return Fail("restore_link");
    StockItem.SetOwner(Human);
    StockItem.Instigator = Human;
    StockItem.InvManager = Manager;
    StockItem.AmmoCount[0] = Loaded;
    StockItem.SpareAmmoCount[0] = Remaining;
    StockItem.Inventory = Members[0].Inventory;
    if (Previous == None) Manager.InventoryChain = StockItem;
    else Previous.Inventory = StockItem;
    Reserve = 0;
    WorldDropToken[0] = 0; WorldDropToken[1] = 0;
    WorldDropReserve[0] = 0; WorldDropReserve[1] = 0;
    bWorldSplit = false;
    PairState = 3;
    for (I = 0; I < 2; ++I)
    {
        if (Hands != None && (Hands.Selected[I] == Members[0] || Hands.Selected[I] == Members[1])) Hands.Selected[I] = None;
        Members[I].Inventory = None;
        Members[I].AmmoCount[0] = 0;
        Members[I].SpareAmmoCount[0] = 0;
        Members[I].InvManager = None;
        Members[I].SetOwner(None);
        Members[I].Instigator = None;
        Members[I].Destroy();
    }
    if (Hands != None)
    {
        Hands.SyncCompatibility(); Hands.SyncHands();
        if (Human.Health <= 0) { Human.Weapon = StockItem; Human.MyKFWeapon = StockItem; }
    }
    else
    {
        StockItem.ClientGivenTo(Human, true);
        StockItem.ClientForceAmmoUpdate(Loaded, Remaining);
        if (bWasCurrent)
        {
            Human.Weapon = StockItem;
            Human.MyKFWeapon = StockItem;
        }
    }
    StockItem.bForceNetUpdate = true;
    bForceNetUpdate = true;
    `log("KF2VR_PAIR phase=restored family=" $ StockItem.Class.Name $ " rounds=" $ (Loaded + Remaining)
        $ " weight=" $ Manager.CurrentCarryBlocks $ " netmode=" $ WorldInfo.NetMode);
    return true;
}

function AbortPreparation()
{
    local int I;
    if (PairState != 1) return;
    PairState = 3;
    for (I = 0; I < 2; ++I)
        if (Members[I] != None && !Members[I].bDeleteMe)
        {
            Members[I].InvManager = None;
            Members[I].SetOwner(None);
            Members[I].Instigator = None;
            Members[I].Destroy();
        }
    if (bSourceWasActive && StockItem != None && Owns(StockItem) && Human.Health > 0)
        StockItem.Activate();
}

simulated event Tick(float DeltaTime)
{
    UpdateAggregatePresentation();
    if (Role == ROLE_Authority) TickPhysicalReloads();
    if (Human != None && Manager == None) Manager = KFInventoryManager(Human.InvManager);
    // The same stock restoration handles solo traders and a dying owner.
    // Network controllers also call it synchronously before opening the trader.
    if (Role == ROLE_Authority && PairState == 2 && Human != None && !Human.bDeleteMe
        && (Human.Health <= 0 || (Manager != None && Manager.bServerTraderMenuOpen)))
    {
        if (Restore() && KFPlayerController(Human.Controller) != None)
            KFPlayerController(Human.Controller).SyncInventoryProperties();
    }
    if (Role == ROLE_Authority && PairState == 3) { Destroy(); return; }
    if (PairState == 2 && WorldInfo.NetMode != NM_DedicatedServer)
    {
        InitializeMemberPresentation(Members[0]);
        InitializeMemberPresentation(Members[1]);
    }
}

defaultproperties
{
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    NetUpdateFrequency=30
    Families(0)=(DualClass=class'KFWeap_Pistol_Dual9mm',SingleClass=class'KFWeap_Pistol_9mm',MemberClass=class'VRWeap_Paired9mm')
    Families(1)=(DualClass=class'KFWeap_Revolver_DualRem1858',SingleClass=class'KFWeap_Revolver_Rem1858',MemberClass=class'VRWeap_Paired1858')
    Families(2)=(DualClass=class'KFWeap_Pistol_DualDeagle',SingleClass=class'KFWeap_Pistol_Deagle',MemberClass=class'VRWeap_PairedDeagle')
    Families(3)=(DualClass=class'KFWeap_Revolver_DualSW500',SingleClass=class'KFWeap_Revolver_SW500',MemberClass=class'VRWeap_PairedSW500')
    Families(4)=(DualClass=class'KFWeap_Pistol_DualAF2011',SingleClass=class'KFWeap_Pistol_AF2011',MemberClass=class'VRWeap_PairedAF2011')
    Families(5)=(DualClass=class'KFWeap_HRG_93R_Dual',SingleClass=class'KFWeap_HRG_93R',MemberClass=class'VRWeap_Paired93R')
    Families(6)=(DualClass=class'KFWeap_Pistol_DualColt1911',SingleClass=class'KFWeap_Pistol_Colt1911',MemberClass=class'VRWeap_PairedColt1911')
    Families(7)=(DualClass=class'KFWeap_Pistol_DualFlare',SingleClass=class'KFWeap_Pistol_Flare',MemberClass=class'VRWeap_PairedFlare')
    Families(8)=(DualClass=class'KFWeap_Pistol_DualHRGWinterbite',SingleClass=class'KFWeap_Pistol_HRGWinterbite',MemberClass=class'VRWeap_PairedWinterbite')
    Families(9)=(DualClass=class'KFWeap_Pistol_DualG18',SingleClass=class'KFWeap_Pistol_G18C',MemberClass=class'VRWeap_PairedG18C')
    Families(10)=(DualClass=class'KFWeap_Pistol_ChiappaRhinoDual',SingleClass=class'KFWeap_Pistol_ChiappaRhino',MemberClass=class'VRWeap_PairedChiappaRhino')
    Families(11)=(DualClass=class'KFWeap_HRG_Revolver_DualBuckshot',SingleClass=class'KFWeap_HRG_Revolver_Buckshot',MemberClass=class'VRWeap_PairedBuckshot')
    Families(12)=(DualClass=class'KFWeap_Pistol_DualBladed',SingleClass=class'KFWeap_Pistol_Bladed',MemberClass=class'VRWeap_PairedBladed')
}
