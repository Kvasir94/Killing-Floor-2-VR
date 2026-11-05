// Melee roadmap item 5: KFDT_Slashing_IonThrusterHeavy without dismemberment, for a slow or flat
// blade hit (VRMeleeScale.ProcessScaledHit swaps it in for one hit).
class VRDTX_KFDT_Slashing_IonThrusterHeavy extends KFDT_Slashing_IonThrusterHeavy;

static simulated function bool CanDismemberHitZone(name InHitZoneName) { return false; }
static simulated function bool CanDismemberHitZoneWhileAlive(name InHitZoneName) { return false; }
