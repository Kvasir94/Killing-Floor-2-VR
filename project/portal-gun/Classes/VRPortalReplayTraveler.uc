// Small owned pawn fixture for collision/travel replay; never a live player.
class VRPortalReplayTraveler extends Pawn;

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=true
    bBlockActors=true
    bCollideWorld=true
    bCanTeleport=true
    bCanBeDamaged=false
    Physics=PHYS_None
    Health=100
    Begin Object Name=CollisionCylinder
        CollisionRadius=16
        CollisionHeight=32
        CollideActors=true
        BlockActors=true
        BlockZeroExtent=true
        BlockNonZeroExtent=true
    End Object
}
