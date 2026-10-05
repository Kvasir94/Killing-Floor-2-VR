// Stock trader movie whose shop list hides weapons VR cannot hold yet. Under
// the VR viewport it hides weapons without a VR profile; a desktop player
// given the same class keeps the stock list minus VR-only items.
class VRTraderMenu extends KFGFxMenu_Trader;

function bool InVRSession()
{
    local LocalPlayer Player;
    Player = LocalPlayer(GetPC().Player);
    return Player != None && VRGameViewportClient(Player.ViewportClient) != None;
}

// A weapon with its own authored profile, or a stock dual that converts on
// pickup into paired members of one. Desktop players see the stock list minus
// KF2-VR's VR-only items (VRTraderCatalog).
function bool IsOfferedInVR(const out KFGFxObject_TraderItems.STraderItem Item)
{
    if (!InVRSession()) return !class'VRTraderCatalog'.static.IsVROnly(Item.WeaponDef);
    if (class'VRHandsBridge'.static.HasAuthoredProfile(Item.ClassName)) return true;
    return Item.SingleClassName != ''
        && class'VRWeaponPair'.static.ConvertsDual(Item.ClassName, Item.SingleClassName)
        && class'VRHandsBridge'.static.HasAuthoredProfile(Item.SingleClassName);
}

// Whether the current tab lists this item. The ported-weapons tab narrows it.
function bool ShowsInCurrentTab(const out KFGFxObject_TraderItems.STraderItem Item)
{
    return true;
}

function OnOpen()
{
    // Super caches the sell list from the inventory chain. A converted dual
    // must be restored first, or its paired members stand in for it and the
    // dual cannot be sold; the pair's own Tick restore can run a frame late.
    RestoreWeaponPairs();
    Super.OnOpen();
    LogHiddenItems();
}

function RestoreWeaponPairs()
{
    local PlayerController PC;
    local VRWeaponPair Pair;
    PC = GetPC();
    if (PC == None || PC.Pawn == None || PC.Role != ROLE_Authority) return;
    foreach PC.DynamicActors(class'VRWeaponPair', Pair)
        if (Pair.Role == ROLE_Authority && Pair.PairState == 2 && Pair.Human == PC.Pawn)
            Pair.Restore();
}

// One line per trader visit naming everything the filter took out, so a
// missing profile shows up in the log rather than as an absent gun.
function LogHiddenItems()
{
    local KFGFxObject_TraderItems Items;
    local KFGFxObject_TraderItems.STraderItem Item;
    local int I, Hidden;
    local string Names;
    if (!InVRSession() || MyKFPC == None || MyKFPC.GetPurchaseHelper() == None) return;
    Items = MyKFPC.GetPurchaseHelper().TraderItems;
    if (Items == None) return;
    for (I = 0; I < Items.SaleItems.Length; ++I)
    {
        // An out parameter cannot take a dynamic array element directly.
        Item = Items.SaleItems[I];
        if (IsOfferedInVR(Item)) continue;
        if (Hidden++ > 0) Names $= ",";
        Names $= string(Item.ClassName);
    }
    `log("KF2VR_TRADER hidden=" $ Hidden $ " of=" $ Items.SaleItems.Length $ " items=" $ Names);
}

defaultproperties
{
    SubWidgetBindings.Remove((WidgetName="shopContainer",WidgetClass=class'KFGFxTraderContainer_Store'))
    SubWidgetBindings.Add((WidgetName="shopContainer",WidgetClass=class'VRTraderStore'))
}
