// Physical stereo geometry, not a Canvas overlay. Wrist/readout panels use
// world depth; persistent session and alert plates use foreground DPG so map
// geometry cannot erase critical information.
class VRHUDPanel extends Actor;

var StaticMeshComponent Surface;
var StaticMeshComponent WatchCase;
var array<MaterialInstanceConstant> WatchMaterials;
// Flat tint per VRWristwatch material slot, in the generator's order:
// gunmetal case, display backing, ember guards, brass, leather cuff, canvas
// webbing, steel bezel. Slot 1 is unlit so the screen surround stays black.
var LinearColor WatchTints[7];
var ScriptedTexture Display;
var MaterialInstanceConstant DisplayMaterial;
var VRSpatialHUD DisplayOwner;
var int PanelIndex;
var bool bDrawn, bPresented, bReady;
var float LastPlacement;

// Per-component instances keep stock character material assets immutable.
static function MaterialInstanceConstant CreateHorzineMaterial(Object TargetOuter, string Prefix)
{
    local MaterialInstanceConstant M;
    local Texture2D Diffuse, Normal, Specular, Transmission;
    Diffuse = Texture2D(DynamicLoadObject("KF2VRHands." $ Prefix $ "_D", class'Texture2D', true));
    Normal = Texture2D(DynamicLoadObject("KF2VRHands." $ Prefix $ "_N", class'Texture2D', true));
    Specular = Texture2D(DynamicLoadObject("KF2VRHands." $ Prefix $ "_S", class'Texture2D', true));
    if (Diffuse == None || Normal == None || Specular == None) return None;
    M = new(TargetOuter) class'MaterialInstanceConstant';
    M.SetParent(MaterialInstanceConstant'CHR_1P_Arms_MAT.CHR_Master_1stP_Arms_MIC');
    M.SetTextureParameterValue('Tex2d_Diff', Diffuse);
    M.SetTextureParameterValue('Tex2d_Norm', Normal);
    M.SetTextureParameterValue('Tex2d_Spec', Specular);
    // The bare-arm parent enables skin transmission over the whole surface.
    // Leather and metal must not inherit its white subsurface mask; the hands'
    // _T mask restores it on skin only, where the stock arms had it.
    Transmission = Texture2D(DynamicLoadObject("KF2VRHands." $ Prefix $ "_T", class'Texture2D', true));
    M.SetTextureParameterValue('Tex2d_SSSMask', Transmission != None ? Transmission : Texture2D'EngineResources.Black');
    // Hands: the stock bare-arm MIC's broad SpecPower 10 and a weaker
    // reflection, so glove leather reads matte instead of wet. Watch and
    // tomahawk metal keep the tighter highlight.
    M.SetScalarParameterValue('scalar_reflectionIntensity', Prefix == "VRHorzineHands" ? 0.1 : 0.2);
    M.SetScalarParameterValue('Scalar_SpecPower', Prefix == "VRHorzineHands" ? 10 : 24);
    return M;
}

simulated function bool InitializePanel(VRSpatialHUD NewOwner, int Index)
{
    local Material ParentMaterial;
    local Texture ExistingTexture;
    local LinearColor White;
    local int Width, Height;
    DisplayOwner = NewOwner;
    PanelIndex = Index;
    bDrawn = false; bPresented = false; bReady = false;
    // A cooked single-sided master with direct texture RGB/alpha and explicit
    // emissive intensity. Particle vertex colors must not tint a static panel.
    // Shared assets remain untouched; only this instance's parameters change.
    ParentMaterial = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (ParentMaterial == None || ParentMaterial.LightingModel != MLM_Unlit
        || ParentMaterial.BlendMode != BLEND_Translucent || ParentMaterial.bDisableDepthTest
        || !ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture)) return false;
    // Each texture matches its quad's aspect (weapon readout 12 x 4.8 cm is
    // 2.5:1), and native HudTextAlpha registers exactly these twelve panels.
    // Panel 5, the pouch counter, shares the weapon readout target size;
    // panels 6-11 are 512 x 256 teammate tags.
    Height = Index == 0 ? 512 : ((Index < 3 || Index == 5) ? 320 : (Index == 3 ? 512 : 256));
    Width = Index == 0 ? 1024 : ((Index < 3 || Index == 5) ? 800 : (Index >= 6 ? 512 : 1024));
    Display = ScriptedTexture(class'ScriptedTexture'.static.Create(Width, Height, PF_A8R8G8B8, MakeLinearColor(0,0,0,0)));
    if (Display == None) return false;
    // The target already performs sRGB encoding. A second Canvas gamma
    // correction turns dark plates gray and red accents pink/white.
    Display.TargetGamma = 1.0;
    Display.Filter = TF_Linear;
    Display.bNeedsTwoCopies = true;
    Display.Render = RenderDisplay;
    DisplayMaterial = new(self) class'MaterialInstanceConstant';
    DisplayMaterial.SetParent(ParentMaterial);
    DisplayMaterial.SetTextureParameterValue('Texture_D', Display);
    White = MakeLinearColor(1,1,1,1);
    DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', White);
    DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', Index == 0 ? 0.6 : 0.24);
    DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', 1.0);
    Surface.SetMaterial(0, DisplayMaterial);
    Surface.SetDepthPriorityGroup((Index == 3 || Index == 4) ? SDPG_Foreground : SDPG_World);
    SetCollisionType(COLLIDE_NoCollision);
    SetCollision(false, false);
    Surface.SetActorCollision(false, false);
    Surface.SetTraceBlocking(false, false);
    Surface.SetBlockRigidBody(false);
    Surface.SetAbsolute(true, true, true);
    if (Index == 0)
    {
        WatchCase = new(self) class'StaticMeshComponent';
        WatchCase.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VRHands.VRWristwatch", class'StaticMesh', true)));
        if (WatchCase.StaticMesh == None)
            WatchCase.SetStaticMesh(StaticMesh(DynamicLoadObject("EngineMeshes.Cube", class'StaticMesh', true)));
        WatchCase.SetDepthPriorityGroup(SDPG_World);
        WatchCase.CastShadow = false;
        WatchCase.bCastDynamicShadow = false;
        WatchCase.SetActorCollision(false, false, false);
        WatchCase.SetTraceBlocking(false, false);
        WatchCase.SetBlockRigidBody(false);
        WatchCase.SetAbsolute(true, true, true);
        WatchCase.SetHidden(true);
        WatchCase.SetMaterial(0, CreateHorzineMaterial(self, "VRHorzineWatch"));
        AttachComponent(WatchCase);
    }
    return true;
}

simulated function RenderDisplay(Canvas C)
{
    if (DisplayOwner == None || C == None) return;
    DisplayOwner.RenderPanel(PanelIndex, C);
    bDrawn = true;
    // Survives content invalidation during a weapon swap. Stock suppression
    // follows resource readiness, while bDrawn prevents stale spatial values.
    bReady = true;
}

simulated function PlacePanel(vector Position, rotator Orientation, vector Size, bool bVisible)
{
    local vector MeshScale;
    // Collision belongs to the world behind this visual surface. Reassert the
    // component policy when placing it so neither bullets nor aim rays see UI.
    if (bCollideActors || bBlockActors || bProjTarget)
    {
        SetCollisionType(COLLIDE_NoCollision);
        SetCollision(false, false);
        bProjTarget = false;
    }
    if (Surface.CollideActors || Surface.BlockActors || Surface.AlwaysCheckCollision)
        Surface.SetActorCollision(false, false, false);
    if (Surface.BlockZeroExtent || Surface.BlockNonZeroExtent) Surface.SetTraceBlocking(false, false);
    if (Surface.BlockRigidBody) Surface.SetBlockRigidBody(false);
    // Hidden slots need no component transform work. Keep the last valid
    // transform until the next visible placement, and never assign a zero
    // scale (UE3's inverse transform would be singular even while hidden).
    if (!bVisible || !(Size.X > 0 && Size.Y > 0))
    {
        HidePanel();
        LastPlacement = WorldInfo.RealTimeSeconds;
        return;
    }
    // Verified EngineMeshes.Cube bounds are +/-128 UU. Its -X face is the
    // display front, with +Y across the text and +Z up (see asset evidence).
    MeshScale.X = 0.025 / 256.0;
    MeshScale.Y = Size.X / 256.0;
    MeshScale.Z = Size.Y / 256.0;
    Surface.SetTranslation(Position);
    Surface.SetRotation(Orientation);
    Surface.SetScale3D(MeshScale);
    bPresented = bVisible && bDrawn && Size.X > 0 && Size.Y > 0;
    Surface.SetHidden(!bPresented);
    Surface.ForceUpdate(true);
    if (WatchCase != None)
    {
        if (PanelIndex == 0 && DisplayOwner != None && DisplayOwner.Bridge != None && DisplayOwner.Bridge.bWristwatchHUD && bPresented)
        {
            WatchCase.SetTranslation(Position);
            WatchCase.SetRotation(Orientation);
            if (WatchCase.StaticMesh != None && WatchCase.StaticMesh.Name == 'VRWristwatch')
            {
                WatchCase.SetScale3D(vect(1, 1, 1));
                WatchCase.SetScale(FClamp(DisplayOwner.Bridge.WristwatchScale, 0.5, 2.0));
            }
            else
            {
                MeshScale.X = 1.0 / 256.0;
                MeshScale.Y = (Size.X + 0.8) / 256.0;
                MeshScale.Z = (Size.Y + 0.8) / 256.0;
                WatchCase.SetScale3D(MeshScale);
            }
            WatchCase.SetHidden(false);
            WatchCase.ForceUpdate(true);
        }
        else
        {
            if (!WatchCase.HiddenGame) WatchCase.SetHidden(true);
        }
    }
    LastPlacement = WorldInfo.RealTimeSeconds;
}

simulated function HidePanel()
{
    if (!Surface.HiddenGame) Surface.SetHidden(true);
    if (WatchCase != None && !WatchCase.HiddenGame) WatchCase.SetHidden(true);
    bPresented = false;
}

simulated event Tick(float DeltaTime)
{
    if (DisplayOwner == None || DisplayOwner.bDeleteMe) { Destroy(); return; }
    if (WorldInfo.RealTimeSeconds - LastPlacement > 0.25) HidePanel();
}

simulated event Destroyed()
{
    if (WatchCase != None)
    {
        DetachComponent(WatchCase);
        WatchCase = None;
        WatchMaterials.Length = 0;
    }
    if (Display != None) { Display.Render = None; Display.bNeedsUpdate = false; }
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
    WatchTints(0)=(R=0.05,G=0.054,B=0.06,A=1.0)
    WatchTints(1)=(R=0.004,G=0.005,B=0.006,A=1.0)
    WatchTints(2)=(R=0.62,G=0.12,B=0.025,A=1.0)
    WatchTints(3)=(R=0.52,G=0.34,B=0.11,A=1.0)
    WatchTints(4)=(R=0.10,G=0.058,B=0.034,A=1.0)
    WatchTints(5)=(R=0.13,G=0.12,B=0.075,A=1.0)
    WatchTints(6)=(R=0.33,G=0.34,B=0.35,A=1.0)
    Begin Object Class=StaticMeshComponent Name=HUDSurface
        StaticMesh=StaticMesh'EngineMeshes.Cube'
        HiddenGame=true
        DepthPriorityGroup=SDPG_World
        CastShadow=false
        bCastDynamicShadow=false
        bAcceptsLights=false
        bAcceptsDecals=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    Surface=HUDSurface
    Components.Add(HUDSurface)
}
