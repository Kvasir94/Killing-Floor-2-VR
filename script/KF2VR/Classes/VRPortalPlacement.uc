// Portal 2's VerifyPortalPlacement / FitPortalOnSurface, fitted to KF2 traces
// (docs/re/PORTAL2_REFERENCE.md, server.dll 10358b00 / 10356f90 / 10356ba0):
// hit a static surface, bump away from the other portal, then bump away from
// surface edges and obstructions for at most six passes, reject a fit that
// moved too far, snap a wall portal down onto a floor just below it, and
// finish with Portal 2's five-point surface check. A normal shot costs about
// twenty short traces; the worst rejected shot stays in the low hundreds.
class VRPortalPlacement extends Object abstract;

const EdgeInset = 2.0;
const SurfaceProbe = 4.0;
const SurfaceTolerance = 1.5;
const ObstructionLift = 3.0;
const FloorSnap = 24.0;
const MaxPasses = 6;

static function bool RefineSurfaceHit(Actor Context, vector Start, vector End,
    Actor HitActor, out vector Hit, out vector HitNormal, out TraceHitInfo Info,
    optional int ExtraTraceFlags)
{
    local vector Direction, RefinedHit, RefinedNormal, LocalStart, LocalEnd;
    local float Length, Distance, Radius;
    local Actor RefinedActor;
    local TraceHitInfo RefinedInfo;
    if (Context == None || HitActor == None) return false;
    Length=VSize(End-Start);
    if (Length <= 0.001) return false;
    Direction=(End-Start)/Length;
    Distance=FClamp((Hit-Start) dot Direction,0,Length);
    Radius=FMax(128,Length*0.001+2);
    LocalStart=Start+Direction*FMax(0,Distance-Radius);
    LocalEnd=Start+Direction*FMin(Length,Distance+Radius);
    RefinedActor=Context.Trace(RefinedHit,RefinedNormal,LocalEnd,LocalStart,true,,RefinedInfo,ExtraTraceFlags);
    if (RefinedActor != HitActor || RefinedInfo.HitComponent != Info.HitComponent
        || (RefinedNormal dot HitNormal) <= 0.995) return false;
    Hit=RefinedHit;
    HitNormal=RefinedNormal;
    Info=RefinedInfo;
    return true;
}

// A wall, floor or ceiling that stays put: BSP or static world meshes.
static function bool IsPortalable(Actor A)
{
    if (A == None || A.bDeleteMe || Pawn(A) != None || VRPortal(A) != None) return false;
    if (A.bWorldGeometry || A.bStatic) return true;
    return false;
}

// Is there mounting surface directly behind P, on the portal's own plane?
static function bool HasSurface(Actor Context, vector P, vector N, vector PlanePoint)
{
    local vector Hit, HitNormal;
    local Actor A;
    A = Context.Trace(Hit, HitNormal, P - N * SurfaceProbe, P + N * SurfaceProbe, false);
    return A != None && IsPortalable(A) && (HitNormal dot N) > 0.99
        && Abs((Hit - PlanePoint) dot N) < SurfaceTolerance;
}

// How far (0..1 of Reach) the portal may extend from Center along Axis before
// its surface ends or something stands in front of it.
static function float FreeFraction(Actor Context, vector Center, vector N, vector Axis, float Reach)
{
    local vector Hit, HitNormal, Start, P;
    local float Low, High, Mid, Blocked;
    local int I;
    Start = Center + N * ObstructionLift;
    Blocked = 1.0;
    if (Context.Trace(Hit, HitNormal, Start + Axis * Reach, Start, false) != None)
        Blocked = FClamp(((Hit - Start) dot Axis) / Reach, 0, 1);
    P = Center + Axis * (Reach * Blocked);
    if (HasSurface(Context, P, N, Center)) return Blocked;
    // The surface ends first: binary search its edge like Portal 2's corner trace.
    Low = 0; High = Blocked;
    for (I = 0; I < 7; ++I)
    {
        Mid = (Low + High) * 0.5;
        if (HasSurface(Context, Center + Axis * (Reach * Mid), N, Center)) Low = Mid;
        else High = Mid;
    }
    return Low;
}

static function bool FinalCheck(Actor Context, vector Center, rotator Basis, float HalfWidth, float HalfHeight)
{
    local vector X, Y, Z;
    local int SY, SZ;
    GetAxes(Basis, X, Y, Z);
    if (!HasSurface(Context, Center, X, Center)) return false;
    for (SY = -1; SY <= 1; SY += 2)
        for (SZ = -1; SZ <= 1; SZ += 2)
            if (!HasSurface(Context, Center + Y * (SY * (HalfWidth - EdgeInset))
                + Z * (SZ * (HalfHeight - EdgeInset)), X, Center)) return false;
    return true;
}

static function bool OverlapsPortal(vector Center, rotator Basis, float HalfWidth, float HalfHeight, VRPortal Other)
{
    local vector Offs;
    if (Other == None || Other.bDeleteMe) return false;
    if ((vector(Basis) dot vector(Other.Rotation)) < 0.99) return false;
    Offs = (Center - Other.Location) << Other.Rotation;
    return Abs(Offs.X) < 4 && Abs(Offs.Y) < HalfWidth + Other.HalfWidth
        && Abs(Offs.Z) < HalfHeight + Other.HalfHeight;
}

// 10354e90: a portal landing on the other portal's plane is pushed clear of it.
static function vector BumpFromPortal(vector Center, rotator Basis, float HalfWidth, float HalfHeight, VRPortal Other)
{
    local vector Offs, Push;
    local float OverY, OverZ;
    if (!OverlapsPortal(Center, Basis, HalfWidth, HalfHeight, Other)) return Center;
    Offs = (Center - Other.Location) << Other.Rotation;
    OverY = HalfWidth + Other.HalfWidth - Abs(Offs.Y) + 1;
    OverZ = HalfHeight + Other.HalfHeight - Abs(Offs.Z) + 1;
    // Leave along the shorter way out.
    if (OverY <= OverZ) Push.Y = Offs.Y >= 0 ? OverY : -OverY;
    else Push.Z = Offs.Z >= 0 ? OverZ : -OverZ;
    return Center + (Push >> Other.Rotation);
}

static function bool FitOnSurface(Actor Context, out vector Center, rotator Basis, float HalfWidth, float HalfHeight)
{
    local vector X, Y, Z, Start, Shift, Diagonal;
    local float Reach[2], Plus, Minus, Along, MaxShift;
    local int Pass, Axis, SY, SZ;
    GetAxes(Basis, X, Y, Z);
    Start = Center;
    Reach[0] = HalfWidth - EdgeInset;
    Reach[1] = HalfHeight - EdgeInset;
    MaxShift = Sqrt(Square(HalfWidth) + Square(HalfHeight));
    for (Pass = 0; Pass < MaxPasses; ++Pass)
    {
        Shift = vect(0,0,0);
        // Edges that cross a whole side: two corners on the same plane.
        for (Axis = 0; Axis < 2; ++Axis)
        {
            Plus = (1 - FreeFraction(Context, Center, X, Axis == 0 ? Y : Z, Reach[Axis])) * Reach[Axis];
            Minus = (1 - FreeFraction(Context, Center, X, Axis == 0 ? -Y : -Z, Reach[Axis])) * Reach[Axis];
            if (Plus > 0 && Minus > 0) return false; // Opposite edges: too small here.
            Along = Minus - Plus;
            if (Along != 0) Along += Along > 0 ? 1 : -1;
            Shift += (Axis == 0 ? Y : Z) * Along;
        }
        // Single corners: an outside corner or a notch.
        if (VSizeSq(Shift) == 0)
            for (SY = -1; SY <= 1; SY += 2)
                for (SZ = -1; SZ <= 1; SZ += 2)
                {
                    Diagonal = Y * (SY * Reach[0]) + Z * (SZ * Reach[1]);
                    Along = 1 - FreeFraction(Context, Center, X, Normal(Diagonal), VSize(Diagonal));
                    if (Along > 0) Shift -= Diagonal * (Along + 1 / VSize(Diagonal));
                }
        if (VSizeSq(Shift) == 0) return true;
        Center += Shift;
        if (VSize(Center - Start) > MaxShift) return false; // "adjusted too far"
    }
    return false;
}

static function SnapToFloor(Actor Context, out vector Center, rotator Basis, float HalfHeight)
{
    local vector X, Y, Z, Hit, HitNormal, Start;
    local float Drop;
    GetAxes(Basis, X, Y, Z);
    if (Z.Z <= 0.333) return;
    Start = Center + X * ObstructionLift;
    if (Context.Trace(Hit, HitNormal, Start - Z * (HalfHeight + FloorSnap), Start, false) == None) return;
    if (HitNormal.Z < 0.7) return;
    Drop = (Start - Hit) dot Z;
    if (Drop > HalfHeight - EdgeInset && Drop < HalfHeight + FloorSnap)
        Center -= Z * (Drop - HalfHeight - 0.5);
}

// Returns false for an invalid shot, which leaves both current portals alone.
static function bool FindPlacement(Actor Context, vector Start, vector Direction, VRPortal Other,
    float HalfWidth, float HalfHeight, out vector Center, out rotator Basis, optional int Depth,
    optional out string Reason)
{
    local Actor A;
    local vector Hit, N, TraceEnd, Refined, RefinedNormal;
    local VRPortal Through;
    local TraceHitInfo Info;
    Direction = Normal(Direction);
    if (Context == None || VSizeSq(Direction) < 0.5) return false;
    TraceEnd = Start + Direction * 20000;
    A = Context.Trace(Hit, N, TraceEnd, Start, true,, Info, class'Actor'.const.TRACEFLAG_Bullet);
    // Portal shots travel through open portals, as in Portal 2.
    Through = VRPortal(A);
    if (Through != None)
    {
        if (Depth >= 2 || Through.LinkedPortal == None) { Reason = "through-unlinked"; return false; }
        return FindPlacement(Context, Through.MapPointThrough(Hit), Through.MapDirection(Direction),
            Other, HalfWidth, HalfHeight, Center, Basis, Depth + 1, Reason);
    }
    if (A == None) { Reason = "no-hit"; return false; }
    if (!IsPortalable(A)) { Reason = "not-portalable:" $ A.Class; return false; }
    if ((N dot Direction) > -0.05) { Reason = "grazing"; return false; }
    // A long ray's contact is pulled back by 0.001 of its length; refine it.
    if (Context.Trace(Refined, RefinedNormal, Hit + Direction * 64, Hit - Direction * 64, false) != None
        && (RefinedNormal dot N) > 0.995)
    {
        Hit = Refined;
        N = RefinedNormal;
    }
    Basis = class'VRPortalMath'.static.MakeBasis(N, Direction);
    Center = BumpFromPortal(Hit, Basis, HalfWidth, HalfHeight, Other);
    if (!FitOnSurface(Context, Center, Basis, HalfWidth, HalfHeight)) { Reason = "no-fit:" $ A.Class $ "@" $ Hit; return false; }
    SnapToFloor(Context, Center, Basis, HalfHeight);
    if (OverlapsPortal(Center, Basis, HalfWidth, HalfHeight, Other)) { Reason = "overlap"; return false; }
    if (!FinalCheck(Context, Center, Basis, HalfWidth, HalfHeight)) { Reason = "final-check:" $ A.Class; return false; }
    return true;
}
