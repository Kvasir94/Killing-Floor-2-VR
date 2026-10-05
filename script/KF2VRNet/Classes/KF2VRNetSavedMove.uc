// Carries the frame's room-scale displacement alongside the stock move.
// Pawn.MoveSmooth is not an input axis, so without this the server's
// MoveAutonomous replay cannot reproduce the client's position and every
// physical step accumulates against MAXPOSITIONERRORSQUARED.
//
// The displacement is applied inside PlayerController.ProcessMove, which is the
// one function every path shares: ReplicateMove calls it directly for a live
// client move, and MoveAutonomous calls it for both the client's post-correction
// replay and the server's authoritative replay. Applying it anywhere else means
// a different position relative to AutonomousPhysics on each side, and the two
// diverge until the server corrects every move.
class KF2VRNetSavedMove extends SavedMove;

var vector RoomDelta;

function Clear()
{
    Super.Clear();
    RoomDelta = vect(0,0,0);
}

// ProcessMove has already run and swept the pawn by the time ReplicateMove
// calls this, so the recorded offset is the accepted result rather than the
// request. SetMoveFor runs before ProcessMove and would capture nothing.
function PostUpdate(PlayerController P)
{
    local KF2VRNetPlayerController NetPC;
    Super.PostUpdate(P);
    NetPC = KF2VRNetPlayerController(P);
    if (NetPC != None) RoomDelta = NetPC.AppliedRoomMove;
}

// Combining reverts the pawn to the pending move's start location and replays
// acceleration only, which would silently discard the displacement. Standing
// still physically is exactly the zero-acceleration case the stock rule
// combines, so this refuses rather than trying to merge the two offsets.
// The new move's own displacement is read from the controller: its PostUpdate
// has not run yet at the point ReplicateMove tests for combining.
function bool CanCombineWith(SavedMove NewMove, Pawn InPawn, float MaxDelta)
{
    local KF2VRNetPlayerController NetPC;
    if (!IsZero(RoomDelta)) return false;
    if (InPawn != None)
    {
        NetPC = KF2VRNetPlayerController(InPawn.Controller);
        if (NetPC != None && !IsZero(NetPC.AppliedRoomMove)) return false;
    }
    return Super.CanCombineWith(NewMove, InPawn, MaxDelta);
}

// A dropped room move cannot be reconstructed from acceleration, so it has to
// survive as an unacknowledged resend rather than being treated as idle.
function bool IsImportantMove(vector CompareAccel)
{
    return !IsZero(RoomDelta) || Super.IsImportantMove(CompareAccel);
}

// ClientUpdatePosition replays saved moves through MoveAutonomous after a
// server correction. Hand the offset to ProcessMove so the replay applies it at
// the same point the original move did.
function PrepMoveFor(Pawn P)
{
    local KF2VRNetPlayerController NetPC;
    Super.PrepMoveFor(P);
    if (P == None || IsZero(RoomDelta)) return;
    NetPC = KF2VRNetPlayerController(P.Controller);
    if (NetPC != None) NetPC.ActiveRoomMove = RoomDelta;
}
