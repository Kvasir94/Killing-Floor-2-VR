// Swing speed as a multiplier on the stock melee hit. Stock light/heavy modes
// still pick the attack, its damage type and stagger; this only smooths damage
// and knockback within a mode, so every weapon keeps its own numbers and perk
// modifiers apply on top as usual. The same helper runs the authoritative hit,
// so a server clamps whatever scale a client sends.
class VRMeleeScale extends Object;

// 0.35 is the slowest part hit (melee spec M21); a client can only lower its
// own damage with it.
const MIN_SCALE = 0.35;
// Melee spec M30: speed never raises a hit above its stock number, for melee
// weapons and gun bashes alike; the authority clamps to this too.
const MAX_SCALE = 1.0;

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
// Ruling A (Kvasir94 2026-11-09, #227): the part of a melee weapon that struck
// picks the damage type. PART_BLUDGEON (a flat side, a blade's spine, a
// shaft, hilt or guard) and PART_PIERCE (an axe's back pick) replace the
// mode's type for this one hit; the amount stays the mode's (the stock bash).
const PART_NONE = 0;
const PART_BLUDGEON = 1;
const PART_PIERCE = 2;
// The weapon's own stock slashing type (the Crovel's light attack) at the
// swing's own amount: its shovel edge slices on any swing.
const PART_STOCK_SLASH = 3;
// Melee spec M19: a blunt weapon's broad face or back is a striking surface.
// The swing's own mode and amount, as that weapon's bludgeon (the Crovel's
// flat lands its heavy attack's type; its light attack is the edge's slash).
const PART_STOCK_BLUNT = 5;
// Melee spec M22: a tip-first thrust. The stock stab's type and reactions at
// the swing's own mode and amount.
const PART_STOCK_STAB = 6;
// Melee spec M21: the stock rifle-butt bash, the base of a blunt part hit on a
// weapon whose own bash is another attack (a stab, a shield slam, a blade).
const BUTT_DAMAGE = 25.0;

static function class<DamageType> PartDamageType(byte Part)
{
    if (Part == PART_BLUDGEON) return class'VRDT_MeleePommel';
    if (Part == PART_PIERCE) return class'VRDT_MeleePierce';
    return None;
}

// The type a part swaps in for one hit, or None to leave the mode's own.
static function class<DamageType> PartSwapType(KFWeapon W, byte Mode, byte Part)
{
    local byte Heavy;
    if (Part == PART_STOCK_SLASH) return W.InstantHitDamageTypes[0];
    if (Part == PART_STOCK_STAB)
    {
        if (class'KFWeapon'.const.BASH_FIREMODE < W.InstantHitDamageTypes.Length)
            return W.InstantHitDamageTypes[class'KFWeapon'.const.BASH_FIREMODE];
        return None;
    }
    if (Part == PART_STOCK_BLUNT)
    {
        Heavy = class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE;
        if (class<KFDT_Bludgeon>(W.InstantHitDamageTypes[Mode]) == None && Heavy < W.InstantHitDamageTypes.Length
            && class<KFDT_Bludgeon>(W.InstantHitDamageTypes[Heavy]) != None) return W.InstantHitDamageTypes[Heavy];
        return None;
    }
    return PartDamageType(Part);
}

// Melee spec M21: what a part hit (PART_BLUDGEON, PART_PIERCE) is scaled from.
// The weapon's stock bash where that bash is a blunt strike with the weapon
// itself, or its stab for a leading point; otherwise the rifle-butt bash.
static function float PartBaseDamage(KFWeapon W, byte Part)
{
    local byte Bash;
    local class<DamageType> BashType;
    Bash = class'KFWeapon'.const.BASH_FIREMODE;
    if (W == None || Bash >= W.InstantHitDamage.Length || Bash >= W.InstantHitDamageTypes.Length) return BUTT_DAMAGE;
    BashType = W.InstantHitDamageTypes[Bash];
    // Section 7: the folded Scythe's stock bash is a strike with the snath
    // (40); unfolded it is a stab with the blade, so the rifle-butt base.
    if (Part == PART_BLUDGEON && KFWeap_Edged_Scythe(W) != None)
        return KFWeap_Edged_Scythe(W).bIsFolded ? W.InstantHitDamage[Bash] : BUTT_DAMAGE;
    if (Part == PART_PIERCE && class<KFDT_Piercing>(BashType) != None) return W.InstantHitDamage[Bash];
    if (class<KFDT_Bludgeon>(BashType) != None && KFWeap_Blunt_MaceAndShield(W) == None
        && KFWeap_Pistol_Bladed(W) == None) return W.InstantHitDamage[Bash];
    return BUTT_DAMAGE;
}

static function ProcessScaledHit(KFWeapon W, byte Mode, ImpactInfo Impact, float Scale, optional bool bShieldContact,
    optional bool bNoDismember, optional bool bExperimentalInteractions, optional bool bBluntContact, optional byte Part)
{
    local class<DamageType> SavedPartType;
    local bool bPart;
    local float SavedDamage, SavedMomentum, SavedBluntDamage;
    local class<DamageType> SavedBluntType;
    local bool bDamage, bMomentum, bBoneCrusher, bBlunt;
    local class<DamageType> SavedType, SavedBladeType, Twin;
    local bool bTwin;
    local KFWeap_Blunt_MaceAndShield BoneCrusher;
    local byte SavedFireMode;
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
    if (Part != PART_NONE && Mode < W.InstantHitDamageTypes.Length && !bBlunt && !bBoneCrusher
        && PartSwapType(W, Mode, Part) != None)
    {
        SavedPartType = W.InstantHitDamageTypes[Mode];
        W.InstantHitDamageTypes[Mode] = PartSwapType(W, Mode, Part);
        bPart = true;
    }
    if (!(Scale == Scale) || Scale <= 0) Scale = 1.0;
    Scale = FClamp(Scale, MIN_SCALE, MAX_SCALE);
    bDamage = Mode < W.InstantHitDamage.Length;
    bMomentum = Mode < W.InstantHitMomentum.Length;
    if (bDamage)
    {
        SavedDamage = W.InstantHitDamage[Mode];
        if (bPart && (Part == PART_BLUDGEON || Part == PART_PIERCE)) W.InstantHitDamage[Mode] = PartBaseDamage(W, Part) * Scale;
        else W.InstantHitDamage[Mode] = SavedDamage * Scale;
    }
    if (bMomentum) { SavedMomentum = W.InstantHitMomentum[Mode]; W.InstantHitMomentum[Mode] = SavedMomentum * Scale
        * (bExperimentalInteractions ? ZedTimeWeight(W) : 1.0); }
    // Stock NotifyMeleeCollision reads the attack's own fire mode (the Ion
    // Thruster's charge per hit); a VR stroke never enters a stock attack
    // state, so stand in this hit's mode for the call, as the Pulverizer does.
    SavedFireMode = W.CurrentFireMode;
    W.CurrentFireMode = Mode;
    W.MeleeAttackHelper.ProcessMeleeHit(Mode, Impact);
    W.CurrentFireMode = SavedFireMode;
    // Undo the type swaps in the reverse order they were made.
    if (bPart) W.InstantHitDamageTypes[Mode] = SavedPartType;
    if (bTwin) W.InstantHitDamageTypes[Mode] = SavedBladeType;
    if (bBoneCrusher) W.InstantHitDamageTypes[Mode] = SavedType;
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
