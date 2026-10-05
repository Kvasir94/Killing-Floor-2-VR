// Fixture-local input filter. No OS hooks and no changes to ordinary play.
class KF2VRDiagnosticInputGate extends Interaction;

var GameViewportClient Viewport;
var int BlockedKeys, BlockedAxes, BlockedChars;

function bool FilterKey(int ControllerId, name Key, EInputEvent EventType,
    optional float AmountDepressed=1.0, optional bool bGamepad)
{
    if (bGamepad) return false;
    if (Key == 'F10')
    {
        if (EventType == IE_Pressed && Viewport != None)
        {
            `log("KF2VR_INPUT_ISOLATION phase=abort key=F10");
            Viewport.ConsoleCommand("quit");
        }
        return true;
    }
    ++BlockedKeys;
    if (BlockedKeys <= 8) `log("KF2VR_INPUT_ISOLATION phase=blocked_key key=" $ Key);
    return true;
}

function bool FilterAxis(int ControllerId, name Key, float Delta, float DeltaTime,
    optional bool bGamepad)
{
    if (bGamepad) return false;
    ++BlockedAxes;
    if (BlockedAxes <= 4) `log("KF2VR_INPUT_ISOLATION phase=blocked_axis key=" $ Key);
    return true;
}

function bool FilterChar(int ControllerId, string Unicode)
{
    ++BlockedChars;
    if (BlockedChars <= 2) `log("KF2VR_INPUT_ISOLATION phase=blocked_char");
    return true;
}
