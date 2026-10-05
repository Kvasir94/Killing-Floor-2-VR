// Selected blueprint -> held toolbox -> checked world placement. Neither
// preview/cancel/rotation nor changing weapons consumes any metal.
class VREngineerToolbox extends VREngineerWeapon;

var VREngineerPreview Preview;
var int PlacementYaw;
var string InvalidReason;

simulated function StartFire(byte FireModeNum)
{
    if (!CanStartSourceAction()) return;
    if (FireModeNum == 0 && !bPrimaryHeld)
    {
        bPrimaryHeld = true;
        if (!Engineer.PlaceSentry()) PlaySourceSound('wrench_hit_build_fail');
    }
    else if (FireModeNum == 1 && !bSecondaryHeld)
    {
        bSecondaryHeld = true;
        PlacementYaw = (PlacementYaw + 16384) & 65535;
    }
}

simulated function bool FindPlacement(out vector Point, out rotator Facing, out string Reason)
{
    local vector Start, Direction, Hit, HitNormal, Corner, Extent;
    local Actor Surface, Blocker;
    local PrimitiveComponent BlockerComponent;
    local Pawn P;
    local int I;
    Reason = "No ground";
    if (Engineer == None || !Engineer.IsOwnerAlive()) return false;
    // TF2's preview stays in front of the builder. VR uses the held toolbox's
    // forward bearing, while the floor search remains near the player's feet.
    Start = Instigator.GetPawnViewLocation();
    Direction = vector(bTrackedPose ? TrackedAim : Instigator.GetViewRotation());
    Direction.Z = 0;
    Direction = Normal(Direction);
    if (VSizeSq(Direction) < 0.5) return false;
    Point = Instigator.Location + Direction * 200;
    Point.Z = Instigator.Location.Z + 80;
    Surface = Trace(Hit, HitNormal, Point - vect(0,0,300), Point, true);
    if (Surface == None || Pawn(Surface) != None || (!Surface.bWorldGeometry && !Surface.bStatic)) return false;
    Point = Hit + vect(0,0,1);
    Facing = rotator(Direction);
    Facing.Pitch = 0; Facing.Roll = 0; Facing.Yaw += PlacementYaw;
    Reason = "Ground is too steep";
    if (HitNormal.Z < 0.9) return false;
    Reason = "Needs solid ground";
    for (I = 0; I < 4; ++I)
    {
        Corner = Point;
        Corner.X += (I < 2 ? -48 : 48);
        Corner.Y += ((I & 1) == 0 ? -48 : 48);
        Surface = Trace(Hit, HitNormal, Corner - vect(0,0,20), Corner + vect(0,0,20), true);
        if (Surface == None || HitNormal.Z < 0.9 || Abs(Hit.Z - Point.Z) > 12
            || (!Surface.bWorldGeometry && !Surface.bStatic)) return false;
    }
    Reason = "Blocked";
    Extent = vect(50.8,50.8,82.82);
    // A sweep that begins inside a collider can miss its initial overlap.
    // Query nearby collision bounds, then test the actual placement box
    // against each blocking component, including non-Pawn obstacles.
    foreach WorldInfo.CollidingActors(class'Actor', Blocker, VSize(Extent), Point + vect(0,0,84), true)
    {
        if (Blocker == None || Blocker == self || Blocker.bDeleteMe || !Blocker.bBlockActors) continue;
        foreach Blocker.ComponentList(class'PrimitiveComponent', BlockerComponent)
            if (BlockerComponent.CollideActors && BlockerComponent.BlockActors && BlockerComponent.BlockNonZeroExtent
                && PointCheckComponent(BlockerComponent, Point + vect(0,0,84), Extent)) return false;
    }
    Blocker = Trace(Hit, HitNormal, Point + vect(0,0,85), Point + vect(0,0,84), true, Extent);
    if (Blocker != None) return false;
    // Prevent placement through a wall even when the destination is clear.
    if (Trace(Hit, HitNormal, Point + vect(0,0,84), Start, false) != None) return false;
    foreach WorldInfo.AllPawns(class'Pawn', P)
    {
        if (P == None || P.bDeleteMe || !P.bCollideActors || P.CylinderComponent == None) continue;
        if (Abs(P.Location.Z - Point.Z - 83.82) < P.CylinderComponent.CollisionHeight + 83.82
            && VSize2D(P.Location - Point) < P.CylinderComponent.CollisionRadius + 71.85) return false;
    }
    Reason = "";
    return true;
}

simulated event Tick(float DeltaTime)
{
    local vector Point;
    local rotator Facing;
    local bool Valid;
    Super.Tick(DeltaTime);
    if (!CanUseSourceWeapon() || !Engineer.bBlueprintSelected) { HidePreview(); return; }
    Valid = FindPlacement(Point, Facing, InvalidReason) && Engineer.CanSelect(Engineer.SelectedBlueprint);
    if (Preview == None) Preview = Spawn(class'VREngineerPreview', self);
    if (Preview != None) Preview.ShowPlacement(Point, Facing, Valid);
}

simulated function HidePreview()
{
    if (Preview != None) { Preview.Destroy(); Preview = None; }
}

simulated function DetachWeapon()
{
    HidePreview();
    if (Engineer != None) Engineer.CancelBlueprint();
    Super.DetachWeapon();
}

simulated event Destroyed()
{
    HidePreview();
    Super.Destroyed();
}

defaultproperties
{
    FirstPersonMeshName="KF2VREngineer.Toolbox"
    PickupMeshName=""
    GroupPriority=204
}
