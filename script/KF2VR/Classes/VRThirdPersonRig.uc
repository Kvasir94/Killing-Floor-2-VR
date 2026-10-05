// Local presentation interface; the network package supplies the existing rig.
// Dynamic loading keeps core KF2VR independent of its network companion.
class VRThirdPersonRig extends Actor abstract;
var KFPawn_Human LocalPawn;
simulated function bool UpdateLocalTracking(VRHandsBridge Bridge) { return false; }
simulated function bool IsReady() { return false; }
