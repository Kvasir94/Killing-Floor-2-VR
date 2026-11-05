// Magazines that leave the hand or the gun during a physical reload: they fall
// in the world carrying the motion they left with, tumble, bounce off whatever
// they land on with that surface's stock shell-bounce sound, skid, tip over
// onto their side and stay a while, then sink away, independent of the reload
// session that dropped them. Local presentation only: no
// collision, physics actor or network state.
class VRDroppedMagazines extends Object;

// R22: cosmetic ejected cases linger this long before sinking away.
const CaseLinger = 8.5;

struct DroppedMagazine
{
    var MeshComponent Mesh;
    var vector Position, Velocity, Spin, Centre, FlatAxis, Floor;
    var quat Rotation, SettleFrom, SettleTo;
    var float Scale, HalfThickness, Started, Landed;
    var int Bounces;
    var bool bLive, bSliding, bResting;
    // A magazine from a well first slides out along it (ExitAxis, in the
    // gun root's frame) before tumbling.
    var KFWeapon ExitGun;
    var name ExitRoot;
    var vector ExitLocal, ExitAxis;
    var quat ExitLocalQ;
    var float ExitTravel, ExitDistance, ExitSpeed, ExitTimeout;
    // Realistic ammo: the rounds a pulled magazine took with it and the gun
    // it came from. Picking it up returns them to that gun's reserve.
    var int Rounds;
    var byte AmmoSlot, PayloadKind;
    var class<KFWeapon> MagClass;
    // A carry owns this exact slot incarnation, never the next prop reused
    // here. Generation also advances on reacquisition after a release.
    var int Generation;
    var bool bLeased;
    var KFWeapon SourceWeapon;
    var int RemovalToken;
    // Optional authored contact, captured without rebinding a live reload.
    var name CarryAnim, CarryTrack;
    var float CarryTime;
    var int StockHand;
    // World authority owns this payload. This slot is only its local hand mesh.
    var VRWorldDropMagazine WorldProp;
    // A fresh pouch magazine let go before it was paid (#26): only a picture
    // of the carry, which the same reload can catch back. No ammunition.
    var KFWeapon FreshGun;
};
var DroppedMagazine Props[10];
var int LastSlot;
var VRHandsBridge Bridge;
// Surface type (EMaterialTypes) to WW_WEP_Bullet_Impacts.Play_ShellBounce_*.
var array<AkEvent> BounceSounds;
var AkEvent DefaultBounce;
// Restitution is along the hit normal; Friction keeps that share of the
// sliding speed per bounce, SlideDrag slows a skid on the floor.
var float Gravity, Restitution, Friction, SlideDrag, RestSpeed, SettleTime, Linger, SinkTime;

function Initialize(VRHandsBridge B)
{
    Bridge = B;
}

// Cosmetic cartridge users can reserve their complete bounded pool before an
// ejection, avoiding a partly allocated batch and a duplicate stock fallback.
function bool PrepareComponents(bool bSkeletal)
{
    local int I;
    if (Bridge == None) return false;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (Props[I].Mesh != None) continue;
        if (bSkeletal) Props[I].Mesh = new(Bridge) class'KFSkeletalMeshComponent';
        else Props[I].Mesh = new(Bridge) class'StaticMeshComponent';
        if (Props[I].Mesh == None) return false;
        Props[I].Mesh.SetAbsolute(true, true, true);
        Props[I].Mesh.SetActorCollision(false, false);
        Props[I].Mesh.SetTraceBlocking(false, false);
        Props[I].Mesh.CastShadow = false;
        Props[I].Mesh.SetHidden(true);
        Bridge.AttachComponent(Props[I].Mesh);
    }
    return true;
}

function AkEvent LoadBounce(string Surface)
{
    return AkEvent(DynamicLoadObject("WW_WEP_Bullet_Impacts.Play_ShellBounce_" $ Surface, class'AkEvent', true));
}

// The stock surface families, as the shell-bounce bank names them.
function AkEvent BounceFor(PhysicalMaterial Material)
{
    local KFPhysicalMaterialProperty Property;
    local int Type;
    if (DefaultBounce == None)
    {
        DefaultBounce = LoadBounce("Stone");
        BounceSounds.Length = 64;
        BounceSounds[EMT_Rock] = DefaultBounce;
        BounceSounds[EMT_Dirt] = LoadBounce("Dirt");
        BounceSounds[EMT_Dust] = BounceSounds[EMT_Dirt];
        BounceSounds[EMT_Sand] = BounceSounds[EMT_Dirt];
        BounceSounds[EMT_Paper] = BounceSounds[EMT_Dirt];
        BounceSounds[EMT_Mud] = LoadBounce("Mud");
        BounceSounds[EMT_Poop] = BounceSounds[EMT_Mud];
        BounceSounds[EMT_Grass] = LoadBounce("Grass");
        BounceSounds[EMT_Plant] = BounceSounds[EMT_Grass];
        BounceSounds[EMT_Water] = LoadBounce("Water");
        BounceSounds[EMT_WaterShallow] = BounceSounds[EMT_Water];
        BounceSounds[EMT_Snow] = LoadBounce("Snow");
        BounceSounds[EMT_Metal] = LoadBounce("Metal");
        BounceSounds[EMT_MetalArmor] = BounceSounds[EMT_Metal];
        BounceSounds[EMT_MetalHollow] = LoadBounce("Metal_Hollow");
        BounceSounds[EMT_Wood] = LoadBounce("Wood");
        BounceSounds[EMT_WoodHollow] = BounceSounds[EMT_Wood];
        BounceSounds[EMT_BrickRed] = LoadBounce("Brick");
        BounceSounds[EMT_BrickWhite] = BounceSounds[EMT_BrickRed];
        BounceSounds[EMT_Plaster] = BounceSounds[EMT_BrickRed];
        BounceSounds[EMT_Glass] = LoadBounce("Glass");
        BounceSounds[EMT_GlassBroken] = BounceSounds[EMT_Glass];
        BounceSounds[EMT_Ice] = BounceSounds[EMT_Glass];
        BounceSounds[EMT_Rubber] = LoadBounce("Rubber");
        BounceSounds[EMT_Cloth] = BounceSounds[EMT_Rubber];
        BounceSounds[EMT_PlasticBag] = BounceSounds[EMT_Rubber];
        BounceSounds[EMT_Flesh] = LoadBounce("Flesh");
    }
    if (Material != None)
        Property = KFPhysicalMaterialProperty(Material.GetPhysicalMaterialProperty(class'KFPhysicalMaterialProperty'));
    Type = Property != None ? int(Property.MaterialType) : -1;
    if (Type >= 0 && Type < BounceSounds.Length && BounceSounds[Type] != None) return BounceSounds[Type];
    return DefaultBounce;
}

// Centre is the prop's middle in its own frame; FlatAxis its thinnest local
// axis, which faces up once it lies down.
function bool Drop(StaticMesh Mesh, MaterialInterface Surface0, MaterialInterface Surface1, vector Position,
    quat Rotation, vector Velocity, float Scale, vector Centre, vector Extent, optional MaterialInterface Surface2, optional KFWeapon ExitGun, optional name ExitRoot,
    optional vector ExitAxis, optional SkeletalMesh Skeletal)
{
    local int I, Slot;
    local vector Axis;
    local quat RootQ;
    // A failed drop must not leave TagLast pointing at an older magazine.
    LastSlot = -1;
    if (Bridge == None || (Mesh == None && Skeletal == None)) return false;
    Slot = -1;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (Props[I].bLeased || Props[I].Generation == MaxInt) continue;
        if (!Props[I].bLive) { Slot = I; break; }
        if (Slot < 0 || Props[I].Started < Props[Slot].Started) Slot = I;
    }
    // A bounded cosmetic pool must never evict somebody's carried escrow.
    if (Slot < 0) return false;
    if (Props[Slot].Mesh != None
        && ((Skeletal != None) != (SkeletalMeshComponent(Props[Slot].Mesh) != None)))
    {
        Bridge.DetachComponent(Props[Slot].Mesh);
        Props[Slot].Mesh = None;
    }
    if (Props[Slot].Mesh == None)
    {
        if (Skeletal != None) Props[Slot].Mesh = new(Bridge) class'KFSkeletalMeshComponent';
        else Props[Slot].Mesh = new(Bridge) class'StaticMeshComponent';
        if (Props[Slot].Mesh == None) return false;
        Props[Slot].Mesh.SetAbsolute(true, true, true);
        Props[Slot].Mesh.SetActorCollision(false, false);
        Props[Slot].Mesh.SetTraceBlocking(false, false);
        Props[Slot].Mesh.CastShadow = false;
        Bridge.AttachComponent(Props[Slot].Mesh);
    }
    if (Skeletal != None) SkeletalMeshComponent(Props[Slot].Mesh).SetSkeletalMesh(Skeletal);
    else StaticMeshComponent(Props[Slot].Mesh).SetStaticMesh(Mesh);
    Props[Slot].Mesh.SetMaterial(0, Surface0);
    Props[Slot].Mesh.SetMaterial(1, Surface1);
    if (Surface2 != None) Props[Slot].Mesh.SetMaterial(2, Surface2);
    Props[Slot].Mesh.SetHidden(false);
    Props[Slot].Position = Position;
    Props[Slot].Rotation = Rotation;
    Props[Slot].Velocity = Velocity;
    // A tumble about a horizontal axis, as a released magazine turns; a
    // flicked one spins faster.
    Props[Slot].Spin = Normal(vect(1,0,0) * (FRand() - 0.5) + vect(0,1,0) * (FRand() - 0.5))
        * (2.0 + 3.0 * FRand() + FMin(VSize(Velocity) / 100.0, 8.0));
    Props[Slot].Scale = Scale;
    Props[Slot].Centre = Centre;
    Props[Slot].FlatAxis = (Extent.X <= Extent.Y && Extent.X <= Extent.Z) ? vect(1,0,0)
        : (Extent.Y <= Extent.Z ? vect(0,1,0) : vect(0,0,1));
    Props[Slot].HalfThickness = FMin(Extent.X, FMin(Extent.Y, Extent.Z));
    Props[Slot].Started = Bridge.WorldInfo.TimeSeconds;
    Props[Slot].Bounces = 0;
    Props[Slot].bSliding = false;
    Props[Slot].bResting = false;
    Props[Slot].bLive = true;
    ++Props[Slot].Generation;
    Props[Slot].bLeased = false;
    Props[Slot].Rounds = 0; Props[Slot].MagClass = None; Props[Slot].AmmoSlot = 0; Props[Slot].PayloadKind = 0;
    Props[Slot].SourceWeapon = None; Props[Slot].RemovalToken = 0;
    Props[Slot].CarryAnim = ''; Props[Slot].CarryTrack = '';
    Props[Slot].CarryTime = 0; Props[Slot].StockHand = 0;
    Props[Slot].WorldProp = None;
    Props[Slot].FreshGun = None;
    LastSlot = Slot;
    Props[Slot].ExitGun = None;
    if (ExitGun != None && ExitGun.MySkelMesh != None && ExitRoot != '')
    {
        RootQ = ExitGun.MySkelMesh.GetBoneQuaternion(ExitRoot);
        Props[Slot].ExitGun = ExitGun; Props[Slot].ExitRoot = ExitRoot;
        Props[Slot].ExitLocal = QuatRotateVector(QuatInvert(RootQ),
            Position - ExitGun.MySkelMesh.GetBoneLocation(ExitRoot));
        Props[Slot].ExitLocalQ = QuatProduct(QuatInvert(RootQ), Rotation);
        Props[Slot].ExitAxis = VSize(ExitAxis) > 0.5 ? Normal(ExitAxis) : vect(0,0,-1);
        Axis = QuatRotateVector(QuatInvert(Rotation), QuatRotateVector(RootQ, Props[Slot].ExitAxis));
        Props[Slot].ExitDistance = 2 * Scale
            * (Abs(Axis.X) * Extent.X + Abs(Axis.Y) * Extent.Y + Abs(Axis.Z) * Extent.Z);
        Props[Slot].ExitTravel = 0; Props[Slot].ExitSpeed = 100;
        Props[Slot].ExitTimeout = 0.25;
        // Caulk's 27 UU tube assembly cannot clear in the usual quarter
        // second. Keep its acquired rail until the measured length clears,
        // with a bounded fallback when an upward/inverted extraction stalls.
        if (ExitGun.Class == class'KFWeap_Flame_CaulkBurn')
            Props[Slot].ExitTimeout = FClamp(0.1 + Props[Slot].ExitDistance / Props[Slot].ExitSpeed, 0.25, 0.65);
    }
    Place(Slot);
    return true;
}

// The magazine just dropped still holds Rounds of W's ammunition.
function TagLast(int Rounds, class<KFWeapon> MagClass)
{
    if (Rounds <= 0) return;
    TagLastDetails(Rounds, MagClass);
}

// Metadata only: RemovalToken identifies authority's removal, not new ammo.
// Zero-round magazines may be described explicitly; legacy TagLast is unchanged.
function bool TagLastDetails(int Rounds, class<KFWeapon> MagClass, optional KFWeapon SourceWeapon,
    optional int RemovalToken, optional name CarryAnim, optional name CarryTrack,
    optional float CarryTime, optional int StockHand)
{
    if (Rounds < 0 || MagClass == None || LastSlot < 0 || LastSlot >= ArrayCount(Props)
        || !Props[LastSlot].bLive || Props[LastSlot].bLeased || RemovalToken < 0
        || (SourceWeapon != None && SourceWeapon.bDeleteMe)) return false;
    if ((CarryAnim != '' || CarryTrack != '')
        && (CarryAnim == '' || CarryTrack == '' || !(CarryTime >= 0 && CarryTime < 1000000)
            || StockHand < 0 || StockHand > 1)) return false;
    Props[LastSlot].Rounds = Rounds;
    Props[LastSlot].MagClass = MagClass;
    Props[LastSlot].SourceWeapon = SourceWeapon;
    Props[LastSlot].RemovalToken = RemovalToken;
    Props[LastSlot].CarryAnim = CarryAnim; Props[LastSlot].CarryTrack = CarryTrack;
    Props[LastSlot].CarryTime = CarryTime; Props[LastSlot].StockHand = StockHand;
    return true;
}

function bool Acquire(int I, out int Generation)
{
    Generation = 0;
    if (Bridge == None || I < 0 || I >= ArrayCount(Props) || !Props[I].bLive
        || Props[I].bLeased || Props[I].Mesh == None || Props[I].Generation == MaxInt) return false;
    ++Props[I].Generation;
    Props[I].bLeased = true;
    Props[I].ExitGun = None;
    Generation = Props[I].Generation;
    return true;
}

function bool LeaseValid(int I, int Generation)
{
    return Bridge != None && I >= 0 && I < ArrayCount(Props) && Generation > 0
        && Props[I].bLive && Props[I].bLeased && Props[I].Mesh != None
        && Props[I].Generation == Generation;
}

// Import only after the authored hand recipe has been preflighted. The world
// actor remains the payload identity even when its original gun disappears.
function int ImportWorld(VRWorldDropMagazine Prop, name Anim, name Track, float Time, int StockHand)
{
    local StaticMesh Asset;
    local SkeletalMesh RoundAsset;
    local MaterialInterface S0, S1, S2;
    local float Scale;
    if (Prop == None || Prop.bDeleteMe || Prop.Family == None || Prop.RemovalToken <= 0) return -1;
    RoundAsset = Prop.RecoverySkeletal(S0);
    Scale = Prop.Visual.Scale > 0 ? Prop.Visual.Scale : 1.0;
    if (RoundAsset == None && !Prop.GetVisual(Asset, S0, S1, S2, Scale)) return -1;
    if (!Drop(Asset, S0, S1, Prop.Location, QuatFromRotator(Prop.Rotation), vect(0,0,0),
        Scale, vect(0,0,0), vect(1,1,1), S2, None, '', vect(0,0,0), RoundAsset)) return -1;
    Props[LastSlot].WorldProp = Prop;
    Props[LastSlot].Rounds = Prop.Rounds;
    Props[LastSlot].AmmoSlot = Prop.AmmoSlot; Props[LastSlot].PayloadKind = Prop.PayloadKind;
    Props[LastSlot].MagClass = Prop.Family;
    Props[LastSlot].SourceWeapon = Prop.SourceWeapon;
    Props[LastSlot].RemovalToken = Prop.RemovalToken;
    Props[LastSlot].CarryAnim = Anim; Props[LastSlot].CarryTrack = Track;
    Props[LastSlot].CarryTime = Time; Props[LastSlot].StockHand = StockHand;
    return LastSlot;
}

// Carry/guide poses name the mesh's origin; falling Props store its centre.
function bool MoveLease(int I, int Generation, vector Origin, quat Rotation)
{
    local vector CentrePosition;
    if (!LeaseValid(I, Generation) || !class'VRReloadMotionGuard'.static.ValidPosition(Origin)
        || !class'VRHandRolePose'.static.ValidQuaternion(Rotation)
        || !(Props[I].Scale > 0 && Props[I].Scale < 1000000)) return false;
    CentrePosition = Origin + QuatRotateVector(Rotation, Props[I].Centre * Props[I].Scale);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(CentrePosition)) return false;
    Props[I].Position = CentrePosition;
    Props[I].Rotation = Rotation;
    Place(I);
    return true;
}

// Callers supply measured release motion; safety cancellation supplies zero.
// No random impulse or old well-exit motion is manufactured on release.
function bool ReleaseLease(int I, int Generation, vector Velocity, optional vector Spin)
{
    if (!LeaseValid(I, Generation)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Velocity)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Spin)) return false;
    if (Props[I].WorldProp != None)
    {
        // Releasing a local import reveals the existing authority actor; it
        // must never make a second falling magazine with the same paid token.
        Props[I].bLeased = false;
        Take(I);
        Props[I].WorldProp = None;
        return true;
    }
    Props[I].Velocity = Velocity; Props[I].Spin = Spin;
    // A magazine flung from the hand flinches a Zed it meets (authority side).
    if (VSizeSq(Velocity) >= Square(220.0)) Bridge.RequestThrownFlinch(Props[I].Position, Velocity);
    Props[I].ExitGun = None;
    Props[I].bSliding = false; Props[I].bResting = false;
    Props[I].Bounces = 0; Props[I].Landed = 0;
    Props[I].Started = Bridge.WorldInfo.TimeSeconds;
    Props[I].bLeased = false;
    Place(I);
    return true;
}

// Only a confirmed destination receipt may call this. Partial consumption
// retains the lease and its remaining rounds; complete consumption retires it.
function int ConsumeLease(int I, int Generation, int ConfirmedRounds)
{
    if (!LeaseValid(I, Generation) || ConfirmedRounds <= 0 || ConfirmedRounds > Props[I].Rounds) return 0;
    Props[I].Rounds -= ConfirmedRounds;
    if (Props[I].Rounds == 0)
    {
        if (Props[I].WorldProp != None) Props[I].WorldProp.SetLocalLease(false);
        Props[I].bLive = false; Props[I].bLeased = false;
        Props[I].MagClass = None; Props[I].SourceWeapon = None; Props[I].RemovalToken = 0;
        Props[I].CarryAnim = ''; Props[I].CarryTrack = '';
        Props[I].WorldProp = None;
        Props[I].ExitGun = None;
        Props[I].Mesh.SetHidden(true);
    }
    return ConfirmedRounds;
}

// A confirmed empty-magazine destination consumes its visual, not ammunition.
function bool RetireEmptyLease(int I, int Generation)
{
    if (!LeaseValid(I, Generation) || Props[I].Rounds != 0) return false;
    if (Props[I].WorldProp != None) Props[I].WorldProp.SetLocalLease(false);
    Props[I].bLive = false; Props[I].bLeased = false;
    Props[I].MagClass = None; Props[I].SourceWeapon = None; Props[I].RemovalToken = 0;
    Props[I].CarryAnim = ''; Props[I].CarryTrack = '';
    Props[I].WorldProp = None;
    Props[I].ExitGun = None;
    Props[I].Mesh.SetHidden(true);
    return true;
}

// The nearest live magazine still holding rounds within Radius of P, or -1.
function int FindLoaded(vector P, float Radius, out class<KFWeapon> MagClass, out int Rounds)
{
    local int I, Best;
    local float Distance, BestDistance;
    Best = -1;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (!Props[I].bLive || Props[I].bLeased || Props[I].Rounds <= 0 || Props[I].MagClass == None) continue;
        Distance = VSize(Props[I].Position - P);
        if (Distance <= Radius && (Best < 0 || Distance < BestDistance)) { Best = I; BestDistance = Distance; }
    }
    if (Best >= 0) { MagClass = Props[Best].MagClass; Rounds = Props[Best].Rounds; }
    return Best;
}

// Partly pocketed (the reserve filled): the magazine keeps the rest.
function SetRounds(int I, int Rounds)
{
    if (I < 0 || I >= ArrayCount(Props) || !Props[I].bLive || Props[I].bLeased) return;
    Props[I].Rounds = Max(Rounds, 0);
}

function TagLastFresh(KFWeapon W)
{
    if (W == None || LastSlot < 0 || LastSlot >= ArrayCount(Props) || !Props[LastSlot].bLive
        || Props[LastSlot].bLeased || Props[LastSlot].Rounds > 0) return;
    Props[LastSlot].FreshGun = W;
}

// The nearest caught-back candidate: a fresh carry of W within Radius of P,
// in the air or lying where it fell. -1 when there is none.
function int FindFresh(KFWeapon W, vector P, float Radius)
{
    local int I, Best;
    local float Distance, BestDistance;
    Best = -1;
    if (W == None) return -1;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (!Props[I].bLive || Props[I].bLeased || Props[I].FreshGun != W) continue;
        Distance = VSize(Props[I].Position - P);
        if (Distance <= Radius && (Best < 0 || Distance < BestDistance)) { Best = I; BestDistance = Distance; }
    }
    return Best;
}

// Picked up: the magazine leaves the world at once.
function Take(int I)
{
    if (I < 0 || I >= ArrayCount(Props) || !Props[I].bLive || Props[I].bLeased) return;
    if (Props[I].WorldProp != None) Props[I].WorldProp.SetLocalLease(false);
    Props[I].bLive = false;
    Props[I].Rounds = 0; Props[I].MagClass = None;
    Props[I].SourceWeapon = None; Props[I].RemovalToken = 0;
    Props[I].CarryAnim = ''; Props[I].CarryTrack = '';
    Props[I].WorldProp = None;
    Props[I].FreshGun = None;
    Props[I].ExitGun = None;
    if (Props[I].Mesh != None) Props[I].Mesh.SetHidden(true);
}

function Place(int I, optional float Sink)
{
    Props[I].Mesh.SetTranslation(Props[I].Position - vect(0,0,1) * Sink
        - QuatRotateVector(Props[I].Rotation, Props[I].Centre * Props[I].Scale));
    Props[I].Mesh.SetRotation(QuatToRotator(Props[I].Rotation));
    Props[I].Mesh.SetScale(Props[I].Scale);
}

function Tick(float Delta)
{
    local float Remaining, Slice;
    local int Steps;
    if (Bridge == None || Delta <= 0) return;
    // Cosmetic/local props follow the same baseline as recoverable world
    // magazines, even when the headset runs below 120 Hz. Bound hitch work.
    Remaining = FMin(Delta, 0.05);
    while (Remaining > 0 && Steps < 6)
    {
        Slice = FMin(Remaining, 1.0 / 120.0);
        Step(Slice);
        Remaining -= Slice;
        ++Steps;
    }
}

function Step(float Delta)
{
    local int I;
    local vector Next, HitLocation, HitNormal, Tangent, WorldExit;
    local TraceHitInfo HitInfo;
    local Actor Hit;
    local float Speed, Age, Slide;
    local quat RootQ;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (!Props[I].bLive || Props[I].bLeased) continue;
        Age = Bridge.WorldInfo.TimeSeconds - Props[I].Started;
        if (Age > Linger + SinkTime)
        {
            Props[I].bLive = false;
            Props[I].Mesh.SetHidden(true);
            continue;
        }
        if (Props[I].bResting)
        {
            // Tips over onto its side, then later sinks out of sight.
            if (Bridge.WorldInfo.TimeSeconds - Props[I].Landed < SettleTime + Delta)
                Props[I].Rotation = QuatSlerp(Props[I].SettleFrom, Props[I].SettleTo,
                    FMin((Bridge.WorldInfo.TimeSeconds - Props[I].Landed) / SettleTime, 1), true);
            Place(I, Age > Linger ? (Age - Linger) / SinkTime * 4 * Props[I].HalfThickness * Props[I].Scale : 0.0);
            continue;
        }
        if (Props[I].bSliding)
        {
            Slide = VSize(Props[I].Velocity);
            if (Slide <= SlideDrag * Delta) { Rest(I); continue; }
            Next = Props[I].Position + Props[I].Velocity * Delta;
            Hit = Bridge.Trace(HitLocation, HitNormal, Next - Props[I].Floor * (Props[I].HalfThickness * Props[I].Scale + 8),
                Next + Props[I].Floor * 8, false,, HitInfo);
            // Skidded off an edge: falls again.
            if (Hit == None || (HitNormal dot Props[I].Floor) < 0.7) { Props[I].bSliding = false; }
            else
            {
                Props[I].Floor = HitNormal;
                Props[I].Position = HitLocation + HitNormal * Props[I].HalfThickness * Props[I].Scale;
                Props[I].Velocity *= (Slide - SlideDrag * Delta) / Slide;
                Props[I].Rotation = QuatProduct(QuatFromAxisAndAngle(Normal(Props[I].Spin), VSize(Props[I].Spin) * Delta),
                    Props[I].Rotation);
                Props[I].Spin *= FMax(1 - 4 * Delta, 0);
                Place(I);
                continue;
            }
        }
        if (Props[I].ExitGun != None)
        {
            if (!Props[I].ExitGun.bDeleteMe && Props[I].ExitGun.MySkelMesh != None
                && Props[I].ExitTravel < Props[I].ExitDistance && Props[I].ExitSpeed > 0 && Age < Props[I].ExitTimeout)
            {
                RootQ = Props[I].ExitGun.MySkelMesh.GetBoneQuaternion(Props[I].ExitRoot);
                WorldExit = QuatRotateVector(RootQ, Props[I].ExitAxis);
                Props[I].ExitSpeed = FMax(0, Props[I].ExitSpeed - Gravity * WorldExit.Z * Delta);
                Props[I].ExitTravel = FMin(Props[I].ExitDistance,
                    Props[I].ExitTravel + Props[I].ExitSpeed * Delta);
                Props[I].Position = Props[I].ExitGun.MySkelMesh.GetBoneLocation(Props[I].ExitRoot)
                    + QuatRotateVector(RootQ, Props[I].ExitLocal + Props[I].ExitAxis * Props[I].ExitTravel);
                Props[I].Rotation = QuatProduct(RootQ, Props[I].ExitLocalQ);
                Place(I);
                continue;
            }
            // Remove the original world-down push, preserving gun-hand swing,
            // then use the single acquired speed along the magazine well.
            // Spin begins only once the top of the magazine clears the well.
            Props[I].Velocity += vect(0,0,60) + QuatRotateVector(Props[I].Rotation,
                QuatRotateVector(QuatInvert(Props[I].ExitLocalQ), Props[I].ExitAxis)) * Props[I].ExitSpeed;
            Props[I].ExitGun = None;
        }
        Props[I].Velocity.Z -= Gravity * Delta;
        Next = Props[I].Position + Props[I].Velocity * Delta;
        Props[I].Rotation = QuatProduct(QuatFromAxisAndAngle(Normal(Props[I].Spin), VSize(Props[I].Spin) * Delta),
            Props[I].Rotation);
        Hit = Bridge.Trace(HitLocation, HitNormal, Next + Normal(Props[I].Velocity) * Props[I].HalfThickness * Props[I].Scale,
            Props[I].Position, false,, HitInfo);
        if (Hit == None)
        {
            Props[I].Position = Next;
            Place(I);
            continue;
        }
        Speed = -(Props[I].Velocity dot HitNormal);
        if (Speed < 0) Speed = 0;
        if (Speed > 80 && Props[I].Bounces < 4)
            Bridge.PlaySoundBase(BounceFor(HitInfo.PhysMaterial), true,,, HitLocation);
        ++Props[I].Bounces;
        Props[I].Position = HitLocation + HitNormal * Props[I].HalfThickness * Props[I].Scale;
        // Bounce along the normal, keep most of the skid, and let the hit kick
        // the tumble: the end that strikes first gets thrown over.
        Tangent = Props[I].Velocity + HitNormal * Speed;
        Props[I].Velocity = Tangent * Friction + HitNormal * (Speed * Restitution);
        Props[I].Spin = Props[I].Spin * 0.4 + (HitNormal cross Tangent) * 0.02
            + Normal(VRand() cross HitNormal) * FMin(Speed / 60.0, 6.0) * FRand();
        if (HitNormal.Z >= 0.7 && (Speed * Restitution < RestSpeed || Props[I].Bounces >= 6))
        {
            // Too slow to leave the floor again: skid to a stop.
            Props[I].Velocity -= HitNormal * (Props[I].Velocity dot HitNormal);
            Props[I].Floor = HitNormal;
            Props[I].Spin = HitNormal * (FRand() - 0.5) * FMin(VSize(Props[I].Velocity) / 25.0, 10.0);
            Props[I].bSliding = true;
        }
        Place(I);
    }
}

// Tips onto its thinnest side over SettleTime, keeping its heading.
function Rest(int I)
{
    local vector Up, Axis;
    local float Angle;
    Up = QuatRotateVector(Props[I].Rotation, Props[I].FlatAxis);
    if ((Up dot Props[I].Floor) < 0) Up = -Up;
    Axis = Up cross Props[I].Floor;
    Angle = Acos(FClamp(Up dot Props[I].Floor, -1, 1));
    Props[I].SettleFrom = Props[I].Rotation;
    Props[I].SettleTo = Props[I].Rotation;
    if (VSize(Axis) > 0.0001)
        Props[I].SettleTo = QuatProduct(QuatFromAxisAndAngle(Normal(Axis), Angle), Props[I].Rotation);
    Props[I].Velocity = vect(0,0,0);
    Props[I].Landed = Bridge.WorldInfo.TimeSeconds;
    Props[I].bSliding = false;
    Props[I].bResting = true;
    Place(I);
}

function Shutdown()
{
    local int I;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (Props[I].WorldProp != None) Props[I].WorldProp.SetLocalLease(false);
        if (Props[I].Mesh != None && Bridge != None) Bridge.DetachComponent(Props[I].Mesh);
        Props[I].Mesh = None;
        Props[I].bLive = false;
        Props[I].bLeased = false;
        Props[I].Rounds = 0; Props[I].MagClass = None;
        Props[I].SourceWeapon = None; Props[I].RemovalToken = 0;
        Props[I].CarryAnim = ''; Props[I].CarryTrack = '';
        Props[I].WorldProp = None;
    }
}

defaultproperties
{
    Gravity=980
    Restitution=0.22
    Friction=0.7
    SlideDrag=450
    RestSpeed=45
    SettleTime=0.18
    Linger=30
    SinkTime=1.5
}
