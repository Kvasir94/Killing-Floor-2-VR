// Authority-only per-item state, with the same narrow pending-fire ABI as the
// local runtime. Stock weapon actors retain ammunition and action timelines.
class KF2VRNetItemRuntime extends Object;

var KF2VRNetHeldInventory Inventory;
var KFWeapon Item;
var int NativeReady;
var int PendingFireCount, PendingFireMask;
