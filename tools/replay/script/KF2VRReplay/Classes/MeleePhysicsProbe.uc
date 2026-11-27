// Experiment (#227, docs/re/MELEE_PHYSICS_PATH.md): can a physics body follow
// a tracked melee weapon and report contacts with living Zeds?
//
// Summoned by a replay (`console summon KF2VRReplay.MeleePhysicsProbe`). It
// spawns a MeleePhysicsProxy shaped like the held melee weapon's stock pickup
// mesh, drives it to the weapon's RW_Weapon bone by velocity every tick,
// and switches kinematic bone updates on for Zeds within reach (stock leaves
// them off for small Zeds). It measures, and logs once a second:
//   lag       how far the body trails the pose it was asked for (UU)
//   contacts  rigid-body contacts the engine reported with Zeds
//   enabled   Zeds whose bodies it switched on
// Read-only for gameplay: no damage, no change to the VR melee path.
class MeleePhysicsProbe extends Actor;

var float MaxStep;
var MeleePhysicsProxy Proxy;
var KFWeapon Weapon;
var PlayerController PC;
// The pickup mesh's box in its own frame, and the turn that lays its longest
// side along the weapon's long axis (RW_Weapon +Z).
var vector BoxCentre, BoxExtent;
var quat AlignQ;
// Where the middle of the weapon sits along RW_Weapon +Z (the Katana's mesh
// spans -25 to 90).
var float WeaponCentreZ;
var float EnableRadius;
var vector LastTarget;
var bool bHaveTarget;
var float LagSum, LagMax, SpeedMax, ReportAt, TurnLagMax;
var quat LastBodyQ;
var int LagSamples, ZedContacts, OtherContacts, Enabled;
var array<KFPawn_Monster> EnabledZeds;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    PC = GetALocalPlayerController();
    `log("KF2VR_PHYSPROBE kind=start pc=" $ PC);
}

function KFWeapon FindMelee()
{
    local KFWeapon W;
    if (PC == None || PC.Pawn == None) return None;
    W = KFWeapon(PC.Pawn.Weapon);
    if (KFWeap_MeleeBase(W) != None && W.MySkelMesh != None) return W;
    if (PC.Pawn.InvManager != None)
        foreach PC.Pawn.InvManager.InventoryActors(class'KFWeapon', W)
            if (KFWeap_MeleeBase(W) != None && W.MySkelMesh != None) return W;
    return None;
}

function bool BuildProxy()
{
    local StaticMesh Shape;
    local rotator Turn;
    Weapon = FindMelee();
    if (Weapon == None) return false;
    Shape = StaticMesh(DynamicLoadObject(Weapon.PickupMeshName, class'StaticMesh', true));
    if (Shape == None)
    {
        `log("KF2VR_PHYSPROBE kind=refused reason=no-pickup-mesh name=" $ Weapon.PickupMeshName);
        return false;
    }
    Proxy = Spawn(class'MeleePhysicsProxy',,, Weapon.MySkelMesh.GetBoneLocation('RW_Weapon'), rot(0,0,0));
    if (Proxy == None) { `log("KF2VR_PHYSPROBE kind=refused reason=spawn"); return false; }
    Proxy.Probe = self;
    // The body is made when rigid-body physics starts, so give it the mesh first.
    Proxy.SetPhysics(PHYS_None);
    Proxy.StaticMeshComponent.SetStaticMesh(Shape);
    // Channels and the notify flag go on before the body exists: they are
    // baked into its filter data when it is made.
    // Zeds only: no world, no props, so every report is a Zed contact.
    Proxy.StaticMeshComponent.SetRBCollidesWithChannel(RBCC_Default, false);
    Proxy.StaticMeshComponent.SetRBCollidesWithChannel(RBCC_BlockingVolume, false);
    Proxy.StaticMeshComponent.SetRBCollidesWithChannel(RBCC_GameplayPhysics, false);
    Proxy.StaticMeshComponent.SetRBCollidesWithChannel(RBCC_EffectPhysics, false);
    Proxy.StaticMeshComponent.SetRBCollidesWithChannel(RBCC_Pawn, true);
    Proxy.StaticMeshComponent.SetNotifyRigidBodyCollision(true);
    Proxy.StaticMeshComponent.ScriptRigidBodyCollisionThreshold = 1;
    Proxy.Initialize();
    Proxy.SetCollision(true, false);
    if (Proxy.StaticMeshComponent.BodyInstance != None)
        Proxy.StaticMeshComponent.BodyInstance.CustomGravityFactor = 0;
    Proxy.StaticMeshComponent.WakeRigidBody();
    // Unrotated, so the world bounds are the mesh's own box.
    BoxCentre = Proxy.StaticMeshComponent.Bounds.Origin - Proxy.Location;
    BoxExtent = Proxy.StaticMeshComponent.Bounds.BoxExtent;
    if (BoxExtent.X >= BoxExtent.Y && BoxExtent.X >= BoxExtent.Z) Turn = rot(16384,0,0);
    else if (BoxExtent.Y >= BoxExtent.Z) Turn = rot(0,0,16384);
    else Turn = rot(0,0,0);
    AlignQ = QuatFromRotator(Turn);
    `log("KF2VR_PHYSPROBE kind=proxy weapon=" $ Weapon.Class.Name @ "mesh=" $ Weapon.PickupMeshName
        @ "box_centre=" $ BoxCentre @ "box_extent=" $ BoxExtent @ "turn=" $ Turn
        @ "body=" $ (Proxy.StaticMeshComponent.BodyInstance != None)
        @ "notify=" $ Proxy.StaticMeshComponent.bNotifyRigidBodyCollision @ "block=" $ Proxy.StaticMeshComponent.BlockRigidBody
        @ "channel=" $ Proxy.StaticMeshComponent.RBChannel @ "pawn=" $ Proxy.StaticMeshComponent.RBCollideWithChannels.Pawn);
    return true;
}

// The rotation vector (axis times radians) that turns From onto To.
function vector TurnTo(quat From, quat To)
{
    local quat D;
    local vector Axis;
    local float Angle;
    D = QuatProduct(To, QuatInvert(From));
    if (D.W < 0) { D.X = -D.X; D.Y = -D.Y; D.Z = -D.Z; D.W = -D.W; }
    Axis.X = D.X; Axis.Y = D.Y; Axis.Z = D.Z;
    if (VSize(Axis) < 0.0001) return vect(0,0,0);
    Angle = 2.0 * Acos(FClamp(D.W, -1.0, 1.0));
    return Normal(Axis) * Angle;
}

function float CurrentLag()
{
    if (Proxy == None || !bHaveTarget) return -1;
    return VSize(Proxy.Location - LastTarget);
}

function NoteContact(PrimitiveComponent Other)
{
    if (Other != None && KFPawn_Monster(Other.Owner) != None) ++ZedContacts;
    else ++OtherContacts;
}

// Stock leaves a small Zed's bodies where they were made (KFPawn "perf"); this
// is what it does itself for the large Zeds and for FleX collision.
function EnableZeds(vector Around)
{
    local KFPawn_Monster Z;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Z, Around, EnableRadius)
    {
        if (Z.Mesh == None || Z.Health <= 0 || Z.bPlayedDeath || EnabledZeds.Find(Z) != INDEX_NONE) continue;
        EnabledZeds.AddItem(Z);
        `log("KF2VR_PHYSPROBE kind=enable zed=" $ Z.Class.Name @ "was_kinematic=" $ Z.Mesh.bUpdateKinematicBonesFromAnimation
            @ "channel=" $ Z.Mesh.RBChannel @ "instance=" $ (Z.Mesh.PhysicsAssetInstance != None));
        Z.Mesh.bUpdateKinematicBonesFromAnimation = true;
        Z.Mesh.MinDistFactorForKinematicUpdate = 0.0;
        Z.Mesh.SetRBChannel(RBCC_Pawn);
        Z.Mesh.SetBlockRigidBody(true);
        ++Enabled;
    }
}

simulated event Tick(float Delta)
{
    local vector BoneAt, Target;
    local quat BoneQ, BodyQ;
    local float Lag;
    Super.Tick(Delta);
    if (Proxy == None && !BuildProxy()) return;
    if (Weapon == None || Weapon.bDeleteMe || Weapon.MySkelMesh == None) return;
    // The body after last frame's physics step against the pose asked then.
    if (bHaveTarget)
    {
        Lag = VSize(Proxy.Location - LastTarget);
        LagSum += Lag; ++LagSamples; LagMax = FMax(LagMax, Lag);
        TurnLagMax = FMax(TurnLagMax, VSize(TurnTo(QuatFromRotator(Proxy.Rotation), LastBodyQ)) * 180.0 / Pi);
    }
    BoneAt = Weapon.MySkelMesh.GetBoneLocation('RW_Weapon');
    BoneQ = Weapon.MySkelMesh.GetBoneQuaternion('RW_Weapon');
    BodyQ = QuatProduct(BoneQ, AlignQ);
    // The box's middle on the weapon's middle.
    Target = BoneAt + QuatRotateVector(BoneQ, vect(0,0,1) * WeaponCentreZ) - QuatRotateVector(BodyQ, BoxCentre);
    if (bHaveTarget && Delta > 0) SpeedMax = FMax(SpeedMax, VSize(Target - LastTarget) / Delta);
    // Driven by velocity, the usual way to make a physics body follow a
    // tracked hand: this step's velocity is the whole error over the step,
    // so the body arrives unless something stops it. (An RB_Handle spring
    // stiff enough to keep up threw the body thousands of UU away.)
    Proxy.StaticMeshComponent.WakeRigidBody();
    if (Delta > 0)
    {
        Proxy.StaticMeshComponent.SetRBLinearVelocity(ClampLength(Target - Proxy.Location, MaxStep) / Delta);
        Proxy.StaticMeshComponent.SetRBAngularVelocity(TurnTo(QuatFromRotator(Proxy.Rotation), BodyQ) / Delta);
    }
    LastTarget = Target; LastBodyQ = BodyQ; bHaveTarget = true;
    EnableZeds(BoneAt);
    if (WorldInfo.TimeSeconds >= ReportAt)
    {
        ReportAt = WorldInfo.TimeSeconds + 1.0;
        `log("KF2VR_PHYSPROBE kind=track lag_avg=" $ (LagSamples > 0 ? LagSum / LagSamples : 0.0) @ "lag_max=" $ LagMax @ "turn_lag_max_deg=" $ TurnLagMax
            @ "hand_speed_max=" $ int(SpeedMax) @ "zed_contacts=" $ ZedContacts @ "other_contacts=" $ OtherContacts
            @ "enabled=" $ Enabled @ "delta_ms=" $ Delta * 1000);
        LagSum = 0; LagSamples = 0; LagMax = 0; SpeedMax = 0; TurnLagMax = 0;
    }
}

simulated event Destroyed()
{
    if (Proxy != None) Proxy.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    MaxStep=60
    TickGroup=TG_PreAsyncWork
    WeaponCentreZ=32
    EnableRadius=260
    RemoteRole=ROLE_None
    bHidden=true
}
