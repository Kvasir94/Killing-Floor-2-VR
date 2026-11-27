// Melee roadmap item 5: KFDT_Slashing_ScytheLongAlt without dismemberment, for a slow or flat
// blade hit (VRMeleeScale.ProcessScaledHit swaps it in for one hit). The unfolded Scythe's
// types (melee spec M26).
class VRDTX_KFDT_Slashing_ScytheLongAlt extends KFDT_Slashing_ScytheLongAlt;

static simulated function bool CanDismemberHitZone(name InHitZoneName) { return false; }
static simulated function bool CanDismemberHitZoneWhileAlive(name InHitZoneName) { return false; }
