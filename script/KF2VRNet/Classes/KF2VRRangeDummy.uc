// Replicated practice partner; appearance follows the player who respawned it.
class KF2VRRangeDummy extends KFPawn_Human;
var repnotify KFPawn_Human AppearanceSource;
var private bool bAppearanceReady;
replication { if (Role == ROLE_Authority) AppearanceSource; }

simulated function BindAppearance()
{
    local int I;
    if (AppearanceSource == None || AppearanceSource.Mesh == None || Mesh == None
        || AppearanceSource.Mesh.SkeletalMesh == None) return;
    Mesh.SetSkeletalMesh(AppearanceSource.Mesh.SkeletalMesh);
    Mesh.AnimSets = AppearanceSource.Mesh.AnimSets;
    Mesh.SetAnimTreeTemplate(AnimTree(AppearanceSource.Mesh.Animations));
    Mesh.SetTranslation(AppearanceSource.Mesh.Translation);
    Mesh.SetRotation(AppearanceSource.Mesh.Rotation);
    Mesh.SetScale(AppearanceSource.Mesh.Scale);
    Mesh.SetScale3D(AppearanceSource.Mesh.Scale3D);
    for (I=0; I<AppearanceSource.Mesh.GetNumElements(); ++I)
        Mesh.SetMaterial(I, AppearanceSource.Mesh.GetMaterial(I));
    Mesh.SetOwnerNoSee(false);
    Mesh.SetOnlyOwnerSee(false);
    Mesh.bUpdateSkelWhenNotRendered=true;
    Mesh.bTickAnimNodesWhenNotRendered=true;
    bAppearanceReady=true;
}
simulated event Tick(float DeltaTime)
{
    if (!bAppearanceReady) BindAppearance();
}
simulated function ApplyCrouch(bool bCrouched)
{
    if (bIsCrouched == bCrouched) return;
    ShouldCrouch(bCrouched);
    if (bCrouched) ForceCrouch();
    else
    {
        Velocity=vect(0,0,0);
        SetPhysics(PHYS_Walking); AutonomousPhysics(0.001); SetPhysics(PHYS_None);
    }
}
defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=true
    Physics=PHYS_None
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    bNoEncroachCheck=true
    Health=100
    NetUpdateFrequency=120
}
