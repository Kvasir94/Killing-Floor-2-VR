// Local inspection camera, enabled only by the explicit desktop solo fixture.
class KF2VRNetAvatarCamera extends CameraActor;

var KF2VRNetAvatarPreview Preview;
var KF2VRNetPose RemotePose;
var KF2VRNetPlayerController InspectController;
var rotator InitialLook;
var float NextDiagnosticTime;
var bool bOrbitChosen;
var int InitialOrbitYaw;

simulated function vector UnobstructedPosition(vector Focus, rotator Facing, out Actor Obstacle)
{
    local vector Desired, HitLocation, HitNormal;
    Desired = Focus + (vect(210,125,45) >> Facing);
    // KF maps use colliding StaticMeshActors as well as BSP. World-only traces
    // miss those meshes and can put this camera behind a wall.
    Obstacle = Trace(HitLocation, HitNormal, Desired, Focus, true, vect(8,8,8));
    if (Obstacle != None) Desired = HitLocation + HitNormal * 12;
    return Desired;
}

simulated function GetCameraView(float DeltaTime, out TPOV OutPOV)
{
    local vector Focus, Desired, Candidate;
    local rotator Facing, Orbit, CandidateFacing;
    local Actor Obstacle;
    local vector Requested;
    local int I, BestYaw;
    local float BestDistance, CandidateDistance;
    local bool bMoved;
    if (RemotePose != None && !RemotePose.bDeleteMe && RemotePose.TargetPawn != None)
    {
        Facing.Yaw = RemotePose.TargetPawn.Rotation.Yaw;
        Focus = RemotePose.TargetPawn.Location + vect(0,0,5);
    }
    else if (Preview != None && !Preview.bDeleteMe && Preview.bSafePlacement)
    {
        Facing.Yaw = Preview.Rotation.Yaw;
        Focus = Preview.Location + vect(0,0,5);
    }
    else
    {
        Super.GetCameraView(DeltaTime, OutPOV);
        return;
    }
    if (InspectController != None)
    {
        Orbit = Normalize(InspectController.Rotation - InitialLook);
        Facing.Yaw += Orbit.Yaw;
        Facing.Pitch = Clamp(Orbit.Pitch, -9000, 9000);
    }
    if (!bOrbitChosen)
    {
        // Find a useful initial view when a spawn is beside map geometry.
        // Once chosen, keep its angle stable and let the mouse control orbit.
        BestDistance = 0;
        for (I = 0; I < 8; ++I)
        {
            CandidateFacing = Facing;
            CandidateFacing.Yaw += I * 8192;
            Candidate = UnobstructedPosition(Focus, CandidateFacing, Obstacle);
            CandidateDistance = VSize(Candidate - Focus);
            if (CandidateDistance > BestDistance)
            { BestDistance = CandidateDistance; BestYaw = I * 8192; }
            if (CandidateDistance > 220) break;
        }
        InitialOrbitYaw = BestYaw;
        bOrbitChosen = true;
    }
    Facing.Yaw += InitialOrbitYaw;
    Desired = UnobstructedPosition(Focus, Facing, Obstacle);
    Requested = Focus + (vect(210,125,45) >> Facing);
    OutPOV.Location = Desired;
    OutPOV.Rotation = rotator(Focus - Desired);
    OutPOV.FOV = 65;
    // KF's active first-person/fixed camera may subsequently read the actor's
    // eyes transform. Keep that transform identical to this inspection POV.
    bMoved = SetLocation(OutPOV.Location);
    SetRotation(OutPOV.Rotation);
    if (WorldInfo.RealTimeSeconds >= NextDiagnosticTime)
    {
        `log("KF2VRNet avatar_camera_frame time=" $ WorldInfo.RealTimeSeconds
            $ " focus=" $ Focus $ " requested=" $ Requested $ " actual=" $ Location
            $ " distance=" $ VSize(Location - Focus) $ " obstacle=" $ Obstacle
            $ " moved=" $ bMoved $ " rotation=" $ Rotation $ " fov=" $ OutPOV.FOV
            $ " prior_cached=" $ InspectController.PlayerCamera.CameraCache.POV.Location);
        NextDiagnosticTime = WorldInfo.RealTimeSeconds + 2;
    }
}

defaultproperties
{
    // CameraActor is map-authored by default. This local diagnostic is spawned.
    bStatic=false
    bNoDelete=false
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    Physics=PHYS_None
    bConstrainAspectRatio=false
    FOVAngle=65
}
