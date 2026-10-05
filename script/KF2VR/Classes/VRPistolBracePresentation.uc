// Visual-only presentation of a pistol's bracing hand. The support glove is a
// bone-attached hand copy posed by KF2's flat-screen support grip, whose
// forearm runs back toward where the desktop camera sat. With the long left
// bracer that forearm crowds the headset view. Swing the rendered glove about
// its knuckles until the forearm clears the line to the eyes. Aim, the tracked
// support contact and the ammunition/fire state are untouched; only the drawn
// hand (and the watch that rides it) moves.
class VRPistolBracePresentation extends Object;

// Degrees the forearm must be swung (0 when it already clears the eyes).
// Forearm points from the wrist toward the elbow; ToHead from the knuckle
// pivot toward the head. Both need not be normalised.
static function float TargetCorrection(vector Forearm, vector ToHead, float Clearance, float MaxCorrection)
{
    local float Angle;
    if (VSize(Forearm) < 0.001 || VSize(ToHead) < 0.001) return 0;
    Angle = Acos(FClamp(Normal(Forearm) dot Normal(ToHead), -1, 1)) * 180.0 / Pi;
    return FClamp(Clearance - Angle, 0, FMax(MaxCorrection, 0));
}

// Rotating the forearm about this world axis moves it away from the head. A
// forearm pointing straight at the eyes swings down.
static function vector CorrectionAxis(vector Forearm, vector ToHead)
{
    local vector Axis;
    Axis = Normal(ToHead) cross Normal(Forearm);
    if (VSize(Axis) < 0.05) Axis = Normal(ToHead) cross vect(0,0,-1);
    if (VSize(Axis) < 0.05) Axis = vect(0,1,0);
    return Normal(Axis);
}

// Rotation (and matching translation) for the attached component's own
// transform, in its attachment frame, that turns the drawn hand by Degrees
// about WorldAxis through LocalPivot. FrameQ maps that frame to world.
static function SolveOffset(quat FrameQ, vector WorldAxis, float Degrees, vector LocalPivot,
    out quat OffsetQ, out vector OffsetT)
{
    OffsetQ = QuatFromAxisAndAngle(QuatRotateVector(QuatInvert(FrameQ), WorldAxis), Degrees * Pi / 180.0);
    OffsetT = LocalPivot - QuatRotateVector(OffsetQ, LocalPivot);
}
