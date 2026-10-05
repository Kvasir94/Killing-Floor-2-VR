// Local, reversible assistance; all geometry is in the gun root's frame.
// No weapon, animation, ammunition or input side effects. The caller alone
// commits a completed insert and keeps stock timers authoritative.
//
// Once captured, a held part is AS2's magazine slider (MovableHandle, decoded
// 2026-10-02): its insertion is the hand's projection along the magwell from
// where it entered, clamped at both ends, and it locks the moment it reaches
// full depth (OnFullyClosedEvent). Pushing past the latch is full depth, so a
// slam seats it. Sideways drift and hand rotation do not matter once it is in
// (forceReleaseOnDistanceFromHandle=0); pulling it back out of the mouth does.
class VRReloadInsertGuide extends Object;

var bool bCaptured, bSettling, bFinished;
var float Progress, StartDistance, LastTime;
var vector LastPosition;
// Only cylindrical rounds may acquire across a skipped entry sample.
var bool bApproachSample;
var quat ApproachRotation;
var float SettleStarted, SettleDuration, SettleFrom;
var float AlignmentFraction, ReleaseFraction, CaptureDot;
// How far off the magwell axis a hand may wander (in snap radii) before the
// part is taken as pulled away rather than held in the slider.
var float BreakawayRadii;
// A round is a cylinder: only where its nose points matters, not how it is
// rolled in the fingers. AmmoAxis is its long axis in its own frame.
var bool bAxialOnly;
var vector AmmoAxis;

function Reset()
{
    bCaptured = false;
    bSettling = false;
    bFinished = false;
    Progress = 0;
    LastTime = 0;
    bApproachSample = false;
}

function float InsertFraction()
{
    return FClamp((Progress - AlignmentFraction) / (1 - AlignmentFraction), 0, 1);
}

function float RotationMatch(quat A, quat B)
{
    local float C;
    if (bAxialOnly && VSizeSq(AmmoAxis) > 0.5)
    {
        // The quaternion dot of the swing between the two axes, so the same
        // capture and retain thresholds apply with roll left free.
        C = FClamp(Normal(QuatRotateVector(A, AmmoAxis)) dot Normal(QuatRotateVector(B, AmmoAxis)), -1, 1);
        return Sqrt((1 + C) * 0.5);
    }
    return Abs(A.X*B.X + A.Y*B.Y + A.Z*B.Z + A.W*B.W);
}

// Call only with current, valid tracking. AuthoredQ is the stock orientation
// at the current insertion fraction, so a curved shell feed can turn naturally.
function Update(vector Position, quat Rotation, vector Entry, vector Seat,
    quat EntryQ, quat AuthoredQ, float Radius, float Tolerance, float Time,
    optional float LateralSlack)
{
    local vector Axis, Offset, Crossing;
    local float Remaining, Lateral, Match, DT, EntryDistance, PreviousRemaining, Fraction, CaptureRadius;
    local bool bAtEntry, bSweptEntry;
    if (bSettling || bFinished) return;
    Axis = Seat - Entry;
    if (VSize(Axis) < 0.1 || Radius <= 0 || Tolerance <= 0) { Reset(); return; }
    Axis = Normal(Axis);
    Offset = Seat - Position;
    Remaining = Offset dot Axis;
    Lateral = VSize(Offset - Axis * Remaining);
    // Magazine wells may admit a small sideways miss. Keep the entry depth,
    // angle, required push and post-capture breakaway limits unchanged.
    CaptureRadius = Radius + FMax(LateralSlack, 0);
    Match = FMax(RotationMatch(Rotation, EntryQ), RotationMatch(Rotation, AuthoredQ));
    if (!bCaptured)
    {
        // Acquire in front of the mouth, never through the receiver or at
        // the final pose. Require some real travel after acquisition.
        EntryDistance = VSize(Seat - Entry);
        bAtEntry = VSize(Position - Entry) <= 2 * Radius && Lateral <= CaptureRadius
            && Remaining >= EntryDistance - Tolerance
            && Remaining > Tolerance + 1 && Match >= CaptureDot;
        if (!bAtEntry && bAxialOnly && bApproachSample && Match >= CaptureDot
            && RotationMatch(ApproachRotation, EntryQ) >= CaptureDot
            && EntryDistance > Tolerance + 1 && Lateral <= Radius)
        {
            DT = Time - LastTime;
            PreviousRemaining = (Seat - LastPosition) dot Axis;
            // A valid inward segment must actually cross the mouth. Neither
            // starting behind it nor a tracking jump can acquire a shell.
            if (DT > 0 && DT <= 0.15
                && VSize(Position - LastPosition) <= FMax(12, 1000 * DT)
                && PreviousRemaining >= EntryDistance && Remaining < EntryDistance)
            {
                Fraction = (PreviousRemaining - EntryDistance) / (PreviousRemaining - Remaining);
                Crossing = LastPosition + (Position - LastPosition) * Fraction;
                bSweptEntry = VSize(Crossing - Entry) <= Radius;
            }
        }
        if (!bAtEntry && !bSweptEntry)
        {
            bApproachSample = bAxialOnly;
            ApproachRotation = Rotation;
            LastPosition = Position;
            LastTime = Time;
            return;
        }
        bCaptured = true;
        bApproachSample = false;
        Progress = 0;
        if (bAtEntry)
        {
            StartDistance = Remaining;
            LastPosition = Position;
            LastTime = Time;
            return;
        }
        // The entry plane is the start, and the rest of this same valid hand
        // segment is real insertion travel. The normal latch runs only once.
        StartDistance = EntryDistance;
    }
    DT = Time - LastTime;
    // Tracking reacquisition and large frame gaps cannot jump to the latch.
    if (DT <= 0 || DT > 0.15 || VSize(Position - LastPosition) > FMax(12, 1000 * DT))
    { Reset(); return; }
    LastPosition = Position;
    LastTime = Time;
    // The slider: the hand's projection along the magwell, clamped.
    Progress = FClamp((StartDistance - Remaining) / (StartDistance - Tolerance), 0, 1);
    // Out of the slider only by pulling back out of the mouth (with a little
    // hysteresis against capture/release ticks) or wandering far off axis.
    if (Remaining > StartDistance + Radius * 0.25 || Lateral > Radius * BreakawayRadii)
    { Reset(); return; }
    // Full depth locks it; past the latch is still full depth.
    bFinished = Progress >= 1;
}

// Letting go only helps AFTER alignment and a deliberate partial insertion.
// This is the one intentional timed advance, a short ease-out to the latch.
function bool Release(float Time)
{
    if (!bCaptured || bFinished || bSettling || InsertFraction() < ReleaseFraction) return false;
    bSettling = true;
    LastTime = Time;
    SettleStarted = Time;
    SettleFrom = Progress;
    SettleDuration = FClamp(0.25 * (1 - InsertFraction()), 0.04, 0.25);
    return true;
}

function AdvanceSettle(float Time)
{
    local float T;
    if (!bSettling) return;
    if (Time < LastTime || Time - LastTime > 0.15) { Reset(); return; }
    LastTime = Time;
    T = FClamp((Time - SettleStarted) / SettleDuration, 0, 1);
    Progress = SettleFrom + (1 - SettleFrom) * (1 - (1-T)*(1-T));
    bFinished = T >= 1;
    if (bFinished) bSettling = false;
}

defaultproperties
{
    AlignmentFraction=0.25
    ReleaseFraction=0.25
    CaptureDot=0.8433914
    BreakawayRadii=2
}
