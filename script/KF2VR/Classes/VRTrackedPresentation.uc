// Optional presentation hooks for ported weapons. Calibration executes once;
// updates may execute more than once per simulation frame and must not fire,
// reload, integrate physics or consume inventory.
interface VRTrackedPresentation;

simulated function ConfigureTrackedPresentation(VRHandsBridge B);
simulated function UpdateTrackedPresentation(VRHandsBridge B);
