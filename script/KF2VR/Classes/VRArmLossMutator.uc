// Experimental arm loss (#210): the authority's answers to the stock checks
// the native adapter routes here (ArmLossDispatch.cpp). Added on the
// authority by VRBootstrap (Solo) and KF2VRNetGame (online). Every answer
// defaults to stock: the adapter only changes a stock result when one of
// these returns 0 or 1 as documented. With the switch off nothing changes,
// except that arms already lost stay unusable. The same switch gates the
// living wounds (VRLivingWounds), which this mutator decides on the authority.
class VRArmLossMutator extends KFMutator;

// Dedicated server switch (KF2VRNetGame.bLivingArmLoss / VRArmLoss=1).
// Solo and a listen host use the host player's own headset switch, live.
var bool bServerSwitch;
var VRHandsBridge HostBridge;
var float NextHostBridgeCheck;
var VRAttackSampler Sampler;
// Living wounds (VRLivingWounds): Zeds hit this frame, checked next tick once
// stock has booked the hit against their zones.
var array<KFPawn_Monster> WoundChecks;

static function VRArmLossMutator Find(WorldInfo W)
{
    return W != None ? FindIn(W.Game) : None;
}

static function VRArmLossMutator FindIn(GameInfo G)
{
    local Mutator M;
    if (G == None) return None;
    for (M = G.BaseMutator; M != None; M = M.NextMutator)
        if (VRArmLossMutator(M) != None) return VRArmLossMutator(M);
    return None;
}

static function Install(GameInfo G, bool bDedicatedSwitch)
{
    local VRArmLossMutator M;
    if (G == None) return;
    M = FindIn(G);
    if (M == None) { G.AddMutator("KF2VR.VRArmLossMutator", false); M = FindIn(G); }
    if (M != None) M.bServerSwitch = bDedicatedSwitch;
}

function bool Enabled()
{
    local VRHandsBridge B;
    if (WorldInfo.NetMode == NM_DedicatedServer) return bServerSwitch;
    if (HostBridge == None || HostBridge.bDeleteMe)
    {
        HostBridge = None;
        if (WorldInfo.RealTimeSeconds < NextHostBridgeCheck) return false;
        NextHostBridgeCheck = WorldInfo.RealTimeSeconds + 1.0;
        foreach WorldInfo.AllActors(class'VRHandsBridge', B)
            if (B.PC != None && B.PC.IsLocalPlayerController()) { HostBridge = B; break; }
        if (HostBridge == None) return false;
    }
    return HostBridge.LivingArmLossEnabled();
}

function VRAttackSampler Samples()
{
    if (Sampler == None || Sampler.bDeleteMe) Sampler = class'VRAttackSampler'.static.Get(WorldInfo);
    return Sampler;
}

// Stock damage pass (GameInfo.ReduceDamage), before the hit is applied. Only
// notes the Zed; nothing about the damage changes.
function NetDamage(int OriginalDamage, out int Damage, Pawn Injured, Controller InstigatedBy, vector HitLocation,
    out vector Momentum, class<DamageType> DamageType, Actor DamageCauser)
{
    local KFPawn_Monster Zed;
    Zed = KFPawn_Monster(Injured);
    if (Zed != None && Damage > 0 && WoundChecks.Length < 64 && WoundChecks.Find(Zed) == INDEX_NONE && Enabled())
        WoundChecks.AddItem(Zed);
    Super.NetDamage(OriginalDamage, Damage, Injured, InstigatedBy, HitLocation, Momentum, DamageType, DamageCauser);
}

event Tick(float DeltaTime)
{
    local int I;
    Super.Tick(DeltaTime);
    if (WoundChecks.Length == 0) return;
    for (I = 0; I < WoundChecks.Length; ++I)
        if (WoundChecks[I] != None) class'VRLivingWounds'.static.ServerCheckGut(WoundChecks[I]);
    WoundChecks.Length = 0;
}

// KFPawn.CanInjureHitZone, asked by stock TakeHitZoneDamage once a zone's gore
// health is spent. 1: injure this arm. 0: leave stock's answer.
function int NativeCanInjureArm(KFPawn_Monster Zed, class<DamageType> DamageType, int HitZoneIdx)
{
    if (!Enabled() || !class'VRLivingArmLoss'.static.ArmInjuryAllowed(Zed, DamageType, HitZoneIdx)) return 0;
    `log("KF2VR_ARMLOSS action=injured pawn=" $ Zed.Class $ " zone=" $ Zed.HitZones[HitZoneIdx].ZoneName $ " dt=" $ DamageType);
    return 1;
}

// KFPawnAnimInfo.CanDoAttackAnim. 0: this attack needs only arms the Zed has
// lost (every clip of it), so stock never starts it. 1: leave stock.
function int NativeAttackAllowed(KFPawn_Monster Zed, int Idx)
{
    local int Lost, V;
    local KFPawnAnimInfo Info;
    Lost = class'VRLivingArmLoss'.static.LostSides(Zed);
    Info = Zed != None ? Zed.PawnAnimInfo : None;
    if (Lost == 0 || Info == None || Idx < 0 || Idx >= Info.Attacks.Length || Info.Attacks[Idx].Anims.Length == 0) return 1;
    for (V = 0; V < Info.Attacks[Idx].Anims.Length; ++V)
        if ((Samples().SidesOfClip(Zed, Info.Attacks[Idx].Anims[V]) & ~Lost) != 0) return 1;
    return 0;
}

// KFPawn_Monster.MeleeImpactNotify, the stock moment a melee blow lands.
// 0: this impact is struck by an arm the Zed has lost; no blow. 1: stock.
function int NativeImpactAllowed(KFPawn_Monster Zed, AnimNotify Notify)
{
    local int Lost;
    Lost = class'VRLivingArmLoss'.static.LostSides(Zed);
    if (Lost == 0 || Notify == None) return 1;
    if ((Samples().SidesOfNotify(Zed, Notify) & ~Lost) != 0) return 1;
    `log("KF2VR_ARMLOSS action=blow_blocked pawn=" $ Zed.Class $ " lost=" $ Lost);
    return 0;
}

// KFAIController_ZedHusk.CanDoFireball / CanDoFlamethrower. 0: the Husk's gun
// arm (its right) is gone. 1: stock.
function int NativeHuskGunAllowed(KFPawn_Monster Zed)
{
    return (class'VRLivingArmLoss'.static.LostSides(Zed) & class'VRLivingArmLoss'.const.SIDE_RIGHT) != 0 ? 0 : 1;
}

defaultproperties
{
}
