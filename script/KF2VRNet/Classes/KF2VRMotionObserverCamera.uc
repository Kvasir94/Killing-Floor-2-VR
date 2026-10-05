// Desktop camera for a separate observer of the real replicated player.
class KF2VRMotionObserverCamera extends KF2VRNetAvatarCamera;
simulated function GetCameraView(float DeltaTime, out TPOV OutPOV)
{
    local vector X, Y, Z, Move;
    if (InspectController == None || InspectController.MotionCameraMode != 2 || InspectController.PlayerInput == None)
    { Super.GetCameraView(DeltaTime, OutPOV); return; }
    OutPOV.Rotation = InspectController.Rotation;
    GetAxes(OutPOV.Rotation, X, Y, Z);
    Move = X * InspectController.PlayerInput.aForward + Y * InspectController.PlayerInput.aStrafe
        + vect(0,0,1) * InspectController.PlayerInput.aUp;
    if (VSizeSq(Move) > 1) Move = Normal(Move);
    SetLocation(Location + Move * 250 * FClamp(DeltaTime, 0, 0.05));
    SetRotation(OutPOV.Rotation);
    OutPOV.Location = Location; OutPOV.FOV = 65;
}
defaultproperties { RemoteRole=ROLE_None }
