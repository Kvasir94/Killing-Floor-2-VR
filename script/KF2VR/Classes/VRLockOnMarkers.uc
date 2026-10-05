// World-space lock-on markers for the Seeker Six and HRG Locust. Stock draws
// its locks only in the flat DrawHUD, from a protected array; native copies
// that array into VRHandsBridge.LockTarget0-5 each frame (SupplyLockTargets).
// Each lock gets the weapon's own stock icon as a billboard on the Zed, sized
// to a constant angle so a far lock stays readable.
class VRLockOnMarkers extends Actor;

const MaxMarkers = 6;
// Stock draws the icon 200 px on a 1024 px canvas at ~90 deg: about 17 deg.
// A world marker reads well at a third of that.
const MarkerDegrees = 6.0;

var StaticMeshComponent Markers[6];
var MaterialInstanceConstant MarkerMaterial;
var Material ParentMaterial;
var Texture2D CurrentIcon;
var VRSpatialHUD HUDOwner;
var bool bInitialized;
var int ActiveCount;
var KFWeapon PresentedWeapon;
var Pawn PresentedTargets[6];
var float LastPlacement;

simulated function bool Initialize(VRSpatialHUD NewHUDOwner)
{
    local Texture ExistingTexture;
    local int I;
    HUDOwner = NewHUDOwner;
    ParentMaterial = Material(DynamicLoadObject(
        "ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (ParentMaterial == None || ParentMaterial.LightingModel != MLM_Unlit
        || ParentMaterial.BlendMode != BLEND_Translucent || ParentMaterial.bDisableDepthTest
        || !ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture))
        return false;
    MarkerMaterial = new(self) class'MaterialInstanceConstant';
    if (MarkerMaterial == None) return false;
    MarkerMaterial.SetParent(ParentMaterial);
    MarkerMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.35);
    MarkerMaterial.SetScalarParameterValue('Scalar_Opacity', 1.0);
    for (I = 0; I < MaxMarkers; ++I)
    {
        Markers[I] = new(self) class'StaticMeshComponent';
        if (Markers[I] == None || !Markers[I].SetStaticMesh(StaticMesh'EngineMeshes.Cube')) return false;
        // Stock keeps a lock only while the Zed is in sight, so world depth is enough.
        Markers[I].SetDepthPriorityGroup(SDPG_World);
        Markers[I].CastShadow = false;
        Markers[I].bCastDynamicShadow = false;
        Markers[I].SetActorCollision(false, false, false);
        Markers[I].SetTraceBlocking(false, false);
        Markers[I].SetBlockRigidBody(false);
        Markers[I].SetAbsolute(true, true, true);
        Markers[I].SetHidden(true);
        Markers[I].SetMaterial(0, MarkerMaterial);
        AttachComponent(Markers[I]);
    }
    bInitialized = true;
    return true;
}

simulated function SetIcon(Texture2D Icon, LinearColor Tint)
{
    if (Icon == None) { CurrentIcon = None; return; }
    if (Icon == CurrentIcon) return;
    CurrentIcon = Icon;
    MarkerMaterial.SetTextureParameterValue('Texture_D', Icon);
    Tint.A = 1.0;
    MarkerMaterial.SetVectorParameterValue('Vector_Glow_Color', Tint);
}

// Queried from the stock per-target Canvas callback. Only an already placed,
// fresh replacement for this exact weapon and pawn can suppress its stock icon.
simulated function bool ReadyForStockReplacement(KFWeapon W, Pawn P)
{
    local int I;
    if (!bInitialized || bDeleteMe || HUDOwner == None || !HUDOwner.ContextValid()
        || HUDOwner.Bridge.NativeHeadTracked == 0
        || W == None || W.bDeleteMe || W != PresentedWeapon || W != HUDOwner.Bridge.LockSource
        || P == None || P.bDeleteMe || !P.IsAliveAndWell()
        || MarkerMaterial == None || CurrentIcon == None
        || CurrentIcon.SizeX <= 0 || CurrentIcon.SizeY <= 0 || CurrentIcon.ResidentMips <= 0
        || WorldInfo.RealTimeSeconds - LastPlacement < 0
        || WorldInfo.RealTimeSeconds - LastPlacement > 0.25) return false;
    for (I = 0; I < ActiveCount; ++I)
        if (PresentedTargets[I] == P && Markers[I] != None
            && Markers[I].StaticMesh != None && !Markers[I].HiddenGame) return true;
    return false;
}

simulated function vector TargetLocation(KFWeapon W, Pawn P)
{
    if (KFWeap_HRG_Locust(W) != None) return class'KFWeap_HRG_Locust'.static.GetLockedTargetLoc(P);
    return class'KFWeap_RocketLauncher_Seeker6'.static.GetLockedTargetLoc(P);
}

simulated function UpdateMarkers()
{
    local VRHandsBridge B;
    local KFWeapon W;
    local Pawn Targets[6];
    local vector ViewLocation, TargetLoc, MeshScale;
    local rotator ViewRotation;
    local float Size;
    local int I, Count;
    if (!bInitialized || HUDOwner == None || !HUDOwner.ContextValid()) { HideAll(); return; }
    B = HUDOwner.Bridge;
    W = B.LockSource;
    if (W == None || W.bDeleteMe || B.NativeLockCount <= 0) { HideAll(); return; }
    if (KFWeap_HRG_Locust(W) != None)
        SetIcon(KFWeap_HRG_Locust(W).LockedOnIcon, KFWeap_HRG_Locust(W).LockedIconColor);
    else if (KFWeap_RocketLauncher_Seeker6(W) != None)
        SetIcon(KFWeap_RocketLauncher_Seeker6(W).LockedOnIcon, KFWeap_RocketLauncher_Seeker6(W).LockedIconColor);
    else { HideAll(); return; }
    if (CurrentIcon == None || CurrentIcon.SizeX <= 0 || CurrentIcon.SizeY <= 0
        || CurrentIcon.ResidentMips <= 0) { HideAll(); return; }
    Targets[0] = B.LockTarget0; Targets[1] = B.LockTarget1; Targets[2] = B.LockTarget2;
    Targets[3] = B.LockTarget3; Targets[4] = B.LockTarget4; Targets[5] = B.LockTarget5;
    HUDOwner.PC.GetPlayerViewPoint(ViewLocation, ViewRotation);
    for (I = 0; I < Min(B.NativeLockCount, MaxMarkers); ++I)
    {
        if (Targets[I] == None || Targets[I].bDeleteMe || !Targets[I].IsAliveAndWell()) continue;
        TargetLoc = TargetLocation(W, Targets[I]);
        Size = FMax(12.0, VSize(TargetLoc - ViewLocation) * Tan(MarkerDegrees * DegToRad));
        // EngineMeshes.Cube bounds are +/-128 UU: a thin square card facing the eye.
        MeshScale.X = 0.025 / 256.0;
        MeshScale.Y = Size / 256.0;
        MeshScale.Z = Size / 256.0;
        Markers[Count].SetTranslation(TargetLoc);
        // The cube's textured display front is local -X, as on the HUD panels.
        Markers[Count].SetRotation(rotator(TargetLoc - ViewLocation));
        Markers[Count].SetScale3D(MeshScale);
        Markers[Count].SetHidden(false);
        Markers[Count].ForceUpdate(true);
        PresentedTargets[Count] = Targets[I];
        ++Count;
    }
    for (I = Count; I < MaxMarkers; ++I)
    {
        Markers[I].SetHidden(true);
        PresentedTargets[I] = None;
    }
    ActiveCount = Count;
    PresentedWeapon = W;
    LastPlacement = WorldInfo.RealTimeSeconds;
}

simulated function HideAll()
{
    local int I;
    for (I = 0; I < MaxMarkers; ++I)
    {
        if (Markers[I] != None) Markers[I].SetHidden(true);
        PresentedTargets[I] = None;
    }
    ActiveCount = 0;
    PresentedWeapon = None;
}

simulated event Tick(float DeltaTime)
{
    if (HUDOwner == None || HUDOwner.bDeleteMe) { Destroy(); return; }
    if (!HUDOwner.ContextValid() || WorldInfo.RealTimeSeconds - LastPlacement > 0.25) HideAll();
}

simulated event Destroyed()
{
    local int I;
    for (I = 0; I < MaxMarkers; ++I) if (Markers[I] != None) DetachComponent(Markers[I]);
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
