// Each held gun owns its fitted glow meshes, clocks and components. Rings
// may select one next instruction, but neither hand can steal the other's glow.
class VRReloadPartHints extends Object;

var VRInteractiveReload Owner;
var KFWeapon Key;
var name MeshName;
var StaticMesh Meshes[3];
var StaticMeshComponent Parts[3];
var MaterialInstanceConstant Materials[3];
var byte Armed[3];
var float Since[3], ShownAt[3];

function Initialize(VRInteractiveReload O, Material Parent)
{
    local int I;
    Owner = O;
    for (I = 0; I < 3; ++I)
    {
        Materials[I] = Owner.MakeRingMaterial(Parent, I == 2 ? class'VRInteractionColours'.const.ROLE_ACTION : class'VRInteractionColours'.const.ROLE_AMMO);
        // Blue shells at the cue hologram's intensity; 2.5 washed the blue to
        // a flat pastel over the whole part (#121). Amber keeps its punch.
        Materials[I].SetScalarParameterValue('Scalar_Glow_Intensity', I == 2 ? 2.5 : 1.5);
        Materials[I].SetScalarParameterValue('Scalar_Opacity', 0);
        Parts[I] = Owner.MakeComponent(StaticMesh'EngineMeshes.Cube', Materials[I]);
    }
}

function bool Ready(KFWeapon W)
{
    local int I, Profile;
    local bool bPump, bBreak;
    if (W == None || W.bDeleteMe || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) return false;
    bPump = class'VRPumpCatalog'.static.Covers(W);
    bBreak = class'VRBreakAction'.static.Supported(W);
    Profile = class'VRReloadCatalog'.static.FindClass(W.Class);
    if (!bPump && !bBreak && Profile < 0) return false;
    if (MeshName != W.MySkelMesh.SkeletalMesh.Name)
    {
        MeshName = W.MySkelMesh.SkeletalMesh.Name;
        Meshes[0] = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowMag_" $ MeshName, class'StaticMesh', true));
        Meshes[1] = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowWell_" $ MeshName, class'StaticMesh', true));
        Meshes[2] = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowSlide_" $ MeshName, class'StaticMesh', true));
        for (I = 0; I < 3; ++I)
        {
            Parts[I].SetHidden(true);
            if (Meshes[I] != None) { Parts[I].SetStaticMesh(Meshes[I]); Parts[I].SetMaterial(0, Materials[I]); }
        }
    }
    if (bPump) return Meshes[1] != None || Meshes[2] != None;
    if (bBreak) return Meshes[0] != None || Meshes[1] != None || Meshes[2] != None;
    return Meshes[0] != None || Meshes[1] != None || Meshes[2] != None;
}

function Update(KFWeapon W, bool bMagazine, bool bWell, bool bSlide)
{
    local int I;
    local bool bWanted;
    if (Owner.CluesAutomatic(W)) { bMagazine = false; bWell = false; bSlide = false; }
    if (Owner.ActionClueOwned(W)) bSlide = false;
    if (!Owner.Bridge.bReloadHints || W == None) { W = None; bMagazine = false; bWell = false; bSlide = false; }
    if (Key != W)
    {
        Key = W;
        for (I = 0; I < 3; ++I) Armed[I] = 0;
    }
    for (I = 0; I < 3; ++I)
    {
        bWanted = I == 0 ? bMagazine : (I == 1 ? bWell : bSlide);
        if (!bWanted) { Armed[I] = 0; continue; }
        if (Armed[I] == 0) { Armed[I] = 1; Since[I] = Owner.Now(); ShownAt[I] = 0; }
        if (ShownAt[I] == 0 && Visible(I)) ShownAt[I] = Owner.Now();
    }
}

function bool Visible(int Part)
{
    return Owner.Bridge.bReloadHints && Armed[Part] != 0
        && (Owner.Now() - Since[Part] >= Owner.HintDelay
            || Owner.RepeatedDryFire(Key) || Owner.ClueContactNear(Key, Part)
            || (Part < 2 && Owner.OptionalAmmoClue(Key)));
}

function Place(KFWeapon W)
{
    local int I;
    local float Alpha;
    local name Bone;
    if (!Ready(W) || W != Key) { Hide(); return; }
    for (I = 0; I < 3; ++I)
    {
        Bone = Owner.GlowBone(W, I);
        if (!Visible(I) || ShownAt[I] <= 0 || Meshes[I] == None || W.MySkelMesh.MatchRefBone(Bone) < 0)
        { Parts[I].SetHidden(true); continue; }
        Alpha = Owner.ClueAlpha(Since[I], W, Owner.ClueContactNear(W, I));
        if (I < 2 && Owner.OptionalAmmoClue(W) && !Owner.ClueContactNear(W, I)) Alpha = 0.18;
        // A blue tint over the gun's own shading, not a flat coat of pastel
        // paint (#121).
        if (I < 2) Alpha *= Owner.AmmoShellOpacity;
        Parts[I].SetDepthPriorityGroup(W.MySkelMesh.DepthPriorityGroup);
        Owner.SetGlow(Materials[I], I == 2 ? Owner.RackColour : Owner.AmmoColour);
        Materials[I].SetScalarParameterValue('Scalar_Opacity', Alpha);
        Owner.PlaceProp(Parts[I], W.MySkelMesh.GetBoneLocation(Bone), W.MySkelMesh.GetBoneQuaternion(Bone), Owner.ScaleOf(W));
    }
}

function Hide()
{
    local int I;
    for (I = 0; I < 3; ++I) if (Parts[I] != None) Parts[I].SetHidden(true);
}

function Shutdown()
{
    local int I;
    for (I = 0; I < 3; ++I)
        if (Parts[I] != None) Owner.Bridge.DetachComponent(Parts[I]);
    Owner = None; Key = None;
}
