// Shared normal-trader catalog. Source ports are optional dependencies and
// appear only when their weapon class, original model and icon are loadable.
class VRPortedTraderRegistry extends Object;

// Built-in entries must serialize into the package. KF2's compiler discards
// config values assigned in defaultproperties when no matching INI is staged.
var array<string> DefinitionPaths;

static function bool IsPortedDefinition(class<KFWeaponDefinition> Definition)
{
    return Definition != None && default.DefinitionPaths.Find(PathName(Definition)) != INDEX_NONE;
}

static function bool DependenciesReady(class<KFWeaponDefinition> Definition)
{
    local class<KFWeapon> WeaponClass;
    if (Definition == None) return false;
    WeaponClass = class<KFWeapon>(DynamicLoadObject(Definition.default.WeaponClassPath, class'Class', true));
    if (WeaponClass == None) return false;
    if (Definition == class'VRWeapDef_EngineerKit') return class'VREngineerPresentation'.static.HasCoreAssets();
    if (Definition == class'VRWeapDef_Wrangler') return class'VREngineerPresentation'.static.HasWranglerAssets();
    return WeaponClass.default.FirstPersonMeshName != ""
        && DynamicLoadObject(WeaponClass.default.FirstPersonMeshName, class'SkeletalMesh', true) != None;
}

static function KFGFxObject_TraderItems MakeCatalog(KFGameReplicationInfo GRI)
{
    local KFGFxObject_TraderItems Catalog;
    local KFGFxObject_TraderItems.STraderItem Entry;
    local array<KFGFxObject_TraderItems.STraderItem> Additions;
    local class<KFWeaponDefinition> Definition;
    local int I;
    if (GRI == None || GRI.TraderItems == None) return None;
    Catalog = new(GRI) class'KFGFxObject_TraderItems';
    Catalog.SaleItems = GRI.TraderItems.SaleItems;
    Catalog.ArmorPrice = GRI.TraderItems.ArmorPrice;
    Catalog.GrenadePrice = GRI.TraderItems.GrenadePrice;
    Catalog.ArmorDef = GRI.TraderItems.ArmorDef;
    Catalog.KnifeStats = GRI.TraderItems.KnifeStats;
    Catalog.OffPerkIconPath = GRI.TraderItems.OffPerkIconPath;
    for (I = 0; I < default.DefinitionPaths.Length; ++I)
    {
        Definition = class<KFWeaponDefinition>(DynamicLoadObject(default.DefinitionPaths[I], class'Class', true));
        if (!DependenciesReady(Definition) || Catalog.SaleItems.Find('WeaponDef', Definition) != INDEX_NONE) continue;
        // KF2's server purchase indices and several loops are bytes.
        if (Catalog.SaleItems.Length + Additions.Length >= 255) break;
        Entry.WeaponDef = Definition;
        Additions.AddItem(Entry);
    }
    // Preserve every existing entry/index. Native metadata is generated only
    // for additions, then their IDs refer to the complete server catalog.
    Catalog.SetItemsInfo(Additions);
    for (I = 0; I < Additions.Length; ++I)
    {
        Additions[I].ItemID = Catalog.SaleItems.Length;
        Catalog.SaleItems.AddItem(Additions[I]);
    }
    `log("KF2VR_PORTED_TRADER registered=" $ Additions.Length @ "total=" $ Catalog.SaleItems.Length);
    return Catalog;
}

static function InstallMenu(KFPlayerController PC)
{
    local int I;
    local KFPawn_Human P;
    local KFGameReplicationInfo GRI;
    if (PC == None || PC.MyGFxManager == None) return;
    // Install before the movie requests the trader widget. Stock GFx event
    // callbacks still perform all purchases, sales, discounts and weights.
    if (PC.MyGFxManager.TraderMenu == None)
        for (I = 0; I < PC.MyGFxManager.WidgetBindings.Length; ++I)
            if (PC.MyGFxManager.WidgetBindings[I].WidgetName == 'traderMenu')
                PC.MyGFxManager.WidgetBindings[I].WidgetClass = class'VRPortedTraderMenu';
    // Stock helper initialization dereferences the human's perk and catalog.
    // Retry on the next refresh while customization, spawn or travel is pending.
    P = KFPawn_Human(PC.Pawn);
    GRI = KFGameReplicationInfo(PC.WorldInfo.GRI);
    if (P == None || KFPawn_Customization(P) != None || P.Controller != PC || P.Health <= 0
        || PC.CurrentPerk == None || P.GetPerk() == None
        || KFInventoryManager(P.InvManager) == None || KFPlayerReplicationInfo(PC.PlayerReplicationInfo) == None
        || GRI == None || GRI.TraderItems == None) return;
    if (!PC.bClientTraderMenuOpen && (PC.PurchaseHelper == None || PC.PurchaseHelper.Class == class'KFAutoPurchaseHelper'))
    {
        PC.PurchaseHelperClass = class'VRPortedPurchaseHelper';
        PC.PurchaseHelper = None;
        PC.GetPurchaseHelper(true);
    }
}

defaultproperties
{
    DefinitionPaths(0)="KF2VR.VRWeapDef_EngineerKit"
    DefinitionPaths(1)="KF2VR.VRWeapDef_Wrangler"
    DefinitionPaths(2)="KF2VR.VRWeapDef_SuperGravityGun"
    DefinitionPaths(3)="KF2VR.VRWeapDef_StickybombLauncher"
}
