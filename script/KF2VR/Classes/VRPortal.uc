// One portal of a Portal Gun pair (docs/re/PORTAL2_REFERENCE.md).
//
// View: a SceneCapturePortalComponent that the native adapter turns into
// Portal 2's view through the pair (native/portal/PortalCapture.cpp). The
// adapter reads LinkedPortal, HalfWidth, HalfHeight and CaptureMode and counts
// NativeCaptures; it does no work unless this capture is enabled and visible.
// Shots: VRPortalHitscan routes the trace and effects before damage. Travel: Portal 2 teleports a body when its
// reference point crosses the plane inside the hole. KF2 cannot carve wall
// collision, so a player standing in the hole walks in with world collision
// released (the "tunnel") and teleports when the eye crosses; AI and
// projectiles teleport on reaching the plane.
class VRPortal extends Actor;

var byte PortalColor;
var VRWeap_PortalGun Gun;
var VRPortal LinkedPortal;
var float HalfWidth, HalfHeight;
var int CaptureMode;
var int NativeCaptures;

var SceneCapturePortalComponent PortalCapture;
var StaticMeshComponent RimMesh, FillMesh, HitMesh;
var transient TextureRenderTarget2D CaptureTexture;
var transient MaterialInstanceConstant SurfaceMaterial, RimMaterial, FillMaterial;

var int CaptureWidth, CaptureHeight;
var float ScreenSpaceEnter, ScreenSpaceExit;
// Map collision often stands proud of the rendered surface that placement
// traces hit (15 units on Burning Paris): bodies reach the hole this far out.
var float CollisionSkin;
var LinearColor BlueColor, OrangeColor;
var vector2D WindowUVScale, WindowUVBias;

var transient int SeenCaptures;
var transient float LastCaptureSeen;
var transient bool bApertureShown;

// Local-player tunnel and crossing state.
var transient Pawn TunnelPawn;
var transient float LastEyeX;
var transient Pawn RecentTraveler;
var transient float RecentTravelTime;
var Actor MountActor;
var PrimitiveComponent MountComponent;

simulated function bool Setup(VRWeap_PortalGun OwnerGun, byte ColorIndex)
{
    local StaticMesh Aperture, Rim;
    local MaterialInterface SurfaceParent, RimParent, FillParent;
    local LinearColor Clear, Tint, Fill;
    local vector Scale, MountHit, MountNormal;
    local TraceHitInfo MountInfo;
    MountActor=Trace(MountHit,MountNormal,Location-vector(Rotation)*4,Location+vector(Rotation)*4,false,,MountInfo);
    MountComponent=MountInfo.HitComponent;
    Gun = OwnerGun;
    Instigator = OwnerGun.Instigator;
    PortalColor = ColorIndex;
    Aperture = StaticMesh(DynamicLoadObject("KF2VRPortal.SM_PortalAperture", class'StaticMesh', true));
    Rim = StaticMesh(DynamicLoadObject("KF2VRPortal.SM_PortalRim", class'StaticMesh', true));
    SurfaceParent = MaterialInterface(DynamicLoadObject("KF2VRPortal.M_PortalSurface", class'MaterialInterface', true));
    RimParent = MaterialInterface(DynamicLoadObject("KF2VRPortal.M_PortalRim", class'MaterialInterface', true));
    FillParent = MaterialInterface(DynamicLoadObject("KF2VRPortal.M_PortalFill", class'MaterialInterface', true));
    if (Aperture == None || Rim == None || SurfaceParent == None || RimParent == None || FillParent == None || Gun.Apertures == None)
    {
        `log("KF2VR_PORTAL action=setup-failed reason=missing-KF2VRPortal-assets");
        return false;
    }
    Tint = PortalColor == 0 ? BlueColor : OrangeColor;
    Fill.R = Tint.R * 0.35; Fill.G = Tint.G * 0.35; Fill.B = Tint.B * 0.35; Fill.A = 1;
    RimMaterial = new(self) class'MaterialInstanceConstant';
    RimMaterial.SetParent(RimParent);
    RimMaterial.SetVectorParameterValue('PortalColor', Tint);
    FillMaterial = new(self) class'MaterialInstanceConstant';
    FillMaterial.SetParent(FillParent);
    FillMaterial.SetVectorParameterValue('PortalColor', Fill);
    SurfaceMaterial = new(self) class'MaterialInstanceConstant';
    SurfaceMaterial.SetParent(SurfaceParent);
    Clear.A = 1;
    CaptureTexture = class'TextureRenderTarget2D'.static.Create(CaptureWidth, CaptureHeight, PF_A8R8G8B8, Clear);
    if (CaptureTexture == None) return false;
    SurfaceMaterial.SetTextureParameterValue('CaptureTexture', CaptureTexture);
    SurfaceMaterial.SetScalarParameterValue('Linked', 0);
    SurfaceMaterial.SetScalarParameterValue('ScreenSpace', 0);
    Clear.R = WindowUVScale.X; Clear.G = WindowUVScale.Y; Clear.B = WindowUVBias.X; Clear.A = WindowUVBias.Y;
    SurfaceMaterial.SetVectorParameterValue('WindowUV', Clear);

    Scale.X = 1; Scale.Y = HalfWidth; Scale.Z = HalfHeight;
    RimMesh.SetStaticMesh(Rim);
    RimMesh.SetMaterial(0, RimMaterial);
    RimMesh.SetScale3D(Scale);
    FillMesh.SetStaticMesh(Aperture);
    FillMesh.SetMaterial(0, FillMaterial);
    FillMesh.SetScale3D(Scale);
    HitMesh.SetStaticMesh(Aperture);
    HitMesh.SetScale3D(Scale);
    HitMesh.SetTraceBlocking(false, false);
    Gun.Apertures.Place(PortalColor, Location, Rotation, HalfWidth, HalfHeight, SurfaceMaterial);
    Gun.Apertures.Show(PortalColor, false);
    PortalCapture.SetCaptureParameters(CaptureTexture, 1.0, Gun.Apertures);
    PlayCue(PortalColor == 0 ? 'PortalOpenBlue' : 'PortalOpenOrange');
    return true;
}

simulated function PlayCue(name CueName)
{
    local SoundCue Cue;
    Cue = SoundCue(DynamicLoadObject("KF2VRPortal." $ CueName, class'SoundCue', true));
    if (Cue != None) PlaySound(Cue);
}

simulated function LinkTo(VRPortal Other)
{
    if (Other == self || (Other != None && Other.bDeleteMe)) Other = None;
    if (LinkedPortal == Other) return;
    EndTunnel(true);
    LinkedPortal = Other;
    PortalCapture.SetEnabled(Other != None);
    HitMesh.SetTraceBlocking(false, false);
    SeenCaptures = NativeCaptures;
    LastCaptureSeen = -1000;
    UpdateAperture();
}

// Show the view only once the adapter is actually rendering it; otherwise the
// portal shows its flat fill (desktop without the adapter, or a network game).
simulated function UpdateAperture()
{
    local bool bShow;
    if (NativeCaptures != SeenCaptures)
    {
        SeenCaptures = NativeCaptures;
        LastCaptureSeen = WorldInfo.TimeSeconds;
    }
    bShow = LinkedPortal != None && WorldInfo.TimeSeconds - LastCaptureSeen < 0.5;
    if (bShow == bApertureShown || Gun == None || Gun.Apertures == None) return;
    bApertureShown = bShow;
    SurfaceMaterial.SetScalarParameterValue('Linked', bShow ? 1.0 : 0.0);
    Gun.Apertures.Show(PortalColor, bShow);
}

// Close range: the window capture's texels spread over the whole eye, so the
// capture switches to screen space with an oblique clip (native mode 1).
simulated function UpdateCaptureMode(vector EyeLocal)
{
    local int Wanted;
    Wanted = CaptureMode;
    if (Abs(EyeLocal.Y) > HalfWidth + 60 || Abs(EyeLocal.Z) > HalfHeight + 60 || EyeLocal.X < -20) Wanted = 0;
    else if (EyeLocal.X < ScreenSpaceEnter) Wanted = 1;
    else if (EyeLocal.X > ScreenSpaceExit) Wanted = 0;
    if (Wanted == CaptureMode) return;
    CaptureMode = Wanted;
    SurfaceMaterial.SetScalarParameterValue('ScreenSpace', float(Wanted));
}

simulated function vector MapPointThrough(vector P)
{
    local vector Offs;
    Offs = (P - Location) << Rotation;
    Offs.X = 0;
    return class'VRPortalMath'.static.MapPoint(Location + (Offs >> Rotation), Location, Rotation,
        LinkedPortal.Location, LinkedPortal.Rotation) + vector(LinkedPortal.Rotation) * 2;
}

simulated function vector MapDirection(vector D)
{
    return class'VRPortalMath'.static.MapVector(D, Rotation, LinkedPortal.Rotation);
}

// A portal is an opening, so Touch must not consume a projectile on its
// hidden trace surface. The host's HitWall performs the crossing instead.
simulated function bool StopsProjectile(Projectile P)
{
    return LinkedPortal == None;
}

simulated function float ClearanceAlong(Pawn P, vector N)
{
    local float R, H;
    R = P.CylinderComponent.CollisionRadius;
    H = P.CylinderComponent.CollisionHeight;
    return Sqrt(FMax(0, 1 - N.Z * N.Z)) * R + Abs(N.Z) * H;
}

simulated function bool InHoleColumn(Pawn P, vector Offs)
{
    local float R, H;
    R = P.CylinderComponent.CollisionRadius;
    H = P.CylinderComponent.CollisionHeight;
    if (Abs(vector(Rotation).Z) > 0.7)
        return Abs(Offs.Y) <= HalfWidth - R * 0.5 && Abs(Offs.Z) <= HalfHeight - R * 0.5;
    return Abs(Offs.Y) <= HalfWidth - R * 0.5 && Offs.Z - H >= -HalfHeight - 4 && Offs.Z <= HalfHeight;
}

simulated function vector EyeLocation(Pawn P)
{
    local PlayerController PC;
    PC = PlayerController(P.Controller);
    if (PC != None && PC.PlayerCamera != None && PC.PlayerCamera.ViewTarget.Target == P)
        return PC.PlayerCamera.CameraCache.POV.Location;
    return P.GetPawnViewLocation();
}

simulated function BeginTunnel(Pawn P)
{
    if (TunnelPawn == P) return;
    TunnelPawn = P;
    P.bCollideWorld = false;
    if (Abs(vector(Rotation).Z) > 0.7) P.SetPhysics(PHYS_Falling);
    else
    {
        P.SetPhysics(PHYS_Flying);
        P.Velocity.Z = 0;
    }
}

// Restore world collision. If the body is still inside the wall (portal
// closed under it), push it out in front first (ForceEntityToFitInPortalWall).
simulated function EndTunnel(optional bool bEject)
{
    local Pawn P;
    local vector Offs, N;
    local float Clear;
    P = TunnelPawn;
    TunnelPawn = None;
    if (P == None || P.bDeleteMe) return;
    N = vector(Rotation);
    Offs = (P.Location - Location) << Rotation;
    Clear = ClearanceAlong(P, N);
    if (bEject && Offs.X < Clear + 2) P.SetLocation(P.Location + N * (Clear + 2 - Offs.X));
    P.bCollideWorld = true;
    if (P.Physics == PHYS_Flying) P.SetPhysics(PHYS_Falling);
}

function bool TeleportPawn(Pawn P, vector Eye, bool bEyeReference)
{
    local vector NewLocation, Offset, NewVelocity, ExitN, Offs;
    local rotator ViewRotation, BodyRotation, YawRotation;
    local int Yaw;
    local float Along, MinimumOut, Clear;
    local VRPortal Exit;
    local bool bPlayer;
    Exit = LinkedPortal;
    if (Exit == None || P == None || P.Health <= 0) return false;
    ExitN = vector(Exit.Rotation);
    bPlayer = PlayerController(P.Controller) != None;
    ViewRotation = P.Controller != None ? P.Controller.Rotation : P.Rotation;
    Yaw = class'VRPortalMath'.static.TravelYaw(ViewRotation, Rotation, Exit.Rotation);
    YawRotation.Yaw = Yaw;
    if (bEyeReference)
    {
        Offset = Eye - P.Location;
        NewLocation = class'VRPortalMath'.static.MapPoint(Eye, Location, Rotation, Exit.Location, Exit.Rotation)
            - (Offset >> YawRotation);
    }
    else
    {
        // The body met the surface: continue it as if it had passed through.
        Offs = (P.Location - Location) << Rotation;
        Offs.X = -Abs(Offs.X);
        NewLocation = class'VRPortalMath'.static.MapPoint(Location + (Offs >> Rotation), Location, Rotation,
            Exit.Location, Exit.Rotation);
    }
    // An upright KF2 pawn cannot follow Portal 2's rotated body through a
    // floor-to-wall exit. Put its whole cylinder outside the wall before
    // restoring collision, including the collision/render mesh offset.
    Clear = ClearanceAlong(P, ExitN) + Exit.CollisionSkin + 8;
    Offs = (NewLocation - Exit.Location) << Exit.Rotation;
    if (Offs.X < Clear) NewLocation += ExitN * (Clear - Offs.X);
    NewVelocity = MapDirection(P.Velocity);
    // Portal 2 clamps exit speed; a floor exit gets enough to clear the hole.
    Along = NewVelocity dot ExitN;
    MinimumOut = ExitN.Z > 0.7 ? Sqrt(2 * Abs(WorldInfo.WorldGravityZ) * (2 * P.CylinderComponent.CollisionHeight + 40)) : 60.0;
    if (Along < MinimumOut) NewVelocity += ExitN * (MinimumOut - Along);
    if (bPlayer)
    {
        EndTunnel();
        P.bCollideWorld = false;
        if (!P.SetLocation(NewLocation)) { P.bCollideWorld = true; return false; }
        P.bCollideWorld = true;
        P.SetPhysics(PHYS_Falling);
        Exit.LastEyeX = ((EyeLocation(P) - Exit.Location) << Exit.Rotation).X;
    }
    else if (!P.SetLocation(NewLocation) && !P.SetLocation(NewLocation + ExitN * 24)) return false;
    BodyRotation = P.Rotation;
    BodyRotation.Yaw += Yaw;
    BodyRotation.Pitch = 0;
    BodyRotation.Roll = 0;
    P.SetRotation(BodyRotation);
    if (P.Controller != None)
    {
        ViewRotation.Yaw += Yaw;
        ViewRotation.Roll = 0;
        P.Controller.SetRotation(ViewRotation);
        if (!bPlayer) P.Controller.MoveTimer = -1;
    }
    P.Velocity = NewVelocity;
    P.Acceleration = MapDirection(P.Acceleration);
    if (!bPlayer) P.SetPhysics(PHYS_Falling);
    // The camera cache lags one frame behind the move; both ends ignore
    // crossings briefly so that stale eye cannot bounce the traveller back.
    Exit.RecentTraveler = P;
    Exit.RecentTravelTime = WorldInfo.TimeSeconds;
    RecentTraveler = P;
    RecentTravelTime = WorldInfo.TimeSeconds;
    PlayCue('PortalEnter');
    Exit.PlayCue('PortalExit');
    `log("KF2VR_PORTAL action=traverse color=" $ PortalColor @ "pawn=" $ P.Class @ "yaw=" $ Yaw
        @ "speed=" $ int(VSize(NewVelocity)) @ "eye=" $ bEyeReference);
    return true;
}

simulated function UpdatePlayer(Pawn P, float DeltaTime)
{
    local vector N, Offs, EyeLocal, Eye;
    local float Clear, R, H, PreviousEyeX;
    N = vector(Rotation);
    Offs = (P.Location - Location) << Rotation;
    Eye = EyeLocation(P);
    EyeLocal = (Eye - Location) << Rotation;
    PreviousEyeX = LastEyeX;
    LastEyeX = EyeLocal.X;
    UpdateCaptureMode(EyeLocal);
    Clear = ClearanceAlong(P, N);
    if (TunnelPawn != P)
    {
        if (!InHoleColumn(P, Offs) || Offs.X > Clear + CollisionSkin || Offs.X < -Clear) return;
        if (RecentTraveler == P && WorldInfo.TimeSeconds - RecentTravelTime < 0.25) return;
        if (Abs(N.Z) > 0.7 || (P.Velocity dot N) < -5 || (P.Acceleration dot N) < -5
            || (EyeLocal.X < Clear && class'VRPortalMath'.static.InsideEllipse(EyeLocal.Y, EyeLocal.Z, HalfWidth, HalfHeight)))
            BeginTunnel(P);
        else return;
    }
    // Portal 2's trigger: the reference point crosses the plane inside the hole.
    if (RecentTraveler == P && WorldInfo.TimeSeconds - RecentTravelTime < 0.1) PreviousEyeX = 0;
    if (PreviousEyeX > 0 && EyeLocal.X <= 0
        && class'VRPortalMath'.static.InsideEllipse(EyeLocal.Y, EyeLocal.Z, HalfWidth, HalfHeight))
    {
        if (TeleportPawn(P, Eye, true)) return;
    }
    if (Offs.X <= -Clear && TeleportPawn(P, Eye, false)) return;
    if (Offs.X > Clear + CollisionSkin + 8) { EndTunnel(); return; }
    R = P.CylinderComponent.CollisionRadius;
    H = P.CylinderComponent.CollisionHeight;
    // Keep the body inside the hole while it is inside the wall.
    if (Offs.X < Clear)
    {
        Offs.Y = FClamp(Offs.Y, -FMax(0, HalfWidth - R), FMax(0, HalfWidth - R));
        if (Abs(N.Z) > 0.7) Offs.Z = FClamp(Offs.Z, -FMax(0, HalfHeight - R), FMax(0, HalfHeight - R));
        else Offs.Z = FClamp(Offs.Z, -HalfHeight + H, FMax(-HalfHeight + H, HalfHeight - H));
        if (VSizeSq(((Offs >> Rotation) + Location) - P.Location) > 0.01) P.SetLocation((Offs >> Rotation) + Location);
        // Just out of the exit and standing still: ease the body clear.
        if (RecentTraveler == P && (P.Velocity dot N) < 40) P.Move(N * 150 * DeltaTime);
    }
    if (P.Physics == PHYS_Flying) P.Velocity.Z = 0;
}

simulated function UpdateOther(Pawn P)
{
    local vector N, Offs;
    local float Clear;
    if (RecentTraveler == P && WorldInfo.TimeSeconds - RecentTravelTime < 0.5) return;
    N = vector(Rotation);
    Offs = (P.Location - Location) << Rotation;
    Clear = ClearanceAlong(P, N);
    if (Offs.X < -2 || Offs.X > Clear + CollisionSkin + 4 || !InHoleColumn(P, Offs)) return;
    if (Abs(N.Z) <= 0.7 && (P.Velocity dot N) > -10 && (P.Acceleration dot N) > -10) return;
    TeleportPawn(P, P.Location, false);
}

simulated event Tick(float DeltaTime)
{
    local Pawn P;
    local PlayerController PC;
    local bool bSawViewer;
    Super.Tick(DeltaTime);
    if (Gun == None || Gun.bDeleteMe) { Destroy(); return; }
    // Placement already checked the whole aperture. A tiny follow-up trace
    // can miss a valid static mesh and close the portal half a second later.
    // Static world geometry cannot move; only a destroyed mount invalidates it.
    if (MountActor != None && MountActor.bDeleteMe) { Gun.PortalLost(self); return; }
    UpdateAperture();
    if (LinkedPortal == None || LinkedPortal.bDeleteMe)
    {
        if (TunnelPawn != None) EndTunnel(true);
        return;
    }
    if (TunnelPawn != None && (TunnelPawn.bDeleteMe || TunnelPawn.Health <= 0)) EndTunnel(true);
    foreach WorldInfo.AllPawns(class'Pawn', P, Location, FMax(HalfWidth, HalfHeight) + 300)
    {
        if (P.bDeleteMe || P.Health <= 0 || !P.bCanTeleport || P.CylinderComponent == None || Vehicle(P) != None) continue;
        PC = PlayerController(P.Controller);
        if (PC != None && PC.IsLocalPlayerController()) { bSawViewer = true; UpdatePlayer(P, DeltaTime); }
        else UpdateOther(P);
    }
    if (!bSawViewer && CaptureMode != 0) { CaptureMode = 0; SurfaceMaterial.SetScalarParameterValue('ScreenSpace', 0); }

}

simulated event Destroyed()
{
    EndTunnel(true);
    if (LinkedPortal != None && LinkedPortal.LinkedPortal == self) LinkedPortal.LinkTo(None);
    LinkedPortal = None;
    PortalCapture.SetEnabled(false);
    PortalCapture.SetCaptureParameters(None, 1.0, None);
    if (Gun != None && Gun.Apertures != None) Gun.Apertures.Show(PortalColor, false);
    PlayCue(PortalColor == 0 ? 'PortalClose' : 'PortalCloseOrange');
    CaptureTexture = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bNoDelete=false
    bMovable=true
    bHidden=false
    bCollideActors=true
    bBlockActors=false
    bCollideWorld=false
    bWorldGeometry=false
    bCanBeDamaged=false
    bProjTarget=true
    TickGroup=TG_PostAsyncWork
    HalfWidth=81.28
    HalfHeight=142.24
    CaptureWidth=768
    CaptureHeight=1344
    ScreenSpaceEnter=70
    ScreenSpaceExit=95
    CollisionSkin=24
    BlueColor=(R=0.04,G=0.45,B=1.6,A=1)
    OrangeColor=(R=1.6,G=0.35,B=0.03,A=1)
    // FBX import flips Blender's V coordinate: the aperture's top arrives
    // at V=1, while the render target's top is V=0. Flip window sampling
    // back; close-range ScreenPosition sampling does not use this mapping.
    WindowUVScale=(X=1,Y=-1)
    WindowUVBias=(X=0,Y=1)

    Begin Object Class=SceneCapturePortalComponent Name=PortalCaptureComponent
        bEnabled=false
        FrameRate=1000
        ScaleFOV=1.0
        ViewMode=SceneCapView_LitNoShadows
        bEnablePostProcess=false
        bEnableFog=true
        bSkipRenderingDepthPrepass=true
        bSkipUpdateIfOwnerOccluded=false
        bSkipUpdateIfTextureUsersOccluded=false
        MaxStreamingUpdateDist=0
    End Object
    PortalCapture=PortalCaptureComponent
    Components.Add(PortalCaptureComponent)

    Begin Object Class=StaticMeshComponent Name=PortalRimComponent
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDynamicLights=false
        bUseAsOccluder=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
        Translation=(X=0.6,Y=0,Z=0)
    End Object
    RimMesh=PortalRimComponent
    Components.Add(PortalRimComponent)

    Begin Object Class=StaticMeshComponent Name=PortalFillComponent
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDynamicLights=false
        bUseAsOccluder=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
        Translation=(X=0.3,Y=0,Z=0)
    End Object
    FillMesh=PortalFillComponent
    Components.Add(PortalFillComponent)

    Begin Object Class=StaticMeshComponent Name=PortalHitComponent
        HiddenGame=true
        CastShadow=false
        bUseAsOccluder=false
        CollideActors=true
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
        Translation=(X=1.0,Y=0,Z=0)
    End Object
    HitMesh=PortalHitComponent
    Components.Add(PortalHitComponent)
}
