// Local contact cues for the authority actors. Touch only pulses; callers
// must supply a new, deliberate grip edge to request a catch/pocket.
class VRWorldDropHints extends Object;

struct HintSlot
{
    var Actor Prop;
    var StaticMeshComponent Ring;
    var MeshComponent AmmoGlow;
    var MaterialInstanceConstant Surface, AmmoSurface;
    var Actor GroundIdentity;
    var vector StockFloor;
    var float NextGroundCheck;
    var byte StockGrounded;
};
var VRHandsBridge Bridge;
var VRHandInventory Inventory;
var VRMagazineRecovery Recovery;
var bool bMagazinesOnly, bGunsOnly;
var HintSlot Slots[40];
var Actor NearActor[2];
var float NextPulse[2], NextScan;
var StaticMesh RingMesh;
var Material RingParent;
// Skeletal round piles need the skeletal-compiled hologram parent (#173).
var Material HologramParent;
var Texture2D WhiteTexture;
var bool bLoaded;
var int ColourRevision;

function Initialize(VRHandsBridge B, optional VRHandInventory I)
{
    Bridge = B;
    Inventory = I;
}

function bool MagazineEligible(VRWorldDropMagazine Magazine)
{
    return !bGunsOnly && Bridge != None && Bridge.bRecoverMagazineAmmo && Recovery != None
        && Magazine != None && Magazine.CanPickupBy(Bridge.Human) && !Magazine.bLocalLease
        && Recovery.CompatibleOwnedFamily(Magazine.Family, true) != None;
}

function bool HandAvailable(int Hand)
{
    return Inventory != None && Inventory.Registry != None && Inventory.Input != None
        && (!bGunsOnly || Inventory.DeferredCatch[Hand].Weapon == None)
        && Inventory.Registry.GetPrimary(Hand) == None && Inventory.Registry.GetSupport(Hand) == None
        && !Inventory.HasWorldGrab(Hand) && !Inventory.HasGauntletHand(Hand)
        && !Inventory.IsTransferPending(Hand) && !Inventory.Input.IsSelectorOpen(Hand)
        && !Inventory.Input.HandCarrying(Hand)
        && (Inventory.Input.Reloads == None || !Inventory.Input.Reloads.OwnsHand(Hand))
        && (Inventory.Input.Deployables == None || !Inventory.Input.Deployables.IsHeld(Hand))
        && (Inventory.WorldDrops == None || !Inventory.WorldDrops.OwnsHand(Hand));
}

// The player's pickup and ground-ammo colours (VRInteractionColours).
function TintSlot(int I)
{
    local LinearColor Glow;
    if (Slots[I].Surface == None) return;
    Glow = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_PICKUP);
    Slots[I].Surface.SetVectorParameterValue('Vector_Glow_Color', Glow);
    Glow = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_AMMO_PICKUP);
    Slots[I].AmmoSurface.SetVectorParameterValue('Vector_Glow_Color', Glow);
}

function bool EnsureRing(int I)
{
    if (!bLoaded)
    {
        RingMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRReloadRing", class'StaticMesh', true));
        RingParent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
        WhiteTexture = Texture2D(DynamicLoadObject("EngineResources.WhiteSquareTexture", class'Texture2D', true));
        HologramParent = Material(DynamicLoadObject("KF2VRHands.VRHologram", class'Material', true));
        bLoaded = true;
    }
    if (RingMesh == None || RingParent == None || WhiteTexture == None) return false;
    if (Slots[I].Ring != None) return true;
    Slots[I].Surface = new(Bridge) class'MaterialInstanceConstant';
    Slots[I].Surface.SetParent(RingParent);
    Slots[I].Surface.SetTextureParameterValue('Texture_D', WhiteTexture);
    Slots[I].Surface.SetScalarParameterValue('Scalar_Glow_Intensity', 1.5);
    // Blue identifies the near-hand pickup ring. Ground ammunition keeps the
    // stock pickups' green glow, fading in and out whenever it is in view.
    Slots[I].AmmoSurface = new(Bridge) class'MaterialInstanceConstant';
    Slots[I].AmmoSurface.SetParent(RingParent);
    Slots[I].AmmoSurface.SetTextureParameterValue('Texture_D', WhiteTexture);
    Slots[I].AmmoSurface.SetScalarParameterValue('Scalar_Glow_Intensity', 2.5);
    TintSlot(I);
    Slots[I].Ring = new(Bridge) class'StaticMeshComponent';
    Slots[I].Ring.SetStaticMesh(RingMesh);
    Slots[I].Ring.SetMaterial(0, Slots[I].Surface);
    Slots[I].Ring.SetAbsolute(true, true, true);
    Slots[I].Ring.SetActorCollision(false, false);
    Slots[I].Ring.SetTraceBlocking(false, false);
    Slots[I].Ring.CastShadow = false;
    Slots[I].Ring.SetHidden(true);
    Bridge.AttachComponent(Slots[I].Ring);
    return true;
}

function PlaceAmmoGlow(int I, bool Visible)
{
    local VRWorldDropMagazine M;
    local StaticMesh Mesh;
    local SkeletalMesh RoundAsset;
    local MaterialInterface S0, S1, S2;
    local float Scale;
    M = VRWorldDropMagazine(Slots[I].Prop);
    if (!Visible || M == None)
    { if (Slots[I].AmmoGlow != None) Slots[I].AmmoGlow.SetHidden(true); return; }
    RoundAsset = M.RecoverySkeletal(S0);
    Scale = M.Visual.Scale > 0 ? M.Visual.Scale : 1.0;
    if (RoundAsset == None && !M.GetVisual(Mesh, S0, S1, S2, Scale))
    { if (Slots[I].AmmoGlow != None) Slots[I].AmmoGlow.SetHidden(true); return; }
    if (Slots[I].AmmoGlow != None && ((RoundAsset != None) != (SkeletalMeshComponent(Slots[I].AmmoGlow) != None)))
    { Bridge.DetachComponent(Slots[I].AmmoGlow); Slots[I].AmmoGlow = None; }
    if (Slots[I].AmmoGlow == None)
    {
        if (RoundAsset != None && HologramParent == None) return;
        if (RoundAsset != None) Slots[I].AmmoGlow = new(Bridge) class'KFSkeletalMeshComponent';
        else Slots[I].AmmoGlow = new(Bridge) class'StaticMeshComponent';
        Slots[I].AmmoSurface.SetParent(RoundAsset != None ? HologramParent : RingParent);
        Slots[I].AmmoGlow.SetAbsolute(true, true, true);
        Slots[I].AmmoGlow.SetActorCollision(false, false);
        Slots[I].AmmoGlow.SetTraceBlocking(false, false);
        Slots[I].AmmoGlow.CastShadow = false;
        Bridge.AttachComponent(Slots[I].AmmoGlow);
    }
    if (RoundAsset != None) SkeletalMeshComponent(Slots[I].AmmoGlow).SetSkeletalMesh(RoundAsset);
    else StaticMeshComponent(Slots[I].AmmoGlow).SetStaticMesh(Mesh);
    Slots[I].AmmoGlow.SetMaterial(0, Slots[I].AmmoSurface);
    Slots[I].AmmoGlow.SetMaterial(1, Slots[I].AmmoSurface);
    Slots[I].AmmoGlow.SetMaterial(2, Slots[I].AmmoSurface);
    Slots[I].AmmoGlow.SetTranslation(M.Location);
    Slots[I].AmmoGlow.SetRotation(M.Rotation);
    Slots[I].AmmoGlow.SetScale(Scale * 1.02);
    Slots[I].AmmoGlow.SetHidden(false);
    Slots[I].AmmoGlow.ForceUpdate(true);
}

function bool Describe(int I, Actor Prop, out vector GrabAt, out vector FloorAt, out byte Grounded)
{
    local VRWorldDropGun Gun;
    local VRWorldDropMagazine Magazine;
    local vector HitAt, HitNormal;
    if (Prop == None || Prop.bDeleteMe) return false;
    Gun = VRWorldDropGun(Prop);
    if (Gun != None)
    {
        if (bMagazinesOnly || !Gun.CanPickupBy(Bridge.Human)) return false;
        GrabAt = Gun.GrabPosition();
        FloorAt = Gun.GroundPosition;
        Grounded = byte(Gun.bGrounded);
        return true;
    }
    if (!bMagazinesOnly && class'VRStockWorldPickup'.static.IsPickup(Prop))
    {
        GrabAt = class'VRStockWorldPickup'.static.GrabPosition(Prop);
        Grounded = 0; FloorAt = GrabAt;
        if (I >= 0 && I < ArrayCount(Slots) && Slots[I].Prop == Prop)
        {
            if (Slots[I].GroundIdentity != Prop || Bridge.WorldInfo.RealTimeSeconds >= Slots[I].NextGroundCheck)
            {
                Slots[I].GroundIdentity = Prop;
                Slots[I].NextGroundCheck = Bridge.WorldInfo.RealTimeSeconds + 0.1;
                Slots[I].StockGrounded = byte(Bridge.Trace(HitAt, HitNormal, GrabAt - vect(0,0,32),
                    GrabAt + vect(0,0,2), false) != None && HitNormal.Z > 0.55);
                Slots[I].StockFloor = HitAt;
            }
            Grounded = Slots[I].StockGrounded; FloorAt = Slots[I].StockFloor;
        }
        return true;
    }
    Magazine = VRWorldDropMagazine(Prop);
    if (!MagazineEligible(Magazine)) return false;
    GrabAt = Magazine.Location;
    FloorAt = Magazine.GroundPosition;
    Grounded = byte(Magazine.bGrounded);
    return true;
}

function Refresh()
{
    local VRWorldDropGun Gun;
    local VRWorldDropMagazine Magazine;
    local KFDroppedPickup Stock;
    local KFPickupFactory_Item Factory;
    local int I;
    if (!bMagazinesOnly)
        foreach Bridge.WorldInfo.AllActors(class'VRWorldDropGun', Gun)
        {
            if (!Gun.CanPickupBy(Bridge.Human)
                || VSizeSq(Gun.Location - Bridge.HeadPosition) > Square(300.0)) continue;
            if (I >= ArrayCount(Slots)) break;
            Slots[I++].Prop = Gun;
        }
    if (!bGunsOnly)
        foreach Bridge.WorldInfo.AllActors(class'VRWorldDropMagazine', Magazine)
        {
            if (!MagazineEligible(Magazine)
                || VSizeSq(Magazine.Location - Bridge.HeadPosition) > Square(900.0)) continue;
            if (I >= ArrayCount(Slots)) break;
            Slots[I++].Prop = Magazine;
        }
    if (!bMagazinesOnly)
    {
        foreach Bridge.WorldInfo.AllActors(class'KFDroppedPickup', Stock)
        {
            if (!class'VRStockWorldPickup'.static.IsPickup(Stock)
                || VSizeSq(Stock.Location - Bridge.HeadPosition) > Square(300.0)) continue;
            if (I >= ArrayCount(Slots)) break;
            Slots[I++].Prop = Stock;
        }
        foreach Bridge.WorldInfo.AllActors(class'KFPickupFactory_Item', Factory)
        {
            if (!class'VRStockWorldPickup'.static.IsPickup(Factory)
                || VSizeSq(Factory.Location - Bridge.HeadPosition) > Square(300.0)) continue;
            if (I >= ArrayCount(Slots)) break;
            Slots[I++].Prop = Factory;
        }
    }
    while (I < ArrayCount(Slots)) Slots[I++].Prop = None;
}

function bool HandTracked(int Hand)
{
    return Bridge != None && Bridge.NativeHeadTracked != 0 && Bridge.NativeRecenterRequested == 0
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0;
}

function bool NearZone(Actor Prop, vector Palm, float Radius, int Hand)
{
    if (VRWorldDropGun(Prop) != None) return VRWorldDropGun(Prop).NearHand(Palm, Radius, Hand);
    if (!bMagazinesOnly && class'VRStockWorldPickup'.static.IsPickup(Prop))
        return class'VRStockWorldPickup'.static.NearHand(Prop, Palm, Hand);
    return VRWorldDropMagazine(Prop) != None && VRWorldDropMagazine(Prop).NearHand(Palm, Radius);
}

function Update(bool bEnabled)
{
    local int I, Hand;
    local vector GrabAt, FloorAt, Palm;
    local bool Visible, NearPickup;
    local byte Grounded;
    local float Now, Distance, BestDistance, Radius, Beat;
    local Actor Best;
    if (Bridge == None) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (bEnabled && Now >= NextScan)
    {
        Refresh();
        NextScan = Now + 0.1;
    }
    Beat = 0.5 + 0.5 * Sin(Now * 4.0);
    if (ColourRevision != class'VRInteractionColours'.default.Revision)
    {
        ColourRevision = class'VRInteractionColours'.default.Revision;
        for (I = 0; I < ArrayCount(Slots); ++I) TintSlot(I);
    }
    for (I = 0; I < ArrayCount(Slots); ++I)
    {
        Visible = bEnabled && Describe(I, Slots[I].Prop, GrabAt, FloorAt, Grounded)
            && Grounded != 0 && VSizeSq(GrabAt - Bridge.HeadPosition)
                < Square(VRWorldDropMagazine(Slots[I].Prop) != None ? 850.0 : 250.0);
        NearPickup = false;
        if (Visible && EnsureRing(I))
        {
            Radius = VRWorldDropMagazine(Slots[I].Prop) != None ? 10 : 12;
            for (Hand = 0; Hand < 2; ++Hand)
                if (HandTracked(Hand) && HandAvailable(Hand)
                    && NearZone(Slots[I].Prop, Bridge.PalmPosition(Hand), Radius, Hand)) NearPickup = true;
            Slots[I].Ring.SetTranslation(FloorAt + vect(0,0,0.5));
            Slots[I].Ring.SetRotation(rotator(vect(0,0,1)));
            Slots[I].Ring.SetScale(Radius);
            Slots[I].Surface.SetScalarParameterValue('Scalar_Opacity', NearPickup ? 0.7 : 0.18);
            Slots[I].Ring.SetHidden(false);
            Slots[I].Ring.ForceUpdate(true);
            Slots[I].AmmoSurface.SetScalarParameterValue('Scalar_Opacity', 0.05 + Beat * 0.45);
        }
        else if (Slots[I].Ring != None) Slots[I].Ring.SetHidden(true);
        PlaceAmmoGlow(I, Visible && Slots[I].AmmoSurface != None);
    }
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Best = None;
        BestDistance = 1000000;
        if (bEnabled && HandTracked(Hand) && HandAvailable(Hand))
        {
            Palm = Bridge.PalmPosition(Hand);
            for (I = 0; I < ArrayCount(Slots); ++I)
            {
                if (!Describe(I, Slots[I].Prop, GrabAt, FloorAt, Grounded)) continue;
                Distance = VSizeSq(Palm - GrabAt);
                if (Grounded != 0) Distance = FMin(Distance, VSizeSq(Palm - FloorAt));
                Radius = VRWorldDropMagazine(Slots[I].Prop) != None ? 10 : (Grounded != 0 ? 12 : 20);
                if (Slots[I].Prop == NearActor[Hand]) Radius += 3;
                if (Distance >= BestDistance || !NearZone(Slots[I].Prop, Palm, Radius, Hand)) continue;
                Best = Slots[I].Prop;
                BestDistance = Distance;
            }
        }
        if (Best != None && Best != NearActor[Hand] && Now >= NextPulse[Hand])
        {
            Bridge.QueueHandHaptic(1 << Hand, 0.18, 0.025);
            NextPulse[Hand] = Now + 0.25;
        }
        NearActor[Hand] = Best;
    }
}

function VRWorldDropGun GunForGrip(int Hand)
{
    local VRWorldDropGun Gun;
    if (bMagazinesOnly || Hand < 0 || Hand > 1 || !HandTracked(Hand) || !HandAvailable(Hand)) return None;
    Gun = VRWorldDropGun(NearActor[Hand]);
    return (Gun != None && Gun.CanPickupBy(Bridge.Human)
        && Gun.NearHand(Bridge.PalmPosition(Hand), -1, Hand)) ? Gun : None;
}

function VRWorldDropMagazine MagazineForGrip(int Hand)
{
    local VRWorldDropMagazine Magazine;
    if (bGunsOnly || Hand < 0 || Hand > 1 || !HandTracked(Hand) || !HandAvailable(Hand)) return None;
    Magazine = VRWorldDropMagazine(NearActor[Hand]);
    return (MagazineEligible(Magazine) && Magazine.NearHand(Bridge.PalmPosition(Hand))) ? Magazine : None;
}

function Shutdown()
{
    local int I;
    if (Bridge != None)
        for (I = 0; I < ArrayCount(Slots); ++I)
        {
            if (Slots[I].Ring != None) Bridge.DetachComponent(Slots[I].Ring);
            if (Slots[I].AmmoGlow != None) Bridge.DetachComponent(Slots[I].AmmoGlow);
            Slots[I].AmmoGlow = None;
            Slots[I].Ring = None;
            Slots[I].Surface = None;
            Slots[I].AmmoSurface = None;
            Slots[I].Prop = None;
        }
    NearActor[0] = None;
    NearActor[1] = None;
    Inventory = None; Recovery = None;
    Bridge = None;
}
