// Pure portal frame math. Local +X points out of the mounting surface.
// A half turn about local up maps inward entry motion to outward exit motion.
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

static function rotator MapRotation(rotator R, rotator EntryBasis, rotator ExitBasis)
{
    local vector X, Y, Z;
    GetAxes(R, X, Y, Z);
    return OrthoRotation(MapVector(X, EntryBasis, ExitBasis),
        MapVector(Y, EntryBasis, ExitBasis), MapVector(Z, EntryBasis, ExitBasis));
}

static function rotator MakeBasis(vector SurfaceNormal, vector AimDirection)
{
    local vector X, Y, Z;
    X = Normal(SurfaceNormal);
    // Wall portals stay upright. Floor/ceiling portals use the shot heading.
    Z = vect(0,0,1) - X * X.Z;
    if (VSizeSq(Z) < 0.01)
    {
        Z = -AimDirection + X * (AimDirection dot X);
        if (VSizeSq(Z) < 0.01) Z = vect(1,0,0) - X * X.X;
    }
    Z = Normal(Z);
    Y = Normal(Z cross X);
    Z = Normal(X cross Y);
    return OrthoRotation(X, Y, Z);
}

static function bool InsideEllipse(vector LocalPoint, float HalfWidth, float HalfHeight,
    optional float RadiusY, optional float RadiusZ)
{
    local float Y, Z;
    if (HalfWidth <= 0 || HalfHeight <= 0 || RadiusY < 0 || RadiusZ < 0) return false;
    // Conservative support rectangle, not independently shrunk ellipse radii:
    // the furthest corner must fit, including diagonal edge approaches.
    Y = (Abs(LocalPoint.Y) + RadiusY) / HalfWidth;
    Z = (Abs(LocalPoint.Z) + RadiusZ) / HalfHeight;
    return Y*Y + Z*Z <= 1.00001;
}

static function bool SweptCrossing(vector Previous, vector Current, vector Center,
    rotator Basis, float PlaneOffset, out vector CrossPoint)
{
    local vector N;
    local float Before, After, T;
    N = vector(Basis);
    Before = ((Previous - Center) dot N) - PlaneOffset;
    After = ((Current - Center) dot N) - PlaneOffset;
    if (Before <= 0 || After > 0 || Before - After <= 0.00001) return false;
    T = Before / (Before - After);
    CrossPoint = Previous + (Current - Previous) * T;
    return true;
}
