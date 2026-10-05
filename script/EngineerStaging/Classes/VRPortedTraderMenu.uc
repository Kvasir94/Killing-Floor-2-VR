// Fifth tab on the existing trader movie. Item IDs remain indices in the
// complete catalog, even when the displayed list contains only ported items.
class VRPortedTraderMenu extends VRTraderMenu;

var bool bPortedTab;

// Ported items carry their own VR presentation rather than a stock profile.
function bool IsOfferedInVR(const out KFGFxObject_TraderItems.STraderItem Item)
{
    return class'VRPortedTraderRegistry'.static.IsPortedDefinition(Item.WeaponDef) || Super.IsOfferedInVR(Item);
}

// The fifth tab owns the ported weapons and the perkless portal gun, which
// stock would otherwise list under every perk.
function bool IsPortedTabItem(const out KFGFxObject_TraderItems.STraderItem Item)
{
    return class'VRPortedTraderRegistry'.static.IsPortedDefinition(Item.WeaponDef)
        || Item.WeaponDef == class'VRWeapDef_PortalGun';
}

function bool ShowsInCurrentTab(const out KFGFxObject_TraderItems.STraderItem Item)
{
    return bPortedTab || !IsPortedTabItem(Item);
}

function OnOpen()
{
    bPortedTab = false;
    Super.OnOpen();
    SetPortedTabData();
}

function SetPortedTabData()
{
    local GFxObject TabData, Tab;
    local int I;
    if (FilterContainer == None || FilterContainer.TabsArray.Length != 4
        || FilterContainer.TabIconPaths.Length < 4) return;
    // Localized arrays are const in UnrealScript. Build the movie's tabInfo
    // provider with the four stock labels and our fifth label instead.
    TabData = CreateArray();
    for (I = 0; I < 4; ++I)
    {
        Tab = CreateObject("Object");
        Tab.SetString("label", FilterContainer.TabsArray[I]);
        Tab.SetString("source", "img://" $ FilterContainer.TabIconPaths[I]);
        TabData.SetElementObject(I, Tab);
    }
    Tab = CreateObject("Object");
    Tab.SetString("label", Localize("VRPortedTraderMenu", "PortedTabLabel", "KF2VR"));
    Tab.SetString("source", "img://UI_TraderMenu_TEX.UI_WeaponSelect_Trader_All");
    TabData.SetElementObject(4, Tab);
    FilterContainer.SetObject("tabInfo", TabData);
}

event bool WidgetInitialized(name WidgetName, name WidgetPath, GFxObject Widget)
{
    local bool Result;
    Result = Super.WidgetInitialized(WidgetName, WidgetPath, Widget);
    if (WidgetName == 'filterContainer') SetPortedTabData();
    return Result;
}

function Callback_TabChanged(int TabIndex)
{
    if (TabIndex < 0 || TabIndex > 4) return;
    bPortedTab = TabIndex == 4;
    if (!bPortedTab) { Super.Callback_TabChanged(TabIndex); return; }
    CurrentTab = TI_All;
    CurrentFilterIndex = 0;
    RefreshShopItemList(CurrentTab, 0);
}

function RefreshShopItemList(TabIndices TabIndex, byte FilterIndex)
{
    local array<KFGFxObject_TraderItems.STraderItem> Items;
    local KFGFxObject_TraderItems.STraderItem Item;
    local int I;
    if (!bPortedTab) { Super.RefreshShopItemList(TabIndex, FilterIndex); return; }
    if (ShopContainer == None || FilterContainer == None || MyKFPC == None) return;
    for (I = 0; I < MyKFPC.GetPurchaseHelper().TraderItems.SaleItems.Length; ++I)
    {
        // An out parameter cannot take a dynamic array element directly.
        Item = MyKFPC.GetPurchaseHelper().TraderItems.SaleItems[I];
        if (IsPortedTabItem(Item)) Items.AddItem(Item);
    }
    ShopContainer.RefreshAllItems(Items);
    FilterContainer.ClearFilters();
    FilterContainer.SetInt("selectedTab", 4);
    FilterContainer.SetInt("selectedFilter", 0);
    if (SelectedList == TL_Shop && SelectedItemIndex >= 0
        && SelectedItemIndex < MyKFPC.GetPurchaseHelper().TraderItems.SaleItems.Length)
    {
        SetTraderItemDetails(SelectedItemIndex);
        ShopContainer.SetSelectedIndex(SelectedItemIndex);
    }
}
