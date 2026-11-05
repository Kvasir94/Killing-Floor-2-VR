// Which experimental features a build admits at all. Deliberately not config:
// profiles, console options and remote opt-ins cannot admit a closed gate.
// B&S2 interactions are admitted and still need each player's own
// bExperimentalInteractions choice (off: every B&S2 feature off). Standing
// holds stay parked under their own gate.
class VRExperimentalPolicy extends Object abstract;

// Independently restored opt-in. Other experimental interactions and world
// weapons retain their own closed gates.
static simulated function bool ZedGrabbingEnabled()
{
    return true;
}

static simulated function bool InteractionsEnabled()
{
    return true;
}

static simulated function bool StandingHoldsEnabled()
{
    return false;
}

static simulated function bool OptionalContentEnabled()
{
    return false;
}
