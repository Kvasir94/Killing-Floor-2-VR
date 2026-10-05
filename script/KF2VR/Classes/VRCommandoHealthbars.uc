// Worldspace healthbar billboards for the Commando perk. Each visible
// KFPawn_Monster within detection range gets a small overhead panel. A growing
// pool of billboard components is recycled every frame; health is read live from
// each pawn's Health/HealthMax. The stock 2D Canvas draw is suppressed by
// the local perk draw guard when this system is ready.
class VRCommandoHealthbars extends Actor;

const InitialBars = 24;
const BarWidth = 10.0;
const BarHeight = 1.6;
// Stock's 50 px bar on a 1024 px / ~90 degree Canvas stays legible at range.
// Keep roughly that angular width instead of a 10 UU sliver on a distant Zed.
const BarDegrees = 4.0;
// ScriptedTexture resolution per bar: small texture for a simple bar.
const TexWidth = 128;
const TexHeight = 24;

struct ZedBarSlot
{
    var StaticMeshComponent Surface;
    var ScriptedTexture Display;
    var MaterialInstanceConstant DisplayMaterial;
    var VRCommandoHealthbarRenderer Renderer;
    var KFPawn_Monster AssignedZed;
    var float HealthScale;
    var bool bActive;
};

var array<ZedBarSlot> Slots;
var int ActiveCount;
var VRSpatialHUD HUDOwner;
var bool bInitialized, bPresentationReady;
var Material ParentMaterial;
var Texture2D WhiteMaterial;
var color BarBacking, BarFill;

simulated function bool Initialize(VRSpatialHUD NewHUDOwner)
{
    local Texture ExistingTexture;
    local int I;
    HUDOwner = NewHUDOwner;

    ParentMaterial = Material(DynamicLoadObject(
        "ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal",
        class'Material', true));
    if (ParentMaterial == None || !ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture))
        return false;
    WhiteMaterial = Texture2D(DynamicLoadObject("EngineResources.WhiteSquareTexture", class'Texture2D', true));
    if (WhiteMaterial == None) WhiteMaterial = Texture2D'EngineResources.WhiteSquareTexture';

    Slots.Length = InitialBars;
    for (I = 0; I < Slots.Length; ++I)
    {
        if (!InitSlot(I)) return false;
    }
    bInitialized = true;
    return true;
}

simulated function bool InitSlot(int Index)
{
    local LinearColor White;
    Slots[Index].Display = ScriptedTexture(class'ScriptedTexture'.static.Create(
        TexWidth, TexHeight, PF_A8R8G8B8, MakeLinearColor(0, 0, 0, 0)));
    if (Slots[Index].Display == None) return false;
    Slots[Index].Display.TargetGamma = 1.0;
    Slots[Index].Display.bNeedsTwoCopies = true;
    Slots[Index].Renderer = new(self) class'VRCommandoHealthbarRenderer';
    Slots[Index].Renderer.DisplayOwner = self;
    Slots[Index].Renderer.SlotIndex = Index;
    Slots[Index].Display.Render = Slots[Index].Renderer.RenderBar;

    Slots[Index].DisplayMaterial = new(self) class'MaterialInstanceConstant';
    Slots[Index].DisplayMaterial.SetParent(ParentMaterial);
    Slots[Index].DisplayMaterial.SetTextureParameterValue('Texture_D', Slots[Index].Display);
    White = MakeLinearColor(1, 1, 1, 1);
    Slots[Index].DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', White);
    Slots[Index].DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.06);
    Slots[Index].DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', 1.0);

    Slots[Index].Surface = new(self) class'StaticMeshComponent';
    Slots[Index].Surface.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
    Slots[Index].Surface.SetDepthPriorityGroup(SDPG_World);
    Slots[Index].Surface.CastShadow = false;
    Slots[Index].Surface.bCastDynamicShadow = false;
    Slots[Index].Surface.SetActorCollision(false, false, false);
    Slots[Index].Surface.SetTraceBlocking(false, false);
    Slots[Index].Surface.SetBlockRigidBody(false);
    Slots[Index].Surface.SetAbsolute(true, true, true);
    Slots[Index].Surface.SetHidden(true);
    Slots[Index].Surface.SetMaterial(0, Slots[Index].DisplayMaterial);
    AttachComponent(Slots[Index].Surface);

    Slots[Index].bActive = false;
    Slots[Index].AssignedZed = None;
    Slots[Index].HealthScale = 0;
    return true;
}

simulated function RenderBar(int Index, Canvas C)
{
    local float HealthFrac;
    if (Index < 0 || Index >= Slots.Length) return;
    HealthFrac = Slots[Index].HealthScale;
    // Black background
    C.SetPos(0, 0);
    C.SetDrawColor(0, 0, 0, 255);
    C.DrawTile(WhiteMaterial, TexWidth, TexHeight, 0, 0, 32, 32);
    // Red health fill
    if (HealthFrac > 0)
    {
        C.SetDrawColor(BarFill.R, BarFill.G, BarFill.B, BarFill.A);
        C.SetPos(1, 1);
        C.DrawTile(WhiteMaterial, (TexWidth - 2) * FClamp(HealthFrac, 0, 1),
            TexHeight - 2, 0, 0, 32, 32);
    }
}

simulated function UpdateHealthbars(optional bool bCreateResources)
{
    local KFPawn_Monster KFPM;
    local KFPerk_Commando CommandoPerk;
    local vector ViewLocation, ViewDir, TargetLoc, ToZed;
    local rotator ViewRotation, BarOrientation;
    local float DetectionRangeSq, DistSq, ThisDot, Width;
    local int SlotIndex;
    local vector MeshScale;

    bPresentationReady = false;
    if (!bInitialized || HUDOwner == None || !HUDOwner.ContextValid()) { HideAll(); return; }

    // Only active for Commando perk
    CommandoPerk = KFPerk_Commando(HUDOwner.PC.CurrentPerk);
    if (CommandoPerk == None)
    {
        HideAll();
        ActiveCount = 0;
        return;
    }

    // The public accessor uses the same level-scaled passive as stock's HUD.
    DetectionRangeSq = Square(CommandoPerk.GetCloakDetectionRange());

    HUDOwner.PC.GetPlayerViewPoint(ViewLocation, ViewRotation);
    ViewDir = vector(ViewRotation);

    SlotIndex = 0;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', KFPM)
    {
        if (KFPM.Mesh == None) continue;
        if (!KFPM.CanShowHealth() || !KFPM.IsAliveAndWell()) continue;
        if (`TimeSince(KFPM.Mesh.LastRenderTime) > 0.1) continue;

        ToZed = KFPM.Location - ViewLocation;
        DistSq = VSizeSq(ToZed);
        if (DistSq > DetectionRangeSq) continue;

        ThisDot = ViewDir dot Normal(ToZed);
        if (ThisDot <= 0) continue;

        // Position above zed head
        if (KFPM.bCrawler && KFPM.Floor.Z <= -0.7 && KFPM.Physics == PHYS_Spider)
            TargetLoc = KFPM.Location + vect(0,0,-1) * KFPM.GetCollisionHeight() * 1.2 * KFPM.CurrentBodyScale;
        else
            TargetLoc = KFPM.Location + vect(0,0,1) * KFPM.GetCollisionHeight() * 1.2 * KFPM.CurrentBodyScale;

        // Line of sight check
        if (!class'KFGameEngine'.static.FastTrace_PhysX(TargetLoc, ViewLocation)) continue;

        // Do not silently drop the rest of a visible horde at the old 24-bar
        // limit. Allocate only when needed; a resource failure restores stock.
        if (SlotIndex >= Slots.Length)
        {
            // The native late placement call must not create render resources.
            // Tick grows the pool; retain stock for this whole pass meanwhile.
            if (!bCreateResources) { HideAll(); return; }
            Slots.Length = SlotIndex + 1;
            if (!InitSlot(SlotIndex))
            {
                HideAll();
                bInitialized = false;
                return;
            }
        }

        // Assign this zed to a slot
        Slots[SlotIndex].AssignedZed = KFPM;
        Slots[SlotIndex].HealthScale = FClamp(float(KFPM.Health) / float(KFPM.HealthMax), 0, 1);
        Slots[SlotIndex].bActive = true;

        // Billboard orientation: face the camera
        // EngineMeshes.Cube's -X face is the readable display front.
        BarOrientation = rotator(TargetLoc - ViewLocation);

        // EngineMeshes.Cube bounds are +/-128 UU. Scale to desired bar size.
        MeshScale.X = 0.025 / 256.0;
        Width = FMax(BarWidth, VSize(TargetLoc - ViewLocation) * Tan(BarDegrees * DegToRad));
        MeshScale.Y = Width / 256.0;
        MeshScale.Z = Width * (BarHeight / BarWidth) / 256.0;

        Slots[SlotIndex].Surface.SetTranslation(TargetLoc);
        Slots[SlotIndex].Surface.SetRotation(BarOrientation);
        Slots[SlotIndex].Surface.SetScale3D(MeshScale);
        Slots[SlotIndex].Surface.SetHidden(!Slots[SlotIndex].Renderer.bDrawn);
        Slots[SlotIndex].Surface.ForceUpdate(true);

        // Mark the texture dirty so it redraws with new health
        Slots[SlotIndex].Display.bNeedsUpdate = true;

        ++SlotIndex;
    }

    // Hide unused slots
    ActiveCount = SlotIndex;
    while (SlotIndex < Slots.Length)
    {
        if (Slots[SlotIndex].bActive)
        {
            Slots[SlotIndex].bActive = false;
            Slots[SlotIndex].AssignedZed = None;
            Slots[SlotIndex].Surface.SetHidden(true);
        }
        ++SlotIndex;
    }
    bPresentationReady = true;
    for (SlotIndex = 0; SlotIndex < ActiveCount; ++SlotIndex)
        if (!Slots[SlotIndex].Renderer.bDrawn) bPresentationReady = false;
    // A partial spatial pass plus the complete stock fallback would duplicate
    // already ready bars. Present the whole pass only when all its textures exist.
    for (SlotIndex = 0; SlotIndex < ActiveCount; ++SlotIndex)
    {
        Slots[SlotIndex].Surface.SetHidden(!bPresentationReady);
        Slots[SlotIndex].Surface.ForceUpdate(true);
    }
}

simulated function HideAll()
{
    local int I;
    for (I = 0; I < Slots.Length; ++I)
    {
        if (Slots[I].bActive)
        {
            Slots[I].bActive = false;
            Slots[I].AssignedZed = None;
            Slots[I].Surface.SetHidden(true);
        }
    }
    ActiveCount = 0;
    bPresentationReady = false;
}

simulated function bool ReadyForStockReplacement()
{
    return bInitialized && bPresentationReady;
}

simulated event Tick(float DeltaTime)
{
    if (HUDOwner == None || HUDOwner.bDeleteMe) { Destroy(); return; }
    UpdateHealthbars(true);
}

simulated event Destroyed()
{
    local int I;
    for (I = 0; I < Slots.Length; ++I)
    {
        if (Slots[I].Display != None) { Slots[I].Display.Render = None; Slots[I].Display.bNeedsUpdate = false; }
        if (Slots[I].Surface != None) DetachComponent(Slots[I].Surface);
        if (Slots[I].Renderer != None) Slots[I].Renderer.DisplayOwner = None;
    }
    HUDOwner = None;
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
    BarBacking=(R=0,G=0,B=0,A=255)
    BarFill=(R=237,G=8,B=0,A=255)
}
