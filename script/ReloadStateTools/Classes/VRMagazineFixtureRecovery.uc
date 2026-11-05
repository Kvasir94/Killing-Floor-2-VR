// Deterministic external tracking/pouch observations; Update, Poll and lease
// transitions are the production implementation, not a second state model.
class VRMagazineFixtureRecovery extends VRMagazineRecovery;
var bool bFixtureDown, bFixtureOpen, bFixtureContext;
var int FixturePouch;
function bool ContextValid(int Hand) { return bFixtureContext; }
function bool RawHandFree(int Hand) { return true; }
function bool SampleMotion(int Hand) { return true; }
function bool Down(int Hand) { return bFixtureDown; }
function bool Open(int Hand) { return bFixtureOpen; }
function int NearestPouch(int Hand) { return FixturePouch; }

