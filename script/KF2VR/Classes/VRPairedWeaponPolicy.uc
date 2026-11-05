// Paired actors keep their stock single weapon's perk identity. Exact class
// names in stock perk exceptions must not see the inventory wrapper instead.
class VRPairedWeaponPolicy extends Object;

static function class<KFWeapon> StockClass(class<KFWeapon> WeaponClass)
{
    local int I;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (WeaponClass == class'VRWeaponPair'.default.Families[I].MemberClass)
            return class'VRWeaponPair'.default.Families[I].SingleClass;
    return WeaponClass;
}

static function name CapacityClassName(class<KFWeapon> WeaponClass)
{
    WeaponClass = StockClass(WeaponClass);
    return WeaponClass != None ? WeaponClass.Name : '';
}

// Stock's pickup query compares exact classes. A private member is neither
// the stock single nor its aggregate dual, so that check otherwise admits a
// third weapon while both physical members are still owned. Refuse only the
// extra weapon acquisition; ammo boxes and recoverable projectiles retain
// their normal shared-reserve paths, and a lone stock single has no pair.
static function bool DenyExtraFamilyWeapon(VRWeaponPair Pair, KFWeapon Member,
    class<Inventory> ItemClass, Actor Pickup)
{
    local class<KFWeapon> Single;
    if (Pair == None || !Pair.IsMember(Member) || Pickup == None || Pickup.IsA('Projectile')) return false;
    Single = StockClass(Member.Class);
    return Single != None && (ItemClass == Single || ItemClass == Single.default.DualClass);
}

// Stock's additional on-perk name lists include the 9mm and 93R for
// Gunslinger/Sharpshooter, despite those guns having no AssociatedPerkClass.
// Resolve that eligibility with stock's own predicate and canonical identity.
static function class<KFPerk> PerkClassFor(class<KFWeapon> WeaponClass, class<KFPerk> PerkClass)
{
    local array<class<KFPerk> > WeaponPerks;
    WeaponClass = StockClass(WeaponClass);
    if (WeaponClass == None) return None;
    WeaponPerks = WeaponClass.static.GetAssociatedPerkClasses();
    if (PerkClass != None && (WeaponClass.static.AllowedForAllPerks()
        || PerkClass.static.IsWeaponOnPerk(None, WeaponPerks,
            PerkClass, WeaponClass.Name))) return PerkClass;
    return WeaponClass.static.GetWeaponPerkClass(PerkClass);
}

// Same upgrade and perk calculation as KFWeapon, with only its class-name
// argument canonicalized. In particular, Support's Buckshot exemption stays
// active without disabling capacity perks on other paired weapon families.
static function ModifyMagazine(KFWeapon W, out int Capacity, int FireMode,
    int UpgradeIndex, KFPerk CurrentPerk)
{
    local array<class<KFPerk> > WeaponPerks;
    if (W == None || FireMode == class'KFWeapon'.const.BASH_FIREMODE) return;
    Capacity = W.GetUpgradedMagCapacity(FireMode, UpgradeIndex);
    if (CurrentPerk == None) CurrentPerk = W.GetPerk();
    if (CurrentPerk != None)
    {
        WeaponPerks = W.static.GetAssociatedPerkClasses();
        CurrentPerk.ModifyMagSizeAndNumber(W, Capacity, WeaponPerks,
            FireMode == class'KFWeapon'.const.ALTFIRE_FIREMODE, CapacityClassName(W.Class));
    }
}
