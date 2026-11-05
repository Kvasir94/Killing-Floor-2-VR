// One stock-geometry hint shell, attached to its original live bone. Used by
// mechanisms whose parts move independently of the magazine/well/action trio.
class VRReloadPartGlow extends Object;

var VRInteractiveReload Owner;
var StaticMeshComponent Component;
var MaterialInstanceConstant GlowMaterial;
var name MeshFor;
var string KindFor;
var StaticMesh Mesh;

function Initialize(VRInteractiveReload O) { Owner = O; }

function Hide()
{
    if (Component != None) Component.SetHidden(true);
}

function Place(KFWeapon W, string Kind, name Bone, float Alpha, bool bAction)
{
    local Material Parent;
    if (Owner == None || Owner.Bridge == None || !Owner.Bridge.bReloadHints
        || W == None || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None
        || W.MySkelMesh.MatchRefBone(Bone) < 0 || Alpha <= 0.005)
    { Hide(); return; }
    Owner.EnsureVisuals();
    if (!Owner.bRingMesh) { Hide(); return; }
    if (MeshFor != W.MySkelMesh.SkeletalMesh.Name || KindFor != Kind)
    {
        Hide(); MeshFor = W.MySkelMesh.SkeletalMesh.Name; KindFor = Kind;
        Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlow" $ Kind $ "_" $ MeshFor, class'StaticMesh', true));
    }
    if (Mesh == None) { Hide(); return; }
    if (Component == None)
    {
        Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
        GlowMaterial = Owner.MakeRingMaterial(Parent, bAction ? class'VRInteractionColours'.const.ROLE_ACTION : class'VRInteractionColours'.const.ROLE_AMMO);
        GlowMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', bAction ? 2.5 : 1.5);
        Component = Owner.MakeComponent(Mesh, GlowMaterial);
    }
    else if (Component.StaticMesh != Mesh) Component.SetStaticMesh(Mesh);
    Component.SetMaterial(0, GlowMaterial);
    Owner.SetGlow(GlowMaterial, bAction ? Owner.RackColour : Owner.AmmoColour);
    Component.SetDepthPriorityGroup(W.MySkelMesh.DepthPriorityGroup);
    GlowMaterial.SetScalarParameterValue('Scalar_Opacity', bAction ? Alpha : Alpha * Owner.AmmoShellOpacity);
    Owner.PlaceProp(Component, W.MySkelMesh.GetBoneLocation(Bone),
        W.MySkelMesh.GetBoneQuaternion(Bone), Owner.ScaleOf(W));
}

function Shutdown()
{
    if (Owner != None && Owner.Bridge != None && Component != None)
        Owner.Bridge.DetachComponent(Component);
    Component = None; GlowMaterial = None; Mesh = None; Owner = None;
}
