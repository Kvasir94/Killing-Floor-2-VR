// Cosmetic sample playback uses the existing remote body/weapon retargeter.
class KF2VRMotionReplay extends KF2VRNetPose;
var private KF2VRNetTypes.NetPoseSnapshot MotionFrame;
var private KF2VRMotionGhost Ghost;
var private KF2VRMotionCamera MotionCamera;
var private KF2VRNetPlayerController MotionPC;
var private Actor SavedView;
var private bool bSavedIgnoreMove;
var private string LastLeftClass, LastRightClass;

simulated function KF2VRNetTypes.NetPoseSnapshot SamplePreview() { return MotionFrame; }
simulated function bool HasFreshPose() { return Ghost != None && !Ghost.bDeleteMe; }
simulated event Tick(float DeltaTime) { UpdateRemoteWeapons(HasFreshPose()); }

simulated function ApplyBridge(KF2VRNetHandsBridge B)
{
    local rotator Root;
    local KF2VRNetTypes.NetPoseSample S;
    if (Ghost == None)
    {
        Ghost = Spawn(class'KF2VRMotionGhost', self,, B.MotionP0);
        if (Ghost == None) return;
        Ghost.BindAppearance(B.Human);
        TargetPawn = Ghost;
        MotionPC = KF2VRNetPlayerController(B.PC);
        if (MotionPC != None)
        {
            SavedView = MotionPC.GetViewTarget();
            MotionPC.IgnoreMoveInput(true);
            bSavedIgnoreMove = true;
            MotionCamera = Spawn(class'KF2VRMotionCamera', self);
            if (MotionCamera != None)
            {
                MotionCamera.RemotePose = self; MotionCamera.InspectController = MotionPC;
                MotionCamera.InitialLook = MotionPC.Rotation;
                MotionPC.SetViewTarget(MotionCamera);
            }
        }
    }
    Root.Yaw = B.MotionR0.Yaw;
    Ghost.ApplyCrouch(B.MotionS8 != 0);
    Ghost.SetLocation(B.MotionP0); Ghost.SetRotation(Root);
    Ghost.Velocity = B.MotionVelocity;
    Ghost.BaseEyeHeight = B.MotionEyeHeight; Ghost.Health = B.MotionS10;
    Ghost.Mesh.SetHidden(B.MotionS10 <= 0);
    S.TrackingFlags = B.MotionS0 & 7;
    S.PresentationFlags = B.MotionS1 & 63;
    S.ReferenceEpoch = Max(0, B.MotionS7);
    if ((S.TrackingFlags & 1) != 0) { S.HeadPosition = (B.MotionP1 - B.MotionP0) << Root; S.HeadRotation = Normalize(B.MotionR1 - Root); }
    if ((S.TrackingFlags & 2) != 0)
    {
        S.LeftPosition = (B.MotionP2 - B.MotionP0) << Root; S.LeftRotation = Normalize(B.MotionR2 - Root);
        S.LeftGripRotation = Normalize(B.MotionR4 - Root); S.LeftHandPose = B.MotionS2;
    }
    if ((S.TrackingFlags & 4) != 0)
    {
        S.RightPosition = (B.MotionP3 - B.MotionP0) << Root; S.RightRotation = Normalize(B.MotionR3 - Root);
        S.RightGripRotation = Normalize(B.MotionR5 - Root); S.RightHandPose = B.MotionS3;
    }
    if ((S.PresentationFlags & 1) != 0) { S.MuzzlePosition = (B.MotionP6 - B.MotionP0) << Root; S.MuzzleRotation = Normalize(B.MotionR6 - Root); }
    if ((S.PresentationFlags & 2) != 0) { S.LeftMuzzlePosition = (B.MotionP7 - B.MotionP0) << Root; S.LeftMuzzleRotation = Normalize(B.MotionR7 - Root); }
    if ((S.PresentationFlags & 4) != 0) { S.LeftWristPosition = (B.MotionP8 - B.MotionP0) << Root; S.LeftWristRotation = Normalize(B.MotionR8 - Root); }
    if ((S.PresentationFlags & 8) != 0) { S.RightWristPosition = (B.MotionP9 - B.MotionP0) << Root; S.RightWristRotation = Normalize(B.MotionR9 - Root); }
    if (!class'KF2VRNetTypes'.static.IsValidSample(S)) S.TrackingFlags = 0;
    MotionFrame.Sample = S; MotionFrame.RootPosition = B.MotionP0; MotionFrame.RootRotation = Root;
    bIndependentWeapons = true;
    if (LastLeftClass != B.MotionWeapon0)
    {
        if (B.MotionWeapon0 == "") LeftWeapon.WeaponClass = None;
        else LeftWeapon.WeaponClass = class<KFWeapon>(DynamicLoadObject(B.MotionWeapon0, class'Class'));
        LastLeftClass = B.MotionWeapon0;
    }
    if (LastRightClass != B.MotionWeapon1)
    {
        if (B.MotionWeapon1 == "") RightWeapon.WeaponClass = None;
        else RightWeapon.WeaponClass = class<KFWeapon>(DynamicLoadObject(B.MotionWeapon1, class'Class'));
        LastRightClass = B.MotionWeapon1;
    }
    LeftWeapon.ItemId = B.MotionW00; LeftWeapon.ShotSequence = B.MotionW01; LeftWeapon.Ammo = B.MotionW02;
    LeftWeapon.WeaponState = B.MotionW03; LeftWeapon.ReloadStage = B.MotionW04; LeftWeapon.FireMode = B.MotionW05; LeftWeapon.AnimRate = B.MotionRate0;
    RightWeapon.ItemId = B.MotionW10; RightWeapon.ShotSequence = B.MotionW11; RightWeapon.Ammo = B.MotionW12;
    RightWeapon.WeaponState = B.MotionW13; RightWeapon.ReloadStage = B.MotionW14; RightWeapon.FireMode = B.MotionW15; RightWeapon.AnimRate = B.MotionRate1;
    if (MotionCamera != None && MotionPC != None) MotionCamera.CameraMode = MotionPC.MotionCameraMode;
    UpdateRemoteWeapons(true);
}

simulated event Destroyed()
{
    if (MotionPC != None)
    {
        if (MotionPC.GetViewTarget() == MotionCamera && SavedView != None && !SavedView.bDeleteMe) MotionPC.SetViewTarget(SavedView);
        if (bSavedIgnoreMove) MotionPC.IgnoreMoveInput(false);
    }
    if (MotionCamera != None) MotionCamera.Destroy();
    Super.Destroyed();
    if (Ghost != None) Ghost.Destroy();
}
defaultproperties
{
    RemoteRole=ROLE_None
    bAlwaysRelevant=false
    bReplicateMovement=false
}
