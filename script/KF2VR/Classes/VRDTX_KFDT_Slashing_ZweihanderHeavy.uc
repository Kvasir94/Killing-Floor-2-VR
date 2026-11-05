// Melee roadmap item 5: KFDT_Slashing_ZweihanderHeavy without dismemberment, for a slow or flat
// blade hit (VRMeleeScale.ProcessScaledHit swaps it in for one hit).
class VRDTX_KFDT_Slashing_ZweihanderHeavy extends KFDT_Slashing_ZweihanderHeavy;

static simulated function bool CanDismemberHitZone(name InHitZoneName) { return false; }
static simulated function bool CanDismemberHitZoneWhileAlive(name InHitZoneName) { return false; }
