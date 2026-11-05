// Public death loot outlives its former pawn and owner transport. Exact
// detached inventory actors belong here until one verified adoption commits.
class VRWorldDropEscrow extends Actor;

var VRWorldDropRegistry Registry;
var float NextCheck;

event Tick(float DeltaTime)
{
    if (Registry == None) { Destroy(); return; }
    if (WorldInfo.RealTimeSeconds < NextCheck) return;
    NextCheck = WorldInfo.RealTimeSeconds + 0.25;
    Registry.Compact();
    if (Registry.Guns.Length == 0) Destroy();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bKillDuringLevelTransition=true
}
