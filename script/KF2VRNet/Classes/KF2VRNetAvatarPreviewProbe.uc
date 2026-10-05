// A componentless late observer: the mesh owner must tick before its mesh,
// while bone telemetry must run after that mesh has evaluated this frame.
class KF2VRNetAvatarPreviewProbe extends Actor;

var KF2VRNetAvatarPreview Preview;

simulated event Tick(float DeltaTime)
{
    if (Preview == None || Preview.bDeleteMe)
    {
        Destroy();
        return;
    }
    Preview.PostUpdatePreview(DeltaTime);
}

simulated event Destroyed()
{
    Preview = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bStatic=false
    bNoDelete=false
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    bReplicateMovement=false
    Physics=PHYS_None
    TickGroup=TG_PostUpdateWork
}
