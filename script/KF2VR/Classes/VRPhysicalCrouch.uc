// Tracking height is in metres in the calibrated XR space, never pawn/camera Z.
// Feed KF2's ordinary crouch intent so its movement code owns capsule resizing
// and every stock crouch bonus. The view is not lowered again: the bridge holds
// the eye at standing height (VREyeLocation) since the real head already dropped.
// A seated or mobility-limited player can latch the same crouch with a push of
// the turn stick down to its rim (bButtonCrouch); that crouch lowers the view
// as stock does, since the real head has not moved.
class VRPhysicalCrouch extends Object;

var bool bCrouched, bButtonCrouch;
var float StableTime, PreviousHeight;
var int Epoch;

function Cancel(VRHandsBridge B)
{
    StableTime = 0;
    bCrouched = false;
    bButtonCrouch = false;
    if (B != None) B.bPhysicalCrouchEye = false;
    Apply(B);
}

function ToggleButtonCrouch(VRHandsBridge B)
{
    bButtonCrouch = !bButtonCrouch;
    Apply(B);
}

function StandUp(VRHandsBridge B)
{
    if (!bButtonCrouch) return;
    bButtonCrouch = false;
    Apply(B);
}

function Apply(VRHandsBridge B)
{
    local bool bDuck;
    if (B == None || B.PC == None) return;
    bDuck = bCrouched || bButtonCrouch;
    B.PC.bDuck = bDuck ? 1 : 0;
    if (KFPlayerInput(B.PC.PlayerInput) != None)
    {
        if (bDuck) KFPlayerInput(B.PC.PlayerInput).StartCrouch();
        else KFPlayerInput(B.PC.PlayerInput).StopCrouch();
    }
}

function Update(VRHandsBridge B, float RealDelta)
{
    local float Drop;
    if (B == None || B.NativeHeadTracked == 0 || B.NativeRecenterRequested != 0
        || RealDelta <= 0 || RealDelta > 0.25 || Epoch != B.NativeCalibrationEpoch
        || B.NativeStandingHeight <= 0)
    {
        // No usable head height: drop the physical crouch only. A button
        // crouch needs no calibration and survives tracking blips.
        StableTime = 0;
        bCrouched = false;
        if (B != None)
        {
            B.bPhysicalCrouchEye = false;
            Epoch = B.NativeCalibrationEpoch;
            PreviousHeight = B.NativeHeadHeight;
            Apply(B);
        }
        return;
    }
    Drop = B.NativeStandingHeight - B.NativeHeadHeight;
    if (Drop != Drop || Abs(Drop) > 2)
    {
        StableTime = 0; bCrouched = false; B.bPhysicalCrouchEye = false; Apply(B);
        return;
    }
    if (!bCrouched)
    {
        // Reject transient drops and tracking jumps. A full stable dwell is
        // needed after the movement has settled, including for seated users.
        if (Drop >= 0.33 && Abs(B.NativeHeadHeight - PreviousHeight) <= 0.025)
            StableTime += RealDelta;
        else StableTime = 0;
        if (StableTime >= 0.15) bCrouched = true;
    }
    else if (Drop <= 0.22) { bCrouched = false; StableTime = 0; }
    PreviousHeight = B.NativeHeadHeight;
    B.bPhysicalCrouchEye = bCrouched;
    Apply(B);
}
