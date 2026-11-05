// Support-only manual pump receiver inertia; endpoint ownership stays in VRManualPump.
// Positions/pull are UU, velocities UU/s and forces below UU/s^2 (mass-normalized).
// RoomPosition must exclude pawn translation/yaw; RoomBore is in that SAME frame.
// Reset is the only explicit rebase. Invalid tracking resets pull to zero.
// The owner keeps chamber debt and owns rear/forward events, sounds and payment:
// never award a crossing while bContinuous is false, including the two prime samples.
class VRPumpInertia extends Object;

var bool bContinuous, bInvalidated;
var float CurrentPull, SlideVelocity;
var vector LastPosition, LastHandVelocity, FilteredHandAcceleration;
var quat LastRotation;
var float LastTime, LastVelocityInterval;
var int PrimeSamples, LastCalibrationEpoch, HandDirection;
// Actual directed hand travel bounds the inertial receiver motion. A brief
// acceleration spike cannot spend the rest of a stroke while the hand rests.
var float StrokeStartPull, StrokeDistance;
// Modest leverage for the support-only stroke: receiver travel still reaches
// the full stops, without requiring the hand to reproduce every last UU.
var float DirectedTravelGain;

// Deliberately exaggerated hand acceleration, with static preload strong enough
// that ordinary gravity alone cannot unlock a stationary action.
var float AccelerationGain, StaticFriction, DynamicFriction, Damping;
var float AccelerationFilterSeconds, FullStrokeSeconds, IntegrationStepSeconds;
var float RestVelocityTolerance;
// These match the adjacent physical-action continuity conventions.
var float MaxGap, PositionSpeedLimit, PositionSlack, MaxRotationStep, MaxAngularSpeed;
var float MinSampleSeconds;

static function bool FiniteFloat(float Value)
{
    return Value == Value && Abs(Value) < 100000000;
}

static function bool FiniteVector(vector Value)
{
    return FiniteFloat(Value.X) && FiniteFloat(Value.Y) && FiniteFloat(Value.Z);
}

static function bool UnitQuaternion(quat Q)
{
    local float SizeSquared;
    if (!FiniteFloat(Q.X) || !FiniteFloat(Q.Y) || !FiniteFloat(Q.Z) || !FiniteFloat(Q.W)) return false;
    SizeSquared = Q.X*Q.X + Q.Y*Q.Y + Q.Z*Q.Z + Q.W*Q.W;
    return Abs(SizeSquared - 1) < 0.02;
}

function bool SettingsValid()
{
    return FiniteFloat(AccelerationGain) && AccelerationGain >= 0
        && FiniteFloat(DirectedTravelGain) && DirectedTravelGain >= 1 && DirectedTravelGain <= 2
        && FiniteFloat(StaticFriction) && StaticFriction >= 0
        && FiniteFloat(DynamicFriction) && DynamicFriction >= 0 && DynamicFriction <= StaticFriction
        && FiniteFloat(Damping) && Damping >= 0
        && AccelerationFilterSeconds > 0 && AccelerationFilterSeconds <= 1
        && FullStrokeSeconds > 0 && FullStrokeSeconds <= 10
        && IntegrationStepSeconds >= 0.001 && IntegrationStepSeconds <= 0.01
        && RestVelocityTolerance >= 0 && RestVelocityTolerance <= 1
        && MaxGap > 0 && MaxGap <= 0.15
        && FiniteFloat(PositionSpeedLimit) && PositionSpeedLimit > 0
        && FiniteFloat(PositionSlack) && PositionSlack >= 0
        && MaxRotationStep > 0 && MaxRotationStep <= Pi
        && FiniteFloat(MaxAngularSpeed) && MaxAngularSpeed > 0
        && MinSampleSeconds >= 0.0001 && MinSampleSeconds <= 0.01;
}

function Reset(float Pull)
{
    CurrentPull = (FiniteFloat(Pull) && Pull >= 0) ? Pull : 0.0;
    SlideVelocity = 0;
    LastPosition = vect(0,0,0);
    LastHandVelocity = vect(0,0,0);
    FilteredHandAcceleration = vect(0,0,0);
    LastRotation = QuatFromRotator(rot(0,0,0));
    LastTime = 0;
    LastVelocityInterval = 0;
    LastCalibrationEpoch = 0;
    PrimeSamples = 0;
    HandDirection = 0;
    StrokeStartPull = CurrentPull;
    StrokeDistance = 0;
    bContinuous = false;
    bInvalidated = false;
}

function float Invalidate()
{
    Reset(0);
    bInvalidated = true;
    return CurrentPull;
}

function float Step(vector RoomPosition, quat RoomRotation, vector RoomBore,
    float Time, int CalibrationEpoch, float Travel, float GravityZ)
{
    local float DT, Angle, BoreSizeSquared;
    local float AxialSpeed, AxialTravel;
    local int Direction;
    local vector PositionDelta, RotationVector, HandVelocity;
    local quat RotationDelta;

    if (!SettingsValid() || !FiniteVector(RoomPosition) || !UnitQuaternion(RoomRotation)
        || !FiniteVector(RoomBore) || !FiniteFloat(Time) || Time < 0 || CalibrationEpoch < 0
        || !FiniteFloat(Travel) || Travel <= 0.001 || !FiniteFloat(GravityZ)
        || !FiniteFloat(CurrentPull) || !FiniteFloat(SlideVelocity)) return Invalidate();
    BoreSizeSquared = VSizeSq(RoomBore);
    if (!(BoreSizeSquared >= 0.5 && BoreSizeSquared <= 1.5)) return Invalidate();
    RoomBore = Normal(RoomBore);
    CurrentPull = FClamp(CurrentPull, 0, Travel);

    if (PrimeSamples == 0)
    {
        LastPosition = RoomPosition;
        LastRotation = RoomRotation;
        LastTime = Time;
        LastCalibrationEpoch = CalibrationEpoch;
        PrimeSamples = 1;
        bContinuous = false;
        return CurrentPull;
    }

    DT = Time - LastTime;
    if (CalibrationEpoch != LastCalibrationEpoch || !FiniteFloat(DT) || DT < 0 || DT > MaxGap)
        return Invalidate();
    PositionDelta = RoomPosition - LastPosition;
    RotationDelta = QuatProduct(RoomRotation, QuatInvert(LastRotation));
    RotationVector.X = RotationDelta.X;
    RotationVector.Y = RotationDelta.Y;
    RotationVector.Z = RotationDelta.Z;
    Angle = 2 * Atan2(VSize(RotationVector), Abs(RotationDelta.W));
    if (!FiniteFloat(Angle)) return Invalidate();
    // A repeated presentation evaluation is not a second simulation sample.
    // Preserve an already continuous result only for the same physical pose.
    if (DT == 0)
    {
        if (RoomPosition != LastPosition || Angle > 0.0001) return Invalidate();
        return CurrentPull;
    }
    if (!(VSize(PositionDelta) <= PositionSlack + PositionSpeedLimit * DT)
        || !(Angle <= MaxRotationStep && Angle <= MaxAngularSpeed * DT)) return Invalidate();
    // Do not divide near-zero time into acceleration. Keep the previous sample
    // so the next accepted update still spans the complete physical interval.
    if (DT < MinSampleSeconds) return CurrentPull;

    HandVelocity = PositionDelta / DT;
    if (!FiniteVector(HandVelocity)) return Invalidate();
    // Hand braking may reverse acceleration before it reverses travel. Keep
    // braking/friction, but do not let that reverse the receiver by itself.
    // A small stroke-scaled speed threshold ignores stationary tracking jitter;
    // remember the deliberate direction through the pause between strokes.
    AxialSpeed = HandVelocity dot RoomBore;
    if (Abs(AxialSpeed) > Travel * 0.5)
    {
        Direction = AxialSpeed < 0 ? 1 : -1;
        if (Direction != HandDirection)
        {
            HandDirection = Direction;
            StrokeStartPull = CurrentPull;
            StrokeDistance = 0;
        }
    }
    AxialTravel = -(PositionDelta dot RoomBore) * HandDirection * DirectedTravelGain;
    StrokeDistance = FClamp(StrokeDistance + AxialTravel, 0, Travel);
    if (PrimeSamples == 1)
    {
        LastPosition = RoomPosition;
        LastRotation = RoomRotation;
        LastTime = Time;
        LastHandVelocity = HandVelocity;
        LastVelocityInterval = DT;
        PrimeSamples = 2;
        bContinuous = false;
        return CurrentPull;
    }

    LastPosition = RoomPosition;
    LastRotation = RoomRotation;
    LastTime = Time;
    LastHandVelocity = HandVelocity;
    LastVelocityInterval = DT;
    bContinuous = true;
    bInvalidated = false;
    // The held fore-end drives the receiver directly along the bore. Friction
    // and acceleration filtering previously made a slow forward return stall
    // and made the same stroke depend on the gun's angle to gravity. Retain
    // continuity validation and directed travel, without waiting for inertia.
    if (HandDirection != 0)
        CurrentPull = FClamp(StrokeStartPull + HandDirection * StrokeDistance, 0, Travel);
    SlideVelocity = 0;
    if (!FiniteFloat(CurrentPull) || !FiniteFloat(SlideVelocity)) return Invalidate();
    return CurrentPull;
}

defaultproperties
{
    AccelerationGain=2.5
    DirectedTravelGain=1.25
    StaticFriction=1800.0
    DynamicFriction=600.0
    Damping=14.0
    AccelerationFilterSeconds=0.030
    FullStrokeSeconds=0.09
    IntegrationStepSeconds=0.004
    RestVelocityTolerance=0.01
    MaxGap=0.1
    PositionSpeedLimit=1500.0
    PositionSlack=2.0
    MaxRotationStep=0.35
    MaxAngularSpeed=12.0
    MinSampleSeconds=0.001
}
