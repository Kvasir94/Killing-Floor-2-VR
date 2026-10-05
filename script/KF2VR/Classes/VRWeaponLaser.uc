// Local barrel ray. A thin world mesh updates with the final gun transform;
// particle beams cache simulated endpoints before late weapon placement.
class VRWeaponLaser extends Actor;

var StaticMeshComponent Beam, ExitBeam, Dot;
var Actor HitActor;
var vector Start, End, SurfaceNormal, BeamMeshCenter, BeamMeshExtent;
var vector ExitStart, ExitEnd;
var VRPortal EntryPortal;
var float LastUpdateTime;
var float TraceOffAxis;
var transient float NextTraceDebugTime;
var bool bVisible;
var KFWeapon DisplayedWeapon;
var transient MaterialInstanceConstant RedBeamMaterial, RedDotMaterial;

struct HUDTraceState
{
    var Actor Hit;
    var PrimitiveComponent Component;
    var bool ActorCollides, ActorBlocks, ProjectileTarget, IgnoreEncroachers;
    var bool ComponentCollides, ComponentBlocks, ZeroExtent, NonZeroExtent, AlwaysCheck;
};

simulated event PostBeginPlay()
{
    local LinearColor Red;
    Super.PostBeginPlay();
    Beam.SetAbsolute(true, true, true);
    ExitBeam.SetAbsolute(true, true, true);
    Dot.SetAbsolute(true, true, true);
    Beam.SetTranslation(vect(0,0,0));
    Beam.SetRotation(rot(0,0,0));
    Beam.ForceUpdate(true);
    ExitBeam.SetTranslation(vect(0,0,0));
    ExitBeam.SetRotation(rot(0,0,0));
    ExitBeam.ForceUpdate(true);
    // Verified EngineMeshes.Cube native bounds: center 0, half-size 128.
    // Component bounds add a 1 UU safety pad; scaling that pad would shorten
    // a long beam and move its visible start away from the muzzle.
    BeamMeshCenter = vect(0,0,0);
    BeamMeshExtent = vect(128,128,128);
    // Installed, cooked unlit material: its verified Color parameter drives
    // emissive RGB directly. No shared particle template needs modification.
    RedBeamMaterial = new(self) class'MaterialInstanceConstant';
    RedBeamMaterial.SetParent(Material'EngineDebugMaterials.LevelColorationUnlitMaterial');
    Red = MakeLinearColor(1,0,0,1);
    RedBeamMaterial.SetVectorParameterValue('Color', Red);
    Beam.SetMaterial(0, RedBeamMaterial);
    ExitBeam.SetMaterial(0, RedBeamMaterial);
    RedDotMaterial = new(self) class'MaterialInstanceConstant';
    RedDotMaterial.SetParent(Material'WEP_AutoTurret_EMIT.Turret_Laser_Dot_SM_PM');
    RedDotMaterial.SetScalarParameterValue('0blue_1red', 1);
    Dot.SetMaterial(0, RedDotMaterial);
    `log("KF2VR laser color configured: mesh=LevelColorationUnlitMaterial Color=1,0,0 dot=Turret_Laser_Dot_SM_PM 0blue_1red=1"
        @ "meshExtent=" $ BeamMeshExtent);
    HideLaser();
}

simulated function HideLaser()
{
    Beam.SetHidden(true);
    ExitBeam.SetHidden(true);
    Dot.SetHidden(true);
    bVisible = false;
    HitActor = None;
    EntryPortal = None;
}

// Read back the renderer's actual transform, including its native rotation
// basis. Reconstructing an endpoint from Bounds plus a script rotator cast can
// disagree with that basis on long rays.
simulated function vector RenderedBeamEnd()
{
    return TransformVector(Beam.LocalToWorld, BeamMeshCenter + vect(1,0,0) * BeamMeshExtent.X);
}

simulated function bool IsHUDActor(Actor A)
{
    // The panel and any component owned through its display actor are UI,
    // even if a later material/component update accidentally enables collision.
    while (A != None)
    {
        if (A.IsA('VRHUDPanel') || A.IsA('VRSpatialHUD') || A.IsA('VRHandSelector')) return true;
        A = A.Owner;
    }
    return false;
}

simulated function bool IsHUDHit(Actor A, TraceHitInfo HitInfo)
{
    return A != None && (IsHUDActor(A)
        || (HitInfo.HitComponent != None && IsHUDActor(HitInfo.HitComponent.Owner)));
}

// Reuse the session-only ALIGN MARKERS switch on the root hand rig. Each
// laser samples at most once a second, including its portal exit if present.
simulated function bool SampleTraceDebug()
{
    local VRHandsBridge B;
    B = VRHandsBridge(Owner);
    if (B == None) return false;
    if (B.RootBridge != None) B = B.RootBridge;
    if (!B.bAlignmentMarkers || WorldInfo.RealTimeSeconds < NextTraceDebugTime) return false;
    NextTraceDebugTime = WorldInfo.RealTimeSeconds + 1.0;
    return true;
}

simulated function LogTraceHit(KFWeapon W, Actor TraceOwner, Actor Hit, TraceHitInfo HitInfo,
    vector RayStart, vector RayEnd, vector HitLocation, vector HitNormal, name Segment, string Phase, int HUDMasks)
{
    `log("KF2VR_LASER_TRACE time=" $ WorldInfo.RealTimeSeconds @ "laser=" $ self
        @ "weapon=" $ W @ "traceOwner=" $ TraceOwner @ "segment=" $ Segment @ "phase=" $ Phase
        @ "actor=" $ Hit @ "actorClass=" $ (Hit != None ? Hit.Class : None)
        @ "actorOwner=" $ (Hit != None ? Hit.Owner : None)
        @ "component=" $ (Hit != None ? HitInfo.HitComponent : None)
        @ "componentClass=" $ ((Hit != None && HitInfo.HitComponent != None) ? HitInfo.HitComponent.Class : None)
        @ "componentOwner=" $ ((Hit != None && HitInfo.HitComponent != None) ? HitInfo.HitComponent.Owner : None)
        @ "start=" $ RayStart @ "end=" $ RayEnd @ "hit=" $ (Hit != None ? HitLocation : RayEnd)
        @ "normal=" $ (Hit != None ? HitNormal : vect(0,0,0))
        @ "hudMasks=" $ HUDMasks);
}

simulated function Actor TraceAim(KFWeapon W, vector RayStart, vector RayEnd, out vector HitLocation, out vector HitNormal,
    optional bool bLogTrace, optional name Segment)
{
    local Actor TraceOwner, FirstHit;
    local TraceHitInfo HitInfo;
    local array<HUDTraceState> Masked;
    local HUDTraceState Saved;
    local int I;

    TraceOwner = W.GetTraceOwner();
    FirstHit = TraceOwner.Trace(HitLocation, HitNormal, RayEnd, RayStart,
        true, vect(0,0,0), HitInfo, W.TRACEFLAG_Bullet);
    if (bLogTrace) LogTraceHit(W, TraceOwner, FirstHit, HitInfo, RayStart, RayEnd, HitLocation, HitNormal, Segment, "first", 0);
    if (!IsHUDHit(FirstHit, HitInfo)) return FirstHit;

    // Keep using the stock bullet trace, including its range-dependent hit
    // pullback. Mask only intercepted UI, then retrace the ORIGINAL segment so a wall
    // immediately behind a panel cannot be skipped. All flags restore before
    // returning; the usual noncolliding HUD takes the fast path above.
    while (IsHUDHit(FirstHit, HitInfo) && Masked.Length < 16)
    {
        Saved.Hit = FirstHit;
        Saved.Component = HitInfo.HitComponent;
        Saved.ActorCollides = FirstHit.bCollideActors;
        Saved.ActorBlocks = FirstHit.bBlockActors;
        Saved.ProjectileTarget = FirstHit.bProjTarget;
        Saved.IgnoreEncroachers = FirstHit.bIgnoreEncroachers;
        if (Saved.Component != None)
        {
            Saved.ComponentCollides = Saved.Component.CollideActors;
            Saved.ComponentBlocks = Saved.Component.BlockActors;
            Saved.ZeroExtent = Saved.Component.BlockZeroExtent;
            Saved.NonZeroExtent = Saved.Component.BlockNonZeroExtent;
            Saved.AlwaysCheck = Saved.Component.AlwaysCheckCollision;
            Saved.Component.SetActorCollision(false, false);
            Saved.Component.SetTraceBlocking(false, false);
        }
        Masked.AddItem(Saved);
        FirstHit.SetCollision(false, false);
        FirstHit.bProjTarget = false;
        HitInfo.HitComponent = None;
        FirstHit = TraceOwner.Trace(HitLocation, HitNormal, RayEnd, RayStart,
            true, vect(0,0,0), HitInfo, W.TRACEFLAG_Bullet);
    }
    if (IsHUDHit(FirstHit, HitInfo)) { FirstHit = None; HitNormal = vect(0,0,0); }
    for (I = Masked.Length - 1; I >= 0; --I)
    {
        Saved = Masked[I];
        if (Saved.Component != None)
        {
            Saved.Component.SetActorCollision(Saved.ComponentCollides, Saved.ComponentBlocks, Saved.AlwaysCheck);
            Saved.Component.SetTraceBlocking(Saved.ZeroExtent, Saved.NonZeroExtent);
        }
        Saved.Hit.bProjTarget = Saved.ProjectileTarget;
        Saved.Hit.SetCollision(Saved.ActorCollides, Saved.ActorBlocks, Saved.IgnoreEncroachers);
    }
    if (bLogTrace) LogTraceHit(W, TraceOwner, FirstHit, HitInfo, RayStart, RayEnd, HitLocation, HitNormal,
        Segment, "resolved", Masked.Length);
    return FirstHit;
}

simulated function VRPortal FirstPortal(vector RayStart, vector Direction, float Range, Actor FirstHit, vector HitLocation,
    out vector PlaneHit, out float PlaneDistance)
{
    local VRPortal P, Best;
    local vector N, LocalHit, CandidateHit;
    local float Along, Distance, FirstDistance;
    FirstDistance = FirstHit == None ? Range : FClamp((HitLocation - RayStart) dot Direction, 0, Range);
    PlaneDistance = Range;
    foreach WorldInfo.DynamicActors(class'VRPortal', P)
    {
        if (P.LinkedPortal == None || P.bDeleteMe || P.LinkedPortal.bDeleteMe) continue;
        N = vector(P.Rotation);
        Along = Direction dot N;
        if (Along >= -0.001 || ((RayStart - P.Location) dot N) <= 0) continue;
        Distance = ((P.Location - RayStart) dot N) / Along;
        if (Distance < 0 || Distance >= PlaneDistance || Distance > Range) continue;
        // Static-map collision can stand proud of the rendered aperture.
        // Never skip a pawn or movable blocker before the entry plane.
        if (Distance > FirstDistance + (class'VRPortalPlacement'.static.IsPortalable(FirstHit)
            ? P.CollisionSkin + Range * 0.001 + 8.0 : 0.0)) continue;
        CandidateHit = RayStart + Direction * Distance;
        LocalHit = (CandidateHit - P.Location) << P.Rotation;
        if (!class'VRPortalMath'.static.InsideEllipse(LocalHit.Y, LocalHit.Z, P.HalfWidth, P.HalfHeight)) continue;
        Best = P;
        PlaneHit = CandidateHit;
        PlaneDistance = Distance;
    }
    return Best;
}

simulated function DrawSegment(StaticMeshComponent Segment, vector From, vector To, rotator Aim)
{
    local vector Scale, Center;
    local float Distance;
    Distance = VSize(To - From);
    Scale.X = Distance / (2 * BeamMeshExtent.X);
    Scale.Y = 0.05 / BeamMeshExtent.Y;
    Scale.Z = 0.05 / BeamMeshExtent.Z;
    Center.X = BeamMeshCenter.X * Scale.X;
    Center.Y = BeamMeshCenter.Y * Scale.Y;
    Center.Z = BeamMeshCenter.Z * Scale.Z;
    Segment.SetScale3D(Scale);
    Segment.SetRotation(Aim);
    Segment.SetTranslation((From + To) * 0.5 - (Center >> Aim));
    Segment.SetHidden(Distance <= 0.001);
    Segment.ForceUpdate(true);
}

simulated function UpdateAim(KFWeapon W, vector Muzzle, rotator Aim)
{
    local vector HitLocation, Direction, PlaneHit, ExitDirection, ExitHit, DotEnd;
    local float Distance, DirectionLength, Range, PlaneDistance;
    local bool bLogTrace;

    if (BeamMeshExtent.X <= 0 || BeamMeshExtent.Y <= 0 || BeamMeshExtent.Z <= 0)
    {
        HideLaser();
        return;
    }
    DisplayedWeapon = W;
    Start = Muzzle;
    // Use the same native matrix basis as the mesh renderer for the optical
    // ray and scale. Its length need not be exactly one after rotation lookup.
    Direction = MatrixGetAxis(MakeRotationMatrix(Aim), AXIS_X);
    DirectionLength = VSize(Direction);
    if (DirectionLength <= 0.001) { HideLaser(); return; }
    Direction /= DirectionLength;
    SurfaceNormal = vect(0,0,0);
    Range = FMin(W.GetTraceRange(), 20000);
    End = Start + Direction * Range;
    bLogTrace = SampleTraceDebug();
    HitActor = TraceAim(W, Start, End, HitLocation, SurfaceNormal, bLogTrace, 'entry');
    TraceOffAxis = 0;
    if (HitActor != None)
    {
        // Collision contact padding can offset HitLocation sideways from the
        // optical ray. Keep the hit's distance while drawing along the bore.
        Distance = FClamp((HitLocation - Start) dot Direction, 0, VSize(End - Start));
        End = Start + Direction * Distance;
        TraceOffAxis = VSize(HitLocation - End);
    }
    EntryPortal = FirstPortal(Start, Direction, Range, HitActor, HitLocation, PlaneHit, PlaneDistance);
    DotEnd = End;
    if (EntryPortal != None)
    {
        End = PlaneHit;
        ExitDirection = Normal(EntryPortal.MapDirection(Direction));
        ExitStart = EntryPortal.MapPointThrough(PlaneHit) + ExitDirection * 2;
        ExitEnd = ExitStart + ExitDirection * (Range - PlaneDistance);
        HitActor = TraceAim(W, ExitStart, ExitEnd, ExitHit, SurfaceNormal, bLogTrace, 'exit');
        if (HitActor != None)
        {
            Distance = FClamp((ExitHit - ExitStart) dot ExitDirection, 0, Range - PlaneDistance);
            ExitEnd = ExitStart + ExitDirection * Distance;
        }
        DotEnd = ExitEnd;
        DrawSegment(ExitBeam, ExitStart, ExitEnd, rotator(ExitDirection));
    }
    else ExitBeam.SetHidden(true);
    Distance = VSize(End - Start);

    // 1 mm beam in the same depth buffer as the gun. Transform and bounds
    // update immediately, even when called after the particle tick in Draw.
    DrawSegment(Beam, Start, End, Aim);
    bVisible = true;
    LastUpdateTime = WorldInfo.TimeSeconds;
    Dot.SetTranslation(DotEnd + SurfaceNormal * 0.15);
    Dot.SetRotation(Aim);
    Dot.SetScale(FClamp(1 + Distance / 6000, 1, 3));
    Dot.SetHidden(HitActor == None);
    Dot.ForceUpdate(true);
}

simulated event Tick(float DeltaTime)
{
    if (Owner == None || Owner.bDeleteMe) { Destroy(); return; }
    if (bVisible && (DisplayedWeapon == None || DisplayedWeapon.bDeleteMe
        || WorldInfo.TimeSeconds - LastUpdateTime > 0.25)) HideLaser();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    bBlockActors=false
    TickGroup=TG_PostUpdateWork
    Begin Object Class=StaticMeshComponent Name=LaserBeamComponent
        StaticMesh=StaticMesh'EngineMeshes.Cube'
        HiddenGame=true
        DepthPriorityGroup=SDPG_World
        bOwnerNoSee=false
        bOnlyOwnerSee=false
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
    Beam=LaserBeamComponent
    Components.Add(LaserBeamComponent)
    Begin Object Class=StaticMeshComponent Name=LaserExitBeamComponent
        StaticMesh=StaticMesh'EngineMeshes.Cube'
        HiddenGame=true
        DepthPriorityGroup=SDPG_World
        bOwnerNoSee=false
        bOnlyOwnerSee=false
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
    ExitBeam=LaserExitBeamComponent
    Components.Add(LaserExitBeamComponent)
    Begin Object Class=StaticMeshComponent Name=LaserDotComponent
        StaticMesh=StaticMesh'FX_Wep_Laser_MESH.laser_dot_SM'
        HiddenGame=true
        DepthPriorityGroup=SDPG_World
        bOwnerNoSee=false
        bOnlyOwnerSee=false
        CastShadow=false
        bAcceptsLights=false
        bAcceptsDecals=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    Dot=LaserDotComponent
    Components.Add(LaserDotComponent)
}
