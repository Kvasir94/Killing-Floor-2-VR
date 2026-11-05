// Disposition of a physical-end request after the stock weapon-channel sync.
// This carries no ammo and grants no ownership; the caller must still check
// the exact owned runtime and primary Reloading state before completing it.
class VRReloadEndGuard extends Object;

const WaitForMarker = 0;
const Discard = 1;
const Complete = 2;

static function byte Disposition(int Request, int Marker, int MarkerReload,
    int CurrentReload, int LastConsumed, optional bool bExpired)
{
    if (Request <= 0 || Request == MaxInt || Request <= LastConsumed
        || Marker > Request) return Discard;
    if (Marker < Request) return bExpired ? Discard : WaitForMarker;
    // An unobserved or exhausted generation fails closed. Zero must never
    // let an older adapter's marker accelerate an unrelated stock reload.
    if (MarkerReload <= 0 || MarkerReload == MaxInt || MarkerReload != CurrentReload) return Discard;
    return Complete;
}
