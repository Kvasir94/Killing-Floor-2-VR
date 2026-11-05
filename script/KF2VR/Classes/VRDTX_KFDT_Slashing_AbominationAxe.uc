// Melee roadmap item 5: KFDT_Slashing_AbominationAxe without dismemberment, for a slow or flat
// blade hit (VRMeleeScale.ProcessScaledHit swaps it in for one hit).
class VRDTX_KFDT_Slashing_AbominationAxe extends KFDT_Slashing_AbominationAxe;

static simulated function bool CanDismemberHitZone(name InHitZoneName) { return false; }
static simulated function bool CanDismemberHitZoneWhileAlive(name InHitZoneName) { return false; }
