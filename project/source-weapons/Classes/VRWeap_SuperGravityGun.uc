// Powered Citadel form: hostile living targets are electrocuted into physical
// ragdolls on capture, as in HL2, then become held/launchable objects.
class VRWeap_SuperGravityGun extends VRSourceWeapon;

var RB_Handle GrabHandle;
var Actor HeldActor;
var PrimitiveComponent HeldComponent;
var name HeldBone;
var float HeldLifeSpan, HoldDistance, NextSecondaryTime;
var PrimitiveComponent.RBCollisionChannelContainer HeldChannels;
var vector GrabOffset;
var quat HeldOrientation;
var VRGravityEffects Effects;
var Actor Candidate;
var float NextTargetScan;
var bool bClawsOpen, bDroppedUntilRelease;
var bool bHeldFromCorpsePool;

simulated function UpdateTrackedPresentation(VRHandsBridge B)
{
    Super.UpdateTrackedPresentation(B);
    if (SourcePresenter == B && bTrackedPose && Effects != None) Effects.UpdateVisuals();
}

simulated function bool IsManipulable(Actor A, PrimitiveComponent C)
{
    if (A == None || A.bDeleteMe || A == Instigator || A.bWorldGeometry || C == None) return false;
    if (KFPawn_Human(A) != None || Vehicle(A) != None) return false;
    if (KFPawn_Monster(A) != None) return KFPawn_Monster(A).Mesh != None;
    return KActor(A) != None && A.Physics == PHYS_RigidBody && C.GetRootBodyInstance() != None;
}

simulated function Actor FindTarget(out vector HitLocation, out TraceHitInfo Info, optional float Range=2159)
{
    local vector HitNormal, Start, Direction;
    local Actor A;
    Start = SourceOrigin();
    Direction = SourceDirection();
    A = Trace(HitLocation, HitNormal, Start + Direction * Range, Start, true, vect(0,0,0), Info, TRACEFLAG_Bullet);
    if (IsManipulable(A, Info.HitComponent)) return A;
    // A modest hull offers the original aim tolerance but never crosses the
    // first blocking wall or actor to select something behind it.
    if (A != None) return None;
    A = Trace(HitLocation, HitNormal, Start + Direction * Range, Start, true, vect(8,8,8), Info, TRACEFLAG_Bullet);
    return IsManipulable(A, Info.HitComponent) ? A : None;
}

simulated function bool MakePhysical(Actor A, out PrimitiveComponent C, out name Bone, out vector Point)
{
    local KFPawn_Monster Zed;
    Zed = KFPawn_Monster(A);
    if (Zed != None)
    {
        if (Zed.Health > 0)
        {
            // Use the game's death/reward/wave bookkeeping. Do not replace a
            // living pawn with an unrelated prop or silently remove the AI.
            Zed.TakeDamage(Max(1000000, Zed.Health * 1000), Instigator.Controller,
                Point, vect(0,0,0), class'VRDT_SuperGravityGun',, self);
            if (Zed.Health > 0 || Zed.bDeleteMe) return false;
        }
        C = Zed.Mesh;
        if (Zed.Physics != PHYS_RigidBody) Zed.PlayRagdollDeath(class'VRDT_SuperGravityGun', Point);
        if (Zed.Physics != PHYS_RigidBody) return false;
        Zed.Mesh.bNoSkeletonUpdate = false;
        Zed.SetRagdollWarningLevel(0);
        // KF2's torso body is a stable handle even when the killing hit was
        // in an unphysical finger, attachment, or a dismembered extremity.
        Bone = Zed.Mesh.MatchRefBone('Spine1') >= 0 ? 'Spine1' : Zed.Mesh.GetBoneName(0);
        Point = Zed.Mesh.GetBoneLocation(Bone);
    }
    else Bone = '';
    if (C == None) return false;
    C.WakeRigidBody(Bone);
    return true;
}

simulated function TryGrab()
{
    local Actor A;
    local TraceHitInfo Info;
    local vector Point;
    local name Bone;
    local PrimitiveComponent C;
    local KFGoreManager Gore;
    A = FindTarget(Point, Info, 8636);
    if (A == None) return;
    C = Info.HitComponent;
    Bone = Info.BoneName;
    if (!MakePhysical(A, C, Bone, Point)) return;
    HeldChannels = C.RBCollideWithChannels;
    GrabHandle.GrabComponent(C, Bone, Point, KFPawn_Monster(A) == None);
    if (GrabHandle.GrabbedComponent != C) return;
    HeldActor = A;
    HeldComponent = C;
    HeldBone = Bone;
    HeldLifeSpan = A.LifeSpan;
    A.LifeSpan = 0;
    Gore = KFGoreManager(WorldInfo.MyGoreEffectManager);
    bHeldFromCorpsePool = KFPawn(A) != None && Gore != None && Gore.CorpsePool.Find(KFPawn(A)) >= 0;
    if (bHeldFromCorpsePool) Gore.CorpsePool.RemoveItem(KFPawn(A));
    C.SetRBCollidesWithChannel(RBCC_Pawn, false);
    GrabOffset = Point - C.GetPosition();
    HoldDistance = FClamp(110 + VSize(C.Bounds.BoxExtent) * 0.6, 130, 250);
    HeldOrientation = QuatProduct(QuatInvert(QuatFromRotator(TrackedAim)), GrabHandle.GetOrientation());
    PlaySourceSound('GravityPickup');
    StartSourceLoop('GravityHold');
    NextSecondaryTime = WorldInfo.TimeSeconds + 0.4;
    `log("KF2VR_GRAVITY action=grab target=" $ A.Class @ "bone=" $ Bone);
}

simulated function ReleaseHeld(optional bool bLaunch=false)
{
    local Actor A;
    local PrimitiveComponent C;
    local VRGravityFlight Flight;
    local KFGoreManager Gore;
    if (HeldActor == None && GrabHandle.GrabbedComponent == None) return;
    A = HeldActor;
    C = HeldComponent;
    GrabHandle.ReleaseComponent();
    HeldActor = None;
    HeldComponent = None;
    StopSourceLoop();
    if (C != None) C.SetRBCollisionChannels(HeldChannels);
    if (A != None && !A.bDeleteMe)
    {
        A.LifeSpan = HeldLifeSpan;
        if (bLaunch && C != None)
        {
            C.SetRBLinearVelocity(SourceDirection() * 3810);
            C.WakeRigidBody(HeldBone);
            Flight = Spawn(class'VRGravityFlight', self,, C.GetPosition());
            if (Flight != None) Flight.Initialize(A, C, Instigator);
        }
    }
    Gore = KFGoreManager(WorldInfo.MyGoreEffectManager);
    if (bHeldFromCorpsePool && KFPawn(A) != None && !A.bDeleteMe && Gore != None
        && Gore.CorpsePool.Find(KFPawn(A)) < 0) Gore.AddCorpse(KFPawn(A));
    bHeldFromCorpsePool = false;
    HeldBone = '';
}

simulated function StartFire(byte FireModeNum)
{
    local Actor A;
    local PrimitiveComponent C;
    local TraceHitInfo Info;
    local vector Point;
    local name Bone;
    if (!CanUseSourceWeapon()) return;
    if (FireModeNum == 0)
    {
        if (bPrimaryHeld) return;
        bPrimaryHeld = true;
        if (WorldInfo.TimeSeconds < NextPrimaryTime) return;
        NextPrimaryTime = WorldInfo.TimeSeconds + 0.5;
        if (HeldActor != None)
        {
            Point = HeldComponent.GetPosition();
            ReleaseHeld(true);
        }
        else
        {
            A = FindTarget(Point, Info);
            C = Info.HitComponent;
            Bone = Info.BoneName;
            if (A == None || !MakePhysical(A, C, Bone, Point)) { PlaySourceSound('GravityDry'); return; }
            HeldActor = A; HeldComponent = C; HeldBone = Bone;
            HeldLifeSpan = A.LifeSpan; HeldChannels = C.RBCollideWithChannels;
            ReleaseHeld(true);
        }
        PlaySourceSound('GravityLaunch');
        if (Effects != None) Effects.Launch(Point);
    }
    else if (FireModeNum == 1)
    {
        if (bSecondaryHeld) return;
        bSecondaryHeld = true;
        if (WorldInfo.TimeSeconds < NextSecondaryTime) return;
        if (HeldActor != None) { ReleaseHeld(); bDroppedUntilRelease = true; PlaySourceSound('GravityDrop'); NextSecondaryTime = WorldInfo.TimeSeconds + 0.4; }
        else TryGrab();
    }
}

simulated function StopFire(byte FireModeNum)
{
    if (FireModeNum == 0) bPrimaryHeld = false;
    if (FireModeNum == 1) { bSecondaryHeld = false; bDroppedUntilRelease = false; }
}

simulated function CancelSourceInput()
{
    Super.CancelSourceInput();
    bDroppedUntilRelease = false;
    ReleaseHeld();
    if (Effects != None) Effects.SetActive(false);
}

simulated event Tick(float DeltaTime)
{
    local vector Hit, HitNormal, Destination, Start, Current, Step, Extent;
    local quat GoalOrientation;
    local TraceHitInfo Info;
    local Actor Blocker;
    Super.Tick(DeltaTime);
    if (!CanUseSourceWeapon()) return;
    if (Effects == None) Effects = Spawn(class'VRGravityEffects', self);
    if (Effects != None) { Effects.Gun = self; Effects.SetActive(true); }
    if (HeldActor != None)
    {
        if (HeldActor.bDeleteMe || HeldComponent == None || GrabHandle.GrabbedComponent != HeldComponent)
        { ReleaseHeld(); return; }
        Start = SourceOrigin();
        Destination = Start + SourceDirection() * HoldDistance;
        Extent = HeldComponent.Bounds.BoxExtent;
        Extent.X = FClamp(Extent.X, 5, 80); Extent.Y = FClamp(Extent.Y, 5, 80); Extent.Z = FClamp(Extent.Z, 5, 80);
        Blocker = Trace(Hit, HitNormal, Destination, Start, false, Extent);
        if (Blocker != None) Destination = Hit + HitNormal * 5;
        if (VSize(Destination - Start) < 55 || VSize(HeldComponent.GetPosition() - Start) > 9000)
        { ReleaseHeld(); return; }
        Current = GrabHandle.Location;
        Step = Destination - Current;
        Destination = Current + Normal(Step) * FMin(VSize(Step), 3810 * DeltaTime);
        Blocker = Trace(Hit, HitNormal, Destination, Current, false, Extent);
        if (Blocker != None) Destination = Hit + HitNormal * 5;
        GrabHandle.SetSmoothLocation(Destination, FMax(DeltaTime, 0.015));
        if (KFPawn_Monster(HeldActor) == None)
        {
            GoalOrientation = QuatProduct(QuatFromRotator(TrackedAim), HeldOrientation);
            GrabHandle.SetOrientation(GoalOrientation);
        }
        HeldComponent.WakeRigidBody(HeldBone);
    }
    else if (WorldInfo.TimeSeconds >= NextTargetScan)
    {
        NextTargetScan = WorldInfo.TimeSeconds + 0.05;
        Candidate = FindTarget(Hit, Info);
        if (bSecondaryHeld && !bDroppedUntilRelease && WorldInfo.TimeSeconds >= NextSecondaryTime) TryGrab();
    }
    bClawsOpen = HeldActor != None || Candidate != None;
}

simulated event Destroyed()
{
    if (Effects != None) Effects.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    FirstPersonMeshName="KF2VRSource.SuperGravityGun"
    PickupMeshName=""
    MagazineCapacity(0)=1
    InitialSpareMags(0)=0
    AmmoCost(0)=0
    AmmoCost(1)=0
    GroupPriority=200
    Begin Object Class=RB_Handle Name=GravityHandle
        LinearDamping=600
        LinearStiffness=12000
        AngularDamping=500
        AngularStiffness=2500
    End Object
    GrabHandle=GravityHandle
    Components.Add(GravityHandle)
}
