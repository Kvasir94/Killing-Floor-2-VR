// Keep KFHUDBase's remaining-Zed/bounty eligibility and tint. Its DrawZedIcon
// callback supplies these records; only the presentation becomes stereo.
class VRZedMarkers extends Actor;

struct ZedMarker
{
    var Pawn Target;
    var vector TargetLocation;
    var color Tint;
    var float SizeMultiplier, LastRequest;
    var StaticMeshComponent Surface;
    var MaterialInstanceConstant DisplayMaterial;
    var bool bPresented;
};
var array<ZedMarker> Markers;
var VRSpatialHUD HUDOwner;
var Material ParentMaterial;
var Texture2D Icon;
var bool bInitialized;

simulated function bool Initialize(VRSpatialHUD NewOwner)
{
    local Texture ExistingTexture;
    local KFHUDBase H;
    HUDOwner = NewOwner;
    H = KFHUDBase(HUDOwner.PC.MyHUD);
    if (H == None) return false;
    Icon = H.GenericZedIconTexture;
    ParentMaterial = Material(DynamicLoadObject(
        "ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    bInitialized = Icon != None && ParentMaterial != None
        && ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture);
    return bInitialized;
}

// No component/resource creation in the Canvas callback. Return true only for
// the exact pawn whose replacement is already placed; otherwise retain stock.
simulated function bool CaptureMarker(Pawn P, vector PawnLocation, color Tint, float SizeMultiplier)
{
    local int I;
    if (!bInitialized || P == None || P.CylinderComponent == None
        || HUDOwner == None || !HUDOwner.ContextValid()) return false;
    I = Markers.Find('Target', P);
    if (I == INDEX_NONE)
    {
        for (I = 0; I < Markers.Length; ++I)
            if (Markers[I].Target == None) break;
        if (I == Markers.Length) Markers.Length = I + 1;
        Markers[I].Target = P;
        Markers[I].bPresented = false;
    }
    Markers[I].TargetLocation = PawnLocation + vect(0,0,2.5) * P.CylinderComponent.CollisionHeight;
    Markers[I].Tint = Tint;
    Markers[I].SizeMultiplier = SizeMultiplier;
    Markers[I].LastRequest = WorldInfo.RealTimeSeconds;
    return Markers[I].bPresented;
}

simulated function bool InitMarker(int I)
{
    Markers[I].DisplayMaterial = new(self) class'MaterialInstanceConstant';
    Markers[I].DisplayMaterial.SetParent(ParentMaterial);
    Markers[I].DisplayMaterial.SetTextureParameterValue('Texture_D', Icon);
    Markers[I].DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.24);
    Markers[I].Surface = new(self) class'StaticMeshComponent';
    if (!Markers[I].Surface.SetStaticMesh(StaticMesh'EngineMeshes.Cube'))
    {
        Markers[I].Surface = None;
        return false;
    }
    // These are stock through-wall indicators. Foreground keeps that contract
    // while the two eyes still project the same world billboard independently.
    Markers[I].Surface.SetDepthPriorityGroup(SDPG_Foreground);
    Markers[I].Surface.CastShadow = false;
    Markers[I].Surface.bCastDynamicShadow = false;
    Markers[I].Surface.SetActorCollision(false, false, false);
    Markers[I].Surface.SetTraceBlocking(false, false);
    Markers[I].Surface.SetBlockRigidBody(false);
    Markers[I].Surface.SetAbsolute(true, true, true);
    Markers[I].Surface.SetHidden(true);
    Markers[I].Surface.SetMaterial(0, Markers[I].DisplayMaterial);
    AttachComponent(Markers[I].Surface);
    return true;
}

simulated function UpdateMarkers(optional bool bCreateResources)
{
    local int I;
    local vector ViewLocation, Forward, Right, Up, Direction, MarkerLocation, MeshScale;
    local rotator ViewRotation;
    local LinearColor MarkerTint;
    local float Ahead, Across, Above, Size;
    local KFGameReplicationInfo GRI;
    if (!bInitialized || HUDOwner == None || !HUDOwner.ContextValid()) { HideAll(); return; }
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (GRI == None || GRI.bHidePawnIcons || GRI.IsBossWave() || GRI.IsEndlessWave()
        || HUDOwner.PC.bCinematicMode) { HideAll(); return; }
    HUDOwner.PC.GetPlayerViewPoint(ViewLocation, ViewRotation);
    GetAxes(ViewRotation, Forward, Right, Up);
    for (I = 0; I < Markers.Length; ++I)
    {
        if (Markers[I].Target == None || Markers[I].Target.bDeleteMe
            || !Markers[I].Target.IsAliveAndWell()
            || WorldInfo.RealTimeSeconds - Markers[I].LastRequest > 0.1)
        {
            if (Markers[I].Surface != None) Markers[I].Surface.SetHidden(true);
            Markers[I].bPresented = false;
            Markers[I].Target = None;
            continue;
        }
        if (Markers[I].Surface == None)
        {
            if (!bCreateResources || !InitMarker(I)) continue;
        }
        MarkerLocation = Markers[I].TargetLocation;
        Direction = Normal(MarkerLocation - ViewLocation);
        Ahead = Direction dot Forward;
        Across = (Direction dot Right) / FMax(0.01, Abs(Ahead));
        Above = (Direction dot Up) / FMax(0.01, Abs(Ahead));
        // Stock clamps offscreen targets to the screen edge. Keep a directional
        // marker in front of the viewer at a stereo depth, including behind-Zeds.
        if (Ahead <= 0 || Abs(Across) > 0.9 || Abs(Above) > 0.55)
        {
            if (Ahead <= 0) Across = Across < 0 ? -0.9 : 0.9;
            MarkerLocation = ViewLocation + Normal(Forward + Right * FClamp(Across, -0.9, 0.9)
                + Up * FClamp(Above, -0.55, 0.55)) * 165;
        }
        Size = FMax(4.0, VSize(MarkerLocation - ViewLocation) * Tan(2.5 * DegToRad)) * Markers[I].SizeMultiplier;
        MeshScale.X = 0.025 / 256.0;
        MeshScale.Y = Size / 256.0;
        MeshScale.Z = Size / 256.0;
        MarkerTint = ColorToLinearColor(Markers[I].Tint);
        Markers[I].DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', MarkerTint);
        Markers[I].DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', float(Markers[I].Tint.A) / 255);
        Markers[I].Surface.SetTranslation(MarkerLocation);
        Markers[I].Surface.SetRotation(rotator(MarkerLocation - ViewLocation));
        Markers[I].Surface.SetScale3D(MeshScale);
        Markers[I].Surface.SetHidden(false);
        Markers[I].Surface.ForceUpdate(true);
        Markers[I].bPresented = true;
    }
}

simulated function HideAll()
{
    local int I;
    for (I = 0; I < Markers.Length; ++I)
    {
        if (Markers[I].Surface != None) Markers[I].Surface.SetHidden(true);
        Markers[I].bPresented = false;
        Markers[I].Target = None;
    }
}

simulated event Tick(float DeltaTime)
{
    if (HUDOwner == None || HUDOwner.bDeleteMe) { Destroy(); return; }
    UpdateMarkers(true);
}

simulated event Destroyed()
{
    local int I;
    for (I = 0; I < Markers.Length; ++I)
        if (Markers[I].Surface != None) DetachComponent(Markers[I].Surface);
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
}
