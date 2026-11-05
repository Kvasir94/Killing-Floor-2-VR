// Local reserve props, using the gun's own KF2 ammunition art. The historical
// class name is retained; magazines and clips now share the shell display.
// Ownership, pickup and ammo credits stay with VRInteractiveReload/stock KF2.
class VRBeltShellPresentation extends Object;

var VRInteractiveReload Owner;
var VRWeaponRuntime VisibleRuntimes[2];
var StaticMeshComponent Shells[2], AmmoGlows[2], SecondaryProps[2], SecondaryGlows[2];
var MaterialInstanceConstant GlowMaterials[2], SecondaryGlowMaterials[2];
var StaticMeshComponent TinyRoundRings[2];
var MaterialInstanceConstant TinyRoundMaterials[2];
var KFWeapon SecondaryWeapons[2];
var vector SecondaryCentres[2];
var float SecondaryExtents[2];
var KFWeapon ShownWeapons[2];
var vector Centres[2];
var float Extents[2];
var byte PrimaryOwed[2], SecondaryOwed[2];
var float PrimarySince[2], SecondarySince[2];
// UnrealScript permits bool fields in struct arrays, not primitive bool arrays.
struct BeltPropFlags
{
    var bool Prepared;
};
var BeltPropFlags Flags[2];

function Initialize(VRInteractiveReload R) { Owner = R; }

function bool CurrentPrimary(VRWeaponRuntime R)
{
    return R != None && R.IsCurrent() && R.PrimaryHand >= 0 && R.PrimaryHand < 2
        && Owner.InputOwner.Inventory.Registry.GetPrimary(R.PrimaryHand) == R;
}

// Props and counts resolve the same exact held actor, never Pawn.Weapon.
function VRWeaponRuntime RuntimeForHand(int Hand)
{
    local VRWeaponRuntime R;
    if (Hand < 0 || Hand > 1 || Owner == None || Owner.Bridge == None || Owner.InputOwner == None
        || Owner.InputOwner.Inventory == None || Owner.InputOwner.Inventory.Registry == None) return None;
    R = Owner.InputOwner.Inventory.GetHeldForHand(Hand);
    if (CurrentPrimary(R) && R.PrimaryHand == Hand) return R;
    return (R != None && R.IsCurrent() && R.PrimaryHand < 0 && R.SupportHand == Hand
        && R.CarryPrimaryHand >= 0) ? R : None;
}

function VRCylinderSession HipSession(int Hand)
{
    local VRCylinderSession S;
    local VRWeaponRuntime R;
    R = RuntimeForHand(Hand);
    if (R == None) return None;
    S = Owner.DualCylinders[Hand];
    return (S != None && S.Runtime == R && S.BindingValid()) ? S : None;
}

function bool UsesHip(int Hand)
{
    local VRWeaponRuntime R;
    R = RuntimeForHand(Hand);
    if (R == None) return false;
    if (HipSession(Hand) != None) return true;
    // A free-hand session can itself occupy the other hand with its insert.
    // That does not turn the acquired session into an own-hand hip reload.
    if (Owner.bActive && Owner.Runtime == R) return false;
    return Owner.HipCylinderHand(Hand, R);
}

// Follow the reload owner on every placement: free-hand pickup crosses to
// the other hip; an occupied-hand hip reload uses the gun's own side.
function int PouchHand(int Hand)
{
    local VRWeaponRuntime R, Other;
    if (UsesHip(Hand)) return Hand;
    R = RuntimeForHand(Hand);
    Other = RuntimeForHand(1 - Hand);
    // A carried rifle can lack a hip-reload mechanism while the pistol in
    // its other hand has one. Their persistent ammo displays must still
    // occupy different hips. An active free-hand feed keeps its real pickup
    // anchor; this presentation rule never relocates an interaction target.
    if (R != None && Other != None && Other != R
        && !(Owner.bActive && Owner.Runtime == R)
        && !(Owner.Secondary != None && Owner.Secondary.bActive && Owner.Secondary.Gun == R.Item)) return Hand;
    return 1 - Hand;
}

function vector PositionForHand(int Hand) { return Owner.BeltPositionFor(PouchHand(Hand)); }

function bool Covers(KFWeapon W)
{
    return W != None && (class'VRInteractiveReload'.static.Supported(W)
        || (Owner.PairedAuthorityNeeded(W) && class'VRCylinderSession'.static.MagazineIndex(W.Class) >= 0));
}

function bool HasProp(KFWeapon W)
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
        if (W != None && VisibleRuntimes[Hand] != None && VisibleRuntimes[Hand].Item == W
            && VisibleRuntimes[Hand] == RuntimeForHand(Hand)) return true;
    return false;
}

// The Doshinegun buys notes from the player's score instead of a reserve pool.
// This only controls pouch presentation; stock owns reload admission/payment.
function bool HasPouchAmmo(KFWeapon W)
{
    return W != None && (W.bInfiniteSpareAmmo || Owner.ReserveForHUD(W) > 0);
}

// Read the existing approach decision; presentation never chooses a target.
function bool Hovered(KFWeapon W, int GunHand)
{
    local int Hand;
    if (Owner == None || W == None || RuntimeForHand(GunHand) == None
        || RuntimeForHand(GunHand).Item != W || UsesHip(GunHand)
        || (!HasPouchAmmo(W) && !Owner.LoadedBowCarryAllowed(RuntimeForHand(GunHand)))) return false;
    Hand = 1 - GunHand;
    if (!Owner.bActive) return Owner.CanStartPouchReload(RuntimeForHand(GunHand))
        && (Owner.IdleZoneMask & (1 << Hand)) != 0;
    return Owner.Gun == W && Owner.ZoneStep == 1 && Owner.bInZone
        && Owner.HandFree(Hand, false)
        && !Owner.InputOwner.PouchContactPreferred(Hand, Owner.BeltPositionFor(Hand), Owner.BeltRadius);
}

function Prepare(int Hand, KFWeapon W)
{
    local StaticMesh Mesh;
    local SkeletalMesh MaterialMesh;
    local MaterialInterface Surface, Surface1, Surface2;
    local int Magazine, BreakProfile, PumpProfile;
    local Material GlowParent;
    local vector Extent;
    Owner.EnsureVisuals();
    Flags[Hand].Prepared = false;
    ShownWeapons[Hand] = W;
    PrimaryOwed[Hand] = 0;
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ W.MySkelMesh.SkeletalMesh.Name,
        class'StaticMesh', true));
    // Missing art keeps the existing reload-step fallback, not a made-up pool.
    if (Mesh == None) return;
    Magazine = class'VRCylinderSession'.static.MagazineIndex(W.Class);
    BreakProfile = class'VRBreakCatalog'.static.FindClass(W.Class);
    PumpProfile = class'VRPumpCatalog'.static.FindClass(W.Class);
    Surface = W.MySkelMesh.GetMaterial(Magazine >= 0
        ? class'VRReloadCatalog'.default.Profiles[Magazine].MaterialIndex
        : (BreakProfile >= 0 ? class'VRBreakCatalog'.default.Profiles[BreakProfile].MaterialIndex : 0));
    if (Magazine >= 0)
    {
        Surface1 = W.MySkelMesh.GetMaterial(class'VRReloadCatalog'.default.Profiles[Magazine].Section1MaterialIndex);
        if (class'VRReloadCatalog'.default.Profiles[Magazine].Section2MaterialIndex > 0)
            Surface2 = W.MySkelMesh.GetMaterial(class'VRReloadCatalog'.default.Profiles[Magazine].Section2MaterialIndex);
    }
    else if (BreakProfile >= 0)
    {
        Surface1 = W.MySkelMesh.GetMaterial(class'VRBreakCatalog'.default.Profiles[BreakProfile].Section1MaterialIndex);
        if (class'VRBreakCatalog'.default.Profiles[BreakProfile].Section1MaterialMesh != "")
        {
            MaterialMesh = SkeletalMesh(DynamicLoadObject(
                class'VRBreakCatalog'.default.Profiles[BreakProfile].Section1MaterialMesh, class'SkeletalMesh', true));
            if (MaterialMesh != None && MaterialMesh.Materials.Length > 0) Surface1 = MaterialMesh.Materials[0];
        }
    }
    if (PumpProfile >= 0 && class'VRPumpCatalog'.default.Profiles[PumpProfile].AmmoMaterialMesh != "")
    {
        MaterialMesh = SkeletalMesh(DynamicLoadObject(
            class'VRPumpCatalog'.default.Profiles[PumpProfile].AmmoMaterialMesh, class'SkeletalMesh', true));
        if (MaterialMesh != None && MaterialMesh.Materials.Length > 0) Surface = MaterialMesh.Materials[0];
    }
    if (Surface == None) return;
    if (Shells[Hand] == None) Shells[Hand] = Owner.MakeComponent(Mesh, Surface);
    Shells[Hand].SetStaticMesh(Mesh);
    Shells[Hand].SetMaterial(0, Surface);
    Shells[Hand].SetMaterial(1, Surface1);
    Shells[Hand].SetMaterial(2, Surface2);
    Shells[Hand].SetScale3D(vect(1,1,1));
    Shells[Hand].SetScale(1);
    Shells[Hand].SetRotation(rot(0,0,0));
    Shells[Hand].SetTranslation(vect(0,0,0));
    Shells[Hand].ForceUpdate(true);
    Centres[Hand] = Shells[Hand].Bounds.Origin;
    Extent = Shells[Hand].Bounds.BoxExtent;
    Extents[Hand] = FMax(Extent.X, FMax(Extent.Y, Extent.Z));
    if (Extents[Hand] < 0.5 || VSize(Centres[Hand]) > 50) return;
    GlowParent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (GlowParent != None)
    {
        // The single M99 cartridge is the explicit small-ammo exception to
        // model-only glow hints. Its pickup still uses the full belt radius.
        if (W.Class == class'KFWeap_Rifle_M99' && Owner.bRingMesh && Owner.PouchRing != None)
        {
            if (TinyRoundMaterials[Hand] == None)
            {
                TinyRoundMaterials[Hand] = Owner.MakeRingMaterial(GlowParent, class'VRInteractionColours'.const.ROLE_AMMO);
                TinyRoundMaterials[Hand].SetScalarParameterValue('Scalar_Opacity', 0.55);
            }
            if (TinyRoundRings[Hand] == None)
                TinyRoundRings[Hand] = Owner.MakeComponent(Owner.PouchRing.StaticMesh, TinyRoundMaterials[Hand]);
        }
        if (GlowMaterials[Hand] == None) GlowMaterials[Hand] = Owner.MakeRingMaterial(GlowParent, class'VRInteractionColours'.const.ROLE_AMMO);
        if (AmmoGlows[Hand] == None) AmmoGlows[Hand] = Owner.MakeComponent(Mesh, GlowMaterials[Hand]);
        AmmoGlows[Hand].SetStaticMesh(Mesh);
        AmmoGlows[Hand].SetMaterial(0, GlowMaterials[Hand]);
        AmmoGlows[Hand].SetMaterial(1, GlowMaterials[Hand]);
        AmmoGlows[Hand].SetMaterial(2, GlowMaterials[Hand]);
    }
    Flags[Hand].Prepared = true;
}

function bool WantsPrimary(VRWeaponRuntime R)
{
    if (!HasPouchAmmo(R.Item) || Owner.CluesAutomatic(R.Item)) return false;
    if (Owner.bActive && Owner.Runtime == R)
        return Owner.HandMode == 0 && Owner.NeedsAmmo() && !Owner.OptionalAmmoClue(R.Item);
    // Being eligible for a tactical top-up is not an owed-ammo cue. The
    // pouch remains grabbable through CanStartPouchReload independently.
    return R.MagazineOut() || !R.Item.HasAmmo(0);
}

function bool WantsSecondary(VRWeaponRuntime R)
{
    if (Owner.CluesAutomatic(R.Item)) return false;
    if (!R.Item.bInfiniteSpareAmmo && Owner.ReserveForHUD(R.Item, 1) <= 0) return false;
    if (Owner.Secondary != None && Owner.Secondary.bActive && Owner.Secondary.Runtime == R)
        return Owner.Secondary.Stage == 1 && !Owner.Secondary.bCarryingAmmo && !Owner.Secondary.bEngaged;
    // The FAMAS can retain a chambered round with its secondary magazine
    // removed. Only that missing magazine or a dry feed owes pouch ammo;
    // a partial magazine or a paid load awaiting its cycle does not.
    return (R.SecondaryMagazineFlags & 1) != 0 || !R.Item.HasAmmo(1);
}

function float SupplyAlpha(int Hand, VRWeaponRuntime R, bool Secondary, bool Hover)
{
    local bool Owed;
    if (Owner.CluesAutomatic(R.Item)) return 0;
    Owed = Secondary ? WantsSecondary(R) : WantsPrimary(R);
    if (Secondary)
    {
        if (!Owed) SecondaryOwed[Hand] = 0;
        else if (SecondaryOwed[Hand] == 0) { SecondaryOwed[Hand] = 1; SecondarySince[Hand] = Owner.Now(); }
        if (Owed) return Owner.ClueAlpha(SecondarySince[Hand], R.Item, Hover);
    }
    else
    {
        if (!Owed) PrimaryOwed[Hand] = 0;
        else if (PrimaryOwed[Hand] == 0) { PrimaryOwed[Hand] = 1; PrimarySince[Hand] = Owner.Now(); }
        if (Owed) return Owner.ClueAlpha(PrimarySince[Hand], R.Item, Hover);
    }
    // Optional top-ups remain available, but only owed ammunition glows.
    // Hover never turns a full or optional load into a required reload cue.
    return 0;
}

function PlaceSecondary(int Hand, VRWeaponRuntime R)
{
    local StaticMesh Mesh;
    local Material Parent;
    local vector Extent, At;
    local quat Q;
    local int MaterialIndex;
    local float Scale, Alpha;
    if (!class'VRSecondaryReloadCatalog'.static.Supported(R.Item)) return;
    // The active secondary owner draws its own carried/pouch model.
    if (Owner.Secondary != None && Owner.Secondary.bActive && Owner.Secondary.Gun == R.Item
        && Owner.Secondary.Stage == 1 && !Owner.Secondary.bEngaged) return;
    if (SecondaryWeapons[Hand] != R.Item)
    {
        SecondaryWeapons[Hand] = R.Item; SecondaryExtents[Hand] = 0; SecondaryOwed[Hand] = 0;
        Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_Alt_" $ R.Item.MySkelMesh.SkeletalMesh.Name, class'StaticMesh', true));
        if (Mesh == None) return;
        MaterialIndex = (R.Item.Class == class'KFWeap_AssaultRifle_M16M203'
            || R.Item.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle') ? 1 : 0;
        if (SecondaryProps[Hand] == None) SecondaryProps[Hand] = Owner.MakeComponent(Mesh, R.Item.MySkelMesh.GetMaterial(MaterialIndex));
        SecondaryProps[Hand].SetStaticMesh(Mesh);
        SecondaryProps[Hand].SetMaterial(0, R.Item.MySkelMesh.GetMaterial(MaterialIndex));
        SecondaryProps[Hand].SetScale(1); SecondaryProps[Hand].SetScale3D(vect(1,1,1));
        SecondaryProps[Hand].SetTranslation(vect(0,0,0)); SecondaryProps[Hand].SetRotation(rot(0,0,0));
        SecondaryProps[Hand].ForceUpdate(true);
        SecondaryCentres[Hand] = SecondaryProps[Hand].Bounds.Origin;
        Extent = SecondaryProps[Hand].Bounds.BoxExtent;
        SecondaryExtents[Hand] = FMax(Extent.X, FMax(Extent.Y, Extent.Z));
        Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
        if (Parent != None)
        {
            if (SecondaryGlowMaterials[Hand] == None) SecondaryGlowMaterials[Hand] = Owner.MakeRingMaterial(Parent, class'VRInteractionColours'.const.ROLE_AMMO);
            if (SecondaryGlows[Hand] == None) SecondaryGlows[Hand] = Owner.MakeComponent(Mesh, SecondaryGlowMaterials[Hand]);
            SecondaryGlows[Hand].SetStaticMesh(Mesh);
            SecondaryGlows[Hand].SetMaterial(0, SecondaryGlowMaterials[Hand]);
            SecondaryGlows[Hand].SetMaterial(1, SecondaryGlowMaterials[Hand]);
            SecondaryGlows[Hand].SetMaterial(2, SecondaryGlowMaterials[Hand]);
        }
    }
    if (SecondaryProps[Hand] == None || SecondaryExtents[Hand] < 0.5) return;
    Scale = FMin(Owner.ScaleOf(R.Item), 3.5 / SecondaryExtents[Hand]);
    Q = Owner.PouchRotationFor(R.Item, PouchHand(Hand));
    At = PositionForHand(Hand) + (vect(0,8,0) >> Owner.Bridge.BodyYaw());
    At -= QuatRotateVector(Q, SecondaryCentres[Hand] * Scale);
    Owner.PlaceProp(SecondaryProps[Hand], At, Q, Scale);
    Alpha = SupplyAlpha(Hand, R, true, false);
    if (SecondaryGlows[Hand] != None && Alpha > 0 && Owner.Bridge.bReloadHints)
    {
        SecondaryGlowMaterials[Hand].SetScalarParameterValue('Scalar_Opacity', Alpha);
        Owner.PlaceProp(SecondaryGlows[Hand], At, Q, Scale * 1.01);
    }
}

function Place()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    local int Hand;
    local float Scale, Alpha;
    local vector At, ToEye;
    local quat Q;
    Hide();
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = RuntimeForHand(Hand);
        if (R == None) continue;
        W = R.Item;
        if (!Owner.EnabledFor(W) || !Covers(W) || W.bDeleteMe
            || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) continue;
        PlaceSecondary(Hand, R);
        if (ShownWeapons[Hand] != W) Prepare(Hand, W);
        if (!Flags[Hand].Prepared) continue;
        Alpha = SupplyAlpha(Hand, R, false, Hovered(W, Hand));
        // This display cap never changes the carried prop or an ammo pool.
        Scale = FMin(Owner.ScaleOf(W), 4.5 / Extents[Hand]);
        Q = Owner.PouchRotationFor(W, PouchHand(Hand));
        At = PositionForHand(Hand);
        if (Owner.Secondary != None && Owner.Secondary.bActive && Owner.Secondary.Gun == W)
            At += QuatRotateVector(QuatFromRotator(Owner.Bridge.BodyYaw()), vect(0,-4,0));
        Owner.PlaceProp(Shells[Hand], At - QuatRotateVector(Q, Centres[Hand] * Scale), Q, Scale);
        if (W.Class == class'KFWeap_Rifle_M99' && TinyRoundRings[Hand] != None
            && Owner.Bridge.bReloadHints && HasPouchAmmo(W) && Alpha > 0)
        {
            TinyRoundMaterials[Hand].SetScalarParameterValue('Scalar_Opacity', Alpha);
            ToEye = Normal(Owner.Bridge.HeadPosition - At);
            Owner.PlaceProp(TinyRoundRings[Hand], At + ToEye * 1.5, QuatFromRotator(rotator(ToEye)), 7);
        }
        VisibleRuntimes[Hand] = R;
        if (AmmoGlows[Hand] != None && Owner.Bridge.bReloadHints && Alpha > 0)
        {
            GlowMaterials[Hand].SetScalarParameterValue('Scalar_Opacity', Alpha);
            Owner.PlaceProp(AmmoGlows[Hand], At - QuatRotateVector(Q, Centres[Hand] * Scale), Q, Scale * 1.01);
        }
    }
}

function Hide()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        VisibleRuntimes[Hand] = None;
        if (Shells[Hand] != None) Shells[Hand].SetHidden(true);
        if (AmmoGlows[Hand] != None) AmmoGlows[Hand].SetHidden(true);
        if (SecondaryProps[Hand] != None) SecondaryProps[Hand].SetHidden(true);
        if (SecondaryGlows[Hand] != None) SecondaryGlows[Hand].SetHidden(true);
        if (TinyRoundRings[Hand] != None) TinyRoundRings[Hand].SetHidden(true);
    }
}

function Shutdown()
{
    local int Hand;
    Hide();
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Owner.Bridge != None)
        {
            if (Shells[Hand] != None) Owner.Bridge.DetachComponent(Shells[Hand]);
            if (AmmoGlows[Hand] != None) Owner.Bridge.DetachComponent(AmmoGlows[Hand]);
            if (SecondaryProps[Hand] != None) Owner.Bridge.DetachComponent(SecondaryProps[Hand]);
            if (SecondaryGlows[Hand] != None) Owner.Bridge.DetachComponent(SecondaryGlows[Hand]);
            if (TinyRoundRings[Hand] != None) Owner.Bridge.DetachComponent(TinyRoundRings[Hand]);
        }
        Shells[Hand] = None;
        ShownWeapons[Hand] = None;
    }
    Owner = None;
}
