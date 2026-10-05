// Holds one physics body at a hand: position and orientation. Shared by the
// local grab (VRZedGrab) and the server's authoritative copy of it, so both
// ends move a held body the same way.
//
// The held body is made kinematic and placed at the hand every tick; the rest
// of the ragdoll hangs off it through its own joints. Measured
// the alternatives on a real knocked-down Zed: an RB_Handle or a bone spring
// of any stiffness (10k to 1M) left it 150+ UU from the hand, because a
// knocked-down Zed's ragdoll does not answer a spring at all, while the
// kinematic hold sat within 0.001 UU and 0 degrees through a hold, a turn and
// a 470 UU/s swing. That is the "snaps to the hand at near-perfect strength"
// the grab is meant to be.
//
// The grip frame is captured once, when the hand closes: where the body sits
// relative to the hand, and how it is turned relative to it. From then on the
// body is placed in that frame every tick, so it stays in the hand and turns
// with the wrist as if actually gripped.
class VRBodyHold extends Object abstract;

// Longest distance the body's centre may sit from the palm. A head or torso
// held at the surface keeps its centre a little ahead of the hand; anything
// farther snaps in to this.
var float GripReach;
// Seconds over which a newly gripped body is brought from where it lay into
// the hand. Short enough to read as a snap, long enough that the ragdoll
// hanging off it is dragged rather than yanked apart in a single tick.
var float CatchTime;

static function RB_BodyInstance BodyFor(PrimitiveComponent Component, name BoneName)
{
    if (Component == None) return None;
    if (SkeletalMeshComponent(Component) != None)
        return SkeletalMeshComponent(Component).FindBodyInstanceNamed(BoneName);
    return Component.BodyInstance;
}

static function bool FiniteVector(vector V)
{
    return V.X == V.X && V.Y == V.Y && V.Z == V.Z
        && Abs(V.X) < 100000000 && Abs(V.Y) < 100000000 && Abs(V.Z) < 100000000;
}

// Record where the body sits in the hand's frame at the moment of the grab.
static function bool Capture(RB_BodyInstance Body, vector HandLocation, rotator HandRotation,
    out vector OffsetLocal, out Quat RelativeQuat)
{
    local matrix BodyTM;
    local vector Offset;
    local Quat HandQuat, InverseHand;
    if (Body == None || !Body.IsValidBodyInstance()) return false;
    BodyTM = Body.GetUnrealWorldTM();
    Offset = MatrixGetOrigin(BodyTM) - HandLocation;
    if (!FiniteVector(Offset)) return false;
    if (VSize(Offset) > default.GripReach) Offset = Normal(Offset) * default.GripReach;
    HandQuat = QuatFromRotator(HandRotation);
    InverseHand = QuatInvert(HandQuat);
    OffsetLocal = QuatRotateVector(InverseHand, Offset);
    RelativeQuat = QuatProduct(InverseHand, QuatFromRotator(MatrixGetRotator(BodyTM)));
    return true;
}

static function matrix TargetFor(vector HandLocation, rotator HandRotation, vector OffsetLocal, Quat RelativeQuat)
{
    local Quat HandQuat;
    HandQuat = QuatFromRotator(HandRotation);
    return MakeRotationTranslationMatrix(HandLocation + QuatRotateVector(HandQuat, OffsetLocal),
        QuatToRotator(QuatProduct(HandQuat, RelativeQuat)));
}

// Where the body was blended toward where the hand wants it. Alpha 0 is the
// body's own frame when gripped, 1 the hand's.
static function matrix Blend(matrix From, matrix To, float Alpha)
{
    local vector Location;
    local Quat Rotation;
    Alpha = FClamp(Alpha, 0, 1);
    Location = MatrixGetOrigin(From) + (MatrixGetOrigin(To) - MatrixGetOrigin(From)) * Alpha;
    Rotation = QuatSlerp(QuatFromRotator(MatrixGetRotator(From)), QuatFromRotator(MatrixGetRotator(To)), Alpha, true);
    return MakeRotationTranslationMatrix(Location, QuatToRotator(Rotation));
}

static function Begin(RB_BodyInstance Body, optional PrimitiveComponent Component)
{
    // A fixed grab bone belongs to the hand, not the animation updater.
    // The grab owner snapshots this mesh flag and restores on final release.
    if (SkeletalMeshComponent(Component) != None)
        SkeletalMeshComponent(Component).bUpdateKinematicBonesFromAnimation = false;
    if (Body != None && Body.IsValidBodyInstance()) Body.SetFixed(true);
}

static function Move(PrimitiveComponent Component, name BoneName, matrix Target)
{
    if (Component == None) return;
    Component.SetRBPosition(MatrixGetOrigin(Target), BoneName);
    Component.SetRBRotation(MatrixGetRotator(Target), BoneName);
    Component.WakeRigidBody(BoneName);
}

// Let go. With a throw velocity the whole body leaves at the hand's speed;
// without one it keeps whatever the solver gave it.
static function End(RB_BodyInstance Body, PrimitiveComponent Component, optional vector ThrowVelocity)
{
    if (Body != None && Body.IsValidBodyInstance()) Body.SetFixed(false);
    if (Component == None) return;
    if (!IsZero(ThrowVelocity)) Component.SetRBLinearVelocity(ThrowVelocity, false);
    Component.WakeRigidBody();
}

// Distance and angle between a body and the frame it is being driven to.
static function float PositionError(RB_BodyInstance Body, matrix Target)
{
    if (Body == None || !Body.IsValidBodyInstance()) return 100000;
    return VSize(MatrixGetOrigin(Body.GetUnrealWorldTM()) - MatrixGetOrigin(Target));
}

static function float AngleErrorDegrees(RB_BodyInstance Body, matrix Target)
{
    local Quat A, B;
    local float D;
    if (Body == None || !Body.IsValidBodyInstance()) return 180;
    A = QuatFromRotator(MatrixGetRotator(Body.GetUnrealWorldTM()));
    B = QuatFromRotator(MatrixGetRotator(Target));
    D = Abs(A.X * B.X + A.Y * B.Y + A.Z * B.Z + A.W * B.W);
    return 2.0 * Acos(FMin(D, 1.0)) * 57.2958;
}

defaultproperties
{
    GripReach=12.0
    CatchTime=0.15
}
