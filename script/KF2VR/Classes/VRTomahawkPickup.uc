// A dropped RAVEN-7 shows the RAVEN-7. The stock pickup copies the weapon's
// template component and asks native code for the mesh; dress that component
// with the authored mesh and materials on every machine that draws it. The
// prop's UCX boxes give it stock rigid-body tumbling.
class VRTomahawkPickup extends KFDroppedPickup;

simulated function SetPickupMesh(PrimitiveComponent NewPickupMesh)
{
    local StaticMeshComponent Visual;
    Super.SetPickupMesh(NewPickupMesh);
    Visual = StaticMeshComponent(MyMeshComp);
    if (Visual == None) return;
    if (Visual.StaticMesh == None)
        Visual.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VRHands.VRTomahawk", class'StaticMesh', true)));
    if (WorldInfo.NetMode != NM_DedicatedServer) class'VRTomahawkMaterials'.static.Apply(self, Visual);
}

auto state Pickup
{
    // Only a player with tracked hands can take it: its throw and recall
    // have no desktop controls. Stock rules (delay, instigator, walls) follow.
    function bool ValidTouch(Pawn Other)
    {
        return class'VRWeap_Tomahawk'.static.CanWield(self, Other) && Super.ValidTouch(Other);
    }
}
