// The viewport survives pawn death and map travel. Keep VR presentation here,
// independently of VRHandsBridge's living-player weapon/locomotion lifetime.
class VRGameViewportClient extends KFGameViewportClient;

var VRSessionUI VRSession;

event bool Init(out string OutError)
{
    if (!Super.Init(OutError)) return false;
    VRSession = new(self) class'VRSessionUI';
    VRSession.Viewport = self;
    `log("KF2VR_SESSION phase=viewport-init session=" $ VRSession);
    return true;
}

event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (VRSession != None) VRSession.Update(DeltaTime);
}

// Console control of VR Training for scripted replays and testers:
// start, skip, end, styleN (answer the style question), kill (drop the
// training targets) or offer.
exec function KF2VRTraining(string Command)
{
    if (VRSession != None) VRSession.TrainingCommand(Command);
}

event PostRender(Canvas C)
{
    Super.PostRender(C);
    if (VRSession != None) VRSession.Draw(C);
}

event PreBrowse(string Address)
{
    // Release world references before travel/GC; the viewport itself persists.
    if (VRSession != None) VRSession.BeginTravel();
    Super.PreBrowse(Address);
}

defaultproperties
{
}
