// One world-space hologram for VR Training: the step card in front of the
// player, or a small button tag over one hand. It draws through its owner
// into a ScriptedTexture on the same unlit translucent quad the wheel and the
// damage numbers use, and redraws only when its content key changes.
class VRTrainingPanel extends Actor;

var StaticMeshComponent Surface;
var ScriptedTexture Display;
var MaterialInstanceConstant DisplayMaterial;
var VRTraining DisplayOwner;
var int Slot;          // -1 the step card, 0/1 that hand's tag
var int TexWidth, TexHeight;
var string ContentKey;
var float Opacity;
var bool bShown;

simulated function bool InitializePanel(VRTraining NewOwner, int NewSlot, int Width, int Height)
{
    local Material ParentMaterial;
    local Texture ExistingTexture;
    local LinearColor White;

    DisplayOwner = NewOwner;
    Slot = NewSlot;
    TexWidth = Width; TexHeight = Height;
    ParentMaterial = Material(DynamicLoadObject(
        "ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (ParentMaterial == None || ParentMaterial.LightingModel != MLM_Unlit
        || ParentMaterial.BlendMode != BLEND_Translucent || ParentMaterial.bDisableDepthTest
        || !ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture))
        return false;
    Display = ScriptedTexture(class'ScriptedTexture'.static.Create(TexWidth, TexHeight, PF_A8R8G8B8, MakeLinearColor(0,0,0,0)));
    if (Display == None) return false;
    Display.TargetGamma = 1.0;
    Display.bNeedsTwoCopies = true;
    Display.Render = RenderDisplay;
    DisplayMaterial = new(self) class'MaterialInstanceConstant';
    DisplayMaterial.SetParent(ParentMaterial);
    DisplayMaterial.SetTextureParameterValue('Texture_D', Display);
    White = MakeLinearColor(1,1,1,1);
    DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', White);
    // Brighter than the wheel's 0.24: the card is read at arm's length and more,
    // often against bright snow or fire.
    DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.45);
    DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', 0);

    Surface = new(self) class'StaticMeshComponent';
    Surface.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
    Surface.SetDepthPriorityGroup(SDPG_World);
    Surface.CastShadow = false;
    Surface.bCastDynamicShadow = false;
    Surface.SetActorCollision(false, false, false);
    Surface.SetTraceBlocking(false, false);
    Surface.SetBlockRigidBody(false);
    Surface.bUseAsOccluder = false;
    Surface.SetAbsolute(true, true, true);
    Surface.SetHidden(true);
    Surface.SetMaterial(0, DisplayMaterial);
    AttachComponent(Surface);
    SetCollisionType(COLLIDE_NoCollision);
    SetCollision(false, false);
    return true;
}

simulated function RenderDisplay(Canvas C)
{
    if (DisplayOwner != None && C != None) DisplayOwner.RenderPanel(Slot, C, TexWidth, TexHeight);
}

simulated function SetContent(string Key)
{
    if (Key == ContentKey || Display == None) return;
    ContentKey = Key;
    Display.bNeedsUpdate = true;
}

// Width and height in UU; the cube is 256 UU and its display face is -X.
simulated function Place(vector At, rotator Facing, float Width, float Height, float Alpha)
{
    local vector Scale;
    if (Surface == None) return;
    Scale.X = 0.025 / 256.0;
    Scale.Y = Width / 256.0;
    Scale.Z = Height / 256.0;
    Surface.SetTranslation(At);
    Surface.SetRotation(Facing);
    Surface.SetScale3D(Scale);
    Alpha = FClamp(Alpha, 0, 1);
    if (Abs(Alpha - Opacity) > 0.01 || (Alpha >= 1 && Opacity < 1))
    {
        Opacity = Alpha;
        DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', Opacity);
    }
    if (!bShown) { bShown = true; Surface.SetHidden(false); }
    Surface.ForceUpdate(true);
}

simulated function Hide()
{
    if (Surface == None || !bShown) return;
    bShown = false;
    Opacity = 0;
    DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', 0);
    Surface.SetHidden(true);
    Surface.ForceUpdate(true);
}

simulated event Destroyed()
{
    if (Display != None) { Display.Render = None; Display.bNeedsUpdate = false; }
    if (Surface != None) DetachComponent(Surface);
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
