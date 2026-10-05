class KF2VRNetSessionUI extends VRSessionUI;

function bool LocalContext()
{
    if (Super.LocalContext()) return true;
    return PC != None && !PC.bDeleteMe && PC.WorldInfo != None
        && LocalPlayer(PC.Player) != None && PC.WorldInfo.NetMode == NM_Client
        && KF2VRNetPlayerController(PC) != None
        && KF2VRNetPlayerController(PC).NativeNetworkReady == 1;
}

function class<VRHandsBridge> HandPreferenceClass()
{
    return class'KF2VRNetHandsBridge';
}

function AddInspectionRow()
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (NetPC == None) return;
    AddRow(3, "THIRD-PERSON INSPECTION: " $ (NetPC.bSelfAvatarInspection ? "ON" : "OFF"),
        LivingView() ? MA_Inspection : MA_None, 0, LivingView() ? 1 : 4);
}

function ActivateInspection()
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(PC);
    if (!LocalContext() || !LivingView() || NetPC == None) return;
    NetPC.KF2VRThirdPersonToggle();
    `log("KF2VRNet self_view_menu action=toggle requested=" $ NetPC.bSelfAvatarInspection
        $ " source=vr_session page=1 row=3");
    if (NativeShellActive != 0) ToggleMenu();
}
