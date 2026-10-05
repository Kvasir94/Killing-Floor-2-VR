// Authoritative shared desktop/VR projectile. Stock nail tracer is a placeholder.
class BreacherCascadeProjectile extends KFProj_Nail_HRGNailgun;

var array<KFPawn_Monster> HitEnemies;
var float InitialDamage, DamageGain, DamageCapScale;
var float InitialRadius, RadiusGain, RadiusCap;
var repnotify byte DistinctEnemies;
var vector GrowthOrigin;
var bool bHaveGrowthOrigin, bCascadeInitialized;

// One property keeps the final position and stop flag together on remote clients.
struct CascadeStopState
{
    var bool bStopped;
    var vector Position;
};
var repnotify CascadeStopState StopState;

replication
{
    if (bNetDirty) DistinctEnemies, StopState;
}

function Init(vector Direction)
{
    InitialDamage = Damage;
    Super.Init(Direction);
    bCascadeInitialized = true;
    ApplyWidth();
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'StopState' && StopState.bStopped)
    {
        // Presentation only: the authority already resolved damage/collision.
        Super.Shutdown();
        SetLocation(StopState.Position);
    }
    else if (VarName == 'DistinctEnemies') ApplyWidth();
    else Super.ReplicatedEvent(VarName);
}

simulated function Shutdown()
{
    if (Role == ROLE_Authority && !StopState.bStopped)
    {
        StopState.bStopped = true;
        StopState.Position = Location;
        bNetDirty = true;
    }
    Super.Shutdown();
}

simulated function ApplyWidth()
{
    local float Radius;
    if (bShuttingDown || bDeleteMe) return;
    Radius = FMin(RadiusCap, InitialRadius + RadiusGain * DistinctEnemies);
    if (Role == ROLE_Authority) SetCollisionSize(Radius, Radius);
    if (ProjEffects != None) ProjEffects.SetScale(Radius / InitialRadius);
}

simulated function ProcessTouch(Actor Other, vector HitLocation, vector HitNormal)
{
    local KFPawn_Monster Enemy;
    local TraceHitInfo HitInfo;
    if (Role != ROLE_Authority || !bCascadeInitialized || Other == None
        || Other == Instigator || bShuttingDown || bDeleteMe) return;
    Enemy = KFPawn_Monster(Other);
    if (Enemy != None)
    {
        if (Enemy.Health <= 0 || Enemy.bDeleteMe || HitEnemies.Find(Enemy) != INDEX_NONE
            || (Instigator != None && Enemy.GetTeamNum() == Instigator.GetTeamNum())) return;
        // Enlarging the cylinder cannot earn an enemy behind the previous impact.
        if (bHaveGrowthOrigin && ((HitLocation - GrowthOrigin) dot Normal(Velocity)) < 0) return;
        if (HitEnemies.Length >= 64) { Shutdown(); return; }
        // Commit the identity AND growth before damage callbacks can re-enter
        // contact handling for another pawn during death/ragdoll rebuilding.
        HitEnemies.AddItem(Enemy);
        Damage = FMin(InitialDamage * DamageCapScale,
            InitialDamage + DamageGain * DistinctEnemies);
        HitInfo.HitComponent = LastTouchComponent;
        ++DistinctEnemies;
        GrowthOrigin = HitLocation;
        bHaveGrowthOrigin = true;
        bNetDirty = true;
        // This cylinder-contact slice deliberately uses body damage, not a guessed head bone.
        Enemy.TakeDamage(int(Damage), InstigatorController, HitLocation,
            MomentumTransfer * Normal(Velocity), MyDamageType, HitInfo, self);
        ApplyWidth();
        return;
    }
    // Living allies and corpses do not amplify or take projectile damage.
    if (Pawn(Other) != None) return;
    // Nonblocking trigger volumes, water and foliage must not eat the shot.
    // Stop on blocking props/world; no ricochet and no wall penetration.
    if (Other.bBlockActors || Other.bWorldGeometry) Shutdown();
}

simulated event HitWall(vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    if (Role == ROLE_Authority) Super(KFProjectile).HitWall(HitNormal, Wall, WallComp);
}

defaultproperties
{
    bUseClientSideHitDetection=false
    bNoReplicationToInstigator=false
    bSwitchToZeroCollision=false
    bCanPin=false
    bCanStick=false
    bBounce=false
    BouncesLeft=0
    InitialRadius=1.0
    RadiusGain=0.5
    RadiusCap=4.0
    DamageGain=10.0
    DamageCapScale=3.0
    Speed=12000.0
    MaxSpeed=12000.0
    LifeSpan=1.0
}
