// Explicit replay entry point. Merely loading the Portal Gun does not spawn it.
class VRPortalReplayMutator extends KFMutator;

var VRPortalReplay Replay;
var bool bReplayRequested;

function InitMutator(string Options, out string ErrorMessage)
{
    Super.InitMutator(Options,ErrorMessage);
    bReplayRequested=WorldInfo.Game.ParseOption(Options,"VrPortalReplay") ~= "1";
}

simulated function PostBeginPlay()
{
    Super.PostBeginPlay();
    if (WorldInfo.NetMode==NM_Standalone && Role==ROLE_Authority) SetTimer(0.25,true,'TryStartReplay');
}

function TryStartReplay()
{
    local KFPlayerController PC;
    local KFPawn_Human P;
    local KFGameReplicationInfo GRI;
    local VRDemo Demo;
    if (!bReplayRequested || Replay!=None) return;
    GRI=KFGameReplicationInfo(WorldInfo.GRI);
    if (GRI==None || !GRI.bMatchHasBegun || GRI.bMatchIsOver) return;
    // VRDemo creates its bridge only after every starter grant is complete.
    // Do not move/equip the replay pawn while that inventory setup still owns
    // it; the same match-start flag precedes both asynchronous sequences.
    foreach WorldInfo.AllActors(class'VRDemo',Demo)
        if (Demo.HandsBridge == None) return;
    foreach WorldInfo.AllControllers(class'KFPlayerController',PC)
    {
        P=KFPawn_Human(PC.Pawn);
        if (PC.IsLocalController() && P!=None && P.Health>0 && P.InvManager!=None && P.Weapon!=None
            && KFPawn_Customization(P)==None)
        {
            Replay=Spawn(class'VRPortalReplay',self);
            if (Replay!=None) { ClearTimer('TryStartReplay'); Replay.StartReplay(P); }
            return;
        }
    }
}

simulated event Destroyed()
{
    if (Replay!=None) Replay.Destroy();
    Super.Destroyed();
}

defaultproperties { RemoteRole=ROLE_None }
