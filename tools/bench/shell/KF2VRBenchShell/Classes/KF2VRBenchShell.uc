// #148 FPS benchmark helper: dismisses KF2VR's arrival VR shell page so the
// adapter renders the world, not the spatial menu. The stock-only KF2VRBench
// mutator spawns it by name. This one class depends on KF2VR, so it is compiled
// separately against each build's KF2VR.u (tools/bench/build-bench.ps1 -ShellFor).
class KF2VRBenchShell extends Info;

var int Closed;

function Tick(float DeltaTime)
{
    local PlayerController PC;
    local VRGameViewportClient VRViewport;

    super.Tick(DeltaTime);
    PC = GetALocalPlayerController();
    if (PC == none || LocalPlayer(PC.Player) == none)
        return;
    VRViewport = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    if (VRViewport == none || VRViewport.VRSession == none || VRViewport.VRSession.NativeShellActive == 0)
        return;
    VRViewport.VRSession.NativeShellActive = 0;
    if (Closed++ < 3)
        `log("KF2VRBENCH phase=shell-closed count=" $ Closed);
}
