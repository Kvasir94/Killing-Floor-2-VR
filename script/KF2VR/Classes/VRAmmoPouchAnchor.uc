// One calibrated pouch frame for the owner's local pouch interaction.
// The neck pivot keeps the pouch stable while the eyes pitch toward the belt.
class VRAmmoPouchAnchor extends Object;

static function vector Position(vector HeadAt, rotator HeadFacing, rotator TorsoYaw,
    vector ReloadOffset, vector Adjustment, float NeckLength, int Side, optional bool bHeadTracked=true)
{
    local vector X, Y, Z, Pivot;
    ReloadOffset.X += FClamp(Adjustment.X, -15, 20);
    ReloadOffset.Y -= FClamp(Adjustment.Y, -3, 25);
    ReloadOffset.Z += FClamp(Adjustment.Z, -20, 20);
    if (Side == 1) ReloadOffset.Y = -ReloadOffset.Y;
    Z = vect(0,0,1);
    if (bHeadTracked) GetAxes(HeadFacing, X, Y, Z);
    Pivot = HeadAt - Z * NeckLength;
    return Pivot - vect(0,0,1) * (38 - NeckLength) + (ReloadOffset >> TorsoYaw);
}
