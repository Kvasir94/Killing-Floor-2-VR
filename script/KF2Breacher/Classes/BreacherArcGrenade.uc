// Native grenade-slot fallback to the same pin graph. No explosive damage or
// fuse detonation; missed pins expire. Wrist placement is the primary VR input.
class BreacherArcGrenade extends KFProj_EMPGrenade;

var bool bCommitted;
var bool bRetired, bCleanupStarted;

// KFProj_Grenade.Destroyed invokes TriggerExplosion unless already terminal.
// Mark that state before Destroy so the nonexplosive override cannot recurse.
simulated function RetirePin()
{
    if (bRetired || bCleanupStarted) return;
    bRetired=true;
    bHasExploded=true;
    ClearTimer(nameof(ExplodeTimer));
    if (!bDeleteMe && !bPendingDelete) Destroy();
}

function ExplodeTimer() { RetirePin(); }

simulated function TriggerExplosion(vector HitLocation, vector HitNormal, Actor HitActor)
{
    if (Role==ROLE_Authority) RetirePin();
}

function CommitPin(Actor Target, PrimitiveComponent Component, vector Point, vector SurfaceNormal)
{
    local BreacherArcFence Tool;
    if (Role!=ROLE_Authority || bCommitted || bRetired || bCleanupStarted || Target==Instigator) return;
    bCommitted=true;
    foreach DynamicActors(class'BreacherArcFence',Tool)
    {
        if (Instigator!=None && Tool.Owner==Instigator.Controller)
        { Tool.AcceptProjectile(self,Target,Component,Point,SurfaceNormal); break; }
    }
    RetirePin();
}

// Also covers lifespan, failed-spawn and external cancellation destruction
// which can bypass RetirePin. Preserve stock emitter/audio cleanup once.
simulated function Destroyed()
{
    if (bCleanupStarted) return;
    bCleanupStarted=true;
    bRetired=true;
    bHasExploded=true;
    ClearTimer(nameof(ExplodeTimer));
    Super.Destroyed();
}

simulated event HitWall(vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    if (Role==ROLE_Authority) CommitPin(Wall,WallComp,Location,HitNormal);
}

simulated function ProcessTouch(Actor Other, vector HitLocation, vector HitNormal)
{
    if (Other==Instigator || Other==None || Other.IsA('KFProjectile')) return;
    if (Role==ROLE_Authority) CommitPin(Other,LastTouchComponent,HitLocation,HitNormal);
}

defaultproperties
{
    Begin Object Name=ExploTemplate0
        Damage=0
        DamageRadius=0
    End Object
    AssociatedPerkClass=class'BreacherPerk'
    Damage=0
    DamageRadius=0
    FuseTime=8
    LifeSpan=9
}
