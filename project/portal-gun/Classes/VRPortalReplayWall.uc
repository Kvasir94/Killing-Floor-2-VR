// Owned replay geometry: the broad, planar top of a cylinder. Never spawned
// in ordinary matches. World-geometry collision exercises the real trace path.
class VRPortalReplayWall extends Actor;

defaultproperties
{
    RemoteRole=ROLE_None
    Tag=Portalable
    bStatic=false
    bMovable=false
    bWorldGeometry=true
    bHidden=true
    bCollideActors=true
    bBlockActors=true
    bProjTarget=true
    Begin Object Class=CylinderComponent Name=ReplayWallCollision
        CollisionRadius=400
        CollisionHeight=10
        CollideActors=true
        BlockActors=true
        BlockZeroExtent=true
        BlockNonZeroExtent=true
    End Object
    CollisionComponent=ReplayWallCollision
    Components.Add(ReplayWallCollision)
}
