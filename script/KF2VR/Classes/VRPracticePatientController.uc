// A stationary NPC with the controller type expected by stock human healing.
// Skip player login, local audio/input/UI setup and respawn automation.
class VRPracticePatientController extends KFPlayerController;

simulated event PostBeginPlay()
{
    Super(Controller).PostBeginPlay();
    if (PlayerReplicationInfo == None) InitPlayerReplicationInfo();
    if (PlayerReplicationInfo != None) PlayerReplicationInfo.bBot = true;
    MatchStats = new(self) MatchStatsClass;
}

event Possess(Pawn InPawn, bool bVehicleTransition)
{
    Super(Controller).Possess(InPawn, bVehicleTransition);
}

function Restart(bool bVehicleTransition) {}
event PlayerTick(float DeltaTime) {}
function PawnDied(Pawn InPawn) { Super(Controller).PawnDied(InPawn); }

event Destroyed()
{
    if (PlayerReplicationInfo != None) PlayerReplicationInfo.Team = None;
    Super(Controller).Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bIsPlayer=false
}
