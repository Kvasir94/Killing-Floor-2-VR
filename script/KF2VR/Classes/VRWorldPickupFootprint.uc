// Read-only resource footprint for tracked pickup admission. Transfer preflight
// still owns permission, capacity, duplicate legality and every paid round.
class VRWorldPickupFootprint extends Object;

static simulated function class<KFWeapon> SingleFamily(class<KFWeapon> WeaponClass)
{
    local class<KFWeap_DualBase> DualClass;
    WeaponClass = class'VRWeaponDropState'.static.FamilyFor(WeaponClass);
    DualClass = class<KFWeap_DualBase>(WeaponClass);
    if (DualClass != None) return DualClass.default.SingleClass;
    return WeaponClass;
}

static simulated function class<KFWeapon> IncomingClass(Actor Target)
{
    local VRWorldDropGun Prop;
    local KFDroppedPickup Drop;
    local KFPickupFactory_Item Factory;
    local VRWeaponPair Pair;
    if (Target == None || Target.bDeleteMe) return None;
    Prop = VRWorldDropGun(Target);
    if (Prop != None)
    {
        if (Prop.OwnedWeapon == None || Prop.OwnedWeapon.bDeleteMe)
        {
            // Foreign inventory actors need not be relevant to this client yet.
            // Authority always resolves the exact live actor before transferring.
            if (Prop.Role < ROLE_Authority) return SingleFamily(class<KFWeapon>(Prop.InventoryClass));
            return None;
        }
        Pair = class'VRWeaponPair'.static.ForMember(Prop.OwnedWeapon);
        if (Pair != None && Pair.StockItem != None) return Pair.StockItem.SingleClass;
        // The family catalog also works before an owner's pair has replicated.
        return SingleFamily(Prop.OwnedWeapon.Class);
    }
    Drop = KFDroppedPickup(Target);
    if (Drop != None) return class<KFWeapon>(Drop.InventoryClass);
    Factory = KFPickupFactory_Item(Target);
    if (Factory != None && Factory.PickupIndex < Factory.ItemPickups.Length)
        return class<KFWeapon>(Factory.ItemPickups[Factory.PickupIndex].ItemClass);
    return None;
}

static simulated function bool TouchesWeapon(Actor Target, KFWeapon Existing)
{
    local class<KFWeapon> Incoming, Family;
    local VRWorldDropGun Prop;
    Incoming = IncomingClass(Target);
    if (Incoming == None || Existing == None || Existing.bDeleteMe) return true;
    Prop = VRWorldDropGun(Target);
    if (Prop != None && Prop.OwnedWeapon == Existing) return true;
    Family = SingleFamily(Existing.Class);
    Incoming = SingleFamily(Incoming);
    if (Incoming == None || Family == None) return true;
    return Incoming == Family || Incoming.default.DualClass == Existing.Class
        || Family.default.DualClass == Incoming
        || (Incoming.default.DualClass != None && Incoming.default.DualClass == Family.default.DualClass)
        || (class'VRWorldDropTransfer'.static.SecondaryPistol(Incoming)
            && class'VRWorldDropTransfer'.static.SecondaryPistol(Family));
}
