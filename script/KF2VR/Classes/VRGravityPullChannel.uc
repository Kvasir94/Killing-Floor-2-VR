// Controller-owned gravity-pull transport and authority, one per player.
// Solo spawns it locally; a multiplayer host spawns one for every controller.
// Clients only ask: the authority checks reach, aim, line of sight and
// eligibility, claims the item and flies it. Stock pickups fly as a
// replicated copy and are given by the stock GiveTo on the catch; VR world
// guns and magazines fly for real (they are already authority-simulated
// props) and land in the hand through their own catch transactions.
class VRGravityPullChannel extends Actor;

struct PullReply
{
    var int Request;
    var byte Kind;      // 0 pull, 1 catch
    var byte Accepted;
    var byte Reason;    // see Eligibility
    var VRGravityPullFlight Flight;
    var KFWeapon Weapon;
    var float Travel;
};

// A real world prop in flight, steered onto the palm the client reports.
struct WorldPull
{
    var Actor Prop;
    var vector Goal, GoalBody, LastPosition, LastGoal, GoalVelocity;
    var float ArriveAt, GravityZ, ReturnLeaseUntil;
    var bool bHaveLast;
    // R22: the rest of a pulled pile of loose rounds, trailing the target.
    var array<VRWorldDropMagazine> Pile;
};

var bool bHostAllowed;
// Each hand keeps its response until that hand sends another request.
var repnotify PullReply Replies[2];
var VRGravityPullFlight Flights[2];
var Actor Claimed[2];
// Bool arrays are not allowed in UnrealScript; 0/1 bytes.
var byte ClaimHidden[2], ClaimCollide[2], ClaimBlock[2];
var float NextPullAt[2];
// Local allocator and authority fence share this controller-owned lifetime,
// even when the pawn's VRGravityPull helper is replaced after respawning.
var int RequestSerial;
var int LastRequest;
var WorldPull WorldPulls[2];
var VRWorldMagazineRegistry TrackingRegistry;
var AkEvent PullSound;
var vector FallbackPalm[2], FallbackBody[2];
var float FallbackPalmAt[2];

// Alyx's defaults converted at 1 Alyx unit = 1.27 UU (50 UU per metre).
// The client uses the exact values; the authority adds latency slack.
const MaxRange = 508.0;
const MinRange = 15.0;
const AimSlackDot = 0.766;  // 40 degrees
const ReachFromBody = 180.0;
// Bounded in-flight correction continues through the catch window so a
// moving palm does not leave the magazine aiming at its previous position.
const HomingMax = 635.0;
const HomingStart = 0.6;
const HomingHorizon = 0.10;
// #119: once it arrives, a pulled prop is held on the moving palm (a velocity
// servo with this time constant and speed bound) until the hand closes or
// the catch window ends, so walking or reaching cannot leave it behind.
const MagnetSeconds = 0.06;
const MagnetMaxSpeed = 900.0;
const MagnetWindow = 1.0;

replication
{
    if (bNetDirty && Role == ROLE_Authority)
        bHostAllowed, Replies;
}

// Bound to the accepted tracking stream used by remote carried props.
delegate bool GetHandPosition(int Hand, out vector At) { return false; }

simulated function bool Available()
{
    return !bDeleteMe && bHostAllowed && PlayerController(Owner) != None;
}

function KFPawn_Human Puller()
{
    local PlayerController PC;
    PC = PlayerController(Owner);
    if (PC == None || KFPawn_Human(PC.Pawn) == None) return None;
    if (PC.Pawn.Health <= 0 || PC.Pawn.bDeleteMe) return None;
    return KFPawn_Human(PC.Pawn);
}

static function vector ItemCenter(Actor A)
{
    local PrimitiveComponent C;
    if (VRWorldDropGun(A) != None) return VRWorldDropGun(A).GrabPosition();
    if (VRWorldDropMagazine(A) != None) return A.Location;
    if (KFDroppedPickup(A) != None) C = KFDroppedPickup(A).MyMeshComp;
    else if (PickupFactory(A) != None) C = PickupFactory(A).PickupMesh;
    if (C != None && C.Bounds.SphereRadius > 0 && C.Bounds.SphereRadius < 200) return C.Bounds.Origin;
    return A.Location;
}

// A gun must arrive by the same authored wrist contact its catch validates.
// Mesh bounds can be well ahead of a rifle's grip: steering that centre onto
// the palm leaves the actual grip outside the catch radius indefinitely.
static function vector PullContact(Actor A, int Hand)
{
    local VRWorldDropGun Gun;
    local vector Primary, Support;
    Gun = VRWorldDropGun(A);
    if (Gun != None && Gun.GripContacts(Hand, Primary, Support)) return Primary;
    return ItemCenter(A);
}

// Stock pickups whose GiveTo is the whole transaction, plus the VR world guns
// and magazines, which fly for real and keep their own catch paths.
static function bool WeaponTarget(Actor A)
{
    local KFPickupFactory_Item Factory;
    if (VRWorldDropGun(A) != None) return true;
    if (KFDroppedPickup(A) != None)
        return class<KFWeapon>(KFDroppedPickup(A).InventoryClass) != None;
    Factory = KFPickupFactory_Item(A);
    return Factory != None && Factory.PickupIndex < Factory.ItemPickups.Length
        && class<KFWeapon>(Factory.ItemPickups[Factory.PickupIndex].ItemClass) != None;
}

static function bool PullableClass(Actor A)
{
    if (A == None || A.bDeleteMe) return false;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() && WeaponTarget(A)) return false;
    if (VRWorldDropGun(A) != None || VRWorldDropMagazine(A) != None) return true;
    if (A.Class == class'KFDroppedPickup' || KFDroppedPickup_Cash(A) != None) return true;
    return KFPickupFactory(A) != None;
}

static function bool WorldProp(Actor A)
{
    return VRWorldDropGun(A) != None || VRWorldDropMagazine(A) != None;
}

// Still travelling: a toss on its way in.
static function bool Airborne(Actor A)
{
    if (VRWorldDropGun(A) != None) return !VRWorldDropGun(A).bGrounded && !VRWorldDropGun(A).bReturning;
    if (VRWorldDropMagazine(A) != None) return !VRWorldDropMagazine(A).bGrounded && VRWorldDropMagazine(A).Carrier == None;
    if (KFDroppedPickup(A) != None) return A.Physics == PHYS_Falling || VSize(A.Velocity) > 60;
    return false;
}

static function bool OwnsMagazineFamily(KFPawn_Human P, class<KFWeapon> Family)
{
    local KFWeapon W;
    if (P == None || P.InvManager == None || Family == None) return false;
    foreach P.InvManager.InventoryActors(class'KFWeapon', W)
        if (!W.bDeleteMe && class'VRWeaponDropState'.static.FamilyFor(W.Class) == Family) return true;
    return false;
}

static function bool NeedsAmmo(KFPawn_Human P)
{
    local KFWeapon W;
    local KFInventoryManager IM;
    IM = KFInventoryManager(P.InvManager);
    if (IM == None) return false;
    foreach IM.InventoryActors(class'KFWeapon', W)
    {
        if (W.bInfiniteSpareAmmo) continue;
        if (W.GetMaxAmmoAmount(0) > 0 && W.SpareAmmoCount[0] + W.AmmoCount[0] < W.GetMaxAmmoAmount(0)) return true;
        if (W.CanRefillSecondaryAmmo() && W.AmmoCount[1] < W.MagazineCapacity[1]) return true;
    }
    return P.GetPerk() != None && IM.GrenadeCount < P.GetPerk().MaxGrenadeCount;
}

// 0 ok, 1 not pullable, 2 already flying or claimed, 3 nothing to gain (ammo
// full, already carried, too heavy, no gun for that magazine), 4 out of reach
// or blocked. bLocal: a client's view, where pickup states do not replicate.
static function byte Eligibility(Actor A, KFPawn_Human P, optional bool bLocal)
{
    local KFDroppedPickup Drop;
    local KFPickupFactory Factory;
    local KFInventoryManager IM;
    local KFWeapon W;
    local class<KFWeapon> WC;
    local VRWorldDropGun Gun;
    local VRWorldDropMagazine Magazine;
    if (!PullableClass(A) || P == None || !P.bCanPickupInventory) return 1;
    // VR world props keep their own permission (owner, ALLOW OTHER PLAYERS,
    // public death loot); their catch transactions do the stock checks.
    Gun = VRWorldDropGun(A);
    if (Gun != None)
    {
        if (Gun.bReturning || Gun.bCatchPending || Gun.bHidden) return 2;
        if (!Gun.CanPickupBy(P)) return 1;
        // Too heavy for the carry blocks left: the catch would refuse it. The
        // player's own grounded gun is still in the inventory (#122), its
        // weight already counted, so it is always theirs to pull back.
        IM = KFInventoryManager(P.InvManager);
        WC = class<KFWeapon>(Gun.InventoryClass);
        if (IM != None && WC != None && (Gun.OwnedWeapon == None || Gun.OwnedWeapon.InvManager != IM)
            && !IM.CanCarryWeapon(WC,
            Gun.OwnedWeapon != None ? Gun.OwnedWeapon.CurrentWeaponUpgradeIndex : 0)) return 3;
        return 0;
    }
    Magazine = VRWorldDropMagazine(A);
    if (Magazine != None)
    {
        if (!Magazine.CanPickupBy(P) || Magazine.Rounds <= 0) return 1;
        return OwnsMagazineFamily(P, Magazine.Family) ? 0 : 3;
    }
    Drop = KFDroppedPickup(A);
    if (Drop != None)
    {
        if (Drop.bHidden || (!bLocal && !Drop.IsInState('Pickup')) || A.WorldInfo.TimeSeconds - Drop.CreationTime < 0.5) return 2;
        if (KFDroppedPickup_Cash(Drop) != None) return 0;
        IM = KFInventoryManager(P.InvManager);
        WC = class<KFWeapon>(Drop.InventoryClass);
        if (IM == None || WC == None) return 1;
        foreach IM.InventoryActors(class'KFWeapon', W)
        {
            if ((W.Class == WC && W.DualClass == None) || W.Class == WC.default.DualClass) return 3;
        }
        if (KFWeapon(Drop.Inventory) != None && !IM.CanCarryWeapon(WC, KFWeapon(Drop.Inventory).CurrentWeaponUpgradeIndex)) return 3;
        return 0;
    }
    Factory = KFPickupFactory(A);
    if (Factory.bPickupHidden || (!bLocal && !Factory.IsInState('Pickup'))) return 2;
    if (PickupIsAmmo(Factory) && !NeedsAmmo(P)) return 3;
    if (PickupIsArmor(Factory) && P.Armor >= P.GetMaxArmor()) return 3;
    return 0;
}

// Stock CurrentPickupIsAmmo/IsArmor are not simulated: on a network client
// the map's factories are simulated proxies, so those calls return false and
// a full ammo box or armor vest looked pullable until the server refused it.
static function bool PickupIsAmmo(KFPickupFactory Factory)
{
    return KFPickupFactory_Ammo(Factory) != None;
}

static function bool PickupIsArmor(KFPickupFactory Factory)
{
    local KFPickupFactory_Item Item;
    Item = KFPickupFactory_Item(Factory);
    return Item != None && Item.PickupIndex < Item.ItemPickups.Length
        && Item.ItemPickups[Item.PickupIndex].ItemClass != None
        && Item.ItemPickups[Item.PickupIndex].ItemClass.Name == Item.ArmorClassName;
}

function bool IsClaimed(Actor A)
{
    local VRGravityPullChannel C;
    foreach DynamicActors(class'VRGravityPullChannel', C)
        if (C.Claimed[0] == A || C.Claimed[1] == A) return true;
    return false;
}

simulated function int AllocateRequest()
{
    return ++RequestSerial;
}

function SendReply(int Request, byte Hand, byte Kind, bool bAccepted, byte Reason,
    optional VRGravityPullFlight Flight, optional KFWeapon Weapon, optional float Travel)
{
    if (Hand > 1) return;
    Replies[Hand].Request = Request; Replies[Hand].Kind = Kind; Replies[Hand].Accepted = byte(bAccepted);
    Replies[Hand].Reason = Reason; Replies[Hand].Flight = Flight;
    Replies[Hand].Weapon = Weapon; Replies[Hand].Travel = Travel;
    bNetDirty = true;
    bForceNetUpdate = true;
}

// Reach palm + 7.6 UU in 0.32 s at 127 UU to 0.46 s at 508 UU (#26: a
// quicker arrival than Alyx's 0.45-0.62 s; ServerCatch then admits a catch
// from launch, since its 0.4 s early window now covers the whole flight),
// v0 = D/T - g T/2, with the arc's plane turned toward the flick by up to 20
// degrees near (127 UU) and 10 degrees far (318 UU).
static function float TravelTime(float Distance)
{
    // A short pull arrives promptly instead of drifting in at the long
    // pull's pace: "it floated into my hand over a second or two" (#171).
    if (Distance < 127.0) return Lerp(0.15, 0.32, FClamp(Distance / 127.0, 0, 1));
    return Lerp(0.32, 0.46, FClamp((Distance - 127.0) / (508.0 - 127.0), 0, 1));
}

static function vector SteeredLaunch(vector From, vector Goal, float T, float GravityZ, vector Flick)
{
    local vector D, Dn, V, Along, Side, FlickSide, Axis;
    local float MaxAngle, Angle, C, S;
    D = Goal - From;
    V = D / T;
    V.Z -= 0.5 * GravityZ * T;
    Dn = Normal(D);
    if (Flick.Z < 0) Flick.Z = -Flick.Z;
    Along = Dn * (V Dot Dn);
    Side = V - Along;
    FlickSide = Flick - Dn * (Flick Dot Dn);
    if (VSize(Side) < 1 || VSize(FlickSide) < 1) return V;
    MaxAngle = Lerp(20.0, 10.0, FClamp((VSize(D) - 127.0) / (318.0 - 127.0), 0, 1)) * Pi / 180.0;
    Angle = FMin(Acos(FClamp(Normal(Side) Dot Normal(FlickSide), -1, 1)), MaxAngle);
    Axis = Normal(Side Cross FlickSide);
    C = Cos(Angle); S = Sin(Angle);
    // Rodrigues rotation of the side component about Axis (perpendicular to it).
    Side = Side * C + (Axis Cross Side) * S;
    return Along + Side;
}

reliable server function ServerPull(int Request, byte Hand, Actor Target, vector Palm, vector Aim, vector Flick)
{
    local KFPawn_Human P;
    local vector Center, Goal, V;
    local float Distance, T, GravityZ;
    local byte Reason;
    local VRGravityPullFlight Flight;
    if (Request <= LastRequest) return;
    LastRequest = Request;
    P = Puller();
    if (!bHostAllowed || P == None || Hand > 1) { SendReply(Request, Hand, 0, false, 1); return; }
    if (WorldInfo.TimeSeconds < NextPullAt[Hand] || WorldPulls[Hand].Prop != None
        || (Flights[Hand] != None && !Flights[Hand].bDeleteMe && Flights[Hand].Outcome == 0))
    { SendReply(Request, Hand, 0, false, 2); return; }
    Reason = Eligibility(Target, P);
    if (Reason == 0 && IsClaimed(Target)) Reason = 2;
    if (Reason != 0) { SendReply(Request, Hand, 0, false, Reason); return; }
    Center = ItemCenter(Target);
    Distance = VSize(Center - Palm);
    if (VSize(Palm - P.Location) > ReachFromBody || Distance > MaxRange * 1.1 || Distance < MinRange * 0.5
        || (Normal(Center - Palm) Dot Normal(Aim)) < AimSlackDot
        || (!FastTrace(Center, Palm) && !FastTrace(Center + vect(0,0,8), Palm)))
    { SendReply(Request, Hand, 0, false, 4); return; }
    Goal = Palm + vect(0,0,7.6);
    FallbackPalm[Hand] = Palm; FallbackBody[Hand] = P.Location;
    FallbackPalmAt[Hand] = WorldInfo.RealTimeSeconds;
    T = TravelTime(Distance);
    if (WorldProp(Target))
    {
        // These props steer their actual catch contact, not a copied pickup's
        // visual centre. An extra vertical offset spends the catch tolerance
        // before either player motion or network delay has been accounted for.
        Goal = Palm;
        Center = PullContact(Target, Hand);
        GravityZ = PropGravityZ(Target);
        V = SteeredLaunch(Center, Goal, T, GravityZ, Flick);
        if (!LaunchWorldProp(Target, V)) { SendReply(Request, Hand, 0, false, 1); return; }
        WorldPulls[Hand].Prop = Target;
        LaunchPile(Hand, Target, V, P);
        WorldPulls[Hand].Goal = Goal;
        WorldPulls[Hand].GoalBody = P.Location;
        WorldPulls[Hand].ArriveAt = WorldInfo.TimeSeconds + T;
        // A pull accepted just before the ordinary return deadline must get
        // its bounded flight/catch window. Highlighting alone grants no lease.
        WorldPulls[Hand].ReturnLeaseUntil = WorldInfo.RealTimeSeconds
            + FClamp((T + MagnetWindow) / FMax(WorldInfo.TimeDilation, 0.1), 1.2, 12.0);
        if (VRWorldDropGun(Target) != None)
        {
            VRWorldDropGun(Target).GravityReturnOwner = self;
            VRWorldDropGun(Target).GravityReturnUntil = WorldPulls[Hand].ReturnLeaseUntil;
        }
        WorldPulls[Hand].GravityZ = GravityZ;
        WorldPulls[Hand].bHaveLast = false;
        WorldPulls[Hand].GoalVelocity = vect(0,0,0);
        Claimed[Hand] = Target;
        ClaimHidden[Hand] = 0;
        NextPullAt[Hand] = WorldInfo.TimeSeconds + 0.25;
        PlayPullSound(Target);
        SendReply(Request, Hand, 0, true, 0, None, None, T);
        return;
    }
    GravityZ = WorldInfo.WorldGravityZ < -1 ? WorldInfo.WorldGravityZ : -980.0;
    V = SteeredLaunch(Center, Goal, T, GravityZ, Flick);
    Flight = Spawn(class'VRGravityPullFlight', self,, Center, Target.Rotation, , true);
    if (Flight == None || !Flight.Begin(Target, P, Hand, Center, Target.Rotation, V, Goal, GravityZ, T))
    {
        if (Flight != None) Flight.Destroy();
        SendReply(Request, Hand, 0, false, 1);
        return;
    }
    Claim(Hand, Target);
    Flights[Hand] = Flight;
    NextPullAt[Hand] = WorldInfo.TimeSeconds + 0.25;
    PlayPullSound(Flight);
    SendReply(Request, Hand, 0, true, 0, Flight, None, T);
}

// The Gravity Imploder's attract, heard by everyone at the item.
function PlayPullSound(Actor At)
{
    if (PullSound == None)
        // The Imploder attract event loops until its matching weapon event;
        // a gravity-glove flight has no such weapon/audio lifetime owner.
        PullSound = AkEvent(DynamicLoadObject("WW_UI_PlayerCharacter.Play_Grab_Stop", class'AkEvent', true));
    if (PullSound != None && At != None) At.PlaySoundBase(PullSound);
}

// Magazines integrate a fixed 980 UU/s^2 (VRWorldDropMagazine.Step); guns are
// rigid bodies under the world's scaled physics gravity.
function float PropGravityZ(Actor A)
{
    local float G;
    if (VRWorldDropMagazine(A) != None) return -980.0;
    G = WorldInfo.WorldGravityZ < -1 ? WorldInfo.WorldGravityZ : -980.0;
    if (WorldInfo.RBPhysicsGravityScaling > 0) G *= WorldInfo.RBPhysicsGravityScaling;
    return G;
}

function bool LaunchWorldProp(Actor A, vector V)
{
    local VRWorldDropGun Gun;
    local VRWorldDropMagazine Magazine;
    local SkeletalMeshComponent Skel;
    Magazine = VRWorldDropMagazine(A);
    if (Magazine != None)
    {
        Magazine.Linear = V;
        Magazine.Angular = vect(0,0,0);
        Magazine.bGrounded = false;
        Magazine.bForceNetUpdate = true;
        return true;
    }
    Gun = VRWorldDropGun(A);
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || Gun == None || Gun.MyMeshComp == None) return false;
    // A gun that settled may have frozen its bodies (stock sleep); wake it.
    Skel = SkeletalMeshComponent(Gun.MyMeshComp);
    if (Skel != None && Skel.PhysicsAssetInstance != None) Skel.PhysicsAssetInstance.SetAllBodiesFixed(false);
    Gun.MyMeshComp.SetBlockRigidBody(true);
    if (Gun.Physics != PHYS_RigidBody) Gun.SetPhysics(PHYS_RigidBody);
    if (Gun.Physics != PHYS_RigidBody) return false;
    // The accepted pull extracts the original prop before giving it flight.
    // Otherwise its bone follower would fix it back into the Zed each tick.
    if (Gun.Embedded.Victim != None) Gun.ClearEmbedded(true);
    // Static pickup bodies are fixed by the same sleep: unfix before launch.
    Gun.ReviveRigidBody();
    Gun.MyMeshComp.WakeRigidBody();
    Gun.MyMeshComp.SetRBLinearVelocity(V);
    Gun.MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
    Gun.bGrounded = false;
    // The pull's homing assumes plain physics gravity.
    Gun.bTossFlight = false;
    Gun.bForceNetUpdate = true;
    return true;
}

// The puller's palm while a world prop flies, so it lands on the moving hand.
unreliable server function ServerPalm(byte Hand, vector Palm)
{
    local KFPawn_Human P;
    P = Puller();
    if (Hand > 1 || P == None || (WorldPulls[Hand].Prop == None
        && (Flights[Hand] == None || Flights[Hand].bDeleteMe || Flights[Hand].Outcome != 0))
        || !class'VRGrenadeThrow'.static.Bounded(Palm - P.Location, ReachFromBody)) return;
    FallbackPalm[Hand] = Palm; FallbackBody[Hand] = P.Location;
    FallbackPalmAt[Hand] = WorldInfo.RealTimeSeconds;
}

function bool CurrentPalm(int Hand, out vector Palm)
{
    local KFPawn_Human P;
    local VRWorldMagazineRegistry R;
    P = Puller();
    if (Hand < 0 || Hand > 1 || P == None) return false;
    if (GetHandPosition(Hand, Palm))
        return class'VRGrenadeThrow'.static.Bounded(Palm - P.Location, ReachFromBody);
    if (TrackingRegistry == None || TrackingRegistry.bDeleteMe || TrackingRegistry.Human != P)
    {
        TrackingRegistry = None;
        foreach WorldInfo.AllActors(class'VRWorldMagazineRegistry', R)
            if (R.Human == P) { TrackingRegistry = R; break; }
    }
    if (TrackingRegistry != None && TrackingRegistry.CarrierPosition(Hand, Palm))
        return class'VRGrenadeThrow'.static.Bounded(Palm - P.Location, ReachFromBody);
    if (WorldInfo.RealTimeSeconds - FallbackPalmAt[Hand] > 0.1) return false;
    Palm = FallbackPalm[Hand] + P.Location - FallbackBody[Hand];
    return class'VRGrenadeThrow'.static.Bounded(Palm - P.Location, ReachFromBody);
}

// Alyx: a = ((goal - p) / t - v) / t - g t / 2, never pushing along gravity,
// clamped and ramped in near arrival.
function SteerWorldProp(int H, float DeltaTime)
{
    local Actor A;
    local VRWorldDropMagazine Magazine;
    local VRWorldDropGun Gun;
    local vector P, V, Acc, GoalStep;
    local float T, Ramp, Size;
    local bool Terminal;
    A = WorldPulls[H].Prop;
    if (A == None || A.bDeleteMe || DeltaTime <= 0 || !PullableClass(A)) { EndWorldPull(H); return; }
    Magazine = VRWorldDropMagazine(A);
    Gun = VRWorldDropGun(A);
    if ((Magazine != None && Magazine.Carrier != None)
        || (Gun != None && (Gun.bReturning || Gun.bCatchPending))) { EndWorldPull(H); return; }
    T = WorldPulls[H].ArriveAt - WorldInfo.TimeSeconds;
    if (T < -MagnetWindow || WorldInfo.RealTimeSeconds > WorldPulls[H].ReturnLeaseUntil) { EndWorldPull(H); return; }
    P = PullContact(A, H);
    V = Magazine != None ? Magazine.Linear : (P - WorldPulls[H].LastPosition) / DeltaTime;
    if (WorldPulls[H].bHaveLast)
    {
        // Match the moving palm's velocity as well as its position. Chasing
        // position alone leaves a walking player's hand perpetually ahead.
        GoalStep = (WorldPulls[H].Goal - WorldPulls[H].LastGoal) / DeltaTime;
        if (class'VRGrenadeThrow'.static.Bounded(GoalStep, 1200))
            WorldPulls[H].GoalVelocity += (GoalStep - WorldPulls[H].GoalVelocity)
                * FClamp(DeltaTime / 0.04, 0, 1);
        else WorldPulls[H].GoalVelocity = vect(0,0,0);
        Terminal = T <= HomingHorizon;
        if (Terminal)
        {
            Magnet(H, Magazine, Gun, P, DeltaTime);
            WorldPulls[H].LastPosition = P;
            WorldPulls[H].LastGoal = WorldPulls[H].Goal;
            return;
        }
        T = FMax(T, HomingHorizon);
        Acc = ((WorldPulls[H].Goal - P) / T + WorldPulls[H].GoalVelocity - V) / T;
        if (!Terminal) Acc.Z -= 0.5 * WorldPulls[H].GravityZ * T;
        Size = VSize(Acc);
        if (Size > HomingMax) Acc *= HomingMax / Size;
        Ramp = FClamp((HomingStart - T) / HomingStart, 0, 1);
        Acc *= Ramp;
        // Gravity is integrated by the prop itself; compensate it separately
        // from the bounded positional correction (including lowering palms).
        if (Terminal) Acc.Z -= WorldPulls[H].GravityZ;
        Acc *= DeltaTime;
        if (Magazine != None) { Magazine.Linear += Acc; Magazine.bGrounded = false; SteerPile(H, Magazine, DeltaTime); }
        else if (Gun != None && Gun.MyMeshComp != None) Gun.MyMeshComp.SetRBLinearVelocity(Acc, true);
    }
    WorldPulls[H].LastPosition = P;
    WorldPulls[H].LastGoal = WorldPulls[H].Goal;
    WorldPulls[H].bHaveLast = true;
}

// Arrived: drive the catch contact onto the palm at the palm's own velocity.
// Each prop integrates its own gravity, so this step's share is added back.
function Magnet(int H, VRWorldDropMagazine Magazine, VRWorldDropGun Gun, vector P, float DeltaTime)
{
    local vector Desired, Correction;
    Correction = (WorldPulls[H].Goal - P) / MagnetSeconds;
    if (VSize(Correction) > MagnetMaxSpeed) Correction = Normal(Correction) * MagnetMaxSpeed;
    Desired = WorldPulls[H].GoalVelocity + Correction;
    Desired.Z -= WorldPulls[H].GravityZ * DeltaTime;
    if (Magazine != None) { Magazine.Linear = Desired; Magazine.bGrounded = false; SteerPile(H, Magazine, DeltaTime); }
    else if (Gun != None && Gun.MyMeshComp != None)
    {
        Gun.MyMeshComp.SetRBLinearVelocity(Desired);
        // Settle its tumble so the grip it presents stays still to close on.
        Gun.MyMeshComp.SetRBAngularVelocity(Gun.MyMeshComp.BodyInstance != None
            ? Gun.MyMeshComp.BodyInstance.GetUnrealWorldAngularVelocity() * FClamp(1 - DeltaTime / 0.15, 0, 1)
            : vect(0,0,0));
        Gun.bForceNetUpdate = true;
    }
}

function EndWorldPull(int H)
{
    local VRWorldDropGun Gun;
    Gun = VRWorldDropGun(WorldPulls[H].Prop);
    if (Gun != None && Gun.GravityReturnOwner == self)
    { Gun.GravityReturnOwner = None; Gun.GravityReturnUntil = 0; }
    if (WorldPulls[H].Prop != None && Claimed[H] == WorldPulls[H].Prop) Claimed[H] = None;
    WorldPulls[H].Prop = None;
    WorldPulls[H].Pile.Length = 0;
}

// R22 cluster pull: the other loose rounds of a pulled pile launch with it and
// trail it to the hand, where one grip scoops them all (ScoopInto). They stay
// ordinary world rounds: nothing is claimed or credited in flight.
function LaunchPile(int H, Actor Target, vector V, KFPawn_Human P)
{
    local array<VRWorldDropMagazine> Near;
    local int I;
    WorldPulls[H].Pile.Length = 0;
    if (VRWorldDropMagazine(Target) == None || VRWorldDropMagazine(Target).PayloadKind != 1) return;
    class'VRWorldDropMagazine'.static.LooseRoundsNear(VRWorldDropMagazine(Target),
        class'VRWorldDropMagazine'.const.PileRadius, Near);
    for (I = 0; I < Near.Length; ++I)
        if (Near[I].CanPickupBy(P) && !IsClaimed(Near[I]) && LaunchWorldProp(Near[I], V))
            WorldPulls[H].Pile.AddItem(Near[I]);
}

function SteerPile(int H, VRWorldDropMagazine Lead, float DeltaTime)
{
    local int I;
    local VRWorldDropMagazine M;
    for (I = WorldPulls[H].Pile.Length - 1; I >= 0; --I)
    {
        M = WorldPulls[H].Pile[I];
        if (M == None || M.bDeleteMe || M.Carrier != None) { WorldPulls[H].Pile.Remove(I, 1); continue; }
        // Match the lead's velocity and close the gap within about 0.15 s.
        M.Linear = Lead.Linear + (Lead.Location - M.Location) * FClamp(DeltaTime / 0.15, 0, 1) / FMax(DeltaTime, 0.001);
        M.bGrounded = false;
        M.bForceNetUpdate = true;
    }
}

function Claim(byte Hand, Actor Target)
{
    Claimed[Hand] = Target;
    ClaimHidden[Hand] = 0;
    // A dropped pickup leaves the floor for the flight; nobody else can touch
    // it. A factory stays put (the flight hides its mesh locally) and keeps
    // stock respawn rules; it is only reserved against a second pull.
    if (KFDroppedPickup(Target) != None)
    {
        ClaimCollide[Hand] = byte(Target.bCollideActors);
        ClaimBlock[Hand] = byte(Target.bBlockActors);
        Target.SetHidden(true);
        Target.SetCollision(false, false);
        ClaimHidden[Hand] = 1;
    }
}

// An uncaught or refused pull leaves a dropped pickup at the puller's feet,
// where Alyx's would have fallen, back in its stock state.
function ReleaseClaim(byte Hand, bool bConsumed, optional vector DropNear)
{
    local Actor A;
    local vector HitLocation, HitNormal, Floor;
    A = Claimed[Hand];
    Claimed[Hand] = None;
    if (A == None || A.bDeleteMe || bConsumed || ClaimHidden[Hand] == 0) return;
    if (DropNear != vect(0,0,0))
    {
        Floor = DropNear;
        if (Trace(HitLocation, HitNormal, DropNear - vect(0,0,400), DropNear, false) != None)
            Floor = HitLocation + vect(0,0,6);
        A.SetLocation(Floor);
    }
    A.SetCollision(ClaimCollide[Hand] != 0, ClaimBlock[Hand] != 0);
    A.SetHidden(false);
    A.bForceNetUpdate = true;
}

function FlightEnded(VRGravityPullFlight Flight, byte Result)
{
    local int H;
    for (H = 0; H < 2; ++H)
        if (Flights[H] == Flight)
        {
            if (Result != 1) ReleaseClaim(H, false, Flight.Location);
            Flights[H] = None;
        }
}

reliable server function ServerCatch(int Request, byte Hand, VRGravityPullFlight Flight)
{
    local KFPawn_Human P;
    local Actor A;
    local KFDroppedPickup Drop;
    local KFPickupFactory Factory;
    local class<Inventory> Given;
    local KFWeapon W, Caught;
    local KFInventoryManager IM;
    local bool bTaken;
    local byte Reason;
    if (Request <= LastRequest) return;
    LastRequest = Request;
    P = Puller();
    if (P == None || Hand > 1 || Flight == None || Flight.bDeleteMe || Flights[Hand] != Flight
        || Flight.Outcome != 0 || Flight.Elapsed() < Flight.TravelTime - 0.4)
    { SendReply(Request, Hand, 1, false, 1); return; }
    A = Claimed[Hand];
    if (A == None || A.bDeleteMe) { Flight.Resolve(2); SendReply(Request, Hand, 1, false, 2); return; }
    if (!PullableClass(A)) { Flight.Resolve(2); SendReply(Request, Hand, 1, false, 1); return; }
    Drop = KFDroppedPickup(A);
    Factory = KFPickupFactory(A);
    if (Drop != None)
    {
        Given = Drop.InventoryClass;
        // Stock pickup, unchanged: limits, duplicates, dosh credit and messages.
        A.SetHidden(false);
        Drop.GiveTo(P);
        bTaken = Drop.bDeleteMe;
        IM = KFInventoryManager(P.InvManager);
        if (bTaken && class<KFWeapon>(Given) != None && IM != None)
            foreach IM.InventoryActors(class'KFWeapon', W)
                if (W.Class == Given || W.Class == class<KFWeapon>(Given).default.DualClass) Caught = W;
        if (!bTaken) A.SetHidden(true);
    }
    else if (Factory != None)
    {
        // Factories stay touchable during flight; recheck before the stock grant.
        Reason = Eligibility(Factory, P);
        if (Reason != 0)
        { Flight.Resolve(2); SendReply(Request, Hand, 1, false, Reason); return; }
        Factory.GiveTo(P);
        bTaken = Factory.bPickupHidden || !Factory.IsInState('Pickup');
    }
    if (bTaken) Claimed[Hand] = None;
    Flight.Resolve(bTaken ? 1 : 2);
    SendReply(Request, Hand, 1, bTaken, bTaken ? 0 : 3, Flight, Caught);
}

event Tick(float DeltaTime)
{
    local int H;
    local vector Palm;
    Super.Tick(DeltaTime);
    if (Role != ROLE_Authority) return;
    if (Owner == None || Owner.bDeleteMe) { Destroy(); return; }
    for (H = 0; H < 2; ++H)
    {
        if (CurrentPalm(H, Palm))
        {
            WorldPulls[H].Goal = Palm;
            if (Flights[H] != None && !Flights[H].bDeleteMe && Flights[H].Outcome == 0)
                Flights[H].SetHandGoal(Palm + vect(0,0,7.6));
        }
        if (WorldPulls[H].Prop != None) { SteerWorldProp(H, DeltaTime); continue; }
        if (Claimed[H] != None && !PullableClass(Claimed[H]))
        {
            // Restore the stock pickup immediately if an obsolete gun claim survived.
            ReleaseClaim(H, false);
            if (Flights[H] != None && !Flights[H].bDeleteMe) Flights[H].Resolve(2);
        }
        if (Claimed[H] != None && (Flights[H] == None || Flights[H].bDeleteMe))
            ReleaseClaim(H, false, Puller() != None ? Puller().Location : vect(0,0,0));
    }
}

event Destroyed()
{
    local int H;
    for (H = 0; H < 2; ++H)
    {
        if (Flights[H] != None && !Flights[H].bDeleteMe) Flights[H].Resolve(2);
        EndWorldPull(H);
        ReleaseClaim(H, false);
    }
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    bReplicateMovement=false
    bHidden=true
    bHostAllowed=true
    NetUpdateFrequency=30
}
