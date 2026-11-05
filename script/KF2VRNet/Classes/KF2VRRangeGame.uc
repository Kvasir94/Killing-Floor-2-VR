// A user-operated sandbox; all VR transport and interaction remain production.
class KF2VRRangeGame extends KF2VRNetGame;
var VRRangeDirector RangeDirector;
var KF2VRRangePractice RangePractice;
var KF2VRRangeArena RangeArena;
event PostBeginPlay()
{
    Super.PostBeginPlay();
    if(WorldInfo.NetMode == NM_Standalone) Spawn(class'KF2VRNetHandContact');
    RangePractice=Spawn(class'KF2VRRangePractice');
    if(RangePractice != None) RangePractice.Tag='VRRangePractice';
    RangeDirector=Spawn(class'VRRangeDirector');
    RangeArena=Spawn(class'KF2VRRangeArena');
}
function Tick(float DeltaTime)
{
    local KF2VRNetPlayerController PC;
    local KFPlayerController PlayerPC;
    local KFPawn_Human Human;
    local VRRangeButton Button;
    local vector Palm;
    local byte Pose;
    local int Hand,Revision;
    if(RangeArena != None) RangeArena.UpdateEligibility();
    Super.Tick(DeltaTime);
    foreach WorldInfo.AllControllers(class'KFPlayerController',PlayerPC)
    {
        PC=KF2VRNetPlayerController(PlayerPC);
        if(WorldInfo.NetMode != NM_Standalone && (PC == None || PC.NetChannel == None)) continue;
        for(Hand=0;Hand<2;++Hand)
        {
            if(WorldInfo.NetMode == NM_Standalone)
            {
                Human=KFPawn_Human(PlayerPC.Pawn);
                if(RangePractice == None || !RangePractice.PlayerContactHand(Human,Hand,Palm,Pose,Revision)) continue;
            }
            else if(!PC.NetChannel.ContactHand(Hand,Human,Palm,Pose,Revision)) continue;
            if((Pose & 64)!=0) continue;
            foreach WorldInfo.DynamicActors(class'VRRangeButton',Button) Button.TryHandPress(Human,Palm);
        }
    }
}
function StartMatch()
{
    local KFPlayerController PC;
    Super(KFGameInfo).StartMatch();
    GotoState('RangeOpen');
    SetTimer(3.0,true,'RespawnRangePlayers');
    foreach WorldInfo.AllControllers(class'KFPlayerController',PC) PC.ClientMatchStarted();
}
function RespawnRangePlayers()
{
    local KFPlayerController PC;
    foreach WorldInfo.AllControllers(class'KFPlayerController',PC)
    {
        if(!PC.bIsPlayer || PC.PlayerReplicationInfo == None || PC.PlayerReplicationInfo.bOnlySpectator) continue;
        if(PC.Pawn != None && PC.Pawn.Health>0) continue;
        if(PC.Pawn != None) PC.UnPossess();
        RestartPlayer(PC);
    }
}
function CheckWaveEnd(optional bool bForceWaveEnd=false) {}
function StartWave() {}
function SkipTrader(int TimeAfterSkipTrader) {}
function CloseTraderTimer() {}
state RangeOpen
{
    function BeginState(name PreviousStateName)
    {
        // Select the replicated pod before announcing trader time to clients.
        if(MyKFGRI.NextTrader == None)
        {
            if(TraderList.Length == 0) InitTraderList();
            SetupNextTrader();
        }
        MyKFGRI.SetWaveActive(false);
        MyKFGRI.bTraderIsOpen=true;
        MyKFGRI.bForceSkipTraderUI=false;
        MyKFGRI.bStopCountDown=true;
        MyKFGRI.RemainingTime=0;
        MyKFGRI.RemainingMinute=0;
        StartHumans();
        // The stock game wrapper starts a countdown; open the pod directly.
        // Clients use the same GRI operation through bTraderIsOpen repnotify.
        MyKFGRI.OpenTrader();
        MyKFGRI.bForceNetUpdate=true;
    }
}
defaultproperties
{
    GameName="KF2 VR Firing Range"
    bRecordGameStatsFile=false
}





