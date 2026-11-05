// Authority-only per-item state, with the same narrow pending-fire ABI as the
// local runtime. Stock weapon actors retain ammunition and action timelines.
class KF2VRNetItemRuntime extends Object;

var KF2VRNetHeldInventory Inventory;
var KFWeapon Item;
var int NativeReady;

var int CarryOnly;
// Last ordered version-2 weapon-channel marker; never an ammunition value.
var int WeaponBarrierSerial;
// Native records a forwarded ServerSendToReload and snapshots its generation
// beside each weapon-channel marker. A late physical-end RPC cannot complete
// a different reload that began after that marker.
var int ReloadGeneration, WeaponBarrierReloadGeneration;
var int LastPhysicalReloadEndSerial;
var int WorldDropped;
// Independent from held/world placement while an own-trick lease is active.
var int WorldTrickPending;
var float WorldDropFireReadyAt;
var int MechanismPending;
var int SecondaryMagazineFlags, SecondaryMagazinePending;
var int PendingFireCount, PendingFireMask;
// Cosmetic counter from stock NotifyWeaponFired, never from ammunition deltas.
var int ShotSequence;
var byte LastShotFireMode;
// Contact blasts use the stock custom-fire interval for this exact weapon.
var float PulverizerReadyAt;
var float DeployableReadyAt;
