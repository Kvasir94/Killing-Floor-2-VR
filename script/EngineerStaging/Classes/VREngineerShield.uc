// Original TF2 shield geometry and material. Its separate particle accents
// remain part of the Source particle-conversion parity gate.
class VREngineerShield extends Actor;

var SkeletalMeshComponent ShieldMesh;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    ShieldMesh.SetSkeletalMesh(SkeletalMesh(DynamicLoadObject("KF2VREngineer.SentryShield", class'SkeletalMesh', true)));
}

simulated function Follow(VREngineerSentry Sentry)
{
    SetLocation(Sentry.Location - vect(0,0,83.82));
    SetRotation(Sentry.Rotation);
    SetHidden(!Sentry.ShieldActive());
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    Begin Object Class=SkeletalMeshComponent Name=OriginalShield
        CollideActors=false
        BlockActors=false
        CastShadow=false
        bCastDynamicShadow=false
        DepthPriorityGroup=SDPG_World
    End Object
    ShieldMesh=OriginalShield
    Components.Add(OriginalShield)
}
