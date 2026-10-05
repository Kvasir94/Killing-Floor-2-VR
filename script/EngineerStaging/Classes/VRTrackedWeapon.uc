// Optional input contract for equipment whose primary/secondary actions do
// not follow KF2 firearm input. This interface has no external asset package.
interface VRTrackedWeapon;

simulated function UpdateTrackedInput(VRHandsBridge Bridge);
simulated function CancelTrackedInput();
