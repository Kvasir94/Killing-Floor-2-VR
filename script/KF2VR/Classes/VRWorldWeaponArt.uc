// Stock knife world art in the authored first-person weapon root frame.
class VRWorldWeaponArt extends Object abstract;

static function string KnifeSuffix(class<Inventory> ItemClass)
{
    if(ItemClass==None) return "";
    switch(ItemClass.Name)
    {
    case 'KFWeap_Knife_Commando': return "Commando";
    case 'KFWeap_Knife_Gunslinger': return "Gunslinger";
    case 'KFWeap_Knife_Firebug': return "Firebug";
    case 'KFWeap_Knife_Survivalist': return "Survivalist";
    case 'KFWeap_Knife_Sharpshooter': return "Sharpshooter";
    case 'KFWeap_Knife_Berserker': return "Berserker";
    case 'KFWeap_Knife_Support': return "Support";
    case 'KFWeap_Knife_FieldMedic': return "FieldMedic";
    case 'KFWeap_Knife_SWAT': return "SWAT";
    case 'KFWeap_Knife_Demolitionist': return "Demolitionist";
    }
    return "";
}

static function StaticMesh KnifeMesh(class<Inventory> ItemClass)
{
    local string S;
    S=KnifeSuffix(ItemClass);
    return S=="" ? None : StaticMesh(DynamicLoadObject("KF2VRHands.VRWorldKnife"$S,class'StaticMesh',true));
}

static function bool IsKnifeMesh(class<Inventory> ItemClass,StaticMesh Mesh)
{
    local string S;
    S=KnifeSuffix(ItemClass);
    // string(Mesh) is only the object name; PathName carries the package.
    return S!="" && Mesh!=None && Caps(PathName(Mesh))==Caps("KF2VRHands.VRWorldKnife"$S);
}

// These are the same stock Idle wrists used by the normal held presenter.
static function bool KnifeGrip(class<Inventory> ItemClass,out vector Primary)
{
    if(KnifeSuffix(ItemClass)=="") return false;
    // All ten stock meshes use the same Commando knife Idle animation.
    Primary=vect(-7.463519,-3.576091,-0.478077);
    return true;
}

static function ApplyKnifeMaterials(MeshComponent Mesh,class<Inventory> ItemClass,optional KFWeapon W)
{
    local class<KFWeapon> WeaponClass;
    local SkeletalMesh Model;
    local MaterialInterface Material;
    local int I;
    if(Mesh==None || KnifeSuffix(ItemClass)=="") return;
    WeaponClass=class<KFWeapon>(ItemClass);
    if(WeaponClass==None) return;
    Model=SkeletalMesh(DynamicLoadObject(WeaponClass.default.FirstPersonMeshName,class'SkeletalMesh',true));
    if(Model==None) return;
    for(I=0;I<Model.Materials.Length;++I)
    {
        Material=Model.Materials[I];
        if(W!=None && W.MySkelMesh!=None && W.MySkelMesh.SkeletalMesh==Model)
            Material=W.MySkelMesh.GetMaterial(I);
        if(Material!=None) Mesh.SetMaterial(I,Material);
    }
}
