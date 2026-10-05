// One-time, local demo grants. The definitions are the installed perks'
// stock primary starters, followed by the user's selected weapon batches.
// The dual-wield bridge owns paired-gun conversion.
class VRStarterLoadout extends Object;

var array<class<KFWeaponDefinition> > Definitions;
var int NextDefinition;
var bool bFailed;

simulated function bool EnsureInventory(KFPawn_Human Human)
{
    local KFInventoryManager Manager;
    local class<KFWeapon> WeaponClass;
    local Inventory Item;
    local KFWeapon W;
    local int PreviousLimit;
    if (bFailed || Human == None) return false;
    if (NextDefinition >= Definitions.Length) return true;
    Manager = KFInventoryManager(Human.InvManager);
    if (Manager == None) return false;
    WeaponClass = class<KFWeapon>(DynamicLoadObject(Definitions[NextDefinition].default.WeaponClassPath, class'Class'));
    if (WeaponClass == None) { bFailed = true; return false; }
    // Polls never refill an existing item or create another copy.
    for (Item = Manager.InventoryChain; Item != None; Item = Item.Inventory)
    {
        if (Item.Class == WeaponClass) { ++NextDefinition; return false; }
    }
    PreviousLimit = Manager.MaxCarryBlocks;
    Manager.MaxCarryBlocks = Max(PreviousLimit,
        Manager.CurrentCarryBlocks + WeaponClass.static.GetDefaultModifiedWeightValue(0));
    W = KFWeapon(Manager.CreateInventory(WeaponClass, true));
    if (W == None)
    {
        Manager.MaxCarryBlocks = PreviousLimit;
        bFailed = true;
        `log("KF2VR_DEMO phase=starter-failed weapon=" $ WeaponClass);
        return false;
    }
    W.bGivenAtStart = true;
    `log("KF2VR_DEMO phase=starter-granted weapon=" $ W.Class @ "ammo=" $ W.AmmoCount[0]
        @ "spare=" $ W.SpareAmmoCount[0] @ "demoCarryLimit=" $ Manager.MaxCarryBlocks);
    ++NextDefinition;
    return false;
}

defaultproperties
{
    Definitions(0)=class'KFWeapDef_AR15'
    Definitions(1)=class'KFWeapDef_HX25'
    Definitions(2)=class'KFWeapDef_MedicPistol'
    Definitions(3)=class'KFWeapDef_CaulkBurn'
    Definitions(4)=class'KFWeapDef_Winchester1894'
    Definitions(5)=class'KFWeapDef_MP7'
    Definitions(6)=class'KFWeapDef_Crovel'
    Definitions(7)=class'KFWeapDef_Remington1858Dual'
    Definitions(8)=class'KFWeapDef_Deagle'
    Definitions(9)=class'KFWeapDef_M79'
    Definitions(10)=class'KFWeapDef_RPG7'
    Definitions(11)=class'KFWeapDef_DragonsBreath'
    Definitions(12)=class'KFWeapDef_SCAR'
    Definitions(13)=class'KFWeapDef_Ak12'
    Definitions(14)=class'KFWeapDef_SW500'
    Definitions(15)=class'KFWeapDef_Flamethrower'
    Definitions(16)=class'KFWeapDef_M14EBR'
    Definitions(17)=class'KFWeapDef_Pulverizer'
}
