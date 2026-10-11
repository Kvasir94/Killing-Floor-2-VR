// Keep the ordinary Solo VR viewport's renderer, session and menu lifetime.
// The launcher selects this subclass only in copied diagnostic engine config.
class VRLocalDiagnosticViewportClient extends VRGameViewportClient;

var VRLocalDiagnosticInputGate DiagnosticInputGate;

event bool Init(out string OutError)
{
    if (!Super.Init(OutError)) return false;
    DiagnosticInputGate = new(self) class'VRLocalDiagnosticInputGate';
    DiagnosticInputGate.Viewport = self;
    DiagnosticInputGate.OnReceivedNativeInputKey = DiagnosticInputGate.FilterKey;
    DiagnosticInputGate.OnReceivedNativeInputAxis = DiagnosticInputGate.FilterAxis;
    DiagnosticInputGate.OnReceivedNativeInputChar = DiagnosticInputGate.FilterChar;
    HandleInputChar = DiagnosticInputGate.FilterChar;
    GlobalInteractions.Insert(0, 1);
    GlobalInteractions[0] = DiagnosticInputGate;
    `log("KF2VR_LOCAL_DIAGNOSTIC phase=input-isolated abort=F10");
    return true;
}
