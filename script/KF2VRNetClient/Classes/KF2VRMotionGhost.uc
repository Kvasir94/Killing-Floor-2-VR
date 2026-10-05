// Unpossessed local cosmetic rig. Never sends movement, inventory or damage RPCs.
class KF2VRMotionGhost extends KFPawn_Human;

simulated function BindAppearance(KFPawn_Human Source)
{
    local int I;
    if (Source == None || Source.Mesh == None || Mesh == None) return;
    Mesh.SetSkeletalMesh(Source.Mesh.SkeletalMesh);
    Mesh.AnimSets = Source.Mesh.AnimSets;
    Mesh.SetAnimTreeTemplate(AnimTree(Source.Mesh.Animations));
    Mesh.SetTranslation(Source.Mesh.Translation);
    Mesh.SetRotation(Source.Mesh.Rotation);
    Mesh.SetScale(Source.Mesh.Scale); Mesh.SetScale3D(Source.Mesh.Scale3D);
    for (I = 0; I < Source.Mesh.GetNumElements(); ++I) Mesh.SetMaterial(I, Source.Mesh.GetMaterial(I));
    Mesh.SetOwnerNoSee(false); Mesh.SetOnlyOwnerSee(false);
    Mesh.SetActorCollision(false, false); Mesh.SetTraceBlocking(false, false);
    Mesh.bUpdateSkelWhenNotRendered = true; Mesh.bTickAnimNodesWhenNotRendered = true;
    SetCollision(false, false); SetPhysics(PHYS_None);
}

// Only this collisionless cosmetic actor runs the native stance transition.
simulated function ApplyCrouch(bool bCrouched)
{
    if (bIsCrouched == bCrouched) return;
    ShouldCrouch(bCrouched);
    if (bCrouched) ForceCrouch();
    else
    {
        Velocity = vect(0,0,0);
        SetPhysics(PHYS_Walking); AutonomousPhysics(0.001); SetPhysics(PHYS_None);
    }
}
simulated event Tick(float DeltaTime) {}
defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    bNoEncroachCheck=true
    bReplicateMovement=false
    Physics=PHYS_None
    Health=100
}
