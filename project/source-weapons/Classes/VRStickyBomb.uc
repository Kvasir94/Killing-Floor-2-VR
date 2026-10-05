// Explicit swept simulation retains TF2's toss/gravity independently of KF2
// grenade perks. Living pawns bounce it; solid world surfaces attach it.
class VRStickyBomb extends Actor;

var VRWeap_StickybombLauncher Launcher;
var StaticMeshComponent BombMesh;
var ParticleSystemComponent Trail, ArmPulse;
var float BornAt, Charge, Speed, MaxSpeed, NextStickTime;
var bool bStuck, bDetonated, bArmedEffect;
var vector SurfaceNormal;
// PHYS_None is deliberate: this actor owns the swept flight integration.
// Keep its simulation state separate from the engine's movement velocity.
var vector FlightVelocity, LaunchOrigin;
var bool bReportedFlight, bReportedMoveFailure;
var rotator Spin;

simulated function InitializeFlight(VRWeap_StickybombLauncher Gun, vector InitialVelocity, float LaunchCharge)
{
    Launcher = Gun;
    Instigator = Gun.Instigator;
    LaunchOrigin = Location;
    FlightVelocity = InitialVelocity;
    Velocity = FlightVelocity;
    Speed = VSize(FlightVelocity);
    MaxSpeed = 9000;
    Charge = LaunchCharge;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    BornAt = WorldInfo.TimeSeconds;
    BombMesh.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VRSource.Stickybomb", class'StaticMesh', true)));
    BombMesh.SetMaterial(0, MaterialInterface(DynamicLoadObject("KF2VRSource.StickybombMaterial", class'MaterialInterface', true)));
    Trail = class'VRSourceEffects'.static.Attach(self, 'StickyTrail', BombMesh);
    Spin.Roll = 109227; Spin.Pitch = int((FRand() * 2 - 1) * 218453); Spin.Yaw = 0;
}

simulated event Tick(float DeltaTime)
{
    local vector Hit, HitNormal, Step, End;
    local TraceHitInfo Info;
    local Actor A;
    local float Dt, Remaining;
    local int Steps;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority || Launcher == None || Launcher.bDeleteMe
        || Instigator == None || Instigator.Health <= 0) { Destroy(); return; }
    if (!bArmedEffect && WorldInfo.TimeSeconds - BornAt >= 0.8)
    {
        bArmedEffect = true;
        ArmPulse = class'VRSourceEffects'.static.Attach(self, 'StickyArm', BombMesh);
    }
    if (bStuck || bDetonated) return;
    Remaining = DeltaTime;
    while (Remaining > 0 && Steps++ < 32)
    {
        Dt = FMin(Remaining, FMax(0.008, DeltaTime / 32));
        Remaining -= Dt;
        // Stock Source projectile gravity is 800 in/s^2 times its 0.4 scale.
        FlightVelocity.Z -= 812.8 * Dt;
        if (VSizeSq(FlightVelocity) > Square(MaxSpeed)) FlightVelocity = Normal(FlightVelocity) * MaxSpeed;
        Step = FlightVelocity * Dt;
        End = Location + Step;
        A = TraceFlight(Hit, HitNormal, Info, End);
        if (A != None)
        {
            if (Pawn(A) == None && !A.IsA('Projectile') && !A.IsA('VRStickyBomb') && WorldInfo.TimeSeconds >= NextStickTime)
            {
                bStuck = true;
                SurfaceNormal = HitNormal;
                SetLocation(Hit + HitNormal * 3.5);
                if (!A.bStatic) SetBase(A);
                FlightVelocity = vect(0,0,0);
                `log("KF2VR_STICKY action=stick surface=" $ A.Class.Name @ "travel=" $ VSize(Location-LaunchOrigin)
                    @ "age=" $ (WorldInfo.TimeSeconds-BornAt));
                if (Trail != None) Trail.DeactivateSystem();
                break;
            }
            FlightVelocity = (FlightVelocity - 2 * (FlightVelocity dot HitNormal) * HitNormal) * (Pawn(A) != None ? 0.135 : 0.45);
            SetLocation(Hit + HitNormal * 4);
        }
        else if (!SetLocation(End) && !bReportedMoveFailure)
        {
            bReportedMoveFailure = true;
            `log("KF2VR_STICKY action=move-failed location=" $ Location @ "end=" $ End);
        }
    }
    Velocity = FlightVelocity; // Particle velocity inheritance only; not simulation state.
    if (!bReportedFlight && WorldInfo.TimeSeconds-BornAt >= 0.15)
    {
        bReportedFlight = true;
        `log("KF2VR_STICKY action=flight travel=" $ VSize(Location-LaunchOrigin) @ "speed=" $ VSize(FlightVelocity));
    }
    if (!bStuck) SetRotation(Rotation + Spin * DeltaTime);
}

simulated function Actor TraceFlight(out vector Hit, out vector HitNormal, out TraceHitInfo Info, vector End)
{
    local Actor A, Nearest;
    local vector Point, N;
    local float Distance, Best;
    local TraceHitInfo CandidateInfo;
    Nearest = Trace(Hit, HitNormal, End, Location, false, vect(5.08,5.08,5.08), Info);
    Best = Nearest == None ? VSizeSq(End-Location) + 1 : VSizeSq(Hit-Location);
    foreach TraceActors(class'Actor', A, Point, N, End, Location, vect(5.08,5.08,5.08), CandidateInfo)
    {
        // TraceActors includes touch-only actors. Triggers, the other held
        // weapon, pickup volumes and presentation helpers are not surfaces.
        if (A == self || A == Instigator || A == Launcher || Inventory(A) != None
            || A.IsA('VRHUDPanel') || A.IsA('VRSpatialHUD') || A.IsA('VRHandSelector')) continue;
        if (!A.bWorldGeometry && !A.bBlockActors && Pawn(A) == None
            && !A.IsA('Projectile') && !A.IsA('VRStickyBomb')) continue;
        Distance = VSizeSq(Point-Location);
        if (Distance < Best) { Best=Distance; Nearest=A; Hit=Point; HitNormal=N; Info=CandidateInfo; }
    }
    return Nearest;
}

simulated function Detonate(optional bool bForced=false)
{
    local Pawn Victim;
    local KActor Prop;
    local vector Direction, Hit, HitNormal, Center, Impulse;
    local float Distance, Fraction, Amount, Radius, Force;
    local SoundCue Cue;
    if (bDetonated || bDeleteMe || WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority
        || Instigator == None || (!bForced && WorldInfo.TimeSeconds - BornAt < 0.8)) return;
    bDetonated = true;
    Center = Location + (bStuck ? SurfaceNormal * 6 : vect(0,0,0));
    Radius = 370.84;
    // TF2 grows an airborne sticky's radius from 85% to full over two seconds.
    if (!bStuck) Radius *= Lerp(0.85, 1.0, FClamp((WorldInfo.TimeSeconds - BornAt - 0.8) / 2.0, 0, 1));
    foreach WorldInfo.AllPawns(class'Pawn', Victim)
    {
        if (Victim.Health <= 0 || (KFPawn_Monster(Victim) == None && Victim != Instigator)) continue;
        Distance = FMin(VSize(Victim.Location - Center), VSize(Victim.Location - vect(0,0,1) * Victim.CylinderComponent.CollisionHeight - Center));
        if (Distance > Radius || Trace(Hit, HitNormal, Victim.Location, Center, false) != None) continue;
        Fraction = 1 - 0.5 * FClamp(Distance / Radius, 0, 1);
        Amount = 120 * Fraction;
        Direction = Normal(Victim.Location - Center);
        if (Victim == Instigator)
        {
            // Self blast remains real locomotion, including sticky jumps.
            // No camera kick/shake is attached to the explosion.
            Amount *= 0.75;
        }
        // Valve DamageForce: scale 9 for sticky self-jumps, 6 for others,
        // capped at 1000 Source in/s. Use TF2's standing/duck hull ratio so
        // the KF2 character mesh does not change the requested blast force.
        Force = Amount * (Victim == Instigator ? 9 : 6);
        if (Victim == Instigator && Victim.bIsCrouched) Force *= 82.0 / 55.0;
        Impulse = Direction * FMin(Force, 1000) * 2.54;
        Victim.TakeDamage(int(Amount), Instigator.Controller, Center, vect(0,0,0), class'VRDT_Stickybomb',, self);
        if (Victim.Health > 0)
        {
            Victim.Velocity += Impulse;
            if (Victim.Physics == PHYS_Walking && Impulse.Z > 0) Victim.SetPhysics(PHYS_Falling);
        }
        else if (Victim.Mesh != None) Victim.Mesh.SetRBLinearVelocity(Impulse, true);
    }
    foreach CollidingActors(class'KActor', Prop, Radius, Center)
    {
        if (Prop.StaticMeshComponent != None && FastTrace(Prop.Location, Center))
        {
            Distance = VSize(Prop.Location - Center);
            Amount = 120 * (1 - 0.5 * FClamp(Distance / Radius, 0, 1));
            // Source explosive impulse uses the equivalent of a 75 kg body
            // accelerated by four in/s per damage point; PhysX applies mass.
            Impulse = Normal(Prop.Location - Center) * FMin(Amount * 75 * 4, 75 * 400) * (0.85 + FRand() * 0.3) * 2.54;
            Prop.TakeDamage(int(Amount), Instigator.Controller, Center, vect(0,0,0), class'VRDT_Stickybomb',, self);
            Prop.StaticMeshComponent.AddImpulse(Impulse, Center,, false);
        }
    }
    class'VRSourceEffects'.static.Emit(self, bStuck ? 'StickyExplosionWall' : 'StickyExplosionAir', Center, rotator(SurfaceNormal));
    Cue = SoundCue(DynamicLoadObject("KF2VRSource.StickyExplosion", class'SoundCue', true));
    if (Cue != None) PlaySound(Cue, true, false, false, Center);
    Destroy();
}

event TakeDamage(int Damage, Controller EventInstigator, vector HitLocation, vector Momentum,
    class<DamageType> DamageType, optional TraceHitInfo HitInfo, optional Actor DamageCauser)
{
    local vector BlastImpulse;
    if (WorldInfo.NetMode != NM_Standalone || bDetonated || !bStuck || Damage <= 0
        || EventInstigator == None || EventInstigator.Pawn == Instigator) return;
    if (ClassIsChildOf(DamageType, class'KFDT_Explosive'))
    {
        BlastImpulse = Momentum * 0.15;
        // Original sticky .phy has a 5 kg body; Source's detach threshold is
        // an impulse of 1500 kg*in/s, not a per-frame velocity multiplier.
        if (VSize(BlastImpulse) <= 1500 * 2.54) return;
        bStuck = false;
        SetBase(None);
        FlightVelocity += BlastImpulse / 5;
        Velocity = FlightVelocity;
        NextStickTime = WorldInfo.TimeSeconds + 1.0;
        SurfaceNormal = vect(0,0,0);
        if (Trail != None) Trail.ActivateSystem();
    }
    else Destroy();
}

simulated event Destroyed()
{
    if (Trail != None) { Trail.DeactivateSystem(); DetachComponent(Trail); Trail = None; }
    if (ArmPulse != None) { ArmPulse.DeactivateSystem(); DetachComponent(ArmPulse); ArmPulse = None; }
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=true
    bBlockActors=false
    bProjTarget=true
    LifeSpan=0
    Begin Object Class=StaticMeshComponent Name=StickyMesh
        DepthPriorityGroup=SDPG_World
        CastShadow=true
        CollideActors=true
        BlockActors=false
        BlockZeroExtent=true
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    BombMesh=StickyMesh
    CollisionComponent=StickyMesh
    Components.Add(StickyMesh)
}
