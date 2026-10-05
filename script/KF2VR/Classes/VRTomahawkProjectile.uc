// One persistent axe bound to its source inventory weapon. Only authority
// moves it between outbound, embedded and returning phases or deals damage.
class VRTomahawkProjectile extends KFProjectile config(Game);

var repnotify byte Phase; // 2 outbound, 3 embedded/resting, 4 returning, 5 suspended
var KFPawn_Human Human;
var VRWeap_Tomahawk SourceWeapon;
var StaticMeshComponent HawkMesh;
var float FlightStarted, RecallStarted;
var array<KFPawn_Monster> ReturnHits;
// Provisional utility tuning, server-owned. Radius is bounded to 160 UU;
// the one-time walking-host tug is hard-capped to 60 UU (about two feet).
const PrototypeShockRadius = 80;
const MaximumShockRadius = 160;
const MaximumRecallTug = 60;
var config float SuspendedShockRadius, RecallTugDistance;
var KFPawn_Monster RecallHost;
// Visual balance point, measured from the authored grip origin (the 46.8 cm
// model; tools/raven7_model.py). The projectile's
// ballistic root stays stable while the head/haft rotate about this point.
var vector SpinCenter;
var bool bCatchAligned;
var AkEvent FlightSound;
// Electric layers: the Ion Thruster's hum rides the flying axe (the ambient
// loop), its twirl whoosh marks release and recall, Static Strikers arcs
// burst at release, recall and embedding, Hans' spark stream trails the
// blade in flight, and a short lightning flick crackles on a shocked host.
var AkEvent WhooshSound;
var ParticleSystem BurstTemplate, FlickTemplate;
// The cutting edge's centre in model space: effects ride the blade, not the grip.
var vector BladeLocal;
// An embedded axe shocks its living host every ShockInterval seconds for
// ShockFraction of the outbound hit with the EMP damage type.
var float ShockInterval, ShockFraction, NextShockTime, NextFlickTime;
// The KF helper's standard attachment replication excludes the owning client.
// Mirror the attachment for this reusable owner-controlled item as well.
struct HawkAttachment
{
    var Actor Target;
    var int Bone;
    var vector Position;
    var rotator Rotation;
};
var repnotify HawkAttachment Attachment;

replication
{
    if (bNetDirty) Phase, Human, SourceWeapon, Attachment, bCatchAligned;
}

simulated function PostBeginPlay()
{
    Super.PostBeginPlay();
    HawkMesh.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VRHands.VRTomahawk", class'StaticMesh', true)));
    // Existing game materials ship with KF2. The new mesh has its own geometry.
    class'VRTomahawkMaterials'.static.Apply(self, HawkMesh);
    HawkMesh.SetTranslation(-SpinCenter);
    ApplyPhase();
    // Clients hear it once the spawn's replicated phase has arrived, so a
    // late-joining observer of an embedded axe hears nothing.
    if (Role == ROLE_Authority) PlayFlightSound();
    else SetTimer(0.05, false, nameof(PlayFlightSound));
}

// The stock Fire Axe spin whoosh under the Ion Thruster's twirl, heard by
// everyone, on release and recall, with a burst of arcs off the blade.
simulated function PlayFlightSound()
{
    if (WorldInfo.NetMode == NM_DedicatedServer || (Phase != 2 && Phase != 4)) return;
    PlaySoundBase(FlightSound, true);
    PlaySoundBase(WhooshSound, true);
    PlayBurst();
}

simulated function PlayBurst()
{
    if (WorldInfo.NetMode == NM_DedicatedServer || BurstTemplate == None) return;
    WorldInfo.MyEmitterPool.SpawnEmitter(BurstTemplate, BladeWorld(), Rotation, self);
}

// World position of the cutting edge's centre for the current mesh pose.
simulated function vector BladeWorld()
{
    return Location + ((HawkMesh.Translation + (BladeLocal >> HawkMesh.Rotation)) >> Rotation);
}

// The living enemy an embedded axe is stuck in, if any.
simulated function KFPawn_Monster ShockHost()
{
    local KFPawn_Monster M;
    M = KFPawn_Monster(StuckToActor);
    if (Phase != 3 || M == None || M.Health <= 0 || M.bPlayedDeath || M.bDeleteMe || Human == None
        || M.GetTeamNum() == Human.GetTeamNum()) return None;
    return M;
}

// The hum loop and the blade's spark stream run only while the axe flies out
// or returns. KFProjectile starts both at spawn; restart them the same way.
simulated function SetFlightEffects(bool bOn)
{
    if (WorldInfo.NetMode == NM_DedicatedServer) return;
    if (bOn) { if (ProjEffects == None) SpawnFlightEffects(); return; }
    StopAmbientSound();
    if (ProjEffects == None) return;
    DetachComponent(ProjEffects);
    WorldInfo.MyEmitterPool.OnParticleSystemFinished(ProjEffects);
    ProjEffects = None;
}

simulated function ApplyPhase()
{
    if (Phase == 4 && StuckToActor != None) StickHelper.UnStick();
    bCollideWorld = Phase == 2;
    SetCollision(Phase == 2, false, false);
    if (Phase != 2) { SetPhysics(PHYS_None); Velocity = vect(0,0,0); }
    else SetPhysics(PHYS_Falling);
    if (Phase == 3) { HawkMesh.SetRotation(rot(0,0,0)); HawkMesh.SetTranslation(vect(0,0,0)); }
    SetFlightEffects(Phase == 2 || Phase == 4 || Phase == 5);
}

// Both phase and attachment notifications rebuild from the complete current
// snapshot. This works whether Phase or Attachment arrives first, and prevents
// KFProjectile's separate StuckToActor notification from reattaching a recall.
simulated function SyncAttachment()
{
    if (Phase == 3 && Attachment.Target != None)
    {
        StuckToLocation = Attachment.Position; StuckToRotation = Attachment.Rotation;
        StickHelper.ReplicatedStick(Attachment.Target, Attachment.Bone);
    }
    else if (StuckToActor != None || Base != None) StickHelper.UnStick();
    ApplyPhase();
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'Phase' && Phase == 4) PlayFlightSound();
    if (VarName == 'Phase' || VarName == 'Attachment' || VarName == 'StuckToActor')
        SyncAttachment();
    else Super.ReplicatedEvent(VarName);
    if (VarName == 'Phase' && (Phase == 3 || Phase == 5)) PlayBurst();
}

function BeginSuspend()
{
    if (Role != ROLE_Authority || Phase != 2) return;
    Phase = 5; ApplyPhase(); bForceNetUpdate = true;
    NextShockTime = WorldInfo.TimeSeconds + ShockInterval;
    PlayBurst();
}

function BeginRecall()
{
    if (Role != ROLE_Authority || Phase == 4) return;
    RecallHost = KFPawn_Monster(StuckToActor);
    StickHelper.UnStick(); Attachment.Target = None;
    TugRecallHost();
    // Embedded actors use a grip root; flight/return actors use a balance root.
    if (Phase == 3) SetLocation(Location + (SpinCenter >> Rotation));
    Phase = 4; RecallStarted = WorldInfo.RealTimeSeconds;
    ReturnHits.Length = 0; ApplyPhase(); bForceNetUpdate = true;
    PlayFlightSound();
}

// Config zero/unset selects the provisional defaults; a negative value disables.
function float EffectiveShockRadius()
{
    return SuspendedShockRadius == 0 ? float(PrototypeShockRadius) : FClamp(SuspendedShockRadius, 0, MaximumShockRadius);
}

function float EffectiveRecallTug()
{
    return RecallTugDistance == 0 ? float(MaximumRecallTug) : FClamp(RecallTugDistance, 0, MaximumRecallTug);
}

// One controlled displacement, never an impulse or a constraint following
// the returning axe. Collision movement can shorten/refuse it. Rigid-body
// corpses and knocked-down Zeds are excluded: moving a pawn root cannot safely
// translate all of its articulated physics bodies without stretching joints.
function TugRecallHost()
{
    local vector Toward;
    local float Distance, Travel, Radius, Height, OwnerRadius, OwnerHeight;
    if (RecallHost == None || RecallHost.bDeleteMe || RecallHost.Health <= 0
        || RecallHost.bPlayedDeath || RecallHost.Physics != PHYS_Walking
        || !RecallHost.bCollideWorld || !RecallHost.bCollideActors || Human == None
        || RecallHost.GetTeamNum() == Human.GetTeamNum()) return;
    Toward = SourceWeapon.ReturnEndpoint() - RecallHost.Location;
    Toward.Z = 0;
    Distance = VSize(Toward);
    RecallHost.GetBoundingCylinder(Radius, Height);
    Human.GetBoundingCylinder(OwnerRadius, OwnerHeight);
    Travel = FMin(EffectiveRecallTug(), FMax(0, Distance - Radius - OwnerRadius));
    if (!(Travel > 0)) return;
    RecallHost.Move(Normal(Toward) * Travel);
    RecallHost.bForceNetUpdate = true;
}

// A swept capsule against living monster cylinders deliberately ignores world
// geometry: returning through a wall cannot strand the axe. Authority computes
// all contacts/damage; no client can submit a target or damage amount.
function SweepReturn(vector Start, vector End)
{
    local KFPawn_Monster M;
    local vector Segment, Closest, Offset, At, BoneLocation;
    local float Along, Radius, Height;
    local TraceHitInfo HitInfo;
    Segment = End - Start;
    foreach DynamicActors(class'KFPawn_Monster', M)
    {
        if (M.Health <= 0 || M.bDeleteMe || M.GetTeamNum() == Human.GetTeamNum()
            || ReturnHits.Find(M) != INDEX_NONE) continue;
        Along = FClamp(((M.Location - Start) dot Segment) / FMax(VSizeSq(Segment), 1), 0, 1);
        Closest = Start + Segment * Along;
        M.GetBoundingCylinder(Radius, Height);
        Offset = Closest - M.Location;
        Offset.Z = FMax(0, Abs(Offset.Z) - Height);
        if (VSizeSq(Offset) > (Radius + 7) * (Radius + 7)) continue;
        ReturnHits.AddItem(M);
        At = Closest;
        HitInfo.BoneName = '';
        HitInfo.HitComponent = M.Mesh;
        if (M.Mesh != None) HitInfo.BoneName = M.Mesh.FindClosestBone(At, BoneLocation);
        M.TakeDamage(int(Damage * 0.4), InstigatorController, At,
            (M == RecallHost ? vect(0,0,0) : Normal(Segment) * 18000), class'VRDT_Tomahawk', HitInfo, self);
    }
}

function ReturnStep(float DeltaTime)
{
    local vector Target, ToTarget, Next;
    local float Distance, Travel;
    local rotator CatchFacing;
    CatchFacing = SourceWeapon.ReturnOrientation();
    Target = SourceWeapon.ReturnEndpoint() + (SpinCenter >> CatchFacing);
    ToTarget = Target - Location; Distance = VSize(ToTarget);
    // Distance-scaled catch-up keeps recall useful after teleport/fast movement.
    Travel = FMax(1600, Distance * 2.5) * DeltaTime;
    Next = Location + Normal(ToTarget) * FMin(Travel, Distance);
    SweepReturn(Location, Next);
    SetLocation(Next);
    bCatchAligned = Distance < 160;
    if (bCatchAligned) SetRotation(CatchFacing);
    else if (Distance > 1) SetRotation(rotator(ToTarget));
    bForceNetUpdate = true;
    if (Distance <= Travel + 12 || WorldInfo.RealTimeSeconds - RecallStarted > 4)
    {
        SourceWeapon.AxeReturned(self);
        Destroy();
    }
}

simulated event Destroyed()
{
    // Kill volumes, attachment deletion and cleanup restore the existing slot,
    // never spawn another inventory item or leave a permanent empty weapon.
    if (Role == ROLE_Authority && SourceWeapon != None && !SourceWeapon.bDeleteMe)
        SourceWeapon.AxeReturned(self);
    Super.Destroyed();
}

function Impact(Actor Other, PrimitiveComponent Component, vector At, vector NormalHit)
{
    local TraceHitInfo HitInfo;
    local vector TraceLocation, TraceNormal, Direction, BoneLocation;
    local KFPawn_Monster Monster;
    local int Bone;
    if (Role != ROLE_Authority || Phase != 2 || Other == Human || KFPawn_Human(Other) != None) return;
    Direction = Normal(Velocity);
    // Keep headshot/bone data only when the trace actually hit this actor.
    if (Trace(TraceLocation, TraceNormal, At + Direction * 24, At - Direction * 24,
        true,, HitInfo, TRACEFLAG_Bullet) != Other)
    { HitInfo.BoneName = ''; HitInfo.HitComponent = Component; }
    if (HitInfo.HitComponent == None) HitInfo.HitComponent = Component;
    Monster = KFPawn_Monster(Other);
    Bone = INDEX_NONE;
    if (Monster != None && Monster.Mesh != None)
    {
        if (HitInfo.BoneName == '') HitInfo.BoneName = Monster.Mesh.FindClosestBone(At, BoneLocation);
        Bone = Monster.Mesh.MatchRefBone(HitInfo.BoneName);
        HitInfo.HitComponent = Monster.Mesh;
    }
    // Disable collision before repositioning so a nearby corner cannot refuse
    // the blade-aligned placement. Leave the grip outside the hit surface:
    // the cutting edge's centre sits at model (12.75, 0, 18.75).
    Phase = 3; ApplyPhase();
    SetRotation(rotator(Direction));
    SetLocation(At - (vect(12.75,0,18.75) >> Rotation));
    HawkMesh.SetRotation(rot(0,0,0));
    HawkMesh.SetTranslation(vect(0,0,0));
    // Use KF2's bone/base attachment helper directly: TryStick intentionally
    // refuses a remote instigator on a dedicated server.
    if (Other != None && !Other.bDeleteMe && !Other.bTearOff)
        StickHelper.StickToActor(Other, HitInfo.HitComponent, Bone, true);
    Attachment.Target = StuckToActor; Attachment.Bone = StuckToBoneIdx;
    Attachment.Position = StuckToLocation; Attachment.Rotation = StuckToRotation;
    if (Monster != None && Monster.Health > 0 && Monster.GetTeamNum() != Human.GetTeamNum())
        Monster.TakeDamage(int(Damage), InstigatorController, At, Direction * 18000, class'VRDT_Tomahawk', HitInfo, self);
    if (WorldInfo.NetMode != NM_DedicatedServer)
        `ImpactEffectManager.PlayImpactEffects(At, Instigator, NormalHit, ImpactEffects);
    PlayBurst();
    NextShockTime = WorldInfo.TimeSeconds + ShockInterval; NextFlickTime = NextShockTime;
    bForceNetUpdate = true;
}

// Each tick is a fraction of the outbound hit with the EMP damage type, so
// perk and upgrade scaling follow the throw and the affliction builds until
// the stock EMP lands, then dissipates and builds again after its cooldown.
function Shock()
{
    local KFPawn_Monster M;
    local TraceHitInfo HitInfo;
    M = ShockHost();
    if (M == None) return;
    HitInfo.HitComponent = M.Mesh;
    if (M.Mesh != None && StuckToBoneIdx != INDEX_NONE) HitInfo.BoneName = M.Mesh.GetBoneName(StuckToBoneIdx);
    M.TakeDamage(Max(1, int(Damage * ShockFraction)), InstigatorController, BladeWorld(), vect(0,0,0),
        class'VRDT_TomahawkShock', HitInfo, self);
}

// Suspended electricity reuses the embedded tick's damage fraction, EMP type
// and cadence. No return multiplier, new stun mechanic or through-wall damage.
function ShockArea()
{
    local KFPawn_Monster M;
    local vector At, Center;
    local float Radius;
    local TraceHitInfo HitInfo;
    Radius = EffectiveShockRadius();
    if (!(Radius > 0) || Human == None) return;
    Center = BladeWorld();
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', M, Center, Radius)
    {
        if (M.bDeleteMe || M.Health <= 0 || M.bPlayedDeath || !M.bCanBeDamaged
            || M.GetTeamNum() == Human.GetTeamNum()) continue;
        At = M.Location + vect(0,0,1) * M.BaseEyeHeight * 0.5;
        if (VSizeSq(At - Center) > Radius * Radius || !FastTrace(At, Center)) continue;
        HitInfo.BoneName = ''; HitInfo.HitComponent = M.Mesh;
        M.TakeDamage(Max(1, int(Damage * ShockFraction)), InstigatorController,
            At, vect(0,0,0), class'VRDT_TomahawkShock', HitInfo, self);
    }
}

simulated singular event HitWall(vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    if (Role == ROLE_Authority && Phase == 3)
    { SetPhysics(PHYS_None); Velocity = vect(0,0,0); bForceNetUpdate = true; return; }
    Impact(Wall, WallComp, Location, HitNormal);
}

simulated event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    Impact(Other, OtherComp, HitLocation, HitNormal);
}

simulated function ProcessTouch(Actor Other, vector HitLocation, vector HitNormal)
{
    Impact(Other, None, HitLocation, HitNormal);
}

// Reject KFProjectile's client-driven sticking RPC. All impacts are authoritative.
reliable server function ServerStick(Actor StickTo, int BoneIdx, vector StickLoc, rotator StickRot) {}

simulated event Tick(float DeltaTime)
{
    local rotator Spin;
    Super.Tick(DeltaTime);
    if (Phase == 2 || (Phase == 4 && !bCatchAligned))
    {
        // Local +Z is the haft; negative pitch carries its head toward +X,
        // producing forward end-over-end rotation in the flight direction.
        Spin = HawkMesh.Rotation; Spin.Pitch -= int(131072 * DeltaTime);
        HawkMesh.SetRotation(Spin);
        HawkMesh.SetTranslation(-(SpinCenter >> Spin));
    }
    else if (Phase != 5)
    {
        HawkMesh.SetRotation(rot(0,0,0));
        HawkMesh.SetTranslation(Phase == 4 ? -SpinCenter : vect(0,0,0));
    }
    if (ProjEffects != None) ProjEffects.SetTranslation(HawkMesh.Translation + (BladeLocal >> HawkMesh.Rotation));
    // Everyone sees the host crackle on the shock cadence without an RPC.
    if (WorldInfo.NetMode != NM_DedicatedServer && FlickTemplate != None && (ShockHost() != None || Phase == 5)
        && WorldInfo.TimeSeconds >= NextFlickTime)
    {
        NextFlickTime = WorldInfo.TimeSeconds + ShockInterval;
        WorldInfo.MyEmitterPool.SpawnEmitter(FlickTemplate, BladeWorld(), Rotation, self);
    }
    if (Role != ROLE_Authority) return;
    if (SourceWeapon == None || SourceWeapon.bDeleteMe || !SourceWeapon.ValidOwner()
        || SourceWeapon.ThrownAxe != self || Human != SourceWeapon.Instigator)
    { Destroy(); return; }
    if (Phase == 4) { ReturnStep(DeltaTime); return; }
    // No unattended AOE after switching hands/items, opening a menu or losing
    // input. A short hold lease returns this same axe when updates stop.
    if (Phase == 5 && !SourceWeapon.SuspensionHeld()) { BeginRecall(); return; }
    if ((Phase == 3 || Phase == 5) && WorldInfo.TimeSeconds >= NextShockTime)
    {
        NextShockTime = WorldInfo.TimeSeconds + ShockInterval;
        if (Phase == 5) ShockArea();
        else Shock();
    }
    if (Phase == 3 && Attachment.Target != None && StuckToActor == None)
    {
        Attachment.Target = None; ApplyPhase(); bForceNetUpdate = true;
    }
    // A flight that never hits rests in place but remains bound to its slot.
    // Switching away never recalls it: draw the slot again and request recall.
    if (Phase == 2 && WorldInfo.RealTimeSeconds - FlightStarted > 12)
    {
        Phase = 3; ApplyPhase();
        SetLocation(Location - (SpinCenter >> Rotation));
        bForceNetUpdate = true;
    }
}

defaultproperties
{
    Phase=2
    FlightSound=AkEvent'WW_WEP_MEL_FireAxe.Play_WEP_FireAxe_Spin'
    WhooshSound=AkEvent'WW_WEP_MEL_IonThruster.Play_WEP_IonThruster_Handling_Spin'
    AmbientSoundPlayEvent=AkEvent'WW_WEP_MEL_IonThruster.Play_WEP_IonThruster_Handling_Idle_LP'
    AmbientSoundStopEvent=AkEvent'WW_WEP_MEL_IonThruster.Stop_WEP_IonThruster_Handling_Idle_LP'
    bAutoStartAmbientSound=true
    bImportantAmbientSound=true
    bStopAmbientSoundOnExplode=false
    Begin Object Class=AkComponent Name=HawkHum
        bStopWhenOwnerDestroyed=true
        bForceOcclusionUpdateInterval=true
        OcclusionUpdateInterval=0.25
    End Object
    AmbientComponent=HawkHum
    Components.Add(HawkHum)
    ProjFlightTemplate=ParticleSystem'ZED_Hans_EMIT.FX_Hans_Sparks_LowD_01'
    BurstTemplate=ParticleSystem'WEP_Static_Strikers_EMIT.FX_Static_Strikers_Electric_Swing_01'
    FlickTemplate=ParticleSystem'WEP_Static_Strikers_EMIT.FX_Static_Strikers_Static_Bash_01'
    BladeLocal=(X=12.75,Y=0,Z=18.75)
    ShockInterval=0.25
    ShockFraction=0.035
    SpinCenter=(X=1.5,Y=0,Z=10.5)
    Physics=PHYS_Falling
    LifeSpan=0
    Speed=0
    MaxSpeed=2500
    Damage=100
    DamageRadius=0
    MyDamageType=class'VRDT_Tomahawk'
    ImpactEffects=KFImpactEffectInfo'FX_Impacts_ARCH.Bladed_melee_impact'
    bCanStick=true
    bCanPin=false
    bCanDisintegrate=false
    bBlockedByInstigator=false
    bCollideActors=false
    bCollideWorld=true
    bCollideComplex=true
    bNoEncroachCheck=true
    bNetTemporary=false
    bNoReplicationToInstigator=false
    bUseClientSideHitDetection=false
    bUpdateSimulatedPosition=true
    bRotationFollowsVelocity=false
    NetUpdateFrequency=20
    Begin Object Class=KFProjectileStickHelper Name=HawkStickHelper
    End Object
    StickHelper=HawkStickHelper
    Begin Object Class=StaticMeshComponent Name=HawkVisual
        CollideActors=false
        BlockActors=false
        BlockRigidBody=false
        CastShadow=true
    End Object
    HawkMesh=HawkVisual
    Components.Add(HawkVisual)
}
