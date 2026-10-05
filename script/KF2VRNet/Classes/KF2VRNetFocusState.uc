class KF2VRNetFocusState extends Actor;

var bool bFocusRequested;
var bool bFocusActive;
var float EffectiveFocusScale;
var int Revision;

replication
{
    if (Role == ROLE_Authority)
        bFocusRequested, bFocusActive, EffectiveFocusScale, Revision;
}

function Publish(bool bRequested, bool bActive, float Scale)
{
    if (Role != ROLE_Authority) return;
    if (!bActive) Scale = 1.0;
    if (bFocusRequested == bRequested && bFocusActive == bActive
        && Abs(EffectiveFocusScale - Scale) <= 0.0001) return;
    bFocusRequested = bRequested;
    bFocusActive = bActive;
    EffectiveFocusScale = Scale;
    if (Revision == 2147483647)
        Revision = 1;
    else
        ++Revision;
    bForceNetUpdate = true;
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bOnlyRelevantToOwner=false
    bReplicateMovement=false
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=5.0
    EffectiveFocusScale=1.0
}
