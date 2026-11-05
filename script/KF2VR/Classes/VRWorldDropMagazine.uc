// Authority-simulated reload prop, visible to every player. The trusted
// reload transaction supplies escrowed rounds; clients never mint a budget.
class VRWorldDropMagazine extends Actor;

// R22: a grip scoops loose rounds within a hand's width; rounds lying this close
// together form a pile the gravity grab pulls as one.
const ScoopRadius = 12.0;
const PileRadius = 30.0;

struct MagazineVisual
{
    var StaticMesh StaticAsset;
    var SkeletalMesh SkeletalAsset;
    var MaterialInterface Surface0, Surface1, Surface2;
    var float Scale;
};
var repnotify MagazineVisual Visual;
var repnotify KFWeapon SourceWeapon;
var repnotify KFPawn_Human DropOwner;
var repnotify int Rounds;
var repnotify class<KFWeapon> Family;
var repnotify byte AmmoSlot, PayloadKind;
var repnotify int RemovalToken;
var repnotify KFPawn_Human Carrier;
var repnotify int CarrierHand;
var repnotify bool bPublic, bAllowOtherPlayers;
// R22: a loose round shrinks away over its last LapseSeconds (1 = whole).
var repnotify float Lapse;
var float LapseSeconds;
var VRWorldMagazineRegistry Registry;
var VRWorldMagazineRegistry CarrierRegistry;
var KFPawn_Human LastCarrier;
var float ReleasedAt;
var float NextCarryUpdate, NextLooseUpdate, LooseElapsed;
var vector CarryOffset;
var quat CarryOffsetQ;
var bool bCarryFrame;
var bool bRemovalPresented, bLocalLease;
var bool bGrounded;
var vector GroundPosition;
var MeshComponent DrawMesh;
var vector Linear, Angular;
// Only the original accepted removal may guide the part out of its well.
// Follow the existing hand stream until its full length clears, then fall.
var VRWorldMagazineRegistry ExitRegistry;
var int ExitHand;
var vector ExitOffset, ExitAxisLocal, ExitLastOrigin, ExitMotionVelocity;
var float ExitMotionTime;
var quat ExitRotation;
var float ExitTravel, ExitDistance, ExitSpeed;
var float Started, RestedAt;
// Authority only: a cylinder round waits hidden for its owner's chamber
// presentation, and shows where it is after this time if none arrives.
var float RevealAt;
var VRWorldDropReactions Reactions;
var repnotify VRWorldDropGun.ImpactPresentation LastImpact;

replication
{
    if (Role == ROLE_Authority)
        Visual, SourceWeapon, DropOwner, Rounds, bGrounded, GroundPosition, LastImpact,
        Family, AmmoSlot, PayloadKind, RemovalToken, Carrier, CarrierHand, bPublic, bAllowOtherPlayers, Lapse;
}

function bool Initialize(KFPawn_Human Human, KFWeapon W, MagazineVisual Look,
    vector ReleaseVelocity, vector Spin, int EscrowedRounds)
{
    if (Role != ROLE_Authority || Human == None || W == None || W.Owner != Human
        || (Look.StaticAsset == None && Look.SkeletalAsset == None)) return false;
    SourceWeapon = W;
    AmmoSlot = 0;
    DropOwner = Human;
    Visual = Look;
    Visual.Scale = FClamp(Look.Scale, 0.01, 8);
    Rounds = Max(EscrowedRounds, 0);
    Family = class'VRWeaponDropState'.static.FamilyFor(W.Class);
    Linear = ReleaseVelocity;
    if (VSize(Linear) > 1000) Linear = Normal(Linear) * 1000;
    Angular = Spin;
    if (VSize(Angular) > 8) Angular = Normal(Angular) * 8;
    Started = WorldInfo.TimeSeconds;
    BuildVisual();
    bForceNetUpdate = true;
    return true;
}

// Client-only asset loading: dedicated servers need neither KF2VRHands nor
// first-person rigs. The authority publishes an audited weapon family only.
simulated function bool GetVisual(out StaticMesh Asset, out MaterialInterface Surface0,
    out MaterialInterface Surface1, out MaterialInterface Surface2, out float Scale)
{
    local int Profile;
    local SkeletalMesh Rig, RoundRig;
    local int PumpProfile;
    Asset = Visual.StaticAsset;
    Surface0 = Visual.Surface0; Surface1 = Visual.Surface1; Surface2 = Visual.Surface2;
    Scale = Visual.Scale > 0 ? Visual.Scale : 1.0;
    if (WorldInfo.NetMode == NM_DedicatedServer) return false;
    if (PayloadKind == 1) return class'VRLiveRoundEjection'.static.RecoveryVisual(Family, Asset, Surface0);
    Profile = class'VRReloadCatalog'.static.FindClass(Family);
    if (AmmoSlot == 0 && class'VRBreakCatalog'.static.FindClass(Family) >= 0)
    {
        Profile = class'VRBreakCatalog'.static.FindClass(Family);
        if (Profile < 0) return false;
        Asset = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_"
            $ class'VRBreakCatalog'.default.Profiles[Profile].MeshName, class'StaticMesh', true));
        Rig = SkeletalMesh(DynamicLoadObject(Family.default.FirstPersonMeshName, class'SkeletalMesh', true));
        if (Rig != None)
        {
            Surface0 = Rig.Materials[class'VRBreakCatalog'.default.Profiles[Profile].MaterialIndex];
            Surface1 = Rig.Materials[class'VRBreakCatalog'.default.Profiles[Profile].Section1MaterialIndex];
        }
        if (class'VRBreakCatalog'.default.Profiles[Profile].Section1MaterialMesh != "")
        {
            RoundRig = SkeletalMesh(DynamicLoadObject(class'VRBreakCatalog'.default.Profiles[Profile].Section1MaterialMesh, class'SkeletalMesh', true));
            if (RoundRig != None && RoundRig.Materials.Length > 0) Surface1 = RoundRig.Materials[0];
        }
        return Asset != None;
    }
    PumpProfile = class'VRPumpCatalog'.static.FindClass(Family);
    if (AmmoSlot == 0 && PumpProfile >= 0)
    {
        Asset = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ class'VRPumpCatalog'.default.Profiles[PumpProfile].MeshName, class'StaticMesh', true));
        Rig = SkeletalMesh(DynamicLoadObject(Family.default.FirstPersonMeshName, class'SkeletalMesh', true));
        if (Rig != None && Rig.Materials.Length > 0) Surface0 = Rig.Materials[0];
        if (class'VRPumpCatalog'.default.Profiles[PumpProfile].AmmoMaterialMesh != "")
        {
            RoundRig = SkeletalMesh(DynamicLoadObject(class'VRPumpCatalog'.default.Profiles[PumpProfile].AmmoMaterialMesh, class'SkeletalMesh', true));
            if (RoundRig != None && RoundRig.Materials.Length > 0) Surface0 = RoundRig.Materials[0];
        }
        return Asset != None;
    }
    if (Profile >= 0)
    {
        Asset = StaticMesh(DynamicLoadObject((AmmoSlot == 1 ? "KF2VRHands.VRAmmo_Alt_" : "KF2VRHands.VRAmmo_")
            $ class'VRReloadCatalog'.default.Profiles[Profile].MeshName, class'StaticMesh', true));
        Rig = SkeletalMesh(DynamicLoadObject(Family.default.FirstPersonMeshName, class'SkeletalMesh', true));
        if (Rig != None)
        {
            if (AmmoSlot == 1)
            {
                Surface0 = Rig.Materials[(Family == class'KFWeap_AssaultRifle_M16M203'
                    || Family == class'KFWeap_AssaultRifle_HRGIncendiaryRifle') ? 1 : 0];
                Surface1 = None; Surface2 = None;
            }
            else if (class'VRReloadCatalog'.default.Profiles[Profile].MaterialIndex < Rig.Materials.Length)
                Surface0 = Rig.Materials[class'VRReloadCatalog'.default.Profiles[Profile].MaterialIndex];
            if (AmmoSlot == 0 && class'VRReloadCatalog'.default.Profiles[Profile].Section1MaterialIndex < Rig.Materials.Length)
                Surface1 = Rig.Materials[class'VRReloadCatalog'.default.Profiles[Profile].Section1MaterialIndex];
            if (AmmoSlot == 0 && class'VRReloadCatalog'.default.Profiles[Profile].Section2MaterialIndex > 0
                && class'VRReloadCatalog'.default.Profiles[Profile].Section2MaterialIndex < Rig.Materials.Length)
                Surface2 = Rig.Materials[class'VRReloadCatalog'.default.Profiles[Profile].Section2MaterialIndex];
        }
    }
    return Asset != None;
}

simulated function SkeletalMesh RecoverySkeletal(out MaterialInterface Surface)
{
    local SkeletalMesh Asset;
    if (PayloadKind == 1) class'VRRevolverEjection'.static.RecoveryMesh(Family, Asset, Surface);
    return Asset;
}

simulated function BuildVisual()
{
    local StaticMesh Asset;
    local SkeletalMesh RoundAsset;
    local MaterialInterface Surface0, Surface1, Surface2;
    local float Scale;
    if (WorldInfo.NetMode == NM_DedicatedServer || AmmoSlot > 1) return;
    if (DrawMesh != None) { DrawMesh.SetScale((Visual.Scale > 0 ? Visual.Scale : 1.0) * LapseFactor()); return; }
    Surface0 = Visual.Surface0; Surface1 = Visual.Surface1; Surface2 = Visual.Surface2;
    Scale = Visual.Scale;
    RoundAsset = RecoverySkeletal(Surface0);
    if (RoundAsset != None)
    {
        DrawMesh = new(self) class'KFSkeletalMeshComponent';
        SkeletalMeshComponent(DrawMesh).SetSkeletalMesh(RoundAsset);
    }
    else if (Visual.SkeletalAsset != None)
    {
        DrawMesh = new(self) class'KFSkeletalMeshComponent';
        SkeletalMeshComponent(DrawMesh).SetSkeletalMesh(Visual.SkeletalAsset);
    }
    else if (GetVisual(Asset, Surface0, Surface1, Surface2, Scale))
    {
        DrawMesh = new(self) class'StaticMeshComponent';
        StaticMeshComponent(DrawMesh).SetStaticMesh(Asset);
    }
    if (DrawMesh == None) return;
    if (Surface0 != None) DrawMesh.SetMaterial(0, Surface0);
    if (Surface1 != None) DrawMesh.SetMaterial(1, Surface1);
    if (Surface2 != None) DrawMesh.SetMaterial(2, Surface2);
    DrawMesh.SetActorCollision(false, false);
    DrawMesh.SetTraceBlocking(false, false);
    DrawMesh.SetScale((Scale > 0 ? Scale : 1.0) * LapseFactor());
    DrawMesh.CastShadow = false;
    DrawMesh.SetHidden(bLocalLease);
    AttachComponent(DrawMesh);
}

// Authority: the ledger's seconds left before this loose round lapses.
function SetLapse(float TimeLeft)
{
    local float L;
    L = TimeLeft < 0 ? 1.0 : FClamp(TimeLeft / LapseSeconds, 0, 1);
    if (Abs(L - Lapse) < 0.05 && (L > 0 || Lapse <= 0)) return;
    Lapse = L; bNetDirty = true;
    BuildVisual();
}

// Other loose live rounds of Seed's family lying within Radius of it, for the
// scoop and the cluster pull (R22). Never Seed itself or a carried round.
static function int LooseRoundsNear(VRWorldDropMagazine Seed, float Radius, optional out array<VRWorldDropMagazine> Found)
{
    local VRWorldDropMagazine M;
    Found.Length = 0;
    if (Seed == None || Seed.bDeleteMe || Seed.PayloadKind != 1) return 0;
    foreach Seed.DynamicActors(class'VRWorldDropMagazine', M)
        if (M != Seed && !M.bDeleteMe && M.PayloadKind == 1 && M.Family == Seed.Family && M.AmmoSlot == Seed.AmmoSlot
            && M.Carrier == None && M.Rounds > 0 && VSize(M.Location - Seed.Location) <= Radius) Found.AddItem(M);
    return Found.Length;
}

simulated function float LapseFactor()
{
    return FClamp(Lapse, 0.05, 1.0);
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'AmmoSlot' || VarName == 'PayloadKind')
    { if (DrawMesh != None) DetachComponent(DrawMesh); DrawMesh = None; BuildVisual(); }
    else if (VarName == 'Visual' || VarName == 'Family' || VarName == 'Lapse') BuildVisual();
    else if (VarName == 'LastImpact')
    {
        if (LastImpact.Victim != None && LastImpact.Victim.Health > 0)
            LastImpact.Victim.TryPlayHitReactionAnim(LastImpact.Direction, LastImpact.Kind, 255);
    }
    else Super.ReplicatedEvent(VarName);
}

simulated function bool CanPickupBy(KFPawn_Human Human)
{
    return !bDeleteMe && Rounds > 0 && AmmoSlot <= 1 && PayloadKind <= 2
        && (PayloadKind == 0 || AmmoSlot == 0) && RemovalToken > 0 && Carrier == None && Family != None
        && Human != None && !Human.bDeleteMe && Human.Health > 0
        && (Human == DropOwner || bPublic || bAllowOtherPlayers);
}

// Importers suppress this renderer only while their leased local component
// draws the same magazine. Other clients continue seeing this world actor.
simulated function SetLocalLease(bool bLeased)
{
    bLocalLease = bLeased;
    if (DrawMesh != None) DrawMesh.SetHidden(bLocalLease);
}

// One accepted release/removal event may refine presentation. Counts always
// remain in the ledger. The short former-carrier window allows a receipt to
// arrive before the final pose without granting arbitrary world relocation.
function bool PresentFor(KFPawn_Human Human, vector At, rotator Facing,
    vector Velocity, float Scale, optional vector WellAxis, optional float WellDistance, optional int WellHand=-1)
{
    local bool bInitial;
    local vector HandAt, Offset;
    local rotator HandFacing;
    local quat HandQ;
    if (Role != ROLE_Authority || Registry == None || Human == None
        || !class'VRWorldDropTransfer'.static.ValidBody(Human)
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Velocity)
        || !(Scale >= 0.01 && Scale <= 8) || VSizeSq(At - Human.Location) > Square(250)
        || !FastTrace(At, Human.Location)) return false;
    bInitial = !bRemovalPresented && !bPublic && Human == DropOwner && Carrier == None;
    if (!bInitial && Human != Carrier && !(Carrier == None && Human == LastCarrier
        && WorldInfo.TimeSeconds - ReleasedAt <= 1)) return false;
    if (Human == Carrier)
    {
        if (CarrierRegistry == None || CarrierRegistry.bDeleteMe || CarrierRegistry.Human != Human
            || !CarrierRegistry.CarrierFrame(CarrierHand, HandAt, HandFacing)) return false;
        HandQ = QuatFromRotator(HandFacing);
        Offset = QuatRotateVector(QuatInvert(HandQ), At - HandAt);
        if (VSizeSq(Offset) > Square(30.0)) return false;
        // One visible authored carry frame supplies the rigid contact. Every
        // later movement comes from the already accepted hand pose stream.
        CarryOffset = Offset;
        CarryOffsetQ = QuatProduct(QuatInvert(HandQ), QuatFromRotator(Facing));
        bCarryFrame = true;
    }
    if (bInitial) bRemovalPresented = true;
    if (bInitial && RevealAt > 0) { RevealAt = 0; SetHidden(false); }
    ExitRegistry = None;
    if (bInitial && WellHand >= 0 && WellHand < 2 && WellDistance > 0 && WellDistance <= 60
        && class'VRReloadMotionGuard'.static.ValidPosition(WellAxis)
        && VSizeSq(WellAxis) > 0.9 && VSizeSq(WellAxis) < 1.1
        && Registry.CarrierFrame(WellHand, HandAt, HandFacing)
        && VSizeSq(At - HandAt) <= Square(110))
    {
        HandQ = QuatFromRotator(HandFacing);
        ExitRegistry = Registry; ExitHand = WellHand;
        ExitOffset = QuatRotateVector(QuatInvert(HandQ), At - HandAt);
        ExitRotation = QuatProduct(QuatInvert(HandQ), QuatFromRotator(Facing));
        ExitAxisLocal = QuatRotateVector(QuatInvert(HandQ), Normal(WellAxis));
        ExitDistance = WellDistance; ExitTravel = 0; ExitSpeed = 100;
        ExitLastOrigin = At; ExitMotionTime = WorldInfo.RealTimeSeconds;
        ExitMotionVelocity = Velocity + vect(0,0,60);
    }
    LastCarrier = None;
    SetLocation(At); SetRotation(Facing);
    Linear = VSize(Velocity) > 700 ? Normal(Velocity) * 700 : Velocity;
    Angular = vect(2,1,0);
    Visual.Scale = Scale;
    bGrounded = false;
    LooseElapsed = 0; NextLooseUpdate = WorldInfo.RealTimeSeconds;
    Started = WorldInfo.TimeSeconds;
    bForceNetUpdate = true; bNetDirty = true;
    BuildVisual();
    return true;
}

simulated function bool NearHand(vector At, optional float Radius=14)
{
    if (bDeleteMe) return false;
    if (VSizeSq(At - Location) <= Square(Radius) && FastTrace(Location, At)) return true;
    return bGrounded && VSizeSq(At - GroundPosition) <= Square(Radius)
        && FastTrace(GroundPosition, At);
}

function Step(float DeltaTime)
{
    local vector From, To, HitAt, HitNormal, HandAt, Axis;
    local Actor Surface;
    local KFPawn_Monster Victim;
    local rotator NextRotation, HandFacing;
    local quat HandQ;
    local float Speed;
    From = Location;
    if (ExitRegistry != None)
    {
        if (!ExitRegistry.bDeleteMe && Carrier == None && WorldInfo.TimeSeconds - Started < 0.5
            && ExitRegistry.CarrierFrame(ExitHand, HandAt, HandFacing))
        {
            HandQ = QuatFromRotator(HandFacing);
            Axis = QuatRotateVector(HandQ, ExitAxisLocal);
            ExitSpeed = FMax(0, ExitSpeed - 980 * Axis.Z * DeltaTime);
            ExitTravel = FMin(ExitDistance, ExitTravel + ExitSpeed * DeltaTime);
            To = HandAt + QuatRotateVector(HandQ, ExitOffset) + Axis * ExitTravel;
            // Invalid hand discontinuities release here, without teleporting.
            if (VSizeSq(To - From) <= Square(40) && FastTrace(To, From))
            {
                SetLocation(To); SetRotation(QuatToRotator(QuatProduct(HandQ, ExitRotation)));
                bNetDirty = true;
                if (ExitTravel < ExitDistance && ExitSpeed > 0) return;
                Linear = ExitMotionVelocity + Axis * ExitSpeed;
                From = Location;
            }
        }
        ExitRegistry = None;
    }
    Linear.Z -= 980 * DeltaTime;
    To = From + Linear * DeltaTime;
    Surface = Trace(HitAt, HitNormal, To, From, false, vect(1.5,1.5,1.5));
    if (Surface != None) To = HitAt + HitNormal * 1.6;
    Speed = VSize(Linear);
    if (Reactions != None && WorldInfo.TimeSeconds - Started > 0.08)
    {
        Victim = Reactions.Sweep(self, From, To, Speed);
        if (Victim != None)
        {
            LastImpact.Victim = Victim;
            LastImpact.Direction = Normal(To - From);
            LastImpact.Kind = class'VRWorldDropReactions'.static.KindFor(Victim);
            ++LastImpact.Serial;
        }
    }
    SetLocation(To);
    NextRotation = Rotation;
    NextRotation.Roll += int(Angular.X * 10430.378 * DeltaTime);
    NextRotation.Pitch += int(Angular.Y * 10430.378 * DeltaTime);
    NextRotation.Yaw += int(Angular.Z * 10430.378 * DeltaTime);
    SetRotation(NextRotation);
    if (Surface != None)
    {
        Linear = (Linear - HitNormal * (Linear Dot HitNormal) * 1.22) * 0.7;
        Angular *= 0.55;
        if (HitNormal.Z > 0.55 && VSize(Linear) < 45)
        {
            bGrounded = true;
            GroundPosition = HitAt + HitNormal;
            RestedAt = WorldInfo.TimeSeconds;
            Linear = vect(0,0,0);
            Angular = vect(0,0,0);
            bForceNetUpdate = true;
        }
    }
    bNetDirty = true;
}

simulated event Tick(float DeltaTime)
{
    local float Remaining, Slice, MotionDelta;
    local int Steps;
    local vector At, Origin, Motion;
    local rotator Facing;
    local quat HandQ;
    if (DrawMesh == None) BuildVisual();
    if (DrawMesh != None) DrawMesh.SetHidden(bLocalLease);
    if (Role != ROLE_Authority) return;
    if (RevealAt > 0 && (WorldInfo.TimeSeconds >= RevealAt || Carrier != None))
    { RevealAt = 0; SetHidden(false); bForceNetUpdate = true; }
    if (ExitRegistry != None && ExitRegistry.CarrierFrame(ExitHand, At, Facing))
    {
        Origin = At + QuatRotateVector(QuatFromRotator(Facing), ExitOffset);
        MotionDelta = WorldInfo.RealTimeSeconds - ExitMotionTime;
        if (MotionDelta > 0 && MotionDelta <= 0.08 && VSize(Origin - ExitLastOrigin) <= 40)
        {
            Motion = (Origin - ExitLastOrigin) / MotionDelta;
            if (VSize(Motion) > 700) Motion = Normal(Motion) * 700;
            ExitMotionVelocity = Motion;
        }
        ExitLastOrigin = Origin; ExitMotionTime = WorldInfo.RealTimeSeconds;
    }
    if (Carrier != None)
    {
        ExitRegistry = None;
        LooseElapsed = 0;
        if (WorldInfo.RealTimeSeconds < NextCarryUpdate) return;
        NextCarryUpdate = FMax(NextCarryUpdate + 0.008333, WorldInfo.RealTimeSeconds);
        if (CarrierRegistry != None && !CarrierRegistry.bDeleteMe && CarrierRegistry.Human == Carrier
            && CarrierRegistry.CarrierFrame(CarrierHand, At, Facing))
        {
            if (bCarryFrame)
            {
                HandQ = QuatFromRotator(Facing);
                At += QuatRotateVector(HandQ, CarryOffset);
                Facing = QuatToRotator(QuatProduct(HandQ, CarryOffsetQ));
            }
            if (At != Location || Facing != Rotation)
            { SetLocation(At); SetRotation(Facing); bNetDirty = true; }
        }
        return;
    }
    if (bGrounded) return;
    LooseElapsed += DeltaTime;
    if (WorldInfo.RealTimeSeconds < NextLooseUpdate) return;
    NextLooseUpdate = FMax(NextLooseUpdate + 0.008333, WorldInfo.RealTimeSeconds);
    Remaining = FMin(LooseElapsed, 0.08);
    LooseElapsed = 0;
    // A server tick can be slower than presentation. Subdivide its elapsed
    // time too, so 30/60 Hz hosts retain the 120 Hz collision/gravity baseline.
    while (Remaining > 0 && Steps < 10 && !bGrounded)
    {
        Slice = FMin(Remaining, 1.0 / 120.0);
        Step(Slice);
        Remaining -= Slice;
        ++Steps;
    }
}

defaultproperties
{
    CarrierHand=-1
    AmmoSlot=255
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=true
    // PHYS_None props need this to send motion after their initial spawn.
    bUpdateSimulatedPosition=true
    bCollideActors=false
    bBlockActors=false
    bNetTemporary=false
    bKillDuringLevelTransition=true
    NetUpdateFrequency=120
    LifeSpan=0
    Lapse=1.0
    LapseSeconds=1.5
}
