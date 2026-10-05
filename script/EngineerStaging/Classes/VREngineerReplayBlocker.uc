// An owned, removable collision fixture. It must block real traces; drawing
// a debug line over the target is not an occlusion test.
class VREngineerReplayBlocker extends Actor;

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=true
    bBlockActors=true
    bProjTarget=true
    Begin Object Class=CylinderComponent Name=BlockerCylinder
        CollisionRadius=80
        CollisionHeight=100
        CollideActors=true
        BlockActors=true
        BlockZeroExtent=true
        BlockNonZeroExtent=true
    End Object
    CollisionComponent=BlockerCylinder
    Components.Add(BlockerCylinder)
}
