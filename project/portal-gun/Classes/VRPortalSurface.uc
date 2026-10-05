// Client-side presentation for one portal. Endpoint owns placement/traversal.
// Live stereo requires the owned native capture bridge handshake and per-eye
// capture receipts. See docs/PORTAL_RENDERING.md for validation status.
class VRPortalSurface extends Actor;

var VRPortalEndpoint PortalEndpoint;
var VRPortalEndpoint LinkedEndpoint;
var SceneCapturePortalComponent PortalCapture;
var StaticMeshComponent ApertureMesh;
var StaticMeshComponent RimMesh;
var transient TextureRenderTarget2D CaptureTexture;
var transient MaterialInstanceConstant ApertureMaterial;
var transient MaterialInstanceConstant RimMaterial;
var bool bAssetsReady;
var bool bLiveCapture;
var bool bVRRenderingActive;
var bool bLoggedVRGate;
// Int, rather than a packed script bool, is the native reflection handshake.
// 0=disabled, 2=capture attachment warmup with a dark aperture, 1=live stereo.
var int NativeStereoReady;

simulated function bool BindPortal(VRPortalEndpoint Endpoint)
{
    local StaticMesh ApertureAsset, RimAsset;
    local MaterialInterface ApertureParent, RimParent;
    local vector PortalScale;
    local LinearColor Clear, Tint;

    if (WorldInfo.NetMode == NM_DedicatedServer || Endpoint == None || Endpoint.bDeleteMe)
        return false;

    PortalEndpoint = Endpoint;
    SetLocation(Endpoint.Location);
    SetRotation(Endpoint.Rotation);

    if (!bAssetsReady)
    {
        ApertureAsset = StaticMesh(DynamicLoadObject("KF2VRPortal.SM_PortalAperture", class'StaticMesh', true));
        RimAsset = StaticMesh(DynamicLoadObject("KF2VRPortal.SM_PortalRim", class'StaticMesh', true));
        ApertureParent = MaterialInterface(DynamicLoadObject("KF2VRPortal.M_PortalSurface", class'MaterialInterface', true));
        RimParent = MaterialInterface(DynamicLoadObject("KF2VRPortal.M_PortalRim", class'MaterialInterface', true));
        if (ApertureAsset == None || RimAsset == None || ApertureParent == None || RimParent == None)
        {
            `log("Portal surface unavailable: build KF2VRPortal aperture/rim assets first",, 'KF2VRPortal');
            return false;
        }

        ApertureMesh.SetStaticMesh(ApertureAsset);
        RimMesh.SetStaticMesh(RimAsset);
        ApertureMaterial = new(self) class'MaterialInstanceConstant';
        ApertureMaterial.SetParent(ApertureParent);
        RimMaterial = new(self) class'MaterialInstanceConstant';
        RimMaterial.SetParent(RimParent);
        ApertureMesh.SetMaterial(0, ApertureMaterial);
        RimMesh.SetMaterial(0, RimMaterial);

        Clear.A = 1.0;
        CaptureTexture = class'TextureRenderTarget2D'.static.Create(1024, 1024, PF_A8R8G8B8, Clear);
        if (CaptureTexture == None)
        {
            `log("Portal surface unavailable: render target allocation failed",, 'KF2VRPortal');
            return false;
        }
        ApertureMaterial.SetTextureParameterValue('CaptureTexture', CaptureTexture);
        ApertureMaterial.SetScalarParameterValue('Linked', 0.0);
        bAssetsReady = true;
    }

    // Imported meshes lie in YZ, face +X and have unit inner semiaxes.
    PortalScale.X = 1.0;
    PortalScale.Y = Endpoint.HalfWidth;
    PortalScale.Z = Endpoint.HalfHeight;
    ApertureMesh.SetScale3D(PortalScale);
    RimMesh.SetScale3D(PortalScale);
    Tint.A = 1.0;
    if (Endpoint.PortalColor == 0)
    {
        Tint.R = 0.015;
        Tint.G = 0.32;
        Tint.B = 1.0;
    }
    else
    {
        Tint.R = 1.0;
        Tint.G = 0.18;
        Tint.B = 0.015;
    }
    ApertureMaterial.SetVectorParameterValue('PortalColor', Tint);
    RimMaterial.SetVectorParameterValue('PortalColor', Tint);
    ApertureMesh.SetHidden(false);
    RimMesh.SetHidden(false);
    SetPortalLink(Endpoint.OtherPortal);
    return true;
}

simulated function SetPortalLink(VRPortalEndpoint Destination)
{
    local Actor CaptureDestination;
    if (Destination == self.PortalEndpoint || (Destination != None && Destination.bDeleteMe))
        Destination = None;
    if (LinkedEndpoint != Destination)
    {
        // Disable before detaching the old capture destination or texture.
        PortalCapture.SetEnabled(false);
        bLiveCapture = false;
        LinkedEndpoint = Destination;
        if (Destination != None) CaptureDestination=Destination.Surface;
        // KF2 hides components owned by ViewDestination in the exit capture.
        // The visible exit meshes belong to its Surface, not its Endpoint.
        PortalCapture.SetCaptureParameters(CaptureTexture, 1.0, CaptureDestination);
    }
    UpdateCaptureState();
}

// Pose contract for capture validation and a future per-eye native bridge.
// Call once with each actual eye pose, including its positional offset.
// The stock SceneCapturePortalComponent derives its own native view; this
// helper does not claim to install that view or trigger an eye capture.
simulated function bool GetLinkedView(vector EyeLocation, rotator EyeRotation,
    out vector LinkedEyeLocation, out rotator LinkedEyeRotation)
{
    if (PortalEndpoint == None || PortalEndpoint.bDeleteMe
        || LinkedEndpoint == None || LinkedEndpoint.bDeleteMe) return false;
    LinkedEyeLocation = class'VRPortalMath'.static.MapPoint(EyeLocation,
        PortalEndpoint.Location, PortalEndpoint.Rotation, LinkedEndpoint.Location, LinkedEndpoint.Rotation);
    LinkedEyeRotation = class'VRPortalMath'.static.MapRotation(EyeRotation,
        PortalEndpoint.Rotation, LinkedEndpoint.Rotation);
    return true;
}

// Called by the tracked-input integration. A shared, stale mono texture would
// give incorrect binocular disparity, especially when the head crosses a rim.
// Only the native bridge can supply the stereo capability handshake.
simulated function SetVRRenderingActive(bool bActive)
{
    if (bVRRenderingActive == bActive) return;
    bVRRenderingActive = bActive;
    if (bActive && !bLoggedVRGate)
    {
        `log("Portal VR live view requires native per-eye capture readiness",, 'KF2VRPortal');
        bLoggedVRGate = true;
    }
    UpdateCaptureState();
}

simulated function UpdateCaptureState()
{
    local bool bShouldCapture;
    bShouldCapture = bAssetsReady && PortalEndpoint != None && !PortalEndpoint.bDeleteMe
        && LinkedEndpoint != None && !LinkedEndpoint.bDeleteMe
        && (!bVRRenderingActive || NativeStereoReady > 0);
    if (bLiveCapture != bShouldCapture)
    {
        bLiveCapture = bShouldCapture;
        PortalCapture.SetEnabled(bLiveCapture);
    }
    if (ApertureMaterial != None)
        ApertureMaterial.SetScalarParameterValue('Linked', float(bLiveCapture
            && (!bVRRenderingActive || NativeStereoReady == 1)));
}

simulated function RefreshNativeStereoState()
{
    if (NativeStereoReady > 0) bVRRenderingActive = true;
    UpdateCaptureState();
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (PortalEndpoint == None || PortalEndpoint.bDeleteMe)
    {
        ShutdownPortal();
        return;
    }
    if (Location != PortalEndpoint.Location) SetLocation(PortalEndpoint.Location);
    if (Rotation != PortalEndpoint.Rotation) SetRotation(PortalEndpoint.Rotation);
    if (LinkedEndpoint != PortalEndpoint.OtherPortal)
        SetPortalLink(PortalEndpoint.OtherPortal);
    else if (bLiveCapture && (LinkedEndpoint == None || LinkedEndpoint.bDeleteMe))
        UpdateCaptureState();
}

simulated function ShutdownPortal()
{
    if (!bDeleteMe) Destroy();
}

simulated event Destroyed()
{
    PortalCapture.SetEnabled(false);
    PortalCapture.SetCaptureParameters(None, 1.0, None);
    if (ApertureMaterial != None)
    {
        ApertureMaterial.SetScalarParameterValue('Linked', 0.0);
        ApertureMaterial.SetTextureParameterValue('CaptureTexture', None);
    }
    CaptureTexture = None;
    LinkedEndpoint = None;
    PortalEndpoint = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    bNoDelete=false
    bMovable=true
    bHidden=false
    TickGroup=TG_PostUpdateWork

    Begin Object Class=SceneCapturePortalComponent Name=PortalCaptureComponent
        bEnabled=false
        FrameRate=1000
        ScaleFOV=1.0
        ViewMode=SceneCapView_Lit
        bEnablePostProcess=false
        bEnableFog=true
        bSkipUpdateIfOwnerOccluded=false
        bSkipUpdateIfTextureUsersOccluded=false
    End Object
    PortalCapture=PortalCaptureComponent
    Components.Add(PortalCaptureComponent)

    Begin Object Class=StaticMeshComponent Name=PortalApertureComponent
        HiddenGame=true
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDynamicLights=false
        bUseAsOccluder=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        Translation=(X=0.5,Y=0,Z=0)
        DepthPriorityGroup=SDPG_World
    End Object
    ApertureMesh=PortalApertureComponent
    Components.Add(PortalApertureComponent)

    Begin Object Class=StaticMeshComponent Name=PortalRimComponent
        HiddenGame=true
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDynamicLights=false
        bUseAsOccluder=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        Translation=(X=0.6,Y=0,Z=0)
        DepthPriorityGroup=SDPG_World
    End Object
    RimMesh=PortalRimComponent
    Components.Add(PortalRimComponent)
}
