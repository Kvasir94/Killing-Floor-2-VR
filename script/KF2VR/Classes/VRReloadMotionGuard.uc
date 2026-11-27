// Tracking continuity only. Callers supply the hand in the gun root's frame
// and retain ownership of stroke progress, haptics and stock ammunition.
class VRReloadMotionGuard extends Object;

var bool bReady;
var vector LastPosition;
var float LastTime, SpeedLimit, PositionSlack, MaxGap;

static function bool ValidPosition(vector Position)
{
    // Physical coordinates are bounded as well as finite, avoiding overflow
    // in the distance calculation. This matches other tracked-contact guards.
    return Position.X == Position.X && Position.Y == Position.Y && Position.Z == Position.Z
        && Abs(Position.X) < 100000000 && Abs(Position.Y) < 100000000 && Abs(Position.Z) < 100000000;
}

// How far a gun tipped between two world orientations, ignoring turns about
// the vertical (R69: a snap or smooth turn is not a tilt or a discontinuity):
// the larger change in elevation of its forward and right axes, in radians.
static function float TiltStep(quat A, quat B)
{
    local vector FA, FB, RA, RB;
    FA = QuatRotateVector(A, vect(1,0,0)); FB = QuatRotateVector(B, vect(1,0,0));
    RA = QuatRotateVector(A, vect(0,1,0)); RB = QuatRotateVector(B, vect(0,1,0));
    return FMax(Abs(Asin(FClamp(FA.Z, -1, 1)) - Asin(FClamp(FB.Z, -1, 1))),
        Abs(Asin(FClamp(RA.Z, -1, 1)) - Asin(FClamp(RB.Z, -1, 1))));
}

static function bool ValidTime(float Time)
{
    return Time == Time && Time >= 0 && Time < 100000000;
}

function Reset()
{
    bReady = false;
    LastPosition = vect(0,0,0);
    LastTime = 0;
}

function bool Begin(vector Position, float Time)
{
    Reset();
    if (!ValidPosition(Position) || !ValidTime(Time)
        || !(SpeedLimit > 0 && SpeedLimit < 100000000)
        || !(PositionSlack >= 0 && PositionSlack < 100000000)
        || !(MaxGap > 0 && MaxGap <= 0.15)) return false;
    LastPosition = Position;
    LastTime = Time;
    bReady = true;
    return true;
}

function bool Check(vector Position, float Time)
{
    local float DT;
    if (!bReady) return false;
    DT = Time - LastTime;
    if (!ValidPosition(Position) || !ValidTime(Time) || DT < 0 || DT > MaxGap
        || (DT == 0 && Position != LastPosition)
        || !(VSize(Position - LastPosition) <= PositionSlack + SpeedLimit * DT))
    {
        Reset();
        return false;
    }
    LastPosition = Position;
    LastTime = Time;
    return true;
}

defaultproperties
{
    // Initial tuning, not headset acceptance. The slack permits small noise
    // while the speed term allows a fast intentional stroke at VR frame rates.
    SpeedLimit=400
    PositionSlack=2
    MaxGap=0.15
}
