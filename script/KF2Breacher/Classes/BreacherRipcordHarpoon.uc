// A single authority-owned hook flight. No crossbow stick helpers, pickups or
// client-side impact replay: the persistent line owns every recovery path.
class BreacherRipcordHarpoon extends KFProj_Bullet;

var BreacherRipcord Launcher;
var BreacherTether Line;
var bool bResolved;

simulated function ProcessTouch(Actor Other, vector HitLocation, vector HitNormal)
{
    local KFPawn_Monster Enemy;
    local array<ImpactInfo> Contacts;
    local vector Direction;
    if (Role!=ROLE_Authority || bResolved || Other==None || Other==Instigator
        || Line==None || Line.bDeleteMe || Line.Phase!=class'BreacherTether'.const.PHASE_FLYING) return;
    Enemy=KFPawn_Monster(Other);
    if (Enemy!=None)
    {
        if (Enemy.bDeleteMe || Enemy.Health<=0 || Instigator==None
            || Enemy.GetTeamNum()==Instigator.GetTeamNum()) return;
        Direction=Normal(Velocity);
        if (!TraceProjHitZones(Enemy,HitLocation+Direction*(Enemy.CylinderComponent.CollisionRadius*6.0),
            HitLocation,Contacts) || Contacts.Length==0) return;
        bResolved=true;
        Enemy.TakeDamage(int(Damage),InstigatorController,Contacts[0].HitLocation,
            MomentumTransfer*Direction,MyDamageType,Contacts[0].HitInfo,self);
        if (Line==None || !Line.Bite(Enemy))
        {
            if (Line!=None) Line.Finish();
        }
        // The line now follows the accepted target, or retracts from this
        // terminal flight point. The flight actor must not linger in world.
        Destroy();
        return;
    }
    if (Pawn(Other)!=None || (!Other.bBlockActors && !Other.bWorldGeometry)) return;
    bResolved=true;
    SetLocation(HitLocation);
    if (Line!=None) Line.Finish();
    Destroy();
}

simulated event HitWall(vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    if (Role!=ROLE_Authority || bResolved) return;
    bResolved=true;
    if (Line!=None) Line.Finish();
    Destroy();
}

simulated event Destroyed()
{
    if (Role==ROLE_Authority && Line!=None && Line.Phase==class'BreacherTether'.const.PHASE_FLYING)
        Line.Finish();
    Super.Destroyed();
}

defaultproperties
{
    Damage=120
    MyDamageType=class'BreacherRipcordDamage'
    Speed=15000
    MaxSpeed=15000
    LifeSpan=1.5
    bUseClientSideHitDetection=false
    bNoReplicationToInstigator=false
    bCanStick=false
    bCanPin=false
    bBounce=false
    ProjFlightTemplate=None
    ProjFlightTemplateZedTime=None
    ImpactEffects=KFImpactEffectInfo'FX_Impacts_ARCH.Crossbow_impact'
}
