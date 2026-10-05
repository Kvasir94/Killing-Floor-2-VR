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
var int PairState; // 0=new, 1=preparing, 2=members own ammo, 3=restored/aborted
var int SourceMagazine, SourceReserve, SourceUpgrade, SourceSkin, SourceWeight;
var int SourceMagazineCapacity, SourceReserveCapacity, CarryBefore;
var bool bSourceGivenAtStart, bFailed;
var int Reserve, Revision;
var KFWeapon AmmoBorrower;
var int AmmoDepth;
var string Failure;
var bool bSourceWasActive;
var private KFPlayerController PresentationPC;
var private bool bHidAggregate;

// Stock duals that convert into two paired members. The single is checked
// too: a stock dual whose single class differs is not the audited family.
struct VRPairFamily
{
    var class<KFWeap_DualBase> DualClass;
    var class<KFWeapon> SingleClass;
    var class<KFWeapon> MemberClass;
};
var array<VRPairFamily> Families;

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
        SourceReserveCapacity, Reserve, Revision;
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
        // SkinItemId is const/config; its stock mutation APIs are private
        // native functions. Preserve a matching inherited skin and otherwise
        // reject this first milestone without changing the source or config.
        if (Members[I].SkinItemId != SourceSkin)
        {
            AbortPreparation();
            return Fail("skin_copy_requires_native_adapter");
        }
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
    if (WorldInfo.NetMode == NM_DedicatedServer)
        return Members[0] != None && Members[1] != None && Members[0].MagazineCapacity[0] > 0
            && Members[1].MagazineCapacity[0] > 0;
    if (!StockItem.WeaponContentLoaded || StockItem.MySkelMesh == None) return false;
    for (I = 0; I < 2; ++I)
        if (Members[I] == None || Members[I].bDeleteMe || !Members[I].WeaponContentLoaded
            || Members[I].MySkelMesh == None) return false;
    return true;
}

// Virtual allocation seam lets the replay exercise an actual second-spawn
// failure, without adding a failure switch to production input or inventory.
function KFWeapon AllocateMember(class<KFWeapon> MemberClass, int Index)
{
    return Spawn(MemberClass, Human);
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
        || Members[0].SkinItemId != SourceSkin || Members[1].SkinItemId != SourceSkin
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

simulated function int SharedReserve()
{
    return AmmoBorrower != None ? AmmoBorrower.SpareAmmoCount[0] : Reserve;
}

simulated function int TotalRounds()
{
    if (PairState != 2 || Members[0] == None || Members[1] == None) return -1;
    return Members[0].AmmoCount[0] + Members[1].AmmoCount[0] + SharedReserve();
}

// Stock reload notifies are synchronous. Move reserve into exactly one caller
// for its Super call, then move it back, including nested calls on that item.
// Reload A and B in one tick therefore cannot spend the same reserve twice.
simulated function bool BorrowAmmo(KFWeapon W)
{
    if (!IsMember(W) || (AmmoBorrower != None && AmmoBorrower != W)) return false;
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
    if (!IsMember(W) || AmmoDepth != 0) return 0;
    OldReserve = Reserve;
    Limit = Max(0, SourceMagazineCapacity + SourceReserveCapacity
        - Members[0].AmmoCount[0] - Members[1].AmmoCount[0]);
    // Widened/overflowing requests are rejected before arithmetic.
    if (Amount > MaxInt - OldReserve || Amount < -OldReserve) return 0;
    NewReserve = Min(OldReserve + Amount, Limit);
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
    Loaded = Members[0].AmmoCount[0] + Members[1].AmmoCount[0];
    Remaining = Reserve;
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
