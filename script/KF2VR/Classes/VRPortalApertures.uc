// Holds both portals' apertures (the surfaces that show the view through).
// Each portal capture names this actor as its ViewDestination, and KF2's
// portal renderer hides every component of that actor inside the capture:
// a portal seen through the other portal shows its flat fill instead of a
// stale view of itself. That is Portal 2's recursion cutoff, with no native
// hidden-set hook.
class VRPortalApertures extends Actor;

var StaticMeshComponent Apertures[2];

simulated function bool Prepare(StaticMesh Mesh)
{
    local int I;
    if (Mesh == None) return false;
    for (I = 0; I < 2; ++I)
    {
        Apertures[I].SetStaticMesh(Mesh);
        Apertures[I].SetAbsolute(true, true, true);
        Apertures[I].SetHidden(true);
    }
    return true;
}

simulated function Place(int Index, vector Center, rotator Basis, float HalfWidth, float HalfHeight,
    MaterialInterface Material)
{
    local vector Scale;
    if (Index < 0 || Index > 1) return;
    Scale.X = 1;
    Scale.Y = HalfWidth;
    Scale.Z = HalfHeight;
    Apertures[Index].SetMaterial(0, Material);
    Apertures[Index].SetScale3D(Scale);
    Apertures[Index].SetTranslation(Center + vector(Basis) * 0.5);
    Apertures[Index].SetRotation(Basis);
}

simulated function Show(int Index, bool bShow)
{
    if (Index >= 0 && Index <= 1 && Apertures[Index].HiddenGame == bShow) Apertures[Index].SetHidden(!bShow);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bNoDelete=false
    bMovable=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    TickGroup=TG_PostUpdateWork

    Begin Object Class=StaticMeshComponent Name=ApertureA
        HiddenGame=true
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDynamicLights=false
        bUseAsOccluder=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    Apertures(0)=ApertureA
    Components.Add(ApertureA)

    Begin Object Class=StaticMeshComponent Name=ApertureB
        HiddenGame=true
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDynamicLights=false
        bUseAsOccluder=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    Apertures(1)=ApertureB
    Components.Add(ApertureB)
}
