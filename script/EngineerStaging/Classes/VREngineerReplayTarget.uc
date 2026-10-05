// Real KF2 damage routing, with receipts before stock resistances. Stationary
// ballistic target only; the separate zed-attack phase uses a stock AI zed.
class VREngineerReplayTarget extends KFPawn_ZedClot_Cyst;

var int BulletHits, RocketHits, RawBulletDamage;
var float LastBulletTime, MinimumBulletInterval;
var float LastRocketTime, MinimumRocketInterval;

// Pawn.TakeDamage calls this hook to promote PHYS_None to falling. This
// stationary fixture retains its valid spawn position while damage stays real.
function SetMovementPhysics()
{
    SetPhysics(PHYS_None);
}

event TakeDamage(int DamageAmount, Controller EventInstigator, vector HitLocation,
    vector Momentum, class<DamageType> DamageType, optional TraceHitInfo HitInfo, optional Actor DamageCauser)
{
    if (VREngineerSentry(DamageCauser) != None && DamageType == class'VREngineerBulletDamage')
    {
        if (BulletHits > 0) MinimumBulletInterval = FMin(MinimumBulletInterval, WorldInfo.TimeSeconds - LastBulletTime);
        LastBulletTime = WorldInfo.TimeSeconds;
        ++BulletHits; RawBulletDamage += DamageAmount;
    }
    if (VREngineerRocket(DamageCauser) != None && DamageType == class'VREngineerRocketDamage')
    {
        if (LastRocketTime > 0) MinimumRocketInterval = FMin(MinimumRocketInterval, WorldInfo.TimeSeconds - LastRocketTime);
        LastRocketTime = WorldInfo.TimeSeconds;
        ++RocketHits;
    }
    Super.TakeDamage(DamageAmount, EventInstigator, HitLocation, Momentum, DamageType, HitInfo, DamageCauser);
}

defaultproperties
{
    ControllerClass=None
    Health=10000
    HealthMax=10000
    GroundSpeed=0
    SprintSpeed=0
    MinimumBulletInterval=1000
    MinimumRocketInterval=1000
}
