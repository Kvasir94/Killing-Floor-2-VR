// Local camera for the independent spectator; does not affect collision or damage.
class VRMeleeObserverCamera extends CameraActor;
var KF2VRNetDiagnosticClot Target;
simulated function GetCameraView(float DeltaTime, out TPOV OutPOV)
{
    local vector Focus, Desired, HitLocation, HitNormal;
    local Actor Obstacle;
    if (Target == None) { Super.GetCameraView(DeltaTime, OutPOV); return; }
    Focus = Target.Location + vect(0,0,35);
    Desired = Focus + (vect(180,170,65) >> Target.Rotation);
    Obstacle = Trace(HitLocation, HitNormal, Desired, Focus, true, vect(8,8,8));
    if (Obstacle != None) Desired = HitLocation + HitNormal * 12;
    OutPOV.Location = Desired;
    OutPOV.Rotation = Rotator(Focus - Desired);
    OutPOV.FOV = 75;
}
defaultproperties
{
    bStatic=false
    bNoDelete=false
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    Physics=PHYS_None
    bAlwaysTick=true
    bConstrainAspectRatio=false
}
