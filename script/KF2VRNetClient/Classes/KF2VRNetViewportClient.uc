class KF2VRNetViewportClient extends VRGameViewportClient;

var config bool bDiagnosticInputIsolation;
var KF2VRDiagnosticInputGate DiagnosticInputGate;

event bool Init(out string OutError)
{
    if (!Super.Init(OutError)) return false;
    if (bDiagnosticInputIsolation)
    {
        DiagnosticInputGate = new(self) class'KF2VRDiagnosticInputGate';
        DiagnosticInputGate.Viewport = self;
        DiagnosticInputGate.OnReceivedNativeInputKey = DiagnosticInputGate.FilterKey;
        DiagnosticInputGate.OnReceivedNativeInputAxis = DiagnosticInputGate.FilterAxis;
        DiagnosticInputGate.OnReceivedNativeInputChar = DiagnosticInputGate.FilterChar;
        HandleInputChar = DiagnosticInputGate.FilterChar;
        GlobalInteractions.Insert(0, 1);
        GlobalInteractions[0] = DiagnosticInputGate;
        `log("KF2VR_INPUT_ISOLATION phase=installed abort=F10 gamepad=authored");
    }
    VRSession = new(self) class'KF2VRNetSessionUI';
    VRSession.Viewport = self;
    return true;
}
