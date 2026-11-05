// Local barrel ray. A thin world mesh updates with the final gun transform;
// particle beams cache simulated endpoints before late weapon placement.
class VRWeaponLaser extends Actor;

var StaticMeshComponent Beam, Dot, Core;
var Actor HitActor;
var vector Start, End, SurfaceNormal, BeamMeshCenter, BeamMeshExtent;
var float LastUpdateTime;
var float TraceOffAxis;
var transient float NextTraceDebugTime;
var bool bVisible;
var KFWeapon DisplayedWeapon;
var transient MaterialInstanceConstant RedBeamMaterial, RedDotMaterial;
// The player's laser colour and sizes (VRInteractionColours), reapplied on change.
var transient int ColourRevision, GlowChannel;
var transient float BeamWidthScale, DotSizeScale;
var transient bool bSmallDot;

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
    Dot.SetAbsolute(true, true, true);
    Core.SetAbsolute(true, true, true);
    Beam.SetTranslation(vect(0,0,0));
    Beam.SetRotation(rot(0,0,0));
    Beam.ForceUpdate(true);
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
    RedDotMaterial = new(self) class'MaterialInstanceConstant';
    RedDotMaterial.SetParent(Material'WEP_AutoTurret_EMIT.Turret_Laser_Dot_SM_PM');
    RedDotMaterial.SetScalarParameterValue('0blue_1red', 1);
    Dot.SetMaterial(0, RedDotMaterial);
    // The glow card is additive, so it washes out on bright surfaces. A small
    // solid core in the beam's unlit red keeps the point readable there.
    Core.SetMaterial(0, RedBeamMaterial);
    ColourRevision = -1;
    ApplyLook();
    `log("KF2VR laser color configured: mesh=LevelColorationUnlitMaterial Color=1,0,0 dot=Turret_Laser_Dot_SM_PM 0blue_1red=1"
        @ "meshExtent=" $ BeamMeshExtent);
    HideLaser();
}

simulated function ApplyLook()
{
    local LinearColor Tint;
    if (ColourRevision == class'VRInteractionColours'.default.Revision) return;
    ColourRevision = class'VRInteractionColours'.default.Revision;
    Tint = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_LASER);
    RedBeamMaterial.SetVectorParameterValue('Color', Tint);
    GlowChannel = class'VRInteractionColours'.static.LaserGlowChannel();
    if (GlowChannel >= 0) RedDotMaterial.SetScalarParameterValue('0blue_1red', GlowChannel);
    BeamWidthScale = class'VRInteractionColours'.static.BeamWidth() / 100.0;
    // 100% is 85% of the original dot (Kvasir94, 11-03, #163); the player's
    // DOT SIZE percentage scales from there.
    DotSizeScale = class'VRInteractionColours'.static.DotSize() / 100.0 * 0.85;
    bSmallDot = class'VRInteractionColours'.default.bLaserSmallDot;
}

simulated function HideLaser()
{
    Beam.SetHidden(true);
    Dot.SetHidden(true);
    Core.SetHidden(true);
    bVisible = false;
    HitActor = None;
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
// laser samples at most once a second.
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

simulated function DrawSegment(StaticMeshComponent Segment, vector From, vector To, rotator Aim)
{
    local vector Scale, Center;
    local float Distance;
    Distance = VSize(To - From);
    Scale.X = Distance / (2 * BeamMeshExtent.X);
    Scale.Y = 0.05 * BeamWidthScale / BeamMeshExtent.Y;
    Scale.Z = 0.05 * BeamWidthScale / BeamMeshExtent.Z;
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
    local vector HitLocation, Direction;
    local float Distance, DirectionLength, Range;
    local bool bLogTrace;

    if (BeamMeshExtent.X <= 0 || BeamMeshExtent.Y <= 0 || BeamMeshExtent.Z <= 0)
    {
        HideLaser();
        return;
    }
    ApplyLook();
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
    Distance = VSize(End - Start);

    // 1 mm beam in the same depth buffer as the gun. Transform and bounds
    // update immediately, even when called after the particle tick in Draw.
    DrawSegment(Beam, Start, End, Aim);
    bVisible = true;
    LastUpdateTime = WorldInfo.TimeSeconds;
    Dot.SetTranslation(End + SurfaceNormal * 0.15);
    Dot.SetRotation(Aim);
    // Grow with distance so the point keeps a readable angular size: the glow
    // past about 15 ft, the core at roughly a quarter of a degree everywhere.
    // The small-dot option keeps the older fixed glow with no core, unless the
    // laser colour has no glow card, when the core carries the dot.
    if (bSmallDot) Dot.SetScale(FClamp(1 + Distance / 6000, 1, 3) * DotSizeScale);
    else Dot.SetScale(FClamp(Distance / 450, 1, 8) * DotSizeScale);
    Dot.SetHidden(HitActor == None || GlowChannel < 0);
    Dot.ForceUpdate(true);
    Core.SetTranslation(End + SurfaceNormal * 0.3);
    Core.SetRotation(Aim);
    Core.SetScale(FMax(Distance * 0.0022, 0.25) * DotSizeScale * (GlowChannel < 0 ? 1.6 : 1.0) / BeamMeshExtent.X);
    Core.SetHidden(HitActor == None || (bSmallDot && GlowChannel >= 0));
    Core.ForceUpdate(true);
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
    Begin Object Class=StaticMeshComponent Name=LaserCoreComponent
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
    Core=LaserCoreComponent
    Components.Add(LaserCoreComponent)
}
