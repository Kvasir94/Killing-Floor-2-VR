// Pose-following visibility bounds for the floating-hand mesh. The asset's
// noncolliding bone spheres are measured from every weighted source vertex;
// these are culling shapes, never simulated bodies or interaction contacts.
class VRHandBounds extends Object;

var PhysicsAsset Asset;

static function Apply(KFSkeletalMeshComponent Mesh)
{
    if (Mesh == None || default.Asset == None) return;
    Mesh.SetHasPhysicsAssetInstance(false);
    // SetPhysicsAsset refreshes bHasValidBodies even without an instance;
    // CalcAABB uses the posed BoundsBodies regardless of collision flags.
    Mesh.SetPhysicsAsset(default.Asset);
    Mesh.bComponentUseFixedSkelBounds = false;
    Mesh.bUseBoundsFromParentAnimComponent = false;
}

defaultproperties
{
    Asset=PhysicsAsset'KF2VRHands.VRFloatingHandsBounds'
}
