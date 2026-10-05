class VREngineerPanel extends Actor;

var StaticMeshComponent Surface;
var ScriptedTexture Display;
var MaterialInstanceConstant DisplayMaterial;
var VREngineerHUD HUD;
var bool bDestruction;

simulated function Initialize(VREngineerHUD NewHUD)
{
    local Material Parent;
    local LinearColor White;
    HUD = NewHUD;
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (Parent == None) return;
    Display = ScriptedTexture(class'ScriptedTexture'.static.Create(656, 202, PF_A8R8G8B8, MakeLinearColor(0,0,0,0)));
    Display.TargetGamma = 1; Display.bNeedsTwoCopies = true;
    Display.Render = RenderDisplay;
    DisplayMaterial = new(self) class'MaterialInstanceConstant';
    DisplayMaterial.SetParent(Parent);
    DisplayMaterial.SetTextureParameterValue('Texture_D', Display);
    White = MakeLinearColor(1,1,1,1);
    DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', White);
    DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.08);
    Surface.SetMaterial(0, DisplayMaterial);
}

simulated function RenderDisplay(Canvas C)
{
    if (HUD != None) HUD.RenderMenu(C, bDestruction);
}

simulated function Place(vector Position, rotator Orientation)
{
    if (Display == None) return;
    SetHidden(false);
    Surface.SetTranslation(Position);
    Surface.SetRotation(Orientation);
    Surface.SetScale3D(vect(0.0001,0.3,0.09238));
    Surface.ForceUpdate(true);
    Display.bNeedsUpdate = true;
}

simulated event Destroyed()
{
    if (Display != None) { Display.Render = None; Display.bNeedsUpdate = false; }
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    Begin Object Class=StaticMeshComponent Name=PanelSurface
        StaticMesh=StaticMesh'EngineMeshes.Cube'
        DepthPriorityGroup=SDPG_World
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
        CastShadow=false
        bCastDynamicShadow=false
    End Object
    Surface=PanelSurface
    Components.Add(PanelSurface)
}
