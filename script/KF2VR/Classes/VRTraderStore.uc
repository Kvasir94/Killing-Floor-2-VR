// Stock store list with one extra rule: in a VR session, weapons without an
// authored VR profile are not offered. Item IDs stay indices in the complete
// catalog, so server purchases and desktop players are unaffected.
class VRTraderStore extends KFGFxTraderContainer_Store;

function bool IsItemFiltered(STraderItem Item, optional bool bDebug)
{
    local VRTraderMenu Menu;
    if (Super.IsItemFiltered(Item, bDebug)) return true;
    Menu = VRTraderMenu(MyTraderMenu);
    if (Menu != None && !Menu.ShowsInCurrentTab(Item)) return true;
    if (Menu == None || Menu.IsOfferedInVR(Item)) return false;
    if (bDebug) `log("Item has no VR profile");
    return true;
}
