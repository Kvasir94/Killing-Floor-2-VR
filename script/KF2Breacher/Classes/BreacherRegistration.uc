// Exists only when the optional mutator spawns it. Both normal UI surfaces
// enumerate PC.PerkList: Perks selection and the trader's per-perk filter row.
class BreacherRegistration extends ReplicationInfo;



var repnotify int TraderSlot;
// Trader entries in slot order; TraderSlot is the first one's ItemID.
var array< class<KFWeaponDefinition> > WeaponDefinitions;
// Development perk level/build from the mutator; 0 keeps the ordinary level-0 perk.
var repnotify int DevLevel;
var repnotify int DevBuild;
var KFGameReplicationInfo CatalogGRI;
var KFGFxObject_TraderItems OriginalCatalog, OwnedCatalog;
var array<KFPlayerController> RegisteredPlayers;
var array<byte> PreviousPerkChoices;
var bool bReportedMismatch;
var array<BreacherArcFence> ArcTools;

replication
{
    if (bNetDirty) TraderSlot, DevLevel, DevBuild;
}

function BreacherArcFence ArcTool(KFPlayerController PC)
{
    local int I;
    local BreacherArcFence Tool;
    for (I = ArcTools.Length - 1; I >= 0; --I)
    {
        if (ArcTools[I] == None || ArcTools[I].bDeleteMe) ArcTools.Remove(I, 1);
        else if (ArcTools[I].Owner == PC) return ArcTools[I];
    }
    if (Role != ROLE_Authority || PC == None) return None;
    Tool = Spawn(class'BreacherArcFence', PC);
    if (Tool != None) ArcTools.AddItem(Tool);
    return Tool;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    // Let the game's PostBeginPlay finish its base catalog before appending.
    SetTimer(0.25, true, 'RegisterContent');
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'TraderSlot' || VarName == 'DevLevel' || VarName == 'DevBuild') RegisterContent();
    else Super.ReplicatedEvent(VarName);
}

simulated function bool RegisterTrader()
{
    local array<KFGFxObject_TraderItems.STraderItem> Added;
    local KFGFxObject_TraderItems.STraderItem Entry;
    local int Index, I;
    CatalogGRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (CatalogGRI == None || CatalogGRI.TraderItems == None) return false;
    Index = CatalogGRI.TraderItems.SaleItems.Find('WeaponDef', WeaponDefinitions[0]);
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
    if (CatalogGRI.TraderItems.SaleItems.Length + WeaponDefinitions.Length > 255) return false;
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
    for (I = 0; I < WeaponDefinitions.Length; ++I)
    {
        Entry.WeaponDef = WeaponDefinitions[I];
        Added.AddItem(Entry);
    }
    OwnedCatalog.SetItemsInfo(Added);
    for (I = 0; I < Added.Length; ++I)
    {
        Added[I].ItemID = OwnedCatalog.SaleItems.Length;
        OwnedCatalog.SaleItems.AddItem(Added[I]);
    }
    CatalogGRI.TraderItems = OwnedCatalog;
    if (Role == ROLE_Authority)
    {
        TraderSlot = Added[0].ItemID;
        bNetDirty = true;
        bForceNetUpdate = true;
    }
    `log("BREACHER trader registered slot=" $ Added[0].ItemID @ "entries=" $ Added.Length
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
            Entry.PerkLevel = DevLevel;
            Entry.PrestigeLevel = 0;
            Entry.PerkArchetype = Spawn(class'BreacherPerk', PC);
            PC.PerkList.AddItem(Entry);
            ApplyDevLevel(PC);
            if (PC.MyGFxManager != None && PC.MyGFxManager.PerksMenu != None
                && PC.MyGFxManager.PerksMenu.SelectionContainer != None)
                PC.MyGFxManager.PerksMenu.SelectionContainer.UpdatePerkSelection(PC.SavedPerkIndex);
        }
        ApplyDevLevel(PC);
        if (Role == ROLE_Authority) ArcTool(PC); // every player can detach from a field
        if (Role == ROLE_Authority && BreacherPerk(PC.CurrentPerk) != None
            && BreacherPerk(PC.CurrentPerk).SkillActive(9)) class'BreacherOverpressure'.static.ForPlayer(PC);
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

// Hold the menu entry, the archetype and the selected perk at the development
// level on every pass, since native selection can reset a custom perk to 0.
simulated function ApplyDevLevel(KFPlayerController PC)
{
    local int Index;
    local BreacherPerk Perk;
    local bool bLevelChanged;
    if (DevLevel <= 0) return;
    Index = PC.PerkList.Find('PerkClass', class'BreacherPerk');
    if (Index == INDEX_NONE) return;
    bLevelChanged = PC.PerkList[Index].PerkLevel != DevLevel;
    PC.PerkList[Index].PerkLevel = DevLevel;
    Perk = BreacherPerk(PC.PerkList[Index].PerkArchetype);
    if (Perk != None && (Perk.GetLevel() != DevLevel || Perk.DevLevel != DevLevel
        || Perk.DevBuild != DevBuild || Perk.GetSavedBuild() == 0)) Perk.ApplyDevLevel(DevLevel, DevBuild);
    Perk = BreacherPerk(PC.CurrentPerk);
    if (Perk != None && (Perk.GetLevel() != DevLevel || Perk.DevLevel != DevLevel
        || Perk.DevBuild != DevBuild || Perk.GetSavedBuild() == 0)) Perk.ApplyDevLevel(DevLevel, DevBuild);
    if (bLevelChanged) PC.UpdatePerkLevelMenu(class'BreacherPerk');
}

simulated event Destroyed()
{
    local KFPlayerController PC;
    local KFAutoPurchaseHelper Purchase;
    local int I, Index;
    ClearTimer('RegisterContent');
    for (I = 0; I < ArcTools.Length; ++I)
        if (ArcTools[I] != None) ArcTools[I].Destroy();
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
        Index = OwnedCatalog.SaleItems.Find('WeaponDef', WeaponDefinitions[0]);
        if (Index != INDEX_NONE)
        {
            OwnedCatalog.SaleItems.Remove(Index, WeaponDefinitions.Length);
            for (I = Index; I < OwnedCatalog.SaleItems.Length; ++I)
                OwnedCatalog.SaleItems[I].ItemID = I;
        }
    }
    Super.Destroyed();
}

defaultproperties
{
    WeaponDefinitions(0)=class'BreacherDeadboltDefinition'
    WeaponDefinitions(1)=class'BreacherRipcordDefinition'
    TraderSlot=-1
    bAlwaysRelevant=true
    bOnlyRelevantToOwner=false
    RemoteRole=ROLE_SimulatedProxy
    NetUpdateFrequency=2.0
}
