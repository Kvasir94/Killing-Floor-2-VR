// Portal frame math. Local +X points out of the mounting surface, +Y right,
// +Z up. Travel maps entry-local (x,y,z) to exit-local (-x,-y,z): a half turn
// about local up, as in Portal 2 (docs/re/PORTAL2_REFERENCE.md).
class VRPortalMath extends Object abstract;

static function vector MapVector(vector V, rotator EntryBasis, rotator ExitBasis)
{
    local vector LocalV;
    LocalV = V << EntryBasis;
    LocalV.X = -LocalV.X;
    LocalV.Y = -LocalV.Y;
    return LocalV >> ExitBasis;
}

static function vector MapPoint(vector P, vector EntryCenter, rotator EntryBasis,
    vector ExitCenter, rotator ExitBasis)
{
    return ExitCenter + MapVector(P - EntryCenter, EntryBasis, ExitBasis);
}

// Wall portals stay upright. Floor and ceiling portals take their "up" from
// the shot heading, so the portal's top faces away from the shooter.
static function rotator MakeBasis(vector SurfaceNormal, vector AimDirection)
{
    local vector X, Y, Z;
    X = Normal(SurfaceNormal);
    Z = vect(0,0,1) - X * X.Z;
    if (VSizeSq(Z) < 0.01)
    {
        Z = AimDirection - X * (AimDirection dot X);
        if (VSizeSq(Z) < 0.01) Z = vect(1,0,0) - X * X.X;
    }
    Z = Normal(Z);
    Y = Normal(Z cross X);
    Z = Normal(X cross Y);
    return OrthoRotation(X, Y, Z);
}

static function bool InsideEllipse(float LocalY, float LocalZ, float HalfWidth, float HalfHeight)
{
    if (HalfWidth <= 0 || HalfHeight <= 0) return false;
    return Square(LocalY / HalfWidth) + Square(LocalZ / HalfHeight) <= 1.0;
}

// Yaw change a traveller's view receives. KF2 bodies stay upright, so only the
// heading of the mapped forward vector is kept (Portal 2 re-uprights over time;
// a headset cannot be tilted).
static function int TravelYaw(rotator View, rotator EntryBasis, rotator ExitBasis)
{
    local vector Forward, Mapped;
    Forward = vector(View);
    Forward.Z = 0;
    if (VSizeSq(Forward) < 0.0001) Forward = vector(EntryBasis) * -1;
    Mapped = MapVector(Normal(Forward), EntryBasis, ExitBasis);
    Mapped.Z = 0;
    if (VSizeSq(Mapped) < 0.0001)
    {
        // Straight down a floor portal: keep facing the exit's outward heading.
        Mapped = vector(ExitBasis);
        Mapped.Z = 0;
        if (VSizeSq(Mapped) < 0.0001) return 0;
    }
    return NormalizeRotAxis(rotator(Mapped).Yaw - rotator(Forward).Yaw);
}
