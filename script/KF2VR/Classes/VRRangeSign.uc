// Static replicated caption; each viewer owns the existing world-space panel.
// Signs have no interaction endpoint and consume no server presentation tick.
class VRRangeSign extends Actor;
var repnotify string Caption;
var VRRangeLabel Label;
replication { if(Role==ROLE_Authority && bNetDirty) Caption; }

function Configure(string Text)
{
    Caption=Text;
    bForceNetUpdate=true;
    UpdateLabel();
}
simulated function UpdateLabel()
{
    if(WorldInfo.NetMode==NM_DedicatedServer || Caption=="") return;
    if(Label==None) Label=Spawn(class'VRRangeLabel',self,,Location,Rotation);
    if(Label!=None)
    {
        Label.Caption=Caption;
        Label.bShowHint=false;
        if(Label.Display!=None) Label.Display.bNeedsUpdate=true;
    }
}
simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    UpdateLabel();
}
simulated event ReplicatedEvent(name VarName)
{
    if(VarName=='Caption') UpdateLabel();
    else Super.ReplicatedEvent(VarName);
}
simulated event Destroyed()
{
    if(Label!=None) Label.Destroy();
    Super.Destroyed();
}
defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bNetInitialRotation=true
    bAlwaysRelevant=true
    bHidden=false
    bCollideActors=false
    bBlockActors=false
}
