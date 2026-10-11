// This interaction belongs only to an explicit diagnostic viewport. The
// authored pulse enters the native hand fields, never viewport key events.
class VRLocalDiagnosticInputGate extends Interaction;

var GameViewportClient Viewport;

function bool FilterKey(int ControllerId, name Key, EInputEvent EventType,
    optional float AmountDepressed=1.0, optional bool bGamepad)
{
    if (Key == 'F10')
    {
        if (EventType == IE_Pressed && Viewport != None)
        {
            `log("KF2VR_LOCAL_DIAGNOSTIC phase=abort key=F10");
            Viewport.ConsoleCommand("quit");
        }
        return true;
    }
    return true;
}

function bool FilterAxis(int ControllerId, name Key, float Delta, float DeltaTime,
    optional bool bGamepad) { return true; }

function bool FilterChar(int ControllerId, string Unicode) { return true; }
