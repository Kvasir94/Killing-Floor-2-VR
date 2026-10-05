// Shared held/thrown/dropped RAVEN-7 material contract; instances never mutate stock assets.
class VRTomahawkMaterials extends Object;

// Per-slot response on the shared arms parent: polished steel and blade keep
// a tight bright highlight, ceramic and armor a broader dull one, tape none.
static function Dress(Object Target, MeshComponent Mesh, int Slot, string Prefix, float Reflection, float SpecPower)
{
    local MaterialInstanceConstant M;
    M = class'VRHUDPanel'.static.CreateHorzineMaterial(Target, Prefix);
    if (M == None) return;
    M.SetScalarParameterValue('scalar_reflectionIntensity', Reflection);
    M.SetScalarParameterValue('Scalar_SpecPower', SpecPower);
    Mesh.SetMaterial(Slot, M);
}

static function Apply(Object Target, MeshComponent Mesh)
{
    local MaterialInstanceConstant Glow;
    local Material Parent;
    local Texture2D Texture;
    local LinearColor Cyan;
    Dress(Target, Mesh, 0, "VRTomahawkSteel", 0.40, 44);
    Dress(Target, Mesh, 1, "VRTomahawkGrip", 0.06, 8);
    Dress(Target, Mesh, 2, "VRTomahawkArmor", 0.18, 20);
    Dress(Target, Mesh, 3, "VRTomahawkEnergy", 0.2, 24);
    Dress(Target, Mesh, 4, "VRTomahawkRed", 0.12, 16);
    Dress(Target, Mesh, 5, "VRTomahawkMarking", 0.12, 16);
    Dress(Target, Mesh, 6, "VRTomahawkBlade", 0.45, 48);
    Dress(Target, Mesh, 7, "VRTomahawkCeramic", 0.18, 20);
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    Texture = Texture2D(DynamicLoadObject("KF2VRHands.VRTomahawkEnergy_D", class'Texture2D', true));
    if (Parent == None || Texture == None) return;
    Glow = new(Target) class'MaterialInstanceConstant';
    Glow.SetParent(Parent);
    Glow.SetTextureParameterValue('Texture_D', Texture);
    // The texture carries a white-hot core; a cyan tint and more intensity
    // let KF2's bloom spread the reference's halo around the edge.
    Cyan.R = 0.40; Cyan.G = 0.92; Cyan.B = 1.0; Cyan.A = 1;
    Glow.SetVectorParameterValue('Vector_Glow_Color', Cyan);
    Glow.SetScalarParameterValue('Scalar_Glow_Intensity', 2.4);
    Glow.SetScalarParameterValue('Scalar_Opacity', 1.0);
    Mesh.SetMaterial(3, Glow);
}
