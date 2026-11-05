// Explicitly summoned nonshipping fixture: exercise stock absolute travel.
// No configurable URL, input spoofing, authorization changes or lease changes.
class VRAbsoluteTravelProbe extends Actor;

event PostBeginPlay()
{
    super.PostBeginPlay();
    // Let the existing console action finish its receipt before world travel.
    SetTimer(0.25, false, 'TravelOnce');
}

function Refuse(string Reason)
{
    `log("KF2VR_ABSOLUTE_TRAVEL failed=" $ Reason);
    Destroy();
}

function TravelOnce()
{
    local VRLocalTestControl Control, Candidate;
    local KFPlayerController PC, LocalPC;
    local int Controls, Players;
    local string URL;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority)
    { Refuse("requires-standalone-authority"); return; }
    foreach WorldInfo.AllActors(class'VRLocalTestControl', Candidate)
        if (!Candidate.bDeleteMe && Candidate.Authorized() && Candidate.NativeTestWorldClosed == 0)
        { Control = Candidate; ++Controls; }
    if (Controls != 1 || Control == None || Control.bJobActive || Control.Diagnostic != None)
    { Refuse("requires-idle-ordinary-local-control"); return; }
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
        if (!PC.bDeleteMe && PC.IsLocalController() && LocalPlayer(PC.Player) != None
            && PC.PlayerReplicationInfo != None)
        { LocalPC = PC; ++Players; }
    if (Players != 1 || LocalPC == None
        || Control.LocalPlayerByID(LocalPC.PlayerReplicationInfo.PlayerID) != LocalPC)
    { Refuse("requires-exact-local-player"); return; }
    URL = "KF-Outpost?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?GameLength=0"
        $ "?VRNormalGame=1?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo";
    `log("KF2VR_ABSOLUTE_TRAVEL dispatched=1 destination=KF-Outpost type=TRAVEL_Absolute");
    LocalPC.ClientTravel(URL, TRAVEL_Absolute);
    Destroy();
}

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
    bAlwaysRelevant=false
    bCollideActors=false
    LifeSpan=5
}
