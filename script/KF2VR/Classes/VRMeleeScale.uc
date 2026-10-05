// Swing speed as a multiplier on the stock melee hit. Stock light/heavy modes
// still pick the attack, its damage type and stagger; this only smooths damage
// and knockback within a mode, so every weapon keeps its own numbers and perk
// modifiers apply on top as usual. The same helper runs the authoritative hit,
// so a server clamps whatever scale a client sends.
class VRMeleeScale extends Object;

const MIN_SCALE = 0.75;
const MAX_SCALE = 1.35;

// Linear from MinScale at Low to MaxScale at High, clamped at both ends.
static function float SwingScale(float Speed, float Low, float High, float MinScale, float MaxScale)
{
    local float Alpha;
    if (!(Speed == Speed)) return 1.0;
    Alpha = FClamp((Speed - Low) / FMax(High - Low, 1.0), 0, 1);
    return FClamp(MinScale + (MaxScale - MinScale) * Alpha, MIN_SCALE, MAX_SCALE);
}

// Runs the stock ProcessMeleeHit with this mode's damage and momentum scaled,
// then restores them, so nothing outside the one hit ever sees the change.
static function ProcessScaledHit(KFWeapon W, byte Mode, ImpactInfo Impact, float Scale, optional bool bShieldContact)
{
    local float SavedDamage, SavedMomentum;
    local bool bDamage, bMomentum, bBoneCrusher;
    local class<DamageType> SavedType;
    local KFWeap_Blunt_MaceAndShield BoneCrusher;
    if (W == None || W.MeleeAttackHelper == None) return;
    BoneCrusher = KFWeap_Blunt_MaceAndShield(W);
    bBoneCrusher = BoneCrusher != None && Mode < W.InstantHitDamageTypes.Length
        && (Mode == 0 || Mode == class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE);
    if (bBoneCrusher)
    {
        SavedType = W.InstantHitDamageTypes[Mode];
        if (Mode == 0) W.InstantHitDamageTypes[Mode] = bShieldContact ? BoneCrusher.ShieldLightDamageType : BoneCrusher.MaceLightDamageType;
        else W.InstantHitDamageTypes[Mode] = bShieldContact ? BoneCrusher.ShieldHeavyDamageType : BoneCrusher.MaceHeavyDamageType;
    }
    if (!(Scale == Scale) || Scale <= 0) Scale = 1.0;
    Scale = FClamp(Scale, MIN_SCALE, MAX_SCALE);
    bDamage = Mode < W.InstantHitDamage.Length;
    bMomentum = Mode < W.InstantHitMomentum.Length;
    if (bDamage) { SavedDamage = W.InstantHitDamage[Mode]; W.InstantHitDamage[Mode] = SavedDamage * Scale; }
    if (bMomentum) { SavedMomentum = W.InstantHitMomentum[Mode]; W.InstantHitMomentum[Mode] = SavedMomentum * Scale; }
    W.MeleeAttackHelper.ProcessMeleeHit(Mode, Impact);
    if (bBoneCrusher) W.InstantHitDamageTypes[Mode] = SavedType;
    if (bDamage) W.InstantHitDamage[Mode] = SavedDamage;
    if (bMomentum) W.InstantHitMomentum[Mode] = SavedMomentum;
}
