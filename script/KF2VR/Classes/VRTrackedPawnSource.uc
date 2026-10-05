// Something that knows whether a pawn is driven by tracked VR hands: the
// local VRHandsBridge in a session, a player's network channel on a server.
interface VRTrackedPawnSource;

function bool TracksPawn(Pawn P);
