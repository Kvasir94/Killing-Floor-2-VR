// Melee roadmap item 5: KFDT_Slashing_KnifeHeavy_SWAT without dismemberment, for a slow or flat
// blade hit (VRMeleeScale.ProcessScaledHit swaps it in for one hit).
class VRDTX_KFDT_Slashing_KnifeHeavy_SWAT extends KFDT_Slashing_KnifeHeavy_SWAT;

static simulated function bool CanDismemberHitZone(name InHitZoneName) { return false; }
static simulated function bool CanDismemberHitZoneWhileAlive(name InHitZoneName) { return false; }
