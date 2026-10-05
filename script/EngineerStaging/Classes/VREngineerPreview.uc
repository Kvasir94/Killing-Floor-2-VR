class VREngineerPreview extends Actor;

var SkeletalMeshComponent BlueprintMesh;
var array<MaterialInterface> ValidMaterials;
var array<MaterialInstanceConstant> InvalidMaterials;
var bool bPlacementValid;

simulated event PostBeginPlay()
{
    local int I;
    local LinearColor RejectedTint;
    local MaterialInstanceConstant Rejected;
    Super.PostBeginPlay();
    BlueprintMesh.SetSkeletalMesh(SkeletalMesh(DynamicLoadObject("KF2VREngineer.SentryBlueprint", class'SkeletalMesh', true)));
    RejectedTint = MakeLinearColor(1,0.15,0.15,1);
    for (I = 0; I < BlueprintMesh.GetNumElements(); ++I)
    {
        ValidMaterials.AddItem(BlueprintMesh.GetMaterial(I));
        Rejected = new(self) class'MaterialInstanceConstant';
        Rejected.SetParent(ValidMaterials[I]);
        Rejected.SetVectorParameterValue('EngineerTint', RejectedTint);
        InvalidMaterials.AddItem(Rejected);
    }
}

simulated function ShowPlacement(vector Point, rotator Facing, bool Valid)
{
    local int I;
    SetLocation(Point); SetRotation(Facing);
    bPlacementValid = Valid;
    for (I = 0; I < BlueprintMesh.GetNumElements(); ++I)
        BlueprintMesh.SetMaterial(I, Valid ? ValidMaterials[I] : InvalidMaterials[I]);
    BlueprintMesh.SetHidden(false);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    Begin Object Class=SkeletalMeshComponent Name=OriginalBlueprint
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
        CastShadow=false
        bCastDynamicShadow=false
        bAcceptsLights=false
        DepthPriorityGroup=SDPG_World
    End Object
    BlueprintMesh=OriginalBlueprint
    Components.Add(OriginalBlueprint)
}
