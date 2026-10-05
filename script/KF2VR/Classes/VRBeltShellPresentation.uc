// Reserve shells stay on the existing pouch even when no reload is running.
// These are local display props: ownership, pickup, stock ammo and reload
// credits remain entirely with VRInteractiveReload and the weapon.
class VRBeltShellPresentation extends Object;

var VRInteractiveReload Owner;
var StaticMeshComponent Shells[2];
var KFWeapon ShownWeapons[2];
var vector Centres[2];

function Initialize(VRInteractiveReload R) { Owner = R; }

function bool Covers(KFWeapon W)
{
    if (W == None || (!W.IsA('KFWeap_ShotgunBase') && !W.IsA('KFWeap_Rifle_FrostShotgunAxe')))
        return false;
    // Magazine-fed shotguns keep their existing magazine presentation.
    return class'VRPumpCatalog'.static.Covers(W)
        || (class'VRBreakCatalog'.static.Covers(W)
            && class'VRBreakCatalog'.static.ShellBone(W.Class, 0) != '');
}

function Prepare(int Hand, KFWeapon W)
{
    local StaticMesh Mesh;
    local SkeletalMesh MaterialMesh;
    local MaterialInterface Surface;
    local int Profile;
    Owner.EnsureVisuals();
    if (Shells[Hand] == None)
        Shells[Hand] = Owner.MakeComponent(StaticMesh'EngineMeshes.Cube', Owner.CubeMaterial);
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ W.MySkelMesh.SkeletalMesh.Name,
        class'StaticMesh', true));
    Profile = class'VRBreakCatalog'.static.FindClass(W.Class);
    Surface = W.MySkelMesh.GetMaterial(Profile >= 0
        ? class'VRBreakCatalog'.default.Profiles[Profile].MaterialIndex : 0);
    Profile = class'VRPumpCatalog'.static.FindClass(W.Class);
    if (Profile >= 0 && class'VRPumpCatalog'.default.Profiles[Profile].AmmoMaterialMesh != "")
    {
        MaterialMesh = SkeletalMesh(DynamicLoadObject(
            class'VRPumpCatalog'.default.Profiles[Profile].AmmoMaterialMesh, class'SkeletalMesh', true));
        if (MaterialMesh != None && MaterialMesh.Materials.Length > 0) Surface = MaterialMesh.Materials[0];
    }
    if (Mesh != None)
    {
        Shells[Hand].SetStaticMesh(Mesh);
        Shells[Hand].SetMaterial(0, Surface);
        Shells[Hand].SetScale3D(vect(1,1,1));
    }
    else
    {
        // Match the existing carried-shell fallback when its asset is absent.
        Shells[Hand].SetStaticMesh(StaticMesh'EngineMeshes.Cube');
        Shells[Hand].SetMaterial(0, Owner.CubeMaterial);
        Shells[Hand].SetScale3D(vect(6.5,1.9,1.9) / 256.0);
    }
    Shells[Hand].SetScale(1);
    Shells[Hand].SetRotation(rot(0,0,0));
    Shells[Hand].SetTranslation(vect(0,0,0));
    Shells[Hand].ForceUpdate(true);
    Centres[Hand] = Shells[Hand].Bounds.Origin;
    if (VSize(Shells[Hand].Bounds.BoxExtent) < 0.5 || VSize(Centres[Hand]) > 50)
        Centres[Hand] = vect(0,0,0);
    ShownWeapons[Hand] = W;
}

function Place()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    local int Hand;
    local float Scale;
    local vector At;
    local quat Q;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Owner.InputOwner.Inventory.Registry.GetPrimary(Hand);
        if (R == None || !R.IsCurrent()) continue;
        W = R.Item;
        if (!Covers(W) || W.bDeleteMe || W.SpareAmmoCount[0] <= 0
            || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) continue;
        if (ShownWeapons[Hand] != W) Prepare(Hand, W);
        Scale = Owner.ScaleOf(W);
        Q = QuatProduct(QuatFromRotator(Owner.Torso()), QuatFromRotator(rot(16384,0,0)));
        At = Owner.BeltPositionFor(1 - Hand);
        Owner.PlaceProp(Shells[Hand], At - QuatRotateVector(Q, Centres[Hand] * Scale), Q, Scale);
    }
}

function Hide()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
        if (Shells[Hand] != None) Shells[Hand].SetHidden(true);
}

function Shutdown()
{
    local int Hand;
    Hide();
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Shells[Hand] != None && Owner.Bridge != None) Owner.Bridge.DetachComponent(Shells[Hand]);
        Shells[Hand] = None;
        ShownWeapons[Hand] = None;
    }
    Owner = None;
}
