// One retained gauntlet's gesture and its notify-free stock mechanism paths.
// The wrist owes a deliberate flex AND return; a release or tracking jump
// abandons that wrist's unpaid cycle instead of accepting a recovery pose.
class VRBrawlerWrist extends Object;

var VRActionPath CockPath, ReturnPath;
var VRReloadMotionGuard PositionGuard, RotationGuard;
var bool bSeeded, bReturning, bComplete;
var bool bCockSoundPlayed, bReturnSoundPlayed;
var float Amount, BasePitch, TurnPitch, PhaseSince;
var float CockSoundAt, ReturnSoundAt;
var AkEvent CockSound, ReturnSound;

function Initialize()
{
    PositionGuard = new(self) class'VRReloadMotionGuard';
    PositionGuard.SpeedLimit = 1500;
    RotationGuard = new(self) class'VRReloadMotionGuard';
    RotationGuard.SpeedLimit = 220;
    RotationGuard.PositionSlack = 1;
}

function Reset()
{
    bSeeded = false; bReturning = false; bComplete = false;
    bCockSoundPlayed = false; bReturnSoundPlayed = false;
    Amount = 0;
    PositionGuard.Reset(); RotationGuard.Reset();
}

function VRActionPath CurrentPath() { return bReturning ? ReturnPath : CockPath; }

function AkEvent ConsumeSound()
{
    if (!bSeeded) return None;
    if (!bCockSoundPlayed && (bReturning || Amount > 0 && Amount >= CockSoundAt))
    {
        bCockSoundPlayed = true;
        return CockSound;
    }
    if (bReturning && !bReturnSoundPlayed && (bComplete || Amount > 0 && Amount >= ReturnSoundAt))
    {
        bReturnSoundPlayed = true;
        return ReturnSound;
    }
    return None;
}

// Pitch is invariant under ordinary room/body yaw. Turning the head or using
// snap turn cannot itself cock a glove; the room epoch still invalidates a
// relocation. Either flex direction is comfortable, but return must retrace
// the same excursion. The asset's own mirrored handle motion stays authored.
function float WristPitch(quat ControllerQ)
{
    local vector Forward;
    Forward = QuatRotateVector(ControllerQ, vect(1,0,0));
    Forward.Z = FClamp(Forward.Z, -1, 1);
    return Atan2(Forward.Z, Sqrt(FMax(0, 1 - Forward.Z * Forward.Z)));
}

// 0 ongoing, 1 cock stop, 2 returned/ready, 3 discontinuity/release.
function int Update(vector Position, quat ControllerQ, bool bGrip, float Now)
{
    local vector Forward;
    local float Pitch, Excursion;
    if (!bGrip || !class'VRReloadHandPose'.static.ValidQ(ControllerQ)) { Reset(); return 3; }
    Forward = QuatRotateVector(ControllerQ, vect(1,0,0)) * 20;
    Pitch = WristPitch(ControllerQ);
    if (!bSeeded)
    {
        if (!PositionGuard.Begin(Position, Now) || !RotationGuard.Begin(Forward, Now))
        { Reset(); return 3; }
        BasePitch = Pitch; PhaseSince = Now; bSeeded = true;
        return 0;
    }
    if (!PositionGuard.Check(Position, Now) || !RotationGuard.Check(Forward, Now))
    { Reset(); return 3; }
    if (bComplete) return 0;
    // 30 degrees of deliberate wrist flex, followed by a return within five.
    // Neither a tiny shake nor completing the animation with time pays ammo.
    Excursion = Abs(Pitch - BasePitch);
    if (!bReturning)
    {
        Amount = FClamp(Excursion / 0.5235988, 0, 1);
        if (Amount < 1.0 || Now - PhaseSince < 0.12) return 0;
        TurnPitch = Pitch;
        bReturning = true; Amount = 0; PhaseSince = Now;
        return 1;
    }
    Amount = FClamp(1 - Excursion / FMax(Abs(TurnPitch - BasePitch), 0.497), 0, 1);
    if (Excursion > 0.0872665 || Now - PhaseSince < 0.12) return 0;
    Amount = 1; bComplete = true;
    return 2;
}
