// A RAVEN-7 cut is the Ion Thruster's electric strike layered with an
// ordinary bladed slice: the skin type's FXG_Slashing_Ion hit sound and the
// Static Strikers' electric impact, plus the FXG_Slashing slice and blood.
class VRDT_Tomahawk extends KFDT_Slashing;

static function PlayImpactHitEffects(KFPawn P, vector HitLocation, vector HitDirection, byte HitZoneIndex, optional Pawn HitInstigator)
{
    local KFSkinTypeEffects SkinType;
    local AkEvent Slice;
    Super.PlayImpactHitEffects(P, HitLocation, HitDirection, HitZoneIndex, HitInstigator);
    if (P.CharacterArch == None) return;
    SkinType = P.GetHitZoneSkinTypeEffects(HitZoneIndex);
    if (SkinType == None) return;
    SkinType.PlayImpactParticleEffect(P, HitLocation, HitDirection, HitZoneIndex, FXG_Slashing);
    // PlayTakeHitSound admits one sound per hit interval; the slice is the
    // second layer of this same hit, so it bypasses that gate.
    if (!P.ActorEffectIsRelevant(HitInstigator, false, 4000)) return;
    Slice = SkinType.GetImpactSound(FXG_Slashing, HitInstigator, P);
    if (Slice != None) P.PlaySoundBase(Slice, true,,, HitLocation);
}

defaultproperties
{
    StumblePower=35
    KnockdownPower=20
    EffectGroup=FXG_Slashing_Ion
    OverrideImpactEffect=ParticleSystem'WEP_Static_Strikers_EMIT.FX_Static_Strikers_Impact'
    WeaponDef=class'VRWeapDef_Tomahawk'
    ModifierPerkList(0)=class'KFPerk_Berserker'
}
