class VREngineerRocket extends Projectile;

var StaticMeshComponent RocketMesh;
var bool bExploded;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    RocketMesh.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VREngineer.SentryRocket", class'StaticMesh', true)));
    RocketMesh.SetMaterial(0, MaterialInterface(DynamicLoadObject("KF2VREngineer.Mat_7dc8b1aaae023b86", class'MaterialInterface', true)));
}

simulated function ProcessTouch(Actor Other, vector HitLocation, vector HitNormal)
{
    if (Other == Owner || Other == Instigator || VREngineerPreview(Other) != None) return;
    Explode(HitLocation, HitNormal);
}

simulated event HitWall(vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    Explode(Location, HitNormal);
}

simulated function Explode(vector HitLocation, vector HitNormal)
{
    local Pawn Victim;
    local float Distance, Amount;
    local vector Center;
    if (bExploded) return;
    bExploded = true;
    Center = HitLocation + HitNormal * 3;
    if (Role == ROLE_Authority && Instigator != None)
    {
        foreach WorldInfo.AllPawns(class'Pawn', Victim)
        {
            if (Victim.Health <= 0 || (KFPawn_Monster(Victim) == None && Victim != Instigator)) continue;
            Distance = FMax(0, VSize(Victim.Location - Center) - Victim.CylinderComponent.CollisionRadius);
            if (Distance > 370.84 || !FastTrace(Victim.Location, Center)) continue;
            Amount = 100 * (1 - 0.5 * FClamp(Distance / 370.84, 0, 1));
            Victim.TakeDamage(int(Amount), Instigator.Controller, Center,
                Normal(Victim.Location - Center) * 400, class'VREngineerRocketDamage',, self);
        }
    }
    class'VREngineerPresentation'.static.PlayCue(self, 'sentry_explode');
    Destroy();
}

defaultproperties
{
    RemoteRole=ROLE_None
    Physics=PHYS_Projectile
    Speed=2794
    MaxSpeed=2794
    LifeSpan=10
    Damage=100
    DamageRadius=370.84
    bCollideActors=true
    bCollideWorld=true
    Begin Object Class=StaticMeshComponent Name=OriginalRocket
        CollideActors=false
        BlockActors=false
        CastShadow=true
        DepthPriorityGroup=SDPG_World
    End Object
    RocketMesh=OriginalRocket
    Components.Add(OriginalRocket)
}
