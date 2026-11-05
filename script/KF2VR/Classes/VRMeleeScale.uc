// Swing speed as a multiplier on the stock melee hit. Stock light/heavy modes
// still pick the attack, its damage type and stagger; this only smooths damage
// and knockback within a mode, so every weapon keeps its own numbers and perk
// modifiers apply on top as usual. The same helper runs the authoritative hit,
// so a server clamps whatever scale a client sends.
class VRMeleeScale extends Object;

// 0.35 lets a flat blade hit (curve floor x0.75 times flat x0.5) through; a
// client can only lower its own damage with it.
const MIN_SCALE = 0.35;
const MAX_SCALE = 1.5;

// A gun with a blade on part of it (the compound bow's spike and limb blades,
// the Mosin's bayonet) keeps its stock bash type for the blade. Any other part
// of it strikes with a rifle-butt bludgeon at the stock rifle-butt damage.
// Which part struck is decided by the caller (the rig-frame surface catalog,
// VRWorldGunRigs.SharpAt); this table is only the damage for a blunt strike,
// shared by held bashes and thrown guns.
struct BluntPart
{
    var name Weapon;
    var class<DamageType> DamageType;
    var float Damage;
    // Blades off the held bash's bore line, swept as extra contact points.
    var array<name> ContactBones;
};
var array<BluntPart> BluntParts;

// Linear from MinScale at Low to MaxScale at High, clamped at both ends.
static function float SwingScale(float Speed, float Low, float High, float MinScale, float MaxScale)
{
    local float Alpha;
    if (!(Speed == Speed)) return 1.0;
    Alpha = FClamp((Speed - Low) / FMax(High - Low, 1.0), 0, 1);
    return FClamp(MinScale + (MaxScale - MinScale) * Alpha, MIN_SCALE, MAX_SCALE);
}

// Item 9: during Zed Time melee blows keep their weight (B&S
// addForceSlowMoMultiplier 1.2-1.5). Momentum only; damage is unchanged.
static function float ZedTimeWeight(KFWeapon W)
{
    local byte MeleeClass;
    if (W == None || W.WorldInfo == None || !(W.WorldInfo.TimeDilation < 1.0)) return 1.0;
    MeleeClass = class'VRMeleeTraits'.static.ClassOf(W);
    if (MeleeClass == class'VRMeleeTraits'.const.CLASS_NONE) return 1.0;
    return MeleeClass == class'VRMeleeTraits'.const.CLASS_BLUNT ? 1.3 : 1.15;
}

// Runs the stock ProcessMeleeHit with this mode's damage and momentum scaled,
// then restores them, so nothing outside the one hit ever sees the change.
// Item 5: the twin of a stock blade damage type that cannot dismember
// (VRDTX_<stock name>), or None when the type has no twin.
static function class<DamageType> NoDismemberTwin(class<DamageType> Stock)
{
    if (Stock == None || Left(string(Stock.Name), 13) != "KFDT_Slashing") return None;
    return class<DamageType>(DynamicLoadObject("KF2VR.VRDTX_" $ string(Stock.Name), class'Class', true));
}

// The blunt-part entry for a gun with a blade on part of it, or -1 when the
// whole gun strikes with its stock bash.
static function int BluntPartIndex(class<Inventory> ItemClass)
{
    local int I;
    if (ItemClass == None) return -1;
    for (I = 0; I < default.BluntParts.Length; ++I)
        if (ClassIsChildOf(ItemClass, class'KFWeapon') && ItemClass.Name == default.BluntParts[I].Weapon) return I;
    return -1;
}

static function ContactBones(class<Inventory> ItemClass, out array<name> Bones)
{
    local int I;
    Bones.Length = 0;
    I = BluntPartIndex(ItemClass);
    if (I >= 0) Bones = default.BluntParts[I].ContactBones;
}

static function bool HasBluntParts(class<Inventory> ItemClass)
{
    return BluntPartIndex(ItemClass) >= 0;
}

// Swaps Mode's damage type and damage for the gun's blunt part. Returns false,
// changing nothing, for a gun without one. Pair every true with RestoreBlunt.
static function bool ApplyBlunt(KFWeapon W, byte Mode, out class<DamageType> SavedType, out float SavedDamage)
{
    local int I;
    if (W == None || Mode >= W.InstantHitDamageTypes.Length || Mode >= W.InstantHitDamage.Length) return false;
    I = BluntPartIndex(W.Class);
    if (I < 0) return false;
    SavedType = W.InstantHitDamageTypes[Mode];
    SavedDamage = W.InstantHitDamage[Mode];
    W.InstantHitDamageTypes[Mode] = default.BluntParts[I].DamageType;
    W.InstantHitDamage[Mode] = default.BluntParts[I].Damage;
    return true;
}

static function RestoreBlunt(KFWeapon W, byte Mode, class<DamageType> SavedType, float SavedDamage)
{
    if (W == None || Mode >= W.InstantHitDamageTypes.Length || Mode >= W.InstantHitDamage.Length) return;
    W.InstantHitDamageTypes[Mode] = SavedType;
    W.InstantHitDamage[Mode] = SavedDamage;
}

// bBluntContact (a gun with a blade on part of it, struck with another part)
// can only lower the hit: a gun without a blunt-part entry ignores it.
static function ProcessScaledHit(KFWeapon W, byte Mode, ImpactInfo Impact, float Scale, optional bool bShieldContact,
    optional bool bNoDismember, optional bool bExperimentalInteractions, optional bool bBluntContact)
{
    local float SavedDamage, SavedMomentum, SavedBluntDamage;
    local class<DamageType> SavedBluntType;
    local bool bDamage, bMomentum, bBoneCrusher, bBlunt;
    local class<DamageType> SavedType, SavedBladeType, Twin;
    local bool bTwin;
    local KFWeap_Blunt_MaceAndShield BoneCrusher;
    if (W == None || W.MeleeAttackHelper == None) return;
    bBlunt = bBluntContact && Mode == class'KFWeapon'.const.BASH_FIREMODE
        && ApplyBlunt(W, Mode, SavedBluntType, SavedBluntDamage);
    BoneCrusher = KFWeap_Blunt_MaceAndShield(W);
    bBoneCrusher = BoneCrusher != None && Mode < W.InstantHitDamageTypes.Length
        && (Mode == 0 || Mode == class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE);
    if (bBoneCrusher)
    {
        SavedType = W.InstantHitDamageTypes[Mode];
        if (Mode == 0) W.InstantHitDamageTypes[Mode] = bShieldContact ? BoneCrusher.ShieldLightDamageType : BoneCrusher.MaceLightDamageType;
        else W.InstantHitDamageTypes[Mode] = bShieldContact ? BoneCrusher.ShieldHeavyDamageType : BoneCrusher.MaceHeavyDamageType;
    }
    // A slow or flat blade hit keeps its stock damage, afflictions and perk
    // modifiers but cannot take a limb: swap in the twin for this one hit.
    if (bNoDismember && !bBoneCrusher && Mode < W.InstantHitDamageTypes.Length)
    {
        Twin = NoDismemberTwin(W.InstantHitDamageTypes[Mode]);
        if (Twin != None)
        {
            SavedBladeType = W.InstantHitDamageTypes[Mode];
            W.InstantHitDamageTypes[Mode] = Twin;
            bTwin = true;
        }
    }
    if (!(Scale == Scale) || Scale <= 0) Scale = 1.0;
    Scale = FClamp(Scale, MIN_SCALE, MAX_SCALE);
    bDamage = Mode < W.InstantHitDamage.Length;
    bMomentum = Mode < W.InstantHitMomentum.Length;
    if (bDamage) { SavedDamage = W.InstantHitDamage[Mode]; W.InstantHitDamage[Mode] = SavedDamage * Scale; }
    if (bMomentum) { SavedMomentum = W.InstantHitMomentum[Mode]; W.InstantHitMomentum[Mode] = SavedMomentum * Scale
        * (bExperimentalInteractions ? ZedTimeWeight(W) : 1.0); }
    W.MeleeAttackHelper.ProcessMeleeHit(Mode, Impact);
    if (bBoneCrusher) W.InstantHitDamageTypes[Mode] = SavedType;
    if (bTwin) W.InstantHitDamageTypes[Mode] = SavedBladeType;
    if (bDamage) W.InstantHitDamage[Mode] = SavedDamage;
    if (bMomentum) W.InstantHitMomentum[Mode] = SavedMomentum;
    if (bBlunt) RestoreBlunt(W, Mode, SavedBluntType, SavedBluntDamage);
}

defaultproperties
{
    // Rifle-butt damage of the nearest stock sibling: the crossbow's 26 for
    // the bow, the M99's 30 for the Mosin.
    BluntParts(0)=(Weapon=KFWeap_Bow_CompoundBow,DamageType=class'VRDT_CompoundBowBash',Damage=26,ContactBones=(RW_TopBase,RW_BottomBase))
    BluntParts(1)=(Weapon=KFWeap_Rifle_MosinNagant,DamageType=class'VRDT_MosinNagantBash',Damage=30)
}
