// Uses the shared inspection camera's wall-bounded orbit. Free movement is cosmetic.
class KF2VRMotionCamera extends KF2VRNetAvatarCamera;
var int CameraMode;
simulated function GetCameraView(float DeltaTime, out TPOV OutPOV)
{
    local vector X, Y, Z, Move;
    if (CameraMode != 2)
    {
        if (CameraMode == 0 && InspectController != None) InitialLook = InspectController.Rotation;
        Super.GetCameraView(DeltaTime, OutPOV);
        return;
    }
    if (InspectController == None || InspectController.PlayerInput == None)
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
