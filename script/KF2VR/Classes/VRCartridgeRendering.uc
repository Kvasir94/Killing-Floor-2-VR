// Revolver cartridge meshes keep stock cylinder, reload and socket behavior.
// Preserve their render settings while the presenter places them in the world.
class VRCartridgeRendering extends Object dependson(Scene);

struct CartridgeRenderState
{
    var KFSkeletalMeshComponent Component;
    var ESceneDepthPriorityGroup DepthGroup, OwnerDepthGroup;
    var bool bOwnerDepth;
    var float FOV;
};
var array<CartridgeRenderState> Saved;

simulated function Capture(KFWeapon W)
{
    local KFWeap_PistolBase P;
    local KFSkeletalMeshComponent C;
    local CartridgeRenderState Snapshot;
    local int I;
    Restore();
    if (W == None || W.bDeleteMe
        || (!W.IsA('KFWeap_Revolver_SW500') && !W.IsA('KFWeap_Revolver_Rem1858'))) return;
    P = KFWeap_PistolBase(W);
    if (P == None) return;
    for (I = 0; I < P.BulletMeshComponents.Length; ++I)
    {
        C = P.BulletMeshComponents[I];
        if (C == None) continue;
        Snapshot.Component = C;
        Snapshot.DepthGroup = C.DepthPriorityGroup;
        Snapshot.bOwnerDepth = C.bUseViewOwnerDepthPriorityGroup;
        Snapshot.OwnerDepthGroup = C.ViewOwnerDepthPriorityGroup;
        Snapshot.FOV = C.FOV;
        Saved.AddItem(Snapshot);
    }
}

// Call after the weapon's SetFOV override has restored its main mesh, so the
// individual cartridge settings remain exact even if they originally differed.
simulated function Restore()
{
    local int I;
    for (I = 0; I < Saved.Length; ++I)
        if (Saved[I].Component != None)
        {
            Saved[I].Component.SetDepthPriorityGroup(Saved[I].DepthGroup);
            Saved[I].Component.SetViewOwnerDepthPriorityGroup(Saved[I].bOwnerDepth, Saved[I].OwnerDepthGroup);
            Saved[I].Component.SetFOV(Saved[I].FOV);
        }
    Saved.Length = 0;
}
