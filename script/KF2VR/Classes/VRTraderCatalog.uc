// Adds KF2-VR's own trader items (the RAVEN-7, listed under Berserker by its
// weapon's AssociatedPerkClasses) to the stock catalog. The catalog is the
// loaded GP_Trader_ARCH archetype, never replicated as data: the server and
// every client append the same entries in the same order, so purchase item
// indices agree. Idempotent; call it whenever the GRI's catalog is present.
class VRTraderCatalog extends Object abstract config(Game);

var array<class<KFWeaponDefinition> > Definitions;
// Launcher choice (Solo only): the experimental Portal Gun is for sale only
// when the player asked for it. Portals are local, so networked games never
// offer the gun whatever this says.
var config bool bOfferPortalGun;

static function bool Register(KFGameReplicationInfo GRI)
{
    local array<KFGFxObject_TraderItems.STraderItem> Additions;
    local KFGFxObject_TraderItems.STraderItem Entry;
    local int I;
    if (GRI == None || GRI.TraderItems == None) return false;
    for (I = 0; I < default.Definitions.Length; ++I)
    {
        if (GRI.TraderItems.SaleItems.Find('WeaponDef', default.Definitions[I]) != INDEX_NONE) continue;
        // Portals are local-only: offer the gun in standalone games, and only on request.
        if (default.Definitions[I] == class'VRWeapDef_PortalGun'
            && (GRI.WorldInfo.NetMode != NM_Standalone || !default.bOfferPortalGun)) continue;
        // KF2's server purchase indices are bytes.
        if (GRI.TraderItems.SaleItems.Length + Additions.Length >= 255) break;
        Entry.WeaponDef = default.Definitions[I];
        Additions.AddItem(Entry);
    }
    if (Additions.Length == 0) return true;
    // Native metadata (class, perks, weight, price, stats) for the additions
    // only; every existing entry keeps its index.
    GRI.TraderItems.SetItemsInfo(Additions);
    for (I = 0; I < Additions.Length; ++I)
    {
        Additions[I].ItemID = GRI.TraderItems.SaleItems.Length;
        GRI.TraderItems.SaleItems.AddItem(Additions[I]);
    }
    `log("KF2VR_TRADER registered=" $ Additions.Length @ "total=" $ GRI.TraderItems.SaleItems.Length
        @ "netmode=" $ GRI.WorldInfo.NetMode);
    return true;
}

// VR-only items: their throw/recall and authored grip need tracked hands.
static function bool IsVROnly(class<KFWeaponDefinition> Definition)
{
    return Definition != None && default.Definitions.Find(Definition) != INDEX_NONE;
}

defaultproperties
{
    Definitions(0)=class'VRWeapDef_Tomahawk'
    Definitions(1)=class'VRWeapDef_PortalGun'
    Definitions(2)=class'VRWeapDef_TomahawkSecond'
}
