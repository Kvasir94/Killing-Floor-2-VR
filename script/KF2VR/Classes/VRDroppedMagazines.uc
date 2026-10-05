// Magazines that leave the hand or the gun during a physical reload: they fall
// in the world carrying the motion they left with, tumble, bounce off whatever
// they land on with that surface's stock shell-bounce sound, skid, tip over
// onto their side and stay a while, then sink away, independent of the reload
// session that dropped them. Local presentation only: no
// collision, physics actor or network state.
class VRDroppedMagazines extends Object;

struct DroppedMagazine
{
    var StaticMeshComponent Mesh;
    var vector Position, Velocity, Spin, Centre, FlatAxis, Floor;
    var quat Rotation, SettleFrom, SettleTo;
    var float Scale, HalfThickness, Started, Landed;
    var int Bounces;
    var bool bLive, bSliding, bResting;
    // The Deagle magazine slides straight down its well before tumbling.
    var KFWeapon ExitGun;
    var name ExitRoot;
    var vector ExitLocal;
    var quat ExitLocalQ;
    var float ExitTravel, ExitDistance, ExitSpeed;
};
var DroppedMagazine Props[10];
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
function Drop(StaticMesh Mesh, MaterialInterface Surface0, MaterialInterface Surface1, vector Position,
    quat Rotation, vector Velocity, float Scale, vector Centre, vector Extent, optional MaterialInterface Surface2, optional KFWeapon ExitGun, optional name ExitRoot)
{
    local int I, Slot;
    local vector Axis;
    local quat RootQ;
    if (Bridge == None || Mesh == None) return;
    Slot = 0;
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (!Props[I].bLive) { Slot = I; break; }
        if (Props[I].Started < Props[Slot].Started) Slot = I;
    }
    if (Props[Slot].Mesh == None)
    {
        Props[Slot].Mesh = new(Bridge) class'StaticMeshComponent';
        Props[Slot].Mesh.SetAbsolute(true, true, true);
        Props[Slot].Mesh.SetActorCollision(false, false);
        Props[Slot].Mesh.SetTraceBlocking(false, false);
        Props[Slot].Mesh.CastShadow = false;
        Bridge.AttachComponent(Props[Slot].Mesh);
    }
    Props[Slot].Mesh.SetStaticMesh(Mesh);
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
    Props[Slot].ExitGun = None;
    if (ExitGun != None && ExitGun.MySkelMesh != None && ExitRoot != '')
    {
        RootQ = ExitGun.MySkelMesh.GetBoneQuaternion(ExitRoot);
        Props[Slot].ExitGun = ExitGun; Props[Slot].ExitRoot = ExitRoot;
        Props[Slot].ExitLocal = QuatRotateVector(QuatInvert(RootQ),
            Position - ExitGun.MySkelMesh.GetBoneLocation(ExitRoot));
        Props[Slot].ExitLocalQ = QuatProduct(QuatInvert(RootQ), Rotation);
        Axis = QuatRotateVector(QuatInvert(Rotation), QuatRotateVector(RootQ, vect(0,0,-1)));
        Props[Slot].ExitDistance = 2 * Scale
            * (Abs(Axis.X) * Extent.X + Abs(Axis.Y) * Extent.Y + Abs(Axis.Z) * Extent.Z);
        Props[Slot].ExitTravel = 0; Props[Slot].ExitSpeed = 60;
    }
    Place(Slot);
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
    local int I;
    local vector Next, HitLocation, HitNormal, Tangent;
    local TraceHitInfo HitInfo;
    local Actor Hit;
    local float Speed, Age, Slide;
    local quat RootQ;
    if (Bridge == None || Delta <= 0) return;
    Delta = FMin(Delta, 0.05);
    for (I = 0; I < ArrayCount(Props); ++I)
    {
        if (!Props[I].bLive) continue;
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
                && Props[I].ExitTravel < Props[I].ExitDistance && Age < 0.25)
            {
                RootQ = Props[I].ExitGun.MySkelMesh.GetBoneQuaternion(Props[I].ExitRoot);
                Props[I].ExitSpeed += Gravity * Delta;
                Props[I].ExitTravel = FMin(Props[I].ExitDistance,
                    Props[I].ExitTravel + Props[I].ExitSpeed * Delta);
                Props[I].Position = Props[I].ExitGun.MySkelMesh.GetBoneLocation(Props[I].ExitRoot)
                    + QuatRotateVector(RootQ, Props[I].ExitLocal + vect(0,0,-1) * Props[I].ExitTravel);
                Props[I].Rotation = QuatProduct(RootQ, Props[I].ExitLocalQ);
                Place(I);
                continue;
            }
            // Remove the original world-down push, preserving gun-hand swing,
            // then use the single acquired speed along the magazine well.
            // Spin begins only once the top of the magazine clears the well.
            Props[I].Velocity += vect(0,0,60) + QuatRotateVector(Props[I].Rotation,
                QuatRotateVector(QuatInvert(Props[I].ExitLocalQ), vect(0,0,-1))) * Props[I].ExitSpeed;
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
        if (Props[I].Mesh != None && Bridge != None) Bridge.DetachComponent(Props[I].Mesh);
        Props[I].Mesh = None;
        Props[I].bLive = false;
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
