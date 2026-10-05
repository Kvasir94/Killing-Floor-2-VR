// Optional fixture mutator; only admitted by an explicitly synthetic LAN game.
class VRMeleeFixtureMutator extends Mutator;
var VRMeleeFixtureCoordinator Coordinator;
event Tick(float Delta)
{
    local KF2VRNetPlayerController C;
    if (Role != ROLE_Authority || KF2VRNetGame(WorldInfo.Game) == None
        || !KF2VRNetGame(WorldInfo.Game).bAllowSyntheticPoses || Coordinator != None) return;
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', C)
        if (C.Pawn != None && C.Pawn.Health > 0 && KFPawn_Customization(C.Pawn) == None
            && C.PlayerReplicationInfo != None && !C.PlayerReplicationInfo.bOnlySpectator
            && C.NetChannel != None && C.NetChannel.bHandshakeAccepted)
        {
            Coordinator = Spawn(class'VRMeleeFixtureCoordinator', C);
            return;
        }
}
defaultproperties { bAlwaysTick=true }
