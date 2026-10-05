// Collision-preserving local prop pickup. No pawn pickup or launch attack.
class VRPortalCarry extends Actor;

var VRWeap_PortalGun Gun;
var KFPlayerController PC;
var VRPortalUseInteraction UseInput;
var RB_Handle CarryHandle;
var KActor HeldActor;
var PrimitiveComponent HeldComponent;
var float HoldDistance, PickupRange, MaximumMass, MaximumRadius, MoveSpeed;
var vector LastPawnLocation;
var bool bHeldWithTracking;

simulated function bool Initialize(VRWeap_PortalGun OwnerGun)
{
    if (OwnerGun == None || OwnerGun.Instigator == None
        || WorldInfo.NetMode != NM_Standalone) return false;
    Gun = OwnerGun;
    Instigator = Gun.Instigator;
    PC = KFPlayerController(Instigator.Controller);
    if (PC == None || !PC.IsLocalPlayerController()) return false;
    UseInput = new(PC) class'VRPortalUseInteraction';
    if (UseInput == None) return false;
    UseInput.Carry = self;
    PC.Interactions.InsertItem(0, UseInput);
    LastPawnLocation = Instigator.Location;
    return true;
}

simulated function bool CanUse()
{
    return Gun != None && !Gun.bDeleteMe && PC != None && PC.Pawn == Instigator
        && Gun.CanUseSourceWeapon() && !PC.IsPaused()
        && (PC.MyGFxManager == None || !PC.MyGFxManager.bMenusOpen);
}

simulated function bool Eligible(Actor A, PrimitiveComponent C)
{
    local RB_BodyInstance Body;
    if (KActor(A) == None || A.bDeleteMe || A.bStatic || A.bWorldGeometry
        || A.Physics != PHYS_RigidBody || C == None || C != A.CollisionComponent
        || !C.CollideActors || !C.BlockActors) return false;
    if (VSize(C.Bounds.BoxExtent) > MaximumRadius) return false;
    Body = C.GetRootBodyInstance();
    return Body != None && Body.GetBodyMass() > 0 && Body.GetBodyMass() <= MaximumMass;
}

// Multi-hit query avoids the held body or player hiding an obstruction.
simulated function bool PathClear(vector Start, vector End, vector Extent,
    optional bool bAllowLeavingContact)
{
    local Actor A;
    local vector Hit, N;
    local TraceHitInfo Info;
    foreach TraceActors(class'Actor', A, Hit, N, End, Start, Extent, Info)
    {
        if (A == HeldActor || A == Instigator || A == Gun || A == self) continue;
        if (Info.HitComponent != None && !Info.HitComponent.BlockActors && !A.bWorldGeometry) continue;
        // A resting object can be lifted off its supporting face, but cannot
        // move farther into a face which already touches its collision hull.
        if (bAllowLeavingContact && VSizeSq(Hit - Start) < 1.0
            && ((End - Start) dot N) > 0.01) continue;
        return false;
    }
    return true;
}

simulated function bool ToggleCarry()
{
    local Actor A;
    local TraceHitInfo Info;
    local vector Start, Hit, N, Center;
    if (!CanUse()) return false;
    if (HeldActor != None) { ReleaseHeld(); return true; }
    if (Gun.bPortalVRSession && (!Gun.bTrackedPose
        || WorldInfo.TimeSeconds - Gun.LastTrackedInputTime > 0.15)) return false;
    Start = Gun.SourceOrigin();
    // Selection stops at the first world/actor hit. A prop behind a wall or
    // another actor cannot be picked up by tracing through that blocker.
    A = Trace(Hit, N, Start + Gun.SourceDirection()*PickupRange, Start, true,, Info);
    if (!Eligible(A, Info.HitComponent)) return false;
    HeldActor = KActor(A);
    HeldComponent = Info.HitComponent;
    Center = HeldComponent.Bounds.Origin;
    if (!PathClear(Start, Center, vect(0,0,0)))
    { HeldActor=None; HeldComponent=None; return false; }
    CarryHandle.GrabComponent(HeldComponent, '', Center, true);
    if (CarryHandle.GrabbedComponent != HeldComponent)
    { HeldActor=None; HeldComponent=None; return false; }
    HoldDistance = FClamp(127.0 + VSize(HeldComponent.Bounds.BoxExtent), 177.8, 304.8);
    bHeldWithTracking = Gun.bPortalVRSession;
    LastPawnLocation = Instigator.Location;
    HeldComponent.WakeRigidBody();
    `log("KF2VR_PORTAL action=pickup actor=" $ HeldActor.Class);
    return true;
}

simulated function ReleaseHeld()
{
    CarryHandle.ReleaseComponent();
    if (HeldActor != None && !HeldActor.bDeleteMe && HeldComponent != None)
    {
        // A use action is a drop, never a launch. Clear residual spring energy.
        HeldComponent.SetRBLinearVelocity(vect(0,0,0));
        HeldComponent.SetRBAngularVelocity(vect(0,0,0));
        HeldComponent.WakeRigidBody();
        `log("KF2VR_PORTAL action=drop actor=" $ HeldActor.Class);
    }
    HeldActor = None;
    HeldComponent = None;
    bHeldWithTracking = false;
}

// Native/script traversal must not leave a spring stretching across portals.
static function ReleaseForPortalTravel(Actor Traveler)
{
    local VRPortalCarry Carry;
    if (Traveler == None) return;
    foreach Traveler.AllActors(class'VRPortalCarry', Carry)
        if (Carry.HeldActor == Traveler || Carry.Instigator == Traveler)
            Carry.ReleaseHeld();
}

simulated event Tick(float DeltaTime)
{
    local vector Start, Center, Goal, Step, Extent;
    Super.Tick(DeltaTime);
    if (Gun == None || Gun.bDeleteMe || PC == None || Instigator == None
        || PC.Pawn != Instigator || Instigator.Health <= 0)
    { Destroy(); return; }
    if (HeldActor == None) return;
    if (!CanUse() || HeldActor.bDeleteMe || HeldComponent == None
        || CarryHandle.GrabbedComponent != HeldComponent || HeldActor.Physics != PHYS_RigidBody)
    { ReleaseHeld(); return; }
    if (bHeldWithTracking && (!Gun.bTrackedPose
        || WorldInfo.TimeSeconds - Gun.LastTrackedInputTime > 0.15))
    { ReleaseHeld(); return; }
    // Also release on a non-portal teleport, rather than pulling the prop
    // through the intervening world. Ordinary movement is handled below.
    if (VSize(Instigator.Location - LastPawnLocation) > 254.0)
    { ReleaseHeld(); return; }
    LastPawnLocation = Instigator.Location;
    Start = Gun.SourceOrigin();
    Center = HeldComponent.Bounds.Origin;
    Goal = Start + Gun.SourceDirection()*HoldDistance;
    Extent = HeldComponent.Bounds.BoxExtent;
    if (VSize(Center - Start) > HoldDistance + 152.4
        || !PathClear(Start, Center, vect(0,0,0))
        || !PathClear(Start, Goal, vect(0,0,0)))
    { ReleaseHeld(); return; }
    Step = Goal - Center;
    Goal = Center + Normal(Step)*FMin(VSize(Step), MoveSpeed*FMin(DeltaTime,0.05));
    if (!PathClear(Center, Goal, Extent, true))
    { ReleaseHeld(); return; }
    CarryHandle.SetSmoothLocation(Goal, FMax(DeltaTime,0.015));
    HeldComponent.WakeRigidBody();
}

simulated event Destroyed()
{
    ReleaseHeld();
    if (UseInput != None)
    {
        UseInput.Carry = None;
        if (PC != None) PC.Interactions.RemoveItem(UseInput);
    }
    UseInput = None;
    Gun = None;
    PC = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    TickGroup=TG_PreAsyncWork
    PickupRange=203.2
    MaximumMass=85.0
    MaximumRadius=121.92
    MoveSpeed=508.0
    Begin Object Class=RB_Handle Name=PortalCarryHandle
        LinearDamping=180.0
        LinearStiffness=1300.0
        AngularDamping=300.0
        AngularStiffness=1000.0
    End Object
    CarryHandle=PortalCarryHandle
    Components.Add(PortalCarryHandle)
}
