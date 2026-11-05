// Original Options routes share the curated spatial settings shell in VR.
class VRGameSettingsMenu extends KFGFxOptionsMenu_GameSettings;
function OnOpen()
{
    local PlayerController PC;
    local VRGameViewportClient V;
    PC = GetPC();
    if (PC == None || LocalPlayer(PC.Player) == None) return;
    V = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    if (V != None && V.VRSession != None) V.VRSession.RequestedSettingsPage = 5;
}
