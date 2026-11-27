// Experimental living wounds: gore that stock only shows on corpses, played on
// a Zed that is still alive. First wound: the gut wound, stock's own belly
// shrink chunk (Gore_Abdomen) with whatever the Zed's archetype hangs from it.
//
// Everything visual is stock: KFPawn_Monster.SwitchToGoreMesh and
// KFGoreManager.ConditionalApplyPartialGore on the Zed's own gore joint data.
// A wound is cosmetic. It never sets a stock InjuredHitZones bit, so stock's
// "injured Zeds die on knockdown" rule and the grab checks are untouched.
//
// The authority decides (VRArmLossMutator, behind the same switch as arm loss)
// and tells every machine through a VRZedWound actor.
class VRLivingWounds extends Object abstract dependson(KFDamageType);

// Belly gore damage, as a share of the Zed's full health, that opens the gut.
var float GutHealthFraction;

static function bool Living(KFPawn_Monster M)
{
    return M != None && !M.bDeleteMe && !M.bTearOff && !M.bPlayedDeath && M.Health > 0;
}

// The gore joint whose first shrink entry holds the belly chunk, from the
// Zed's own archetype. '' when this Zed has none (it then never gets the wound).
static simulated function name GutJoint(KFPawn_Monster M)
{
    local KFCharacterInfo_Monster Info;
    local int I, K;
    Info = M != None ? M.GetCharacterMonsterInfo() : None;
    if (Info == None) return '';
    for (I = 0; I < Info.GoreJointSettings.Length; ++I)
    {
        if (Info.GoreJointSettings[I] == None || Info.GoreJointSettings[I].BoneShrinkGore.Length == 0) continue;
        for (K = 0; K < Info.GoreJointSettings[I].BoneShrinkGore[0].PartialBreakBones.Length; ++K)
            if (Info.GoreJointSettings[I].BoneShrinkGore[0].PartialBreakBones[K].BoneName == 'Gore_Abdomen')
                return Info.GoreJointSettings[I].HitBoneName;
    }
    return '';
}

static function bool GutEligible(KFPawn_Monster M)
{
    return Living(M) && !class'VRLivingArmLoss'.static.IsBoss(M) && !M.bCanCloak
        && !M.bDisableGoreMeshWhileAlive && !M.bUseDamageInflation && GutJoint(M) != '';
}

static function bool GutDamageGroup(class<KFDamageType> DT)
{
    if (DT == None) return false;
    switch (DT.default.GoreDamageGroup)
    {
        case DGT_AssaultRifle: case DGT_Rifle: case DGT_Submachinegun: case DGT_Shotgun:
        case DGT_Handgun: case DGT_Explosive: case DGT_MeleeSlash: case DGT_Obliteration:
            return true;
    }
    return false;
}

// Gore damage stock has booked against the belly zones so far.
static function float BellyGoreDamage(KFPawn_Monster M)
{
    local int I;
    local float Sum;
    for (I = 0; I < M.HitZones.Length && I < M.default.HitZones.Length; ++I)
        if (M.HitZones[I].ZoneName == 'stomach' || M.HitZones[I].ZoneName == 'abdomen')
            Sum += FMax(0, M.default.HitZones[I].GoreHealth - M.HitZones[I].GoreHealth);
    return Sum;
}

// Authority, after stock has applied a hit: does this living Zed's belly open?
static function bool ServerCheckGut(KFPawn_Monster M)
{
    local int Zone;
    local name ZoneName;
    local float Dealt, Need;
    if (!GutEligible(M) || class'VRZedWound'.static.Has(M, class'VRZedWound'.const.WOUND_GUT)) return false;
    Zone = M.HitFxInfo.HitBoneIndex;
    if (Zone < 0 || Zone >= M.HitZones.Length) return false;
    ZoneName = M.HitZones[Zone].ZoneName;
    if ((ZoneName != 'stomach' && ZoneName != 'abdomen') || !GutDamageGroup(M.HitFxInfo.DamageType)) return false;
    Dealt = BellyGoreDamage(M);
    Need = default.GutHealthFraction * M.HealthMax;
    if (Dealt < Need) return false;
    `log("KF2VR_WOUND action=opened wound=gut pawn=" $ M.Class.Name $ " belly=" $ int(Dealt) $ " need=" $ int(Need));
    return class'VRZedWound'.static.ServerAdd(M, class'VRZedWound'.const.WOUND_GUT);
}

// Every machine that draws: open the belly with stock gore. True once shown.
static simulated function bool PlayGut(KFPawn_Monster M)
{
    local KFGoreManager Gore;
    local name Joint;
    if (M == None || M.Mesh == None || M.WorldInfo.NetMode == NM_DedicatedServer) return false;
    Gore = KFGoreManager(M.WorldInfo.MyGoreEffectManager);
    Joint = GutJoint(M);
    if (Gore == None || !Gore.AllowMutilation() || Joint == '' || M.bDisableGoreMeshWhileAlive) return false;
    if (!M.bIsGoreMesh) M.SwitchToGoreMesh();
    if (!M.bIsGoreMesh) return false;
    if (M.Mesh.IsBrokenConstraint('Gore_Abdomen')) return true;
    Gore.ConditionalApplyPartialGore(M, None, M.Mesh.GetBoneLocation('Gore_Abdomen'), vect(0,0,0), Joint, true);
    `log("KF2VR_WOUND action=played wound=gut pawn=" $ M.Class.Name $ " shown=" $ M.Mesh.IsBrokenConstraint('Gore_Abdomen'));
    return M.Mesh.IsBrokenConstraint('Gore_Abdomen');
}

defaultproperties
{
    GutHealthFraction=0.25
}
