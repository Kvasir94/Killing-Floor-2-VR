// One gravity-pulled item in the air, seen by every player. The authority
// claims the real pickup (hides it or keeps its factory) and replicates only
// the launch; each machine flies the same arc locally, so nothing streams per
// frame. The arc is Half-Life: Alyx's: a ballistic launch timed to reach the
// hand, its plane turned toward the flick, then steered onto the hand.
class VRGravityPullFlight extends Actor;

var repnotify Actor Target;
var KFPawn_Human Puller;
var byte Hand;
var vector StartLocation, Launch, AimPoint, PullerAtLaunch;
var rotator StartRotation;
var float GravityZ, TravelTime;
// 0 flying, 1 caught, 2 dropped or refused.
var repnotify byte Outcome;
var class<KFWeapon> HandlingWeapon;

var float LocalStart, OutcomeAt;
var bool bStarted, bVisualBuilt, bFactoryHidden;
var bool bSawFlying, bCatchSoundPlayed;
var MeshComponent Visual;
var VRHandsBridge LocalBridge;

replication
{
    if (bNetInitial && Role == ROLE_Authority)
        Target, Puller, Hand, StartLocation, Launch,
        StartRotation, GravityZ, TravelTime, HandlingWeapon;
    if (Role == ROLE_Authority)
        Outcome, AimPoint, PullerAtLaunch;
}

function bool Begin(Actor InTarget, KFPawn_Human InPuller, int InHand, vector From, rotator Facing,
    vector InLaunch, vector InAim, float InGravityZ, float InTravel)
{
    if (Role != ROLE_Authority || InTarget == None || InPuller == None || InTravel <= 0) return false;
    Target = InTarget; Puller = InPuller; Hand = byte(Clamp(InHand, 0, 1));
    if (KFDroppedPickup(Target) != None)
        HandlingWeapon = class<KFWeapon>(KFDroppedPickup(Target).InventoryClass);
    StartLocation = From; StartRotation = Facing; Launch = InLaunch; AimPoint = InAim;
    PullerAtLaunch = InPuller.Location; GravityZ = InGravityZ; TravelTime = InTravel;
    Start();
    bForceNetUpdate = true;
    return true;
}

// The authority follows the existing accepted hand stream. Replicate the
// body anchor with the goal, so observers add only subsequent body movement.
function SetHandGoal(vector Goal)
{
    if (Role != ROLE_Authority || Outcome != 0 || Puller == None || Puller.bDeleteMe) return;
    if (!class'VRGrenadeThrow'.static.Bounded(Goal - Puller.Location, 190)) return;
    AimPoint = Goal; PullerAtLaunch = Puller.Location;
    bNetDirty = true;
}

simulated function Start()
{
    if (bStarted) return;
    bStarted = true;
    bSawFlying = Outcome == 0;
    LocalStart = WorldInfo.TimeSeconds;
    SetLocation(StartLocation);
    SetRotation(StartRotation);
    // A flight first seen already finished has nothing to show. Building it
    // then left a copy of the box at the pickup, beside the hidden original.
    if (WorldInfo.NetMode != NM_DedicatedServer && Outcome == 0) BuildVisual();
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'Outcome') Finish();
    else if (VarName == 'Target' && bStarted && !bVisualBuilt && Outcome == 0) BuildVisual();
    else Super.ReplicatedEvent(VarName);
}

simulated function float Elapsed()
{
    return bStarted ? WorldInfo.TimeSeconds - LocalStart : 0.0;
}

simulated function PrimitiveComponent SourceMesh()
{
    if (KFDroppedPickup(Target) != None) return KFDroppedPickup(Target).MyMeshComp;
    if (PickupFactory(Target) != None) return PickupFactory(Target).PickupMesh;
    return None;
}

// A visual copy of the item's own mesh. Factories keep their real mesh, so it
// is hidden locally for the flight and restored if the pickup did not happen.
simulated function BuildVisual()
{
    local PrimitiveComponent Source;
    local StaticMeshComponent SourceStatic, Copy;
    local SkeletalMeshComponent SourceSkeletal, SkeletalCopy;
    local int I;
    if (bVisualBuilt || Target == None) return;
    Source = SourceMesh();
    SourceStatic = StaticMeshComponent(Source);
    SourceSkeletal = SkeletalMeshComponent(Source);
    if (SourceStatic != None && SourceStatic.StaticMesh != None)
    {
        Copy = new(self) class'StaticMeshComponent';
        Copy.SetStaticMesh(SourceStatic.StaticMesh);
        for (I = 0; I < SourceStatic.GetNumElements(); ++I) Copy.SetMaterial(I, SourceStatic.GetMaterial(I));
        Visual = Copy;
    }
    else if (SourceSkeletal != None && SourceSkeletal.SkeletalMesh != None)
    {
        SkeletalCopy = new(self) class'SkeletalMeshComponent';
        SkeletalCopy.SetSkeletalMesh(SourceSkeletal.SkeletalMesh);
        for (I = 0; I < SourceSkeletal.GetNumElements(); ++I) SkeletalCopy.SetMaterial(I, SourceSkeletal.GetMaterial(I));
        Visual = SkeletalCopy;
    }
    if (Visual == None) return;
    // Keep the source's Indoor/Outdoor light mask; a fresh skeletal copy has
    // none and would fly in black (see VRWorldDropGun.WorldLightingChannels).
    if (Source.LightingChannels.Indoor || Source.LightingChannels.Outdoor)
        Visual.SetLightingChannels(Source.LightingChannels);
    Visual.SetScale(Source.Scale * Target.DrawScale);
    Visual.SetScale3D(Source.Scale3D * Target.DrawScale3D);
    // The flight actor follows the visible item centre, not the factory's
    // origin. Stock ammo factories offset their mesh 50 units downward;
    // applying that offset again puts the flying box below the floor/hand.
    Visual.SetTranslation(Source.Translation + ((Target.Location - StartLocation) << StartRotation));
    Visual.SetActorCollision(false, false);
    Visual.SetTraceBlocking(false, false);
    Visual.CastShadow = false;
    AttachComponent(Visual);
    bVisualBuilt = true;
    if (PickupFactory(Target) != None && Source != None && !Source.HiddenGame)
    {
        Source.SetHidden(true);
        bFactoryHidden = true;
    }
}

simulated function VRHandsBridge FindLocalBridge()
{
    local VRHandsBridge B;
    if (LocalBridge != None && !LocalBridge.bDeleteMe) return LocalBridge;
    if (Puller == None || !Puller.IsLocallyControlled()) return None;
    foreach DynamicActors(class'VRHandsBridge', B)
        if (B.Human == Puller && B.RootBridge == None) { LocalBridge = B; break; }
    return LocalBridge;
}

// Where the item is heading now: the real palm for the puller's own machine,
// otherwise the launch aim moved with the puller's body.
simulated function vector HandGoal()
{
    local VRHandsBridge B;
    B = FindLocalBridge();
    if (B != None) return B.PalmPosition(Hand) + vect(0,0,7.6);
    if (Puller != None) return AimPoint + (Puller.Location - PullerAtLaunch);
    return AimPoint;
}

simulated function vector Ballistic(float T)
{
    local vector P;
    P = StartLocation + Launch * T;
    P.Z += 0.5 * GravityZ * T * T;
    return P;
}

simulated event Tick(float DeltaTime)
{
    local float T, U, S;
    local vector P;
    Super.Tick(DeltaTime);
    // Clients start once the launch has replicated (it arrives in one bunch).
    if (!bStarted && Role != ROLE_Authority && TravelTime > 0) Start();
    if (!bStarted) return;
    if (Outcome != 0)
    {
        if (Role == ROLE_Authority && WorldInfo.TimeSeconds - OutcomeAt > 1.0) Destroy();
        return;
    }
    T = FMin(Elapsed(), TravelTime);
    U = T / TravelTime;
    // Smoothstep correction lands the arc exactly on the moving hand; the
    // flick-turned launch only shapes the path on the way.
    S = U * U * (3 - 2 * U);
    P = Ballistic(T) + (HandGoal() - Ballistic(TravelTime)) * S;
    SetLocation(P);
    if (Role == ROLE_Authority && Elapsed() > TravelTime + 0.6) Resolve(2);
}

function Resolve(byte Result)
{
    if (Role != ROLE_Authority || Outcome != 0) return;
    Outcome = Result;
    OutcomeAt = WorldInfo.TimeSeconds;
    bForceNetUpdate = true;
    if (Owner != None && VRGravityPullChannel(Owner) != None) VRGravityPullChannel(Owner).FlightEnded(self, Result);
    Finish();
}

simulated function Finish()
{
    local PrimitiveComponent Source;
    // The owner cues the successful inventory draw. Observers cue only an
    // actual flight they saw; an already-finished initial snapshot is silent.
    if (Outcome == 1 && bSawFlying && !bCatchSoundPlayed && HandlingWeapon != None
        && Puller != None && !Puller.IsLocallyControlled())
    {
        bCatchSoundPlayed = true;
        class'VRWorldHandlingAudio'.static.Play(Puller, HandlingWeapon, true, HandGoal());
    }
    if (Visual != None) Visual.SetHidden(true);
    if (bFactoryHidden)
    {
        Source = SourceMesh();
        // A caught pickup stays hidden: the factory's own bPickupHidden can
        // replicate up to a second later, and showing it in between looked
        // like a duplicate box. Its later respawn is shown by stock.
        if (Source != None && PickupFactory(Target) != None && !PickupFactory(Target).bPickupHidden
            && Outcome != 1)
            Source.SetHidden(false);
        bFactoryHidden = false;
    }
}

simulated event Destroyed()
{
    Finish();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=false
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    Physics=PHYS_None
    bHidden=false
    NetUpdateFrequency=120
    LifeSpan=8.0
}
