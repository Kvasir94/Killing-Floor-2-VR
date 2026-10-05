// A recoverable amount belongs to the debris actor, not to a timer or owner.
// Partial collection leaves the remainder, including when a player is full.
class VREngineerScrap extends Actor;

var int MetalRemaining;
var StaticMeshComponent ScrapMesh;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    ScrapMesh.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VREngineer.SentryScrap", class'StaticMesh', true)));
    ScrapMesh.SetMaterial(0, MaterialInterface(DynamicLoadObject("KF2VREngineer.Mat_29d6b9e21a6780b8", class'MaterialInterface', true)));
}

function Collect(VREngineerState Collector)
{
    local int Added;
    if (Role != ROLE_Authority || bDeleteMe || Collector == None || !Collector.IsOwnerAlive() || MetalRemaining <= 0) return;
    Added = Collector.AddMetal(MetalRemaining);
    MetalRemaining -= Added;
    if (MetalRemaining <= 0) Destroy();
}

event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    local VREngineerState StateOwner;
    if (KFPawn_Human(Other) == None) return;
    foreach WorldInfo.AllActors(class'VREngineerState', StateOwner)
        if (StateOwner.Builder == Other) { Collect(StateOwner); return; }
}

defaultproperties
{
    RemoteRole=ROLE_None
    MetalRemaining=65
    LifeSpan=30
    bCollideActors=true
    bBlockActors=false
    Begin Object Class=CylinderComponent Name=ScrapCylinder
        CollisionRadius=45
        CollisionHeight=45
        CollideActors=true
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
    End Object
    CollisionComponent=ScrapCylinder
    Components.Add(ScrapCylinder)
    Begin Object Class=StaticMeshComponent Name=OriginalDebris
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        CastShadow=true
        DepthPriorityGroup=SDPG_World
    End Object
    ScrapMesh=OriginalDebris
    Components.Add(OriginalDebris)
}
