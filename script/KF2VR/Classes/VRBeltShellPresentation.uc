// Local reserve props, using the gun's own KF2 ammunition art. The historical
// class name is retained; magazines and clips now share the shell display.
// Ownership, pickup and ammo credits stay with VRInteractiveReload/stock KF2.
class VRBeltShellPresentation extends Object;

var VRInteractiveReload Owner;
var StaticMeshComponent Shells[2], HoverRings[2];
var MaterialInstanceConstant HoverMaterials[2];
var KFWeapon ShownWeapons[2];
var vector Centres[2];
var float Extents[2];
// UnrealScript permits bool fields in struct arrays, not primitive bool arrays.
struct BeltPropFlags
{
    var bool Prepared, Axial;
};
var BeltPropFlags Flags[2];

function Initialize(VRInteractiveReload R) { Owner = R; }

function bool Covers(KFWeapon W)
{
    return W != None && class'VRInteractiveReload'.static.Supported(W);
}

function bool HasProp(KFWeapon W)
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
        if (ShownWeapons[Hand] == W && Flags[Hand].Prepared) return true;
    return false;
}

// Read the existing approach decision; presentation never chooses a target.
function bool Hovered(KFWeapon W, int GunHand)
{
    local int Hand;
    if (Owner == None || W == None || W.SpareAmmoCount[0] <= 0) return false;
    Hand = 1 - GunHand;
    if (!Owner.bActive) return (Owner.IdleZoneMask & (1 << Hand)) != 0;
    return Owner.Gun == W && Owner.ZoneStep == 1 && Owner.bInZone
        && Owner.HandFree(Hand, false)
        && !Owner.InputOwner.BodySlotNearer(Hand, Owner.BeltPositionFor(Hand), Owner.BeltRadius);
}

function Prepare(int Hand, KFWeapon W)
{
    local StaticMesh Mesh;
    local SkeletalMesh MaterialMesh;
    local MaterialInterface Surface, Surface1, Surface2;
    local int Magazine, BreakProfile, PumpProfile;
    local vector Extent;
    Owner.EnsureVisuals();
    Flags[Hand].Prepared = false;
    ShownWeapons[Hand] = W;
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ W.MySkelMesh.SkeletalMesh.Name,
        class'StaticMesh', true));
    // Missing art keeps the existing reload-step fallback, not a made-up pool.
    if (Mesh == None) return;
    Magazine = class'VRReloadCatalog'.static.FindClass(W.Class);
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
    Flags[Hand].Axial = Magazine < 0;
    Flags[Hand].Prepared = true;
    if (Owner.bRingMesh && HoverRings[Hand] == None)
    {
        HoverMaterials[Hand] = Owner.MakeRingMaterial(Material(DynamicLoadObject(
            "ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true)), Owner.AmmoColour);
        HoverRings[Hand] = Owner.MakeComponent(StaticMesh(DynamicLoadObject(
            "KF2VRHands.VRReloadRing", class'StaticMesh', true)), HoverMaterials[Hand]);
    }
}

function Place()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    local int Hand;
    local float Scale;
    local vector At, ToEye;
    local quat Q;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Owner.InputOwner.Inventory.Registry.GetPrimary(Hand);
        if (R == None || !R.IsCurrent()) continue;
        W = R.Item;
        // A stock paired weapon has one pool, so it is represented once.
        if (Hand == 1 && ShownWeapons[0] == W && Flags[0].Prepared
            && Owner.InputOwner.Inventory.Registry.GetPrimary(0) == R) continue;
        if (!Covers(W) || W.bDeleteMe || W.SpareAmmoCount[0] <= 0
            || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) continue;
        if (ShownWeapons[Hand] != W) Prepare(Hand, W);
        if (!Flags[Hand].Prepared) continue;
        // Large launchers/boxes must not grow into a waist-obscuring bag.
        // This cap affects the local display only, never the carried prop.
        Scale = FMin(Owner.ScaleOf(W), 4.5 / Extents[Hand]);
        Q = QuatFromRotator(Owner.Torso());
        if (Flags[Hand].Axial) Q = QuatProduct(Q, QuatFromRotator(rot(16384,0,0)));
        At = Owner.BeltPositionFor(1 - Hand);
        Owner.PlaceProp(Shells[Hand], At - QuatRotateVector(Q, Centres[Hand] * Scale), Q, Scale);
        if (Hovered(W, Hand) && HoverRings[Hand] != None)
        {
            ToEye = Normal(Owner.Bridge.HeadPosition - At);
            HoverMaterials[Hand].SetScalarParameterValue('Scalar_Opacity', 0.8);
            HoverRings[Hand].SetTranslation(At + ToEye * 1.5);
            HoverRings[Hand].SetRotation(rotator(ToEye));
            HoverRings[Hand].SetScale(FClamp(Extents[Hand] * Scale * 1.1, 2.0, 5.0));
            HoverRings[Hand].SetHidden(false);
            HoverRings[Hand].ForceUpdate(true);
        }
    }
}

function Hide()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Shells[Hand] != None) Shells[Hand].SetHidden(true);
        if (HoverRings[Hand] != None) HoverRings[Hand].SetHidden(true);
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
            if (HoverRings[Hand] != None) Owner.Bridge.DetachComponent(HoverRings[Hand]);
        }
        Shells[Hand] = None; HoverRings[Hand] = None; HoverMaterials[Hand] = None;
        ShownWeapons[Hand] = None;
    }
    Owner = None;
}
