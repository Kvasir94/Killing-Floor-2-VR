// Opt-in one-gun diagnostic. Keep KF2's existing client-hit pipeline intact.
// This class changes pose sourcing, never duplicates or replaces stock damage.
class KF2VRNet9mm extends KFWeap_Pistol_9mm;

var private int DiagnosticShots;
var private int DiagnosticStartCalls;
var private int DiagnosticAimCalls;
var private int DiagnosticPhysicalCalls;
var private int DiagnosticImpactReceipts;
var private vector DiagnosticLastStart;
var private rotator DiagnosticLastAim;
var private float NextDiagnosticShotLog;
var private float NextDiagnosticImpactLog;

// Read by the owning diagnostic controller after stock input fires. This does
// not depend on FireAmmunition state dispatch reaching our global wrapper.
simulated function GetDiagnosticPoseCounters(out int StartCalls, out int AimCalls)
{
    local KF2VRNetPlayerController PC;
    if (Instigator != None) PC = KF2VRNetPlayerController(Instigator.Controller);
    if (PC != None && PC.NativeNetworkReady == 1)
    {
        StartCalls = PC.NativeTraceCalls;
        AimCalls = PC.NativeAimCalls;
        return;
    }
    StartCalls = DiagnosticStartCalls;
    AimCalls = DiagnosticAimCalls;
}

simulated function bool GetInputWeaponPose(out vector Position, out rotator Aim)
{
    local KF2VRNetPlayerController PC;
    if (Instigator == None || Instigator.Health <= 0
        || Instigator.Weapon != self || CurrentFireMode != DEFAULT_FIREMODE)
    {
        return false;
    }
    PC = KF2VRNetPlayerController(Instigator.Controller);
    if (PC == None)
    {
        return false;
    }
    if (Instigator.IsLocallyControlled())
    {
        // No server-pose fallback here: local actions never wait on pose echo.
        return PC.GetCurrentLocalWeaponPose(Position, Aim);
    }
    if (Role == ROLE_Authority && PC.NetChannel != None)
    {
        return PC.NetChannel.GetAcceptedWeaponPose(Position, Aim);
    }
    return false;
}

simulated protected function vector GetSafeStartTraceLocation()
{
    local vector StockStart, PoseStart, HitLocation, HitNormal;
    local rotator PoseAim;
    StockStart = Super.GetSafeStartTraceLocation();
    if (!GetInputWeaponPose(PoseStart, PoseAim))
    {
        return StockStart;
    }
    // Near-wall obstruction is resolved immediately on the firing client.
    // Retain stock trace origin as the inner point; don't shoot through walls
    // simply because the cosmetic hand extends past one.
    if (Trace(HitLocation, HitNormal, PoseStart, StockStart, false) != None)
    {
        PoseStart = HitLocation + HitNormal * 2.0;
    }
    ++DiagnosticStartCalls;
    DiagnosticLastStart = PoseStart;
    return PoseStart;
}

simulated function rotator GetAdjustedAim(vector StartFireLoc)
{
    local vector PoseStart;
    local rotator PoseAim;
    if (!GetInputWeaponPose(PoseStart, PoseAim))
    {
        return Super.GetAdjustedAim(StartFireLoc);
    }
    ++DiagnosticAimCalls;
    // Local source includes KFPlayerController.WeaponBufferRotation once.
    // KFWeapon.AddSpread preserves upgrades, stance and perk modifiers.
    DiagnosticLastAim = AddSpread(PoseAim);
    return DiagnosticLastAim;
}

simulated event vector GetPhysicalFireStartLoc(optional vector AimDir)
{
    local vector PoseStart;
    local rotator PoseAim;
    if (!GetInputWeaponPose(PoseStart, PoseAim))
    {
        return Super.GetPhysicalFireStartLoc(AimDir);
    }
    ++DiagnosticPhysicalCalls;
    // Same local muzzle used by stock Zed Time's client-hit bullet projectile.
    return GetSafeStartTraceLocation();
}

simulated function FireAmmunition()
{
    local int AmmoBefore;
    AmmoBefore = AmmoCount[0];
    Super.FireAmmunition();
    ++DiagnosticShots;
    if (DiagnosticShots <= 3 || WorldInfo.RealTimeSeconds >= NextDiagnosticShotLog)
    {
        NextDiagnosticShotLog = WorldInfo.RealTimeSeconds + 1.0;
        `log("KF2VRNet shot weapon=" $ self $ " shots=" $ DiagnosticShots
            $ " mode=" $ CurrentFireMode $ " local=" $ (Instigator != None && Instigator.IsLocallyControlled())
            $ " start_calls=" $ DiagnosticStartCalls $ " aim_calls=" $ DiagnosticAimCalls
            $ " physical_calls=" $ DiagnosticPhysicalCalls
            $ " ammo_before=" $ AmmoBefore $ " ammo_after=" $ AmmoCount[0]
            $ " origin=" $ DiagnosticLastStart $ " aim=" $ DiagnosticLastAim
            $ " netmode=" $ WorldInfo.NetMode);
    }
}

simulated function ProcessInstantHitEx(byte FiringMode, ImpactInfo Impact,
    optional int NumHits, optional out float out_PenetrationVal, optional int ImpactNum)
{
    Super.ProcessInstantHitEx(FiringMode, Impact, NumHits, out_PenetrationVal, ImpactNum);
    if (WorldInfo.NetMode == NM_Client && KF2VRNetDiagnosticClot(Impact.HitActor) != None)
        `log("KF2VRNet local_hit target=" $ KF2VRNetDiagnosticClot(Impact.HitActor).DiagnosticId
            $ " actor=" $ Impact.HitActor $ " weapon=" $ self
            $ " mode=" $ FiringMode $ " netmode=" $ WorldInfo.NetMode);
}

event RecieveClientImpact(byte FiringMode, const out ImpactInfo Impact,
    optional out float PenetrationValue, optional int ImpactNum)
{
    local string TargetId;
    // Instrument the real stock receive path once. No extra damage application.
    TargetId = string(Impact.HitActor);
    if (KF2VRNetDiagnosticClot(Impact.HitActor) != None)
        TargetId = KF2VRNetDiagnosticClot(Impact.HitActor).DiagnosticId;
    Super.RecieveClientImpact(FiringMode, Impact, PenetrationValue, ImpactNum);
    ++DiagnosticImpactReceipts;
    if (DiagnosticImpactReceipts <= 8 || WorldInfo.RealTimeSeconds >= NextDiagnosticImpactLog)
    {
        NextDiagnosticImpactLog = WorldInfo.RealTimeSeconds + 1.0;
        `log("KF2VRNet impact weapon=" $ self $ " receipts=" $ DiagnosticImpactReceipts
            $ " mode=" $ FiringMode $ " target=" $ TargetId $ " actor=" $ Impact.HitActor
            $ " impact=" $ ImpactNum $ " location=" $ Impact.HitLocation
            $ " netmode=" $ WorldInfo.NetMode);
    }
}
