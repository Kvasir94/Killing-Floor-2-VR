// Explicit, bounded test orchestration. Never spawned by normal friend games.
class KF2VRNetLifecycle extends Actor;

var KF2VRNetPlayerController Driver;
var KF2VRNetGame Game;
var KFPawn_Human OldPawn;
var int OldEpoch, Step, ArmorBefore;
var float NextAction, DoshBefore;

function Initialize(KF2VRNetPlayerController PC)
{
    Driver = PC;
    Game = KF2VRNetGame(WorldInfo.Game);
    SetTimer(0.25, true, 'Advance');
    LifeSpan = 240;
}

function LogPhase(string Phase, string Details)
{
    `log("KF2VRNet lifecycle phase=" $ Phase $ " world=" $ Driver.NetChannel.WorldEpoch
        $ " connection=" $ Driver.NetChannel.ConnectionEpoch $ " pawn=" $ Driver.NetChannel.PawnEpoch
        $ " netmode=" $ WorldInfo.NetMode $ " " $ Details);
}

function Advance()
{
    local string TravelURL;
    if (Driver == None || Driver.NetChannel == None || Game == None || Game.DiagnosticLifecycle == 0)
    {
        Destroy();
        return;
    }
    if (WorldInfo.RealTimeSeconds < NextAction) return;
    if (Step == 0 && Driver.Pawn != None && Game.GetLivingPlayerCount() >= 2)
    {
        if (Game.DiagnosticLifecycle == 2)
        {
            LogPhase("travel_complete", "living=" $ Game.GetLivingPlayerCount() $ " map=" $ WorldInfo.GetMapName(true));
            ClearTimer('Advance');
            return;
        }
        OldPawn = KFPawn_Human(Driver.Pawn);
        OldEpoch = Driver.NetChannel.PawnEpoch;
        LogPhase("death_begin", "living=" $ Game.GetLivingPlayerCount() $ " actor=" $ OldPawn);
        OldPawn.Suicide();
        Step = 1;
        NextAction = WorldInfo.RealTimeSeconds + 3.0;
    }
    else if (Step == 1 && Driver.Pawn == None && Driver.NetChannel.PawnEpoch == 0)
    {
        LogPhase("dead", "old_pawn=" $ OldEpoch $ " health=" $ OldPawn.Health
            $ " played=" $ OldPawn.bPlayedDeath $ " living=" $ Game.GetLivingPlayerCount());
        // Enter normal trader time; StartHumans/RestartPlayer perform respawn.
        Game.WaveEnded(WEC_WaveWon);
        Step = 2;
    }
    else if (Step == 2 && Driver.Pawn != None && Driver.Pawn.Health > 0
        && Driver.NetChannel.PawnEpoch > OldEpoch)
    {
        LogPhase("respawn", "old_pawn=" $ OldEpoch $ " actor=" $ Driver.Pawn
            $ " trader=" $ Game.MyKFGRI.bTraderIsOpen);
        if (Driver.DiagnosticTarget != None) Driver.DiagnosticTarget.Destroy();
        Driver.DiagnosticTarget = None;
        Driver.bForceNetUpdate = true;
        Driver.ClientLifecycleRespawn();
        Step = 3;
    }
    else if (Step == 6)
    {
        LogPhase("travel_begin", "destination=KF-Outpost");
        Step = 7;
        TravelURL = "KF-Outpost?Game=KF2VRNet.KF2VRNetGame?VRNetDiagnostics=1?VRNetAutoReady=1?VRNet9mm=1?VRNetLifecycle=2?VRNetClients=2?Difficulty=0?GameLength=0";
        if (Game.bIndependentWeapons) TravelURL $= "?VRNetServerAdapter=1?VRNetDualWeapons=1";
        // Travel rebuilds the URL from scratch, so anything not restated here
        // is silently dropped for the second map.
        if (Game.bDiagnosticQuietZeds) TravelURL $= "?VRNetQuietZeds=1";
        WorldInfo.ServerTravel(TravelURL, true);
    }
}

function RequestTrader()
{
    if (Step != 3 || Driver.Pawn == None || !Game.MyKFGRI.bTraderIsOpen) return;
    ArmorBefore = KFPawn_Human(Driver.Pawn).Armor;
    DoshBefore = Driver.PlayerReplicationInfo.Score;
    LogPhase("trader_before", "armor=" $ ArmorBefore $ " dosh=" $ DoshBefore);
    Driver.OpenTraderMenu();
    Driver.ClientLifecycleTrader();
    Step = 4;
}

function ConfirmPurchase()
{
    if (Step != 4 || Driver.Pawn == None) return;
    LogPhase("trader_after", "armor=" $ KFPawn_Human(Driver.Pawn).Armor
        $ " dosh=" $ Driver.PlayerReplicationInfo.Score
        $ " menu=" $ KFInventoryManager(Driver.Pawn.InvManager).bServerTraderMenuOpen);
    if (KFPawn_Human(Driver.Pawn).Armor > ArmorBefore && Driver.PlayerReplicationInfo.Score < DoshBefore)
        Step = 5;
}

function ConfirmClosed()
{
    if (Step != 5 || KFInventoryManager(Driver.Pawn.InvManager).bServerTraderMenuOpen) return;
    LogPhase("trader_closed", "menu=False");
    Step = 6;
    NextAction = WorldInfo.RealTimeSeconds + 5.0;
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
