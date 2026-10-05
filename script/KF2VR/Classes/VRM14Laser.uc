// Retain the M14's physical laser housing. Its stock dot follows screen aim
// and only updates for Pawn.Weapon, so the shared tracked laser owns the beam.
class VRM14Laser extends Object dependson(Scene);

struct LaserRenderState
{
    var PrimitiveComponent Component;
    var ESceneDepthPriorityGroup DepthGroup, OwnerDepthGroup;
    var bool bOwnerDepth, bHidden, bOwnerNoSee, bOverrideVisibility;
    var float FOV;
};
var KFLaserSightAttachment Attachment;
var array<LaserRenderState> Saved;
var bool bOriginalVisible, bWorldApplied;
var float StockFOV;

simulated function SaveComponent(PrimitiveComponent C)
{
    local LaserRenderState S;
    local KFSkeletalMeshComponent M;
    if (C == None) return;
    S.Component = C; S.DepthGroup = C.DepthPriorityGroup;
    S.OwnerDepthGroup = C.ViewOwnerDepthPriorityGroup; S.bOwnerDepth = C.bUseViewOwnerDepthPriorityGroup;
    S.bHidden = C.HiddenGame; S.bOwnerNoSee = C.bOwnerNoSee;
    M = KFSkeletalMeshComponent(C);
    if (M != None)
    {
        S.FOV = bWorldApplied ? StockFOV : M.FOV;
        S.bOverrideVisibility = M.bOverrideAttachmentOwnerVisibility;
    }
    Saved.AddItem(S);
}

simulated function Capture(KFWeapon W)
{
    local bool bWasWorldApplied;
    if (W == None || W.LaserSight == None || Attachment == W.LaserSight) return;
    bWasWorldApplied = bWorldApplied;
    Release(false);
    bWorldApplied = bWasWorldApplied;
    Attachment = W.LaserSight; bOriginalVisible = Attachment.IsVisible;
    SaveComponent(Attachment.LaserSightMeshComp);
    SaveComponent(Attachment.LaserBeamMeshComp);
    SaveComponent(Attachment.LaserDotMeshComp);
}

simulated function Update(VRHandsBridge B)
{
    bWorldApplied = true;
    if (Attachment == None) return;
    // Do not ChangeVisibility(false): that would also hide the housing.
    Attachment.IsVisible = false;
    if (Attachment.LaserDotMeshComp != None) Attachment.LaserDotMeshComp.SetHidden(true);
    if (Attachment.LaserBeamMeshComp != None) Attachment.LaserBeamMeshComp.SetHidden(true);
    if (Attachment.LaserSightMeshComp != None)
    {
        B.UseWorldRendering(Attachment.LaserSightMeshComp);
        Attachment.LaserSightMeshComp.SetHidden(false);
        Attachment.LaserSightMeshComp.SetOwnerNoSee(false);
        Attachment.LaserSightMeshComp.bOverrideAttachmentOwnerVisibility = false;
    }
}

simulated function Release(bool bAbandon)
{
    local int I;
    local KFSkeletalMeshComponent M;
    if (!bAbandon)
    {
        if (Attachment != None) Attachment.IsVisible = bOriginalVisible;
        for (I = 0; I < Saved.Length; ++I)
            if (Saved[I].Component != None)
            {
                Saved[I].Component.SetDepthPriorityGroup(Saved[I].DepthGroup);
                Saved[I].Component.SetViewOwnerDepthPriorityGroup(Saved[I].bOwnerDepth, Saved[I].OwnerDepthGroup);
                Saved[I].Component.SetHidden(Saved[I].bHidden);
                Saved[I].Component.SetOwnerNoSee(Saved[I].bOwnerNoSee);
                M = KFSkeletalMeshComponent(Saved[I].Component);
                if (M != None) { M.SetFOV(Saved[I].FOV); M.bOverrideAttachmentOwnerVisibility = Saved[I].bOverrideVisibility; }
            }
    }
    Attachment = None; Saved.Length = 0; bWorldApplied = false;
}
