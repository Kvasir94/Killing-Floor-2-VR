// Exists only when the optional mutator spawns it. Both normal UI surfaces
// enumerate PC.PerkList: Perks selection and the trader's per-perk filter row.
class BreacherRegistration extends ReplicationInfo;



var repnotify int TraderSlot;
var KFGameReplicationInfo CatalogGRI;
var KFGFxObject_TraderItems OriginalCatalog, OwnedCatalog;
var array<KFPlayerController> RegisteredPlayers;
var array<byte> PreviousPerkChoices;
var bool bReportedMismatch;

replication
{
    if (bNetDirty) TraderSlot;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    // Let the game's PostBeginPlay finish its base catalog before appending.
    SetTimer(0.25, true, 'RegisterContent');
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'TraderSlot') RegisterContent();
    else Super.ReplicatedEvent(VarName);
}

simulated function bool RegisterTrader()
{
    local array<KFGFxObject_TraderItems.STraderItem> Added;
    local KFGFxObject_TraderItems.STraderItem Entry;
    local int Index;
    CatalogGRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (CatalogGRI == None || CatalogGRI.TraderItems == None) return false;
    Index = CatalogGRI.TraderItems.SaleItems.Find('WeaponDef', class'BreacherDeadboltDefinition');
    if (Index != INDEX_NONE) return true;
    if (WorldInfo.NetMode == NM_Client)
    {
        if (TraderSlot < 0 || CatalogGRI.TraderItems.SaleItems.Length < TraderSlot) return false;
        if (CatalogGRI.TraderItems.SaleItems.Length != TraderSlot)
        {
            if (!bReportedMismatch)
            {
                bReportedMismatch = true;
                `log("BREACHER trader catalog order mismatch; optional entry withheld");
            }
            return false;
        }
    }
    if (CatalogGRI.TraderItems.SaleItems.Length >= 255) return false;
    // KFGameReplicationInfo replicates TraderItems on initial connection. A
    // runtime-created Object cannot replace that package-backed reference on
    // the server: joining clients receive None and lose both buy/sell lists.
    // Network peers append locally to the same archetype in TraderSlot order.
    // Standalone can keep a private clone for later OFF maps.
    OriginalCatalog = CatalogGRI.TraderItems;
    OwnedCatalog = OriginalCatalog;
    if (WorldInfo.NetMode == NM_Standalone)
    {
        OwnedCatalog = new(CatalogGRI) class'KFGFxObject_TraderItems';
        OwnedCatalog.SaleItems = OriginalCatalog.SaleItems;
        OwnedCatalog.ArmorPrice = OriginalCatalog.ArmorPrice;
        OwnedCatalog.GrenadePrice = OriginalCatalog.GrenadePrice;
        OwnedCatalog.ArmorDef = OriginalCatalog.ArmorDef;
        OwnedCatalog.KnifeStats = OriginalCatalog.KnifeStats;
        OwnedCatalog.OffPerkIconPath = OriginalCatalog.OffPerkIconPath;
    }
    Entry.WeaponDef = class'BreacherDeadboltDefinition';
    Added.AddItem(Entry);
    OwnedCatalog.SetItemsInfo(Added);
    Added[0].ItemID = OwnedCatalog.SaleItems.Length;
    OwnedCatalog.SaleItems.AddItem(Added[0]);
    CatalogGRI.TraderItems = OwnedCatalog;
    if (Role == ROLE_Authority)
    {
        TraderSlot = Added[0].ItemID;
        bNetDirty = true;
        bForceNetUpdate = true;
    }
    `log("BREACHER trader registered slot=" $ Added[0].ItemID
        @ "total=" $ OwnedCatalog.SaleItems.Length @ "netmode=" $ WorldInfo.NetMode);
    return true;
}

simulated function RegisterContent()
{
    local KFPlayerController PC;
    local KFPlayerController.PerkInfo Entry;
    local KFAutoPurchaseHelper Purchase;
    local int Index, PlayerIndex;
    if (!RegisterTrader()) return;
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
    {
        if (PC.bDeleteMe || (WorldInfo.NetMode == NM_Client && !PC.IsLocalPlayerController())) continue;
        // Do not initialize a helper during login/customization, before the
        // pawn and perk exist. Stock trader opening creates it when ready.
        Purchase = PC.PurchaseHelper;
        if (Purchase != None) Purchase.TraderItems = CatalogGRI.TraderItems;
        Index = PC.PerkList.Find('PerkClass', class'BreacherPerk');
        if (Index == INDEX_NONE)
        {
            if (PC.PerkList.Length >= 255) continue;
            PlayerIndex = RegisteredPlayers.Find(PC);
            if (PlayerIndex == INDEX_NONE)
            {
                RegisteredPlayers.AddItem(PC);
                PreviousPerkChoices.AddItem(PC.SavedPerkIndex < PC.PerkList.Length ? PC.SavedPerkIndex : 0);
            }
            Entry.PerkClass = class'BreacherPerk';
            Entry.PerkLevel = 0;
            Entry.PrestigeLevel = 0;
            Entry.PerkArchetype = Spawn(class'BreacherPerk', PC);
            PC.PerkList.AddItem(Entry);
            if (PC.MyGFxManager != None && PC.MyGFxManager.PerksMenu != None
                && PC.MyGFxManager.PerksMenu.SelectionContainer != None)
                PC.MyGFxManager.PerksMenu.SelectionContainer.UpdatePerkSelection(PC.SavedPerkIndex);
        }
        // Keep the selected experimental perk session-local. Stock menus persist
        // their selected numeric index, which would be invalid in an OFF session.
        PlayerIndex = RegisteredPlayers.Find(PC);
        Index = PC.PerkList.Find('PerkClass', class'BreacherPerk');
        if (PlayerIndex != INDEX_NONE && PC.IsLocalPlayerController()
            && PC.MyGFxManager != None && PC.MyGFxManager.CachedProfile != None
            && PC.MyGFxManager.CachedProfile.GetProfileInt(class'KFProfileSettings'.const.KFID_SavedPerkIndex) == Index)
        {
            PC.MyGFxManager.CachedProfile.SetProfileSettingValueInt(class'KFProfileSettings'.const.KFID_SavedPerkIndex, PreviousPerkChoices[PlayerIndex]);
            if (LocalPlayer(PC.Player) != None)
                PC.MyGFxManager.CachedProfile.Save(LocalPlayer(PC.Player).ControllerId);
        }
    }
}

simulated event Destroyed()
{
    local KFPlayerController PC;
    local KFAutoPurchaseHelper Purchase;
    local int I, Index;
    ClearTimer('RegisterContent');
    for (I = 0; I < RegisteredPlayers.Length; ++I)
    {
        PC = RegisteredPlayers[I];
        if (PC == None || PC.bDeleteMe) continue;
        Purchase = PC.PurchaseHelper;
        if (Purchase != None && Purchase.TraderItems == OwnedCatalog) Purchase.TraderItems = OriginalCatalog;
        Index = PC.PerkList.Find('PerkClass', class'BreacherPerk');
        if (Index == INDEX_NONE) continue;
        if (PC.PerkList[Index].PerkArchetype != None && PC.PerkList[Index].PerkArchetype != PC.CurrentPerk)
            PC.PerkList[Index].PerkArchetype.Destroy();
        PC.PerkList.Remove(Index, 1);
        if (PC.SavedPerkIndex == Index) PC.SavedPerkIndex = PreviousPerkChoices[I];
        else if (PC.SavedPerkIndex > Index) --PC.SavedPerkIndex;
    }
    if (CatalogGRI != None && CatalogGRI.TraderItems == OwnedCatalog)
        CatalogGRI.TraderItems = OriginalCatalog;
    // Network catalogs were extended in place. Remove only our own entry so
    // the shared archetype cannot retain Breacher on a later OFF map.
    if (OwnedCatalog != None && OwnedCatalog == OriginalCatalog)
    {
        Index = OwnedCatalog.SaleItems.Find('WeaponDef', class'BreacherDeadboltDefinition');
        if (Index != INDEX_NONE)
        {
            OwnedCatalog.SaleItems.Remove(Index, 1);
            for (I = Index; I < OwnedCatalog.SaleItems.Length; ++I)
                OwnedCatalog.SaleItems[I].ItemID = I;
        }
    }
    Super.Destroyed();
}

defaultproperties
{
    TraderSlot=-1
    bAlwaysRelevant=true
    bOnlyRelevantToOwner=false
    RemoteRole=ROLE_SimulatedProxy
    NetUpdateFrequency=2.0
}
