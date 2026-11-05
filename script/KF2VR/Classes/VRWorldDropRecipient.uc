// Server-side hand ledger adapter, discoverable without a dependency on the
// multiplayer package. Public loot can find its recipient after its donor left.
interface VRWorldDropRecipient;

function bool ReceivesWorldDropPawn(KFPawn_Human P);
function bool PrepareWorldReplacement(KFWeapon W);
function FinishWorldReplacement(KFWeapon OldWeapon, KFWeapon NewWeapon);
function RegisterWorldDropPair(VRWeaponPair Pair);
