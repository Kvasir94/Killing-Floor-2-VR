// Dedicated-server half of the networked scripted replay: one NetScriptAgent
// per joining player. Loaded only by tools/replay/scripted_mp.py (?Mutator=).
// It readies each player itself a few seconds after login, so the server runs
// without VRNetAutoReady: that diagnostic also runs the held-inventory probe,
// which destroys a "third" weapon (the perk knife, or a gun the script was
// just given).
class NetScriptServer extends KFMutator;

var array<NetScriptAgent> Agents;
var array<float> LoginTimes;

function NotifyLogin(Controller NewPlayer)
{
    local NetScriptAgent Agent;
    Super.NotifyLogin(NewPlayer);
    if (PlayerController(NewPlayer) == None) return;
    Agent = Spawn(class'NetScriptAgent', NewPlayer);
    Agents.AddItem(Agent);
    LoginTimes.AddItem(WorldInfo.RealTimeSeconds);
    `log("KF2VR_SCRIPT_SERVER agent player=" $ NewPlayer.PlayerReplicationInfo.PlayerName @ "netmode=" $ WorldInfo.NetMode);
}

function NotifyLogout(Controller Exiting)
{
    local int I;
    for (I = Agents.Length - 1; I >= 0; --I)
        if (Agents[I] == None || Agents[I].Owner == Exiting)
        {
            if (Agents[I] != None) Agents[I].Destroy();
            Agents.Remove(I, 1);
            LoginTimes.Remove(I, 1);
        }
    Super.NotifyLogout(Exiting);
}

event Tick(float DT)
{
    local int I;
    local PlayerController PC;
    local KFPlayerReplicationInfo PRI;
    Super.Tick(DT);
    for (I = 0; I < Agents.Length; ++I)
    {
        if (Agents[I] == None || WorldInfo.RealTimeSeconds - LoginTimes[I] < 8.0) continue;
        PC = PlayerController(Agents[I].Owner);
        PRI = PC == None ? None : KFPlayerReplicationInfo(PC.PlayerReplicationInfo);
        if (PRI != None && !PRI.bOnlySpectator && !PRI.bReadyToPlay)
        {
            PRI.bReadyToPlay = true;
            `log("KF2VR_SCRIPT_SERVER ready player=" $ PRI.PlayerName);
        }
    }
}
