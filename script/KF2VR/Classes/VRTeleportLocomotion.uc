// Comfort locomotion. Aims a parabolic arc from the movement hand, validates a
// destination the player could have walked to, and relocates behind a short
// fade. Every gate the physical room-movement path already applies is applied
// here too, because a teleport is the same transaction with a larger delta:
// stock walking physics, special moves and the server still own the body.
//
// Reachability is not re-derived. KF2 already teleports zeds onto valid floor
// through NavigationPoint.IsUsableAnchorFor, so a destination is accepted only
// where the game's own walkable graph says a pawn of this size can stand. That
// is both the "somewhere you could normally walk" rule and the anti-cheese
// rule: anywhere the player can reach, the zeds can path to.
class VRTeleportLocomotion extends Object;

var VRDualHandInput Input;
var VRHandsBridge Bridge;
var VRTeleportArc Arc;

// Aiming state. Destination is a capsule centre, already fitted and settled.
var bool bAiming, bValid, bWasValid, bRefusedPulsed, bArrivalPending;
var vector Destination;
var float AimDistance;
// Yaw of the arc toward the destination, and the stick's last firm direction
// relative to it; together they are the arrival facing when that is enabled.
var int ArcYaw, FacingOffset;
var bool bFacingSet;
// A release inside the last moments of the recharge is held, not dropped.
var bool bBuffered;
var int BufferedHand;
var vector BufferedDestination;
var float BufferedDistance;
var int BufferedFacingYaw;
var bool bBufferedFacing;
// The facing the committed hop will apply at the bottom of the fade.
var int PendingFacingYaw;
var bool bPendingFacing;

// Commit state. Phase 1 fades out, 2 waits for a deferred (network) relocation,
// 3 fades in. ReadyTime is the real-time stamp the next aim may commit at.
var int Phase;
var float PhaseStarted, PhaseLength, ReadyTime, ArriveDeadline;
var int Refusals;
var vector PendingDestination;
// The hop's own length, held for the whole commit. Cancel() clears the aiming
// preview on the same frame the commit starts, so cooldown and fade must not
// read AimDistance afterwards or every hop bills as the minimum.
var float CommittedDistance;
var float Blink;

// 48 samples at 0.05 s covers the longest flight (a 30 degree launch to full
// range is about 1.4 s, plus a drop to a lower floor) with room to spare.
const ARC_SAMPLES = 48;
const ARC_STEP = 0.05;
// Fallback launch speed squared over |gravity|, as a multiple of range, used
// only if the aimed-distance solve below ever has no positive solution.
const ARC_REACH = 4.0;
// Pitch chooses distance. Effective pitch (grip pitch plus TeleportAimPitch)
// maps onto the horizontal distance the arc is solved to land at on the
// player's own floor level: NEAR_PITCH and below is a NEAR_DISTANCE step,
// FAR_PITCH and above is full range, and a smoothstep joins them, so there is
// no pitch at which the landing jumps. A level hand lands at about 69 % of
// range (12 m at the 1800 default), which is what makes the default hop a
// deliberate reposition instead of a shuffle.
const NEAR_PITCH = -40.0;
const FAR_PITCH = 25.0;
const NEAR_DISTANCE = 96.0;
// The drawn launch angle follows the hand between a floor and a ceiling, in
// degrees. The floor is ARC_MIN_BEND above the straight line from the hand to
// the aimed spot, which keeps a visible curve and guarantees the speed solve;
// the ceiling keeps a full-range arc's apex near 3.4 m above the floor.
const ARC_MAX_LAUNCH = 30.0;
const ARC_MIN_BEND = 6.0;
// A lofted arc that strikes an underside (normal pointing down) is re-thrown
// flat once, so a raised hand indoors slides under the ceiling to the aimed
// distance instead of dropping at the ceiling contact.
const CEILING_NORMAL_Z = -0.3;
// Range is cut this far inside the limit, measured from the body, so the cut
// point never fails ValidateSpot's own range test by a few units.
const RANGE_MARGIN = 16;
// A refused landing slides back along the drawn flight to the farthest spot
// that validates: at most SLIDE_PROBES coarse probes no closer together than
// SLIDE_MIN_STEP, then SLIDE_REFINE halvings toward the refused end. Nothing
// lands nearer the body than BACKTRACK_MIN.
const SLIDE_PROBES = 16;
const SLIDE_MIN_STEP = 40.0;
const SLIDE_REFINE = 3;
const BACKTRACK_MIN = 64;
// TraceArc outcomes.
const ARC_DROPPED = 0;
const ARC_HIT = 1;
const ARC_RANGE = 2;
// A release this close to the end of the recharge is buffered and fires then.
const BUFFER_SECONDS = 0.3;
// Stick deflection that sets arrival facing; the return to centre passes
// through weaker angles and must not overwrite it.
const FACING_DEFLECTION = 0.6;

function Initialize(VRDualHandInput Owner)
{
    Input = Owner;
    Bridge = Owner.Bridge;
}

function Shutdown()
{
    Cancel();
    if (Arc != None) { Arc.Release(); Arc = None; }
}

function Cancel()
{
    bAiming = false;
    bValid = false;
    bWasValid = false;
    bRefusedPulsed = false;
    bFacingSet = false;
    AimDistance = 0;
    if (Arc != None) Arc.Hide();
}

function ClearBuffer()
{
    bBuffered = false;
    BufferedDestination = vect(0,0,0);
}

// Abandons a commit that can no longer land: the body died, was grabbed or was
// replaced inside the fade. The fade is dropped rather than held, because a
// black screen the player cannot end is worse than an abrupt return.
function AbortCommit()
{
    Phase = 0;
    Blink = 0;
    bArrivalPending = false;
    bPendingFacing = false;
    PendingDestination = vect(0,0,0);
    PublishBlink();
}

function bool ModeActive()
{
    return Bridge != None && Bridge.LocomotionMode == 1;
}

function float Now()
{
    return Bridge.WorldInfo.RealTimeSeconds;
}

function Pulse(int Hand, bool bAccepted)
{
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (1 << Hand);
    Bridge.NativeHapticStrength = bAccepted ? 0.22 : 0.08;
    Bridge.NativeHapticDuration = bAccepted ? 0.03 : 0.08;
}

function Update(float RealDelta)
{
    local int Hand;
    local float X, Y, Magnitude;
    local bool bAllowed, bReady;

    if (Bridge == None) return;
    TryArrivalSound();
    if (!ModeActive())
    {
        if (Phase != 0) AbortCommit();
        ClearBuffer();
        Cancel();
        return;
    }
    // Teleport mode never drives the stock movement axes. Cleared here rather
    // than in the caller so a mid-frame mode change cannot leak a stick sample.
    Bridge.NativeMoveX = 0;
    Bridge.NativeMoveY = 0;
    Input.EndSprint();

    AdvanceCommit(RealDelta);
    if (Phase != 0) { Cancel(); return; }

    Hand = Clamp(Bridge.MovementHand, 0, 1);
    if (!Input.ContextValid()) { ClearBuffer(); Cancel(); return; }
    if (bBuffered && FireBuffered()) { Cancel(); return; }
    X = Hand == 0 ? Bridge.LeftStickX : Bridge.RightStickX;
    Y = Hand == 0 ? Bridge.LeftStickY : Bridge.RightStickY;
    if ((Bridge.NativeValidMask & Bridge.NativeStickActiveMask & (1 << Hand)) == 0
        || X != X || Y != Y || Abs(X) > 1 || Abs(Y) > 1)
    { Cancel(); return; }
    Magnitude = Sqrt(X*X + Y*Y);

    // Stick click puts the arc away. It has no sprint meaning in this mode, so
    // it is the one free control for cancelling without committing.
    if ((Bridge.NativeStickClickActiveMask & Bridge.NativeStickClickMask & (1 << Hand)) != 0)
    {
        ClearBuffer();
        if (bAiming) Cancel();
        return;
    }

    bAllowed = class'VRTeleportLocomotion'.static.BodyReady(Bridge.Human);
    bReady = Now() >= ReadyTime;
    if (Magnitude > 0.12)
    {
        // Re-aiming replaces anything held from the previous release.
        ClearBuffer();
        if (!bAiming)
        {
            bAiming = true;
            bWasValid = false;
            bRefusedPulsed = false;
            bFacingSet = false;
        }
        // Only a firm deflection sets facing; the stick passes through weaker
        // angles on its way back to centre and those must not overwrite it.
        if (Magnitude >= FACING_DEFLECTION)
        {
            FacingOffset = int(Atan2(X, Y) * 32768.0 / Pi);
            bFacingSet = true;
        }
        // The arc is traced during the recharge too, so the player can line up
        // the next hop instead of staring at a grey stub. It is tinted as
        // charging rather than invalid, because the spot itself is fine.
        if (bAllowed) AimArc(Hand, !bReady);
        else
        {
            // A refused arc is still drawn. Silently dropping the input while
            // a Clot has hold of the player reads as lost tracking rather than
            // as the game saying no.
            ShowRefused();
            if (!bRefusedPulsed) { bRefusedPulsed = true; Pulse(Hand, false); }
        }
        if (bValid && bReady && !bWasValid) Pulse(Hand, true);
        bWasValid = bValid && bReady;
        return;
    }
    // Returning to centre releases. A valid destination commits; anything else
    // simply puts the arc away, so a cancelled aim costs nothing. A release in
    // the last moments of the recharge is held and fires when it ends.
    if (bAiming)
    {
        if (bValid && bAllowed)
        {
            if (bReady) BeginCommit(Hand, Destination, AimDistance, ArrivalYaw(), WantsFacing());
            else if (ReadyTime - Now() <= BUFFER_SECONDS)
            {
                bBuffered = true;
                BufferedHand = Hand;
                BufferedDestination = Destination;
                BufferedDistance = AimDistance;
                BufferedFacingYaw = ArrivalYaw();
                bBufferedFacing = WantsFacing();
            }
        }
        Cancel();
    }
}

function bool WantsFacing()
{
    return Bridge.bTeleportArrivalFacing && bFacingSet;
}

function int ArrivalYaw()
{
    return (ArcYaw + FacingOffset) & 65535;
}

// Fires a held release once the recharge ends. The world may have moved in the
// meantime, so the spot is validated again rather than trusted.
function bool FireBuffered()
{
    local vector Spot;
    local string Reason;
    if (Now() < ReadyTime) return false;
    Spot = BufferedDestination;
    ClearBuffer();
    if (!class'VRTeleportLocomotion'.static.ValidateSpot(Bridge.Human, Spot,
        Bridge.TeleportRange, Bridge.TeleportAscentLimit, Bridge.TeleportDescentLimit,
        Bridge.TeleportNavRadius, Reason))
    {
        Pulse(BufferedHand, false);
        return false;
    }
    BeginCommit(BufferedHand, Spot, VSize(Spot - Bridge.Human.Location),
        BufferedFacingYaw, bBufferedFacing);
    return true;
}

// ---------------------------------------------------------------- aiming

// Traces the arc, resolves a landing, and draws the result. The arc is built
// as a list of points first and drawn afterwards, because a refused landing
// slides back along it and the drawn arc has to end where the marker does.
//
// Pitch picks a distance (DesiredDistance) and the curve is solved to land
// there on the player's own floor level, so raising the hand moves the marker
// smoothly outward to full range and lowering it brings the marker in. The old
// arc solved every raised pitch to the range cap and every lowered one to a
// fixed speed, which put a cliff at about -3 degrees: a relaxed, slightly low
// grip landed 3-9 m away and a hair higher threw the full 18 m into the first
// wall or ceiling.
//
// Nothing the arc touches is a dead end on its own: a floor lands, a wall or
// the range circle resolves the floor beneath, and a ceiling re-throws the arc
// flat. Only when that landing fails validation does it slide back along the
// flight to the farthest spot that validates, so aiming past a ledge, into a
// pit or into clutter lands as far as is legal instead of refusing the aim.
function AimArc(int Hand, bool bCharging)
{
    local vector Origin, HitLocation, HitNormal, Body;
    local vector Land, LandNormal, Probe, Floor, FloorNormal, Candidate;
    local array<vector> Path, Landed;
    local rotator Aim, Launch;
    local float Height, Radius, Reach, DropLength, AimPitch, LaunchPitch, FlatPitch, Travel, FootZ;
    local int I, Outcome;
    local bool bLanded, bResolved, bArtificialDrop;

    bValid = false;
    Height = Bridge.Human.GetCollisionHeight();
    Radius = Bridge.Human.GetCollisionRadius();
    if (Height <= 0 || Radius <= 0) { ShowRefused(); return; }

    Aim = Normalize(Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    AimPitch = float(Aim.Pitch) * 360.0 / 65536.0 + Bridge.TeleportAimPitch;
    Origin = Bridge.Hands[Hand].Position;
    Body = Bridge.Human.Location;
    FootZ = Body.Z - Height;
    // Range belongs to the body, as ValidateSpot measures it. Measuring from
    // the hand let an outstretched arm or a room-scale offset carry the cut
    // point past the limit, so aiming as far as possible was refused.
    Reach = FMax(Bridge.TeleportRange - RANGE_MARGIN, 50);
    DropLength = Bridge.TeleportDescentLimit + Height + 100;
    Travel = AimTravel(Aim.Yaw, Origin, Body, Reach, DesiredDistance(AimPitch, Reach));

    // The launch follows the hand between a floor that keeps the solve
    // positive and a ceiling that keeps a long arc under typical interiors.
    FlatPitch = FloorPitch(-FMax(Origin.Z - FootZ, 40), FMax(Travel, NEAR_DISTANCE));
    LaunchPitch = FClamp(AimPitch, FlatPitch, FMax(ARC_MAX_LAUNCH, FlatPitch));
    Launch.Yaw = Aim.Yaw;
    Launch.Pitch = int(LaunchPitch * 65536.0 / 360.0);

    if (Arc == None)
    {
        Arc = new(Bridge) class'VRTeleportArc';
        Arc.Initialize(Bridge);
    }

    Outcome = TraceArc(Launch, Origin, Body, FootZ, Travel, Reach, DropLength, Path, HitLocation, HitNormal);
    if (Outcome == ARC_HIT && HitNormal.Z < CEILING_NORMAL_Z && LaunchPitch > FlatPitch + 1)
    {
        Launch.Pitch = int(FlatPitch * 65536.0 / 360.0);
        Outcome = TraceArc(Launch, Origin, Body, FootZ, Travel, Reach, DropLength, Path, HitLocation, HitNormal);
    }

    if (Outcome == ARC_HIT && HitNormal.Z >= Bridge.Human.WalkableFloorZ)
    {
        Land = HitLocation;
        bLanded = true;
    }
    else
    {
        // A wall, a ceiling or the range circle may still identify a legal
        // floor below. Do not append this provisional vertical drop: a
        // resolved candidate is rebuilt as a collision-checked continuous
        // parabola before drawing.
        Probe = Path[Path.Length - 1];
        if (Outcome == ARC_HIT)
        {
            Probe = HitLocation + HitNormal * (Radius + 4);
            if (Bridge.Human.Trace(Land, LandNormal, Probe, HitLocation + HitNormal, false) != None)
                Probe = Land + LandNormal * 2;
        }
        if (Bridge.Human.Trace(Land, LandNormal, Probe - vect(0,0,1) * DropLength, Probe, false) != None
            && LandNormal.Z >= Bridge.Human.WalkableFloorZ)
        {
            bLanded = true;
            bArtificialDrop = true;
        }
    }
    if (bLanded) bResolved = TryLand(Land, Floor, FloorNormal, Candidate);

    // Every displayed segment must be a segment the final trajectory follows.
    // A vertical floor lookup is rebuilt from the hand to the fitted floor.
    if (bResolved && bArtificialDrop)
    {
        bResolved = RebuildPathToFloor(Launch, Origin, Floor, Landed);
        if (bResolved) Path = Landed;
    }
    // Slide back to the farthest valid spot along the flight.
    if (!bResolved && SlideBack(Launch, Origin, Body, DropLength, Path, Floor, FloorNormal, Candidate, Landed))
    {
        bResolved = true;
        Path = Landed;
    }

    Arc.BeginArc();
    for (I = 1; I < Path.Length; ++I)
        Arc.AddSegment(Path[I - 1], Path[I], VSize(Path[I] - Origin));
    if (!bResolved) { ShowRefused(); return; }

    Destination = Candidate;
    AimDistance = VSize(Destination - Body);
    ArcYaw = rotator(Destination - Body).Yaw;
    bValid = true;
    Arc.Finish(bCharging ? 2 : 1, Floor, FloorNormal, Radius, ArrivalYaw(), WantsFacing());
}

// Horizontal landing distance for an effective pitch in degrees. Continuous
// and monotonic, flat at both ends so the nearest step and full range are each
// held over a band of wrist angle rather than at a single point.
function float DesiredDistance(float PitchDegrees, float Reach)
{
    local float U;
    U = FClamp((PitchDegrees - NEAR_PITCH) / (FAR_PITCH - NEAR_PITCH), 0, 1);
    return NEAR_DISTANCE + FMax(Reach - NEAR_DISTANCE, 0) * U * U * (3 - 2 * U);
}

// How far along the hand's flat heading the arc may travel: the desired
// distance, cut where that ray leaves the body-centred range circle. Sampling
// Body + heading * Reach instead picked a spot beside the drawn path whenever
// the controller sat off-centre.
function float AimTravel(int Yaw, vector Origin, vector Body, float Reach, float Desired)
{
    local vector Heading, Offset;
    local rotator Flat;
    local float Ahead, SideSq;
    Flat.Yaw = Yaw;
    Heading = vector(Flat);
    Offset = Origin - Body;
    Offset.Z = 0;
    Ahead = Offset Dot Heading;
    SideSq = VSizeSq(Offset - Heading * Ahead);
    return FClamp(Desired, 32, FMax(-Ahead + Sqrt(FMax(Reach * Reach - SideSq, 0)), 32));
}

// Launch pitch, in degrees, ARC_MIN_BEND above the straight line that rises by
// Rise over Run. Anything at or above it has a positive ballistic solution.
function float FloorPitch(float Rise, float Run)
{
    return Atan2(Rise, FMax(Run, 1)) * 180.0 / Pi + ARC_MIN_BEND;
}

// Samples the flight solved to land Travel along the heading at foot level.
// World geometry only. That is BSP, static meshes, blocking volumes and KF2's
// doors (bWorldGeometry=true), and it deliberately excludes pawns and every
// local VR presentation actor, which have no business ending an arc.
//
// Deliberately zero-extent. The arc is a pointer, not the route: a body-sized
// sweep along a parabola catches the nosing of every stair and the top of every
// railing, so aiming up a staircase or onto a crate would refuse even though
// walking there is trivial. What the body has to fit is the destination, and
// what stops a teleport through a wall is line of sight; both are checked in
// ValidateSpot.
function int TraceArc(rotator Launch, vector Origin, vector Body, float FootZ, float Travel,
    float Reach, float DropLength, out array<vector> Path, out vector HitLocation, out vector HitNormal)
{
    local vector Velocity, Previous, Sample, Target;
    local rotator Flat;
    local float Speed, T, Horizontal, PreviousHorizontal, Fraction;
    local int I;

    Flat.Yaw = Launch.Yaw;
    Target = Origin + vector(Flat) * Travel;
    Target.Z = FootZ;
    Speed = ArcSpeedToFloor(Launch, Origin, Target, Travel);
    if (Speed <= 0) Speed = ArcSpeed();
    Velocity = vector(Launch) * Speed;
    Path.Length = 0;
    Path.AddItem(Origin);
    Previous = Origin;
    for (I = 1; I <= ARC_SAMPLES; ++I)
    {
        T = float(I) * ARC_STEP;
        Sample = Origin + Velocity * T + vect(0,0,0.5) * Bridge.WorldInfo.GetGravityZ() * T * T;
        if (Bridge.Human.Trace(HitLocation, HitNormal, Sample, Previous, false) != None)
        {
            Path.AddItem(HitLocation);
            return ARC_HIT;
        }
        Horizontal = VSize2D(Sample - Body);
        if (Horizontal > Reach)
        {
            // Only a floor lower than the feet carries the flight this far.
            // End on the circle; the floor under it is looked up and the
            // drawn curve rebuilt to it.
            PreviousHorizontal = VSize2D(Previous - Body);
            Fraction = FClamp((Reach - PreviousHorizontal)
                / FMax(Horizontal - PreviousHorizontal, 0.01), 0, 1);
            Path.AddItem(Previous + (Sample - Previous) * Fraction);
            return ARC_RANGE;
        }
        Path.AddItem(Sample);
        Previous = Sample;
        if (Origin.Z - Sample.Z > DropLength) break;
    }
    return ARC_DROPPED;
}

// The point on the drawn flight Travel horizontally from the hand.
function vector PathPoint(out array<vector> Path, vector Origin, float Travel)
{
    local int I;
    local float Before, After;
    for (I = 1; I < Path.Length; ++I)
    {
        After = VSize2D(Path[I] - Origin);
        if (After < Travel) continue;
        Before = VSize2D(Path[I - 1] - Origin);
        return Path[I - 1] + (Path[I] - Path[I - 1])
            * FClamp((Travel - Before) / FMax(After - Before, 0.01), 0, 1);
    }
    return Path[Path.Length - 1];
}

// One slide candidate: the floor under a point of the flight, fitted and
// validated, with a continuous curve from the hand that actually reaches it.
function bool TrySlide(rotator Launch, vector Origin, vector Body, float DropLength, vector Point,
    out vector Floor, out vector FloorNormal, out vector Candidate, out array<vector> Landed)
{
    local vector Land, LandNormal;
    if (VSize2D(Point - Body) < BACKTRACK_MIN) return false;
    if (Bridge.Human.Trace(Land, LandNormal, Point - vect(0,0,1) * DropLength, Point, false) == None
        || LandNormal.Z < Bridge.Human.WalkableFloorZ) return false;
    if (!TryLand(Land, Floor, FloorNormal, Candidate)) return false;
    return RebuildPathToFloor(Launch, Origin, Floor, Landed);
}

// Walks back from the refused end of the flight toward the body and keeps the
// first spot that validates, then halves the gap to the refused end a few
// times. The probes are spaced by distance, not by sample: a fast flat arc's
// samples are far apart, and walking them left the fallback coarse exactly
// where the aim was longest.
function bool SlideBack(rotator Launch, vector Origin, vector Body, float DropLength,
    out array<vector> Path, out vector Floor, out vector FloorNormal, out vector Candidate,
    out array<vector> Landed)
{
    local vector TryFloor, TryNormal, TryCandidate;
    local array<vector> TryPath;
    local float Far, Step, Travel, Valid, Invalid, Middle;
    local int I;
    local bool bFound;

    if (Path.Length < 2) return false;
    Far = VSize2D(Path[Path.Length - 1] - Origin);
    Step = FMax(SLIDE_MIN_STEP, (Far - BACKTRACK_MIN) / SLIDE_PROBES);
    Invalid = Far;
    for (Travel = Far - Step; Travel >= BACKTRACK_MIN * 0.5; Travel -= Step)
    {
        if (TrySlide(Launch, Origin, Body, DropLength, PathPoint(Path, Origin, Travel),
            Floor, FloorNormal, Candidate, Landed))
        {
            bFound = true;
            Valid = Travel;
            break;
        }
        Invalid = Travel;
    }
    if (!bFound) return false;
    for (I = 0; I < SLIDE_REFINE && Invalid - Valid > 8; ++I)
    {
        Middle = 0.5 * (Valid + Invalid);
        if (TrySlide(Launch, Origin, Body, DropLength, PathPoint(Path, Origin, Middle),
            TryFloor, TryNormal, TryCandidate, TryPath))
        {
            Valid = Middle;
            Floor = TryFloor;
            FloorNormal = TryNormal;
            Candidate = TryCandidate;
            Landed = TryPath;
        }
        else Invalid = Middle;
    }
    return true;
}

// Resolves the floor under a landing rather than trusting the arc's own contact
// point, which can sit on a lip or a sloped face, then applies the validator.
function bool TryLand(vector Land, out vector Floor, out vector FloorNormal, out vector Candidate)
{
    local float Height;
    local string Reason;
    Height = Bridge.Human.GetCollisionHeight();
    if (Bridge.Human.Trace(Floor, FloorNormal, Land - vect(0,0,1) * (Height + 60),
        Land + vect(0,0,2), false) == None) return false;
    Candidate = Floor;
    Candidate.Z += Height + 2;
    if (!class'VRTeleportLocomotion'.static.ValidateSpot(Bridge.Human, Candidate,
        Bridge.TeleportRange, Bridge.TeleportAscentLimit, Bridge.TeleportDescentLimit,
        Bridge.TeleportNavRadius, Reason)) return false;
    // ValidateSpot may make a small FindSpot correction. Use the floor under
    // that final accepted centre when rebuilding the displayed curve.
    if (Bridge.Human.Trace(Floor, FloorNormal, Candidate - vect(0,0,1) * (Height + 60),
        Candidate + vect(0,0,2), false) == None) return false;
    return FloorNormal.Z >= Bridge.Human.WalkableFloorZ;
}

// A vertical floor lookup is useful for finding a candidate, but it must not
// become a visible corner in the aim arc. Re-solve a parabola to the fitted
// floor and trace every segment. The small yaw allowance accepts the ordinary
// floor fit/ledge correction while refusing a path that would bend around an
// obstruction the hand never aimed through. A floor the launch pitch cannot
// reach (a raised landing under a flat throw) lifts the launch just enough to
// have a solution; the traced segments still decide whether it is coherent.
function bool RebuildPathToFloor(rotator InputAim, vector Origin, vector Floor, out array<vector> Path)
{
    local vector ToFloor, Velocity, Previous, Sample, HitLocation, HitNormal;
    local rotator Launch;
    local float Reach, Speed, FlightTime, T, Pitch, HorizontalSpeed, MinPitch;
    local int I;

    ToFloor = Floor - Origin;
    ToFloor.Z = 0;
    Reach = VSize2D(ToFloor);
    if (Reach <= 1) return false;
    Launch = InputAim;
    Launch.Yaw = rotator(ToFloor).Yaw;
    if (Abs(NormalizeRotAxis(Launch.Yaw - InputAim.Yaw)) > 4096) return false;
    MinPitch = FloorPitch(Floor.Z - Origin.Z, Reach);
    if (float(NormalizeRotAxis(Launch.Pitch)) * 360.0 / 65536.0 < MinPitch)
        Launch.Pitch = int(MinPitch * 65536.0 / 360.0);
    Speed = ArcSpeedToFloor(Launch, Origin, Floor, Reach);
    if (Speed <= 0) return false;
    Pitch = float(NormalizeRotAxis(Launch.Pitch)) * Pi / 32768.0;
    HorizontalSpeed = Speed * Cos(Pitch);
    if (HorizontalSpeed <= 0.01) return false;
    FlightTime = Reach / HorizontalSpeed;
    if (FlightTime <= 0 || FlightTime > float(ARC_SAMPLES) * ARC_STEP) return false;

    Velocity = vector(Launch) * Speed;
    Path.Length = 0;
    Path.AddItem(Origin);
    Previous = Origin;
    for (I = 1; I <= ARC_SAMPLES; ++I)
    {
        T = FMin(float(I) * ARC_STEP, FlightTime);
        Sample = Origin + Velocity * T + vect(0,0,0.5) * Bridge.WorldInfo.GetGravityZ() * T * T;
        // Hitting the final floor on the final segment is expected; any other
        // world hit means the reconstructed flight would not be coherent.
        if (Bridge.Human.Trace(HitLocation, HitNormal, Sample, Previous, false) != None
            && (T < FlightTime - 0.005 || VSize(HitLocation - Floor) > 8)) return false;
        if (T >= FlightTime) Sample = Floor;
        Path.AddItem(Sample);
        Previous = Sample;
        if (T >= FlightTime) return true;
    }
    return false;
}

// Fallback if the aimed-distance solve has no positive answer, which the
// FloorPitch launch floor should make unreachable: scale with configured range.
function float ArcSpeed()
{
    return Sqrt(ARC_REACH * FMax(Bridge.TeleportRange, 200)
        * FMax(Abs(Bridge.WorldInfo.GetGravityZ()), 100));
}

// The speed that brings this exact pitch to a point Reach away horizontally
// and Floor.Z - Origin.Z up, so the preview and the landing are one ballistic
// path. Zero means the pairing has no positive solution.
function float ArcSpeedToFloor(rotator Aim, vector Origin, vector Floor, float Reach)
{
    local float Pitch, CosPitch, Denominator, Gravity;
    Pitch = float(NormalizeRotAxis(Aim.Pitch)) * Pi / 32768.0;
    CosPitch = Cos(Pitch);
    Denominator = Reach * Tan(Pitch) - (Floor.Z - Origin.Z);
    Gravity = FMax(Abs(Bridge.WorldInfo.GetGravityZ()), 100);
    if (Abs(CosPitch) < 0.05 || Denominator <= 8) return 0;
    return Sqrt(0.5 * Gravity * Reach * Reach / (CosPitch * CosPitch * Denominator));
}

function ShowRefused()
{
    bValid = false;
    if (Arc != None) Arc.Finish(0, vect(0,0,0), vect(0,0,1), 0, 0, false);
}

// ------------------------------------------------------------- validation

// The same gates ApplyRoomMovement and the server's room validator apply. Every
// victim special move in KF2 declares bDisableMovement, so reading the move
// rather than enumerating zeds covers the Clot and Alpha grab, Hans, the Bloat
// King gorge, the Patriarch and anything Tripwire adds later.
static function bool BodyReady(KFPawn_Human Body)
{
    return Body != None && !Body.bDeleteMe && Body.Health > 0
        && Body.Physics == PHYS_Walking && !Body.IsDoingSpecialMove();
}

// One validator, called by the client to light the marker and by the server to
// decide. Sharing it is the point: two implementations of "is this a legal
// destination" drift, and the drift shows up as a correction on a move the
// player already saw succeed. Spot is a capsule centre and is adjusted to the
// fitted position on success.
//
// The limits are passed rather than read from class defaults. The player's
// numbers live on the bridge instance that validated them, a dedicated server
// has no bridge at all, and a server that trusted the client's would not be
// checking anything. Each side supplies the limits it is entitled to.
static function bool ValidateSpot(KFPawn_Human Body, out vector Spot,
    float Range, float AscentLimit, float DescentLimit, float NavRadius, out string Reason)
{
    local vector Floor, FloorNormal, Extent, Fitted, Eye, Head;
    local vector HitLocation, HitNormal;
    local float Radius, Height, FootZ, TargetFootZ;
    local array<NavigationPoint> Nearby;
    local Cylinder BodySize;
    local int I;
    local bool bNavFound;

    Reason = "";
    if (!BodyReady(Body)) { Reason = "body"; return false; }
    Radius = Body.GetCollisionRadius();
    Height = Body.GetCollisionHeight();
    if (Radius <= 0 || Height <= 0) { Reason = "cylinder"; return false; }
    Extent.X = Radius; Extent.Y = Radius; Extent.Z = Height;

    if (Body.Trace(Floor, FloorNormal, Spot - vect(0,0,1) * (Height + 80), Spot, false) == None)
    { Reason = "no_floor"; return false; }
    if (FloorNormal.Z < Body.WalkableFloorZ) { Reason = "unwalkable"; return false; }

    FootZ = Body.Location.Z - Height;
    TargetFootZ = Floor.Z;
    if (TargetFootZ - FootZ > AscentLimit) { Reason = "too_high"; return false; }
    if (FootZ - TargetFootZ > DescentLimit) { Reason = "too_low"; return false; }

    Fitted = Floor;
    Fitted.Z += Height + 2;
    if (VSize2D(Fitted - Body.Location) > Range) { Reason = "out_of_range"; return false; }

    // FindSpot nudges a marginal box clear of world geometry. A small nudge is
    // the intended correction; a large one means the aim point was never a
    // place to stand, and the player should re-aim rather than be moved
    // somewhere they did not choose.
    Spot = Fitted;
    if (!Body.FindSpot(Extent, Spot)) { Reason = "no_fit"; return false; }
    if (VSize(Spot - Fitted) > 12) { Reason = "fit_drift"; return false; }

    // "The path is viable" in the only form that survives a staircase. A clear
    // line from the eye to where the head will be refuses a teleport through a
    // wall or a welded door -- KF2's doors are solid and bWorldGeometry -- while
    // allowing every ordinary step up, railing and stack of crates the arc flies
    // over. Grates and barred windows are deliberately permissive: you may blink
    // through what you can see through, and the destination still has to be
    // navigable, so nothing reached this way is somewhere zeds cannot follow.
    Eye = Body.GetPawnViewLocation();
    Head = Spot;
    Head.Z += Height * 0.6;
    if (Body.Trace(HitLocation, HitNormal, Head, Eye, false) != None)
    { Reason = "no_sight"; return false; }

    // KF2's own walkable graph decides whether a pawn of this size belongs
    // here. IsUsableAnchorFor is the test the shipped AI teleport uses, and the
    // cylinder filter rejects nodes that cannot hold this body. Requiring a
    // usable node nearby, rather than snapping onto one, keeps free placement
    // while still refusing roofs and ledges the zeds cannot follow onto.
    BodySize.Radius = int(Radius);
    BodySize.Height = int(Height);
    class'NavigationPoint'.static.GetAllNavInRadius(Body, Spot, NavRadius, Nearby, true, -1, BodySize);
    for (I = 0; I < Nearby.Length; ++I)
    {
        if (Nearby[I] == None || Nearby[I].bWallNode) continue;
        if (Nearby[I].IsUsableAnchorFor(Body)) { bNavFound = true; break; }
    }
    // A map with no navigation, or a client that was never sent the cooked
    // graph, would otherwise refuse every teleport. WorldInfo.NavigationPointList
    // is private to script and cannot answer that question, so ask the body:
    // probe for navigation where the player is already standing. Nodes there
    // prove the graph is loaded and reachable in this context, which makes a
    // destination with none genuinely unreachable. Nothing there means there is
    // no graph to consult and the geometric result stands -- floor, fit, range
    // and sight are unaffected either way.
    if (!bNavFound)
    {
        class'NavigationPoint'.static.GetAllNavInRadius(Body, Body.Location, NavRadius,
            Nearby, true, -1, BodySize);
        for (I = 0; I < Nearby.Length; ++I)
        {
            if (Nearby[I] == None || Nearby[I].bWallNode) continue;
            if (Nearby[I].IsUsableAnchorFor(Body)) { Reason = "unreachable"; return false; }
        }
    }
    return true;
}

// ---------------------------------------------------------------- commit

// Fade length tracks distance. A full-range move earns the whole blink; a short
// reposition gets almost none, which is what lets a hop read as a dodge rather
// than as a scene transition.
function float FadeScale()
{
    if (Bridge.BlinkScale <= 0 || Bridge.TeleportRange <= 0) return 0;
    return Bridge.BlinkScale * FClamp(0.25 + 0.75 * (CommittedDistance / Bridge.TeleportRange), 0, 1);
}

function BeginCommit(int Hand, vector Spot, float Distance, int FacingYaw, bool bFacing)
{
    local float Scale;
    PendingDestination = Spot;
    CommittedDistance = Distance;
    PendingFacingYaw = FacingYaw;
    bPendingFacing = bFacing;
    Pulse(Hand, true);
    Scale = FadeScale();
    PhaseLength = Bridge.BlinkOutSeconds * Scale;
    PhaseStarted = Now();
    Phase = 1;
    Blink = 0;
    PublishBlink();
    if (PhaseLength <= 0.001) AdvanceCommit(0);
}

function AdvanceCommit(float RealDelta)
{
    local float Elapsed;
    if (Phase == 0) return;
    // The body can be lost, killed or grabbed inside the fade. Nothing is worth
    // landing after that: the destination was measured against a body that is
    // no longer the one standing here.
    if (!Input.ContextValid() || Bridge.Human == None || Bridge.Human.Health <= 0)
    { AbortCommit(); return; }
    Elapsed = Now() - PhaseStarted;
    if (Phase == 1)
    {
        if (PhaseLength > 0) Blink = FClamp(Elapsed / PhaseLength, 0, 1);
        else Blink = 1;
        PublishBlink();
        if (Elapsed < PhaseLength) return;
        Blink = 1;
        PublishBlink();
        Relocate();
        return;
    }
    if (Phase == 2)
    {
        // A deferred relocation belongs to the server. Holding the fade until
        // the pawn arrives is what makes the round trip invisible instead of a
        // rubber-band, and the deadline means a dropped request can never
        // strand the player in the dark.
        if (VSize(Bridge.Human.Location - PendingDestination) <= 32
            || Now() >= ArriveDeadline) BeginFadeIn();
        return;
    }
    if (PhaseLength > 0) Blink = 1 - FClamp(Elapsed / PhaseLength, 0, 1);
    else Blink = 0;
    PublishBlink();
    if (Elapsed >= PhaseLength) { Phase = 0; Blink = 0; PublishBlink(); }
}

// Recharge is distance over a sustained speed rather than a flat timer, so a
// short reposition costs almost nothing and a full-range escape costs the whole
// beat. The player never has to think about a cooldown; they learn that small
// moves are cheap and big ones are committal, which is the right intuition.
// Arrival is grounded with sound, because a teleport nobody hears reads as a
// camera cut rather than as a step. It waits for the body to be standing again:
// the frame after a relocation the pawn is settling through PHYS_Falling with
// no base, and PlayFootStepSound refuses in exactly that state. On a network
// client the wait covers the correction that carries the move as well.
function TryArrivalSound()
{
    if (!bArrivalPending || Bridge.Human == None) return;
    if (Bridge.Human.Physics != PHYS_Walking || Bridge.Human.Base == None) return;
    bArrivalPending = false;
    Bridge.Human.PlayFootStepSound(0);
}

function Relocate()
{
    bArrivalPending = true;
    ReadyTime = Now() + FClamp(CommittedDistance / FMax(Bridge.TeleportSustainedSpeed, 1),
        Bridge.TeleportMinCooldown, Bridge.TeleportMaxCooldown);
    ApplyFacing();
    if (Bridge.RequestTeleport(PendingDestination))
    {
        Phase = 2;
        ArriveDeadline = Now() + ArrivalWait();
        return;
    }
    BeginFadeIn();
}

// Turns the view to the chosen arrival facing while the screen is dark. Yaw
// is owned by the local controller in both solo and network play, exactly as
// snap turn already applies it, so no server round trip is involved. The head's
// own yaw is what the player sees by, so the controller absorbs the difference.
function ApplyFacing()
{
    local rotator Current;
    local int Delta;
    if (!bPendingFacing || Bridge.PC == None) return;
    bPendingFacing = false;
    Delta = NormalizeRotAxis(PendingFacingYaw - Bridge.NativeHeadRotation.Yaw);
    Current = Bridge.PC.Rotation;
    Current.Yaw += Delta;
    Bridge.PC.SetRotation(Current);
}

// How long the dark hold waits for the server before giving up. A flat half
// second let the fade lift ahead of the correction on a high-ping game, which
// showed the snap the fade exists to hide. Ping is replicated in 4 ms units.
function float ArrivalWait()
{
    local float Ping;
    if (Bridge.PC == None || Bridge.PC.PlayerReplicationInfo == None) return 0.5;
    Ping = float(Bridge.PC.PlayerReplicationInfo.Ping) * 0.004;
    return FClamp(0.5 + 2 * Ping, 0.5, 1.5);
}

// The server's explicit answer to a deferred hop. Accepted changes nothing:
// the body still has to arrive, and Phase 2 already watches for that. Refused
// ends the hold immediately rather than leaving the player in the dark until
// the arrival deadline expires. The optimistic cooldown stands either way --
// it is the more conservative of the two, so honouring it cannot outrun the
// server's own rate limit on the retry.
function ServerAnswered(bool bAccepted)
{
    if (Phase != 2) return;
    if (bAccepted) return;
    ++Refusals;
    BeginFadeIn();
}

function BeginFadeIn()
{
    Phase = 3;
    PhaseStarted = Now();
    PhaseLength = Bridge.BlinkInSeconds * FadeScale();
    if (PhaseLength <= 0.001) { Phase = 0; Blink = 0; PublishBlink(); }
}

// The session object owns every native effect channel. Teleport publishes one
// value there rather than reaching into the renderer, so a lost session drops
// the fade with the rest instead of leaving the view black.
function PublishBlink()
{
    Bridge.NativeBlinkFX = FClamp(Blink, 0, 1);
}
