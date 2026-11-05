// Base-package seam: stock world props do not depend on the network package.
interface VRWorldDropObserver;

function WorldDropAvailable(VRWorldDropGun Prop);
function WorldDropClosed(KFPawn_Human Human, int ItemId, int ReleaseRequest);
function bool ShouldHideWorldDrop(VRWorldDropGun Prop);
