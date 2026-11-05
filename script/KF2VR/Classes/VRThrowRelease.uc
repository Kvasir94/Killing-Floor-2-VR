// Release velocity for every hand throw, as Half-Life: Alyx computes it: drop
// the samples from the last few frames before the fingers open (the hand is
// already braking there, so a plain or smoothed last-frame velocity reads as
// a weak toss), then over the frames before that take the average direction at
// the peak speed. Alyx keeps 5 samples and ignores the newest 3
// (vr_handinfo_history_size / _ignore_size; its estimator is decoded in
// docs/re/HALF_LIFE_ALYX_GRAVITY_GLOVES.md); this is the same window in time,
// so it holds at 90 and 120 Hz. Callers feed the velocity they already measure
// each tick (locomotion removed) and ask for the release velocity on release.
class VRThrowRelease extends Object;

const SIZE = 24;

var vector Velocities[48];
var float Times[48];
var int Count[2], Next[2];
// 3 and 5 frames at 90 Hz.
var float IgnoreSeconds, WindowSeconds;

function Reset(int Hand)
{
    if (Hand < 0 || Hand > 1) return;
    Count[Hand] = 0;
    Next[Hand] = 0;
}

function Add(int Hand, vector Velocity, float Now)
{
    local int Slot;
    if (Hand < 0 || Hand > 1 || Velocity != Velocity) return;
    Slot = Hand * SIZE + Next[Hand];
    Velocities[Slot] = Velocity;
    Times[Slot] = Now;
    if (++Next[Hand] >= SIZE) Next[Hand] = 0;
    Count[Hand] = Min(Count[Hand] + 1, SIZE);
}

// Fallback is returned when there is no history to judge (a release in the
// first frames of a hold): the caller's own estimate, unchanged.
function vector Release(int Hand, float Now, vector Fallback)
{
    local int I, Slot;
    local float Age, Peak, Speed;
    local vector Direction;
    local bool bAny;
    if (Hand < 0 || Hand > 1) return Fallback;
    for (I = 0; I < Count[Hand]; ++I)
    {
        Slot = Next[Hand] - 1 - I;
        if (Slot < 0) Slot += SIZE;
        Slot += Hand * SIZE;
        Age = Now - Times[Slot];
        if (Age < IgnoreSeconds) continue;
        if (Age > IgnoreSeconds + WindowSeconds) break;
        Speed = VSize(Velocities[Slot]);
        if (Speed > 0.001) Direction += Velocities[Slot] / Speed;
        Peak = FMax(Peak, Speed);
        bAny = true;
    }
    if (!bAny || VSize(Direction) < 0.001) return Fallback;
    return Normal(Direction) * Peak;
}

defaultproperties
{
    IgnoreSeconds=0.033
    WindowSeconds=0.056
}
