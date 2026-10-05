class VREngineerLaserDot extends Actor;

var StaticMeshComponent Dot;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    Dot.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VREngineer.WranglerDot", class'StaticMesh', true)));
    Dot.SetMaterial(0, MaterialInterface(DynamicLoadObject("KF2VREngineer.Mat_a2a912eb3833fbe6", class'MaterialInterface', true)));
}

simulated function Place(KFPlayerController PC, vector Point, vector Normal)
{
    local vector CameraLocation;
    local rotator CameraRotation;
    if (PC == None) { SetHidden(true); return; }
    PC.GetPlayerViewPoint(CameraLocation, CameraRotation);
    SetLocation(Point + Normal * 0.25);
    SetRotation(rotator(CameraLocation - Location));
    SetDrawScale(15.24);
    SetHidden(false);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    Begin Object Class=StaticMeshComponent Name=OriginalDot
        CollideActors=false
        BlockActors=false
        CastShadow=false
        bCastDynamicShadow=false
        DepthPriorityGroup=SDPG_World
    End Object
    Dot=OriginalDot
    Components.Add(OriginalDot)
}
