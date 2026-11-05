// Stock weapon hits and the separate non-damaging loose-magazine reactions.
class VRWorldDropReactions extends Object dependsOn(VRMeleeTraits);

struct RecentVictim
{
    var KFPawn_Monster Pawn;
    var float Until;
};
var RecentVictim Recent[16];

// No firing/helper collision callback: explosive melee cartridges, weapon
// ammunition and animation state are unrelated to a free prop's stock hit.
static function bool DamageWeapon(VRWorldDropGun Prop, KFPawn_Monster Victim, name Zone,
    vector At, vector HitNormal, vector RelativeVelocity, int Region, vector TipAxis, vector EdgeAxis,
    vector EdgeTangent, quat ContactBodyQ)
{
    local KFWeapon W;
    local KFWeap_MeleeBase Melee;
    local KFMeleeHelperWeaponFrostShotgunAxe FrostHelper;
    local VRMeleeTraits.VRMeleeTrait Trait;
    local vector Direction, Axis;
    local class<DamageType> Kind;
    local int Mode, Damage;
    local bool bSharp, bHaveTrait, bSavedIced;
    if (Prop == None || Prop.NativeThrownSurfaceAllowed() == 0 || Victim == None || Victim.Health <= 0
        || Victim.bDeleteMe || Victim.GetHitZoneIndex(Zone) < 0) return false;
    W = Prop.OwnedWeapon; Melee = KFWeap_MeleeBase(W); Direction = Normal(RelativeVelocity);
    Mode = class'KFWeapon'.const.BASH_FIREMODE;
    // Hybrid guns inherit MeleeBase too, but their primary mode fires a
    // bullet/sawblade. Their real blade's stock contact lives in bash mode.
    if (Melee != None && W.WeaponFireTypes.Length > 0 && W.WeaponFireTypes[0] == EWFT_Custom) Mode = 0;
    bHaveTrait = class'VRMeleeTraits'.static.Find(W,Trait);
    if (Region > 0 && bHaveTrait)
    {
            Axis = Normal(QuatRotateVector(ContactBodyQ,TipAxis));
            if (Region == 2 && Trait.bPoint && VSizeSq(TipAxis) > 0.5)
            {
                bSharp = (Direction dot Axis) >= Cos(35.0 * Pi / 180.0)
                    && -(Axis dot HitNormal) >= Cos(55.0 * Pi / 180.0);
                if (bSharp && class'VRPhysicalMelee'.static.StabDamageAllowed(W)) Mode = class'KFWeapon'.const.BASH_FIREMODE;
            }
            else if (VSizeSq(EdgeAxis) > 0.5 && VSizeSq(EdgeTangent) > 0.5)
                bSharp = class'VRMeleeTraits'.static.EdgeAligned(Trait.MeleeClass,
                    QuatRotateVector(ContactBodyQ,EdgeAxis),QuatRotateVector(ContactBodyQ,EdgeTangent),RelativeVelocity,Trait.bDoubleEdge);
    }
    // A gun with blade zones but no melee trait (the compound bow): its stock
    // bash is the blade's, so a blade-zone contact keeps it.
    if (Region > 0 && !bHaveTrait && RigBladeZones(Prop)) bSharp = true;
    if (Mode >= W.InstantHitDamageTypes.Length || Mode >= W.InstantHitMomentum.Length) return false;
    Kind = W.InstantHitDamageTypes[Mode];
    // Blunt zones of a bladed weapon land as a butt or flat strike.
    if (!bSharp && ((bHaveTrait && (Trait.MeleeClass == class'VRMeleeTraits'.const.CLASS_BLADE
        || Trait.MeleeClass == class'VRMeleeTraits'.const.CLASS_AXE)) || RigBladeZones(Prop))) Kind = class'VRDT_MeleePommel';
    if (Kind == None) return false;
    FrostHelper = KFMeleeHelperWeaponFrostShotgunAxe(W.MeleeAttackHelper);
    if (FrostHelper != None)
    {
        bSavedIced = FrostHelper.bIcedEnemy;
        FrostHelper.bIcedEnemy = Victim.IsDoingSpecialMove(SM_Frozen);
    }
    Damage = W.GetMeleeDamage(Mode,Direction);
    if (FrostHelper != None) FrostHelper.bIcedEnemy = bSavedIced;
    if (Damage <= 0) return false;
    // Stock physics traces put the named zone here, not its parent bone.
    Victim.NotifyMeleeTakeHit(Prop.DropOwner.Controller,At);
    if (Victim.bDeleteMe || Victim.Health <= 0 || Prop.NativeThrownSurfaceAllowed() == 0) return false;
    Prop.NativeThrownDamage(Victim,Damage,At,Direction * W.InstantHitMomentum[Mode],
        Kind,Zone,At - Direction * 64.0);
    return bSharp && Prop.NativeThrownSurfaceAllowed() != 0 && !Victim.bDeleteMe;
}

// Whether the prop's rig has authored blade zones (VRWorldGunRigs.bSharpZones).
static function bool RigBladeZones(VRWorldDropGun Prop)
{
    local int R;
    R = Prop.GunRig();
    return R >= 0 && class'VRWorldGunRigs'.default.Rigs[R].bSharpZones;
}

// A thrown magazine or loose item makes the Zed flinch: stock afflictions and
// a hit reaction, never damage. Returns whether the Zed survives it.
static function bool Flinch(KFPawn_Monster Zed, vector Direction, Actor Causer)
{
    local byte SavedZone, SavedFxZone;
    local class<KFDamageType> ReactionKind;
    if (Zed == None || Zed.bDeleteMe || Zed.Health <= 0) return false;
    ReactionKind = KindFor(Zed);
    SavedZone = Zed.LastHitZoneIndex;
    SavedFxZone = Zed.HitFxInfo.HitBoneIndex;
    Zed.LastHitZoneIndex = 255;
    Zed.HitFxInfo.HitBoneIndex = 255;
    Zed.HandleAfflictionsOnHit(None, Direction, ReactionKind, Causer);
    if (Zed == None || Zed.bDeleteMe) return false;
    Zed.LastHitZoneIndex = SavedZone;
    Zed.HitFxInfo.HitBoneIndex = SavedFxZone;
    if (Zed.Health <= 0) return false;
    Zed.TryPlayHitReactionAnim(Direction, ReactionKind, 255);
    return true;
}

static function class<KFDamageType> KindFor(KFPawn_Monster Zed)
{
    return Zed.bLargeZed ? class'VRWorldDropImpact' : class'VRWorldDropSmallImpact';
}

function KFPawn_Monster Sweep(Actor Prop, vector From, vector To, float Speed)
{
    local KFPawn_Monster Zed;
    local vector At, HitNormal;
    local int I, Slot;
    local float Now;
    if (Prop == None || Prop.Role != ROLE_Authority || Speed < 220
        || VSizeSq(To - From) < 0.01 || VSizeSq(To - From) > 40000) return None;
    Now = Prop.WorldInfo.TimeSeconds;
    foreach Prop.TraceActors(class'KFPawn_Monster', Zed, At, HitNormal, To, From, vect(6,6,6))
    {
        if (Zed == None || Zed.Health <= 0 || Zed.bDeleteMe || !Prop.FastTrace(At, From)) continue;
        Slot = 0;
        for (I = 0; I < ArrayCount(Recent); ++I)
        {
            if (Recent[I].Pawn == Zed && Now < Recent[I].Until) return None;
            if (Recent[I].Until < Recent[Slot].Until) Slot = I;
        }
        Recent[Slot].Pawn = Zed;
        Recent[Slot].Until = Now + 1.25;
        // None deliberately avoids perk damage/affliction multipliers. The
        // stock manager retains Zed resistances and special-move cooldowns.
        // Without TakeDamage, stock afflictions otherwise read the previous
        // hit's limb. Use torso contact only for this synchronous call, then
        // restore the unrelated replicated/last-hit metadata immediately.
        return Flinch(Zed, Normal(To - From), Prop) ? Zed : None;
    }
    return None;
}
