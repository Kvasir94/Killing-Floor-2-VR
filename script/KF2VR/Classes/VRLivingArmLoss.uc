// Experimental: arms come off living Zeds (#210). Rules shared by the
// authority (VRArmLossMutator, answering the stock checks the native adapter
// routes to it) and every client. Stock decides when an arm zone's gore
// health is spent and asks KFPawn.CanInjureHitZone; the answer may now be yes
// for an arm on a living Zed, after which stock HitZoneInjured sets and
// replicates the InjuredHitZones bit. Stock replication only plays the head
// on a living Zed, so each client plays new arm bits through the stock
// PlayDismemberment (gore manager, gore mesh, partial kinematics for the
// stump) when the stock injury notification arrives. Bosses keep their arms;
// no legs.
class VRLivingArmLoss extends Object abstract;

const SIDE_LEFT = 1;
const SIDE_RIGHT = 2;

// A hand on a small Zed's arm tears it off with a fast pull away from the
// body once the palm is well past where it took hold (Kvasir94, 2026-11-06).
struct ArmYank
{
    var KFPawn_Monster Pawn;
    var name Bone;
    var int Zone;
    var float Base;
    var vector LastPalm;
    var float LastTime;
};
var float YankStretch;   // UU past the grab distance from the chest
var float YankSpeed;     // UU/s of palm speed away from the chest

static function bool IsBoss(KFPawn_Monster M)
{
    return KFInterface_MonsterBoss(M) != None || M.IsA('KFPawn_ZedHansBase');
}

static simulated function bool Living(KFPawn_Monster M)
{
    return M != None && !M.bDeleteMe && !M.bTearOff && !M.bPlayedDeath && M.Health > 0;
}

static simulated function int Side(KFPawn_Monster M, int Zone)
{
    if (Zone < 0 || Zone >= M.HitZones.Length || Zone >= 32) return 0;
    if (M.HitZones[Zone].Limb == BP_LeftArm) return SIDE_LEFT;
    if (M.HitZones[Zone].Limb == BP_RightArm) return SIDE_RIGHT;
    return 0;
}

// Arms already gone, as a mask of SIDE_LEFT / SIDE_RIGHT.
static simulated function int LostSides(KFPawn_Monster M)
{
    local int I, Mask;
    if (M == None || M.InjuredHitZones == 0) return 0;
    for (I = 0; I < M.HitZones.Length && I < 32; ++I)
        if ((M.InjuredHitZones & (1 << I)) != 0) Mask = Mask | Side(M, I);
    return Mask;
}

// Stock asks this once a zone's gore health is spent: may this living Zed's
// arm zone come off to this damage type? One tear per arm.
static function bool ArmInjuryAllowed(KFPawn_Monster M, class<DamageType> DamageType, int Zone)
{
    local class<KFDamageType> DT;
    local int S;
    DT = class<KFDamageType>(DamageType);
    S = Side(M, Zone);
    return M != None && DT != None && S != 0 && Living(M) && !IsBoss(M)
        && (LostSides(M) & S) == 0 && DT.static.CanDismemberHitZone(M.HitZones[Zone].ZoneName);
}

// Small Zeds whose arms may be torn off by hand (Kvasir94, 2026-11-06).
static function bool HandTearable(KFPawn_Monster M)
{
    return M != None && !IsBoss(M) && !M.IsLargeZed()
        && (M.IsA('KFPawn_ZedClot') || M.IsA('KFPawn_ZedCrawler') || M.IsA('KFPawn_ZedStalker'));
}

// Authority only: a hand pull on a held small Zed's arm. Zone is any zone of
// that arm; the forearm comes off through the stock injury.
static function bool ServerTearByHand(KFPawn_Monster M, int Zone)
{
    local int I, S;
    if (M == None || M.Role != ROLE_Authority || !Living(M) || !HandTearable(M)) return false;
    S = Side(M, Zone);
    if (S == 0 || (LostSides(M) & S) != 0) return false;
    for (I = 0; I < M.HitZones.Length && I < 32; ++I)
        if (Side(M, I) == S && (M.HitZones[I].ZoneName == 'lforearm' || M.HitZones[I].ZoneName == 'rforearm'))
        {
            M.HitZones[I].GoreHealth = 0;
            M.HitZoneInjured(I);
            `log("KF2VR_ARMLOSS action=torn pawn=" $ M.Class $ " zone=" $ M.HitZones[I].ZoneName);
            return true;
        }
    return false;
}

// Non-dedicated only: play the arms stock injured on a living Zed. Called
// after the stock injury notification (VRHandsBridge.NativeArmLossInjured),
// which also fires when a Zed with a lost arm first replicates to a client.
static simulated function PlayInjuredArms(KFPawn_Monster M)
{
    local class<KFDamageType> DT;
    local int I;
    if (M == None || M.WorldInfo.NetMode == NM_DedicatedServer || M.InjuredHitZones == 0 || !Living(M) || M.Mesh == None) return;
    for (I = 0; I < M.HitZones.Length && I < 32; ++I)
    {
        if ((M.InjuredHitZones & (1 << I)) == 0 || M.HitZones[I].bPlayedInjury || Side(M, I) == 0) continue;
        DT = M.HitFxInfo.DamageType;
        if (DT == None || !DT.static.CanDismemberHitZone(M.HitZones[I].ZoneName)) DT = class'KFDT_Slashing';
        if (M.PlayDismemberment(I, DT, vect(0,0,0)))
            `log("KF2VR_ARMLOSS action=played pawn=" $ M.Class $ " zone=" $ M.HitZones[I].ZoneName);
    }
}

static function vector ChestPoint(KFPawn_Monster M)
{
    local int I;
    for (I = 0; I < M.HitZones.Length; ++I)
        if (M.HitZones[I].ZoneName == 'chest' && M.HitZones[I].BoneName != '')
            return M.Mesh.GetBoneLocation(M.HitZones[I].BoneName);
    return M.Location;
}

// The arm zone a held bone belongs to, or -1.
static function int ArmZoneFor(KFPawn_Monster M, name Bone)
{
    local int I, Best;
    Best = -1;
    if (M == None || M.Mesh == None || Bone == '') return -1;
    for (I = 0; I < M.HitZones.Length && I < 32; ++I)
    {
        if (Side(M, I) == 0 || M.HitZones[I].BoneName == '') continue;
        if (M.HitZones[I].BoneName == Bone) return I;
        if (Best < 0 && M.Mesh.BoneIsChildOf(Bone, M.HitZones[I].BoneName)) Best = I;
    }
    return Best;
}

// Authority only, once per hand frame while that hand holds M by Bone.
// Returns the arm zone to tear, or -1.
static function int YankStep(out ArmYank S, KFPawn_Monster M, name Bone, vector Palm, float Now)
{
    local vector Anchor, Away;
    local float Dist, Dt, Speed;
    if (M == None || !Living(M) || !HandTearable(M)) { S.Pawn = None; return -1; }
    Anchor = ChestPoint(M);
    Dist = VSize(Palm - Anchor);
    if (S.Pawn != M || S.Bone != Bone)
    {
        S.Pawn = M; S.Bone = Bone; S.Zone = ArmZoneFor(M, Bone);
        S.Base = Dist; S.LastPalm = Palm; S.LastTime = Now;
        return -1;
    }
    Dt = Now - S.LastTime;
    Away = Palm - S.LastPalm;
    S.LastPalm = Palm; S.LastTime = Now;
    if (S.Zone < 0 || Dt <= 0 || Dt > 0.25 || (LostSides(M) & Side(M, S.Zone)) != 0) return -1;
    Speed = (Away dot Normal(Palm - Anchor)) / Dt;
    if (Dist - S.Base < default.YankStretch || Speed < default.YankSpeed) return -1;
    S.Pawn = None;
    return S.Zone;
}

defaultproperties
{
    YankStretch=25.0
    YankSpeed=350.0
}
