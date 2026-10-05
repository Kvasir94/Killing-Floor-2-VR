// Billboard surface for a single 3D world-space damage number popup.
// Renders to a ScriptedTexture once upon activation, then updates world translation
// and fades material opacity without re-rasterizing the texture.
class VRDamagePopupPanel extends Actor;

var StaticMeshComponent Surface;
var ScriptedTexture Display;
var MaterialInstanceConstant DisplayMaterial;
var VRDamagePopups DisplayOwner;
var int PanelIndex;
var bool bInitialized;
var bool bPanelVisible;

const TexWidth = 256;
const TexHeight = 64;

simulated function bool InitializePanel(VRDamagePopups NewOwner, int Index)
{
    local Material ParentMaterial;
    local Texture ExistingTexture;
    local LinearColor White;

    DisplayOwner = NewOwner;
    PanelIndex = Index;

    ParentMaterial = Material(DynamicLoadObject(
        "ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal",
        class'Material', true));
    if (ParentMaterial == None || !ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture))
        return false;

    Display = ScriptedTexture(class'ScriptedTexture'.static.Create(
        TexWidth, TexHeight, PF_A8R8G8B8, MakeLinearColor(0, 0, 0, 0)));
    if (Display == None) return false;

    Display.TargetGamma = 1.0;
    Display.bNeedsTwoCopies = true;
    Display.Render = RenderDisplay;

    DisplayMaterial = new(self) class'MaterialInstanceConstant';
    DisplayMaterial.SetParent(ParentMaterial);
    DisplayMaterial.SetTextureParameterValue('Texture_D', Display);

    White = MakeLinearColor(1, 1, 1, 1);
    DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', White);
    DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.12);
    DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', 1.0);

    Surface = new(self) class'StaticMeshComponent';
    Surface.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
    Surface.SetDepthPriorityGroup(SDPG_World);
    Surface.CastShadow = false;
    Surface.bCastDynamicShadow = false;
    Surface.SetActorCollision(false, false, false);
    Surface.SetTraceBlocking(false, false);
    Surface.SetBlockRigidBody(false);
    Surface.SetAbsolute(true, true, true);
    Surface.SetHidden(true);
    Surface.SetMaterial(0, DisplayMaterial);
    AttachComponent(Surface);

    bInitialized = true;
    return true;
}

simulated function RenderDisplay(Canvas C)
{
    if (DisplayOwner != None)
        DisplayOwner.RenderSlot(PanelIndex, C);
}

simulated function SetOpacity(float Opacity)
{
    if (DisplayMaterial != None)
        DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', FClamp(Opacity, 0.0, 1.0));
}

simulated function SetPlacement(vector NewLoc, rotator NewRot, vector MeshScale)
{
    if (Surface != None)
    {
        Surface.SetTranslation(NewLoc);
        Surface.SetRotation(NewRot);
        Surface.SetScale3D(MeshScale);
        if (!bPanelVisible)
        {
            Surface.SetHidden(false);
            bPanelVisible = true;
        }
        Surface.ForceUpdate(true);
    }
}

simulated function Hide()
{
    if (Surface != None && bPanelVisible)
    {
        Surface.SetHidden(true);
        bPanelVisible = false;
        Surface.ForceUpdate(true);
    }
}

simulated event Destroyed()
{
    if (Display != None)
    {
        Display.Render = None;
        Display.bNeedsUpdate = false;
    }
    if (Surface != None)
        DetachComponent(Surface);
    DisplayOwner = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    TickGroup=TG_PostUpdateWork
}
