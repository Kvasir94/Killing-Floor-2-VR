// Asset-free allowlist shared by authority and observer bindings.
class KF2VRNetMechanismCatalog extends Object;

static function Add(out array<name> Bones, name Bone)
{
    if (Bone != '' && Bone != 'RW_Weapon' && Bones.Find(Bone) == INDEX_NONE) Bones.AddItem(Bone);
}

static function Collect(class<KFWeapon> WeaponClass, out array<name> Bones)
{
    local int Profile, I, J;
    local array<name> Secondary;
    Bones.Length = 0;
    if (WeaponClass == None) return;
    Profile = class'VRReloadCatalog'.static.FindClass(WeaponClass);
    if (Profile >= 0)
    {
        Add(Bones, class'VRReloadCatalog'.default.Profiles[Profile].RackBone);
        Add(Bones, class'VRReloadCatalog'.default.Profiles[Profile].FollowBone);
        Add(Bones, class'VRReloadCatalog'.static.MagazineBone(Profile, false));
        Add(Bones, class'VRReloadCatalog'.static.MagazineBone(Profile, true));
    }
    Profile = class'VRCycleCatalog'.static.FindClass(WeaponClass);
    if (Profile >= 0)
        for (I = 0; I < 3; ++I) Add(Bones, class'VRCycleCatalog'.default.Profiles[Profile].Bones[I]);
    Profile = class'VRPumpCatalog'.static.FindClass(WeaponClass);
    if (Profile >= 0)
        for (I = 0; I < 3; ++I) Add(Bones, class'VRPumpCatalog'.default.Profiles[Profile].LeverBones[I]);
    if ((Profile >= 0 && class'VRPumpCatalog'.default.Profiles[Profile].bPumpAction)
        || class'VRPumpCatalog'.static.CycleOnlyIndex(WeaponClass) >= 0)
    {
        Add(Bones, class'VRPumpCatalog'.static.PumpBoneForClass(WeaponClass));
        Add(Bones, 'RW_Pump'); Add(Bones, 'RW_Bolt'); Add(Bones, 'RW_Bolt_Slide'); Add(Bones, 'RW_Bolt_Elevator');
    }
    Profile = class'VRBreakCatalog'.static.FindClass(WeaponClass);
    if (Profile >= 0)
    {
        for (I = 0; I < class'VRBreakCatalog'.const.MaxPathBones; ++I)
            Add(Bones, class'VRBreakCatalog'.default.Profiles[Profile].PathBones[I]);
        for (I = 0; I < 4; ++I) Add(Bones, class'VRBreakCatalog'.default.Profiles[Profile].ShellBones[I]);
        Add(Bones, class'VRBreakCatalog'.default.Profiles[Profile].ClipBone);
        Add(Bones, 'RW_Barrel');
    }
    if (WeaponClass == class'KFWeap_GrenadeLauncher_M32') Add(Bones, 'RW_Cylinder_Pivot_Main');
    if (WeaponClass == class'KFWeap_AssaultRifle_M16M203' || WeaponClass == class'KFWeap_AssaultRifle_HRGIncendiaryRifle'
        || WeaponClass == class'KFWeap_AssaultRifle_HRGTeslauncher' || WeaponClass == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher'
        || WeaponClass == class'KFWeap_AssaultRifle_FAMAS' || WeaponClass == class'KFWeap_Shotgun_S12')
    {
        class'VRSecondaryReloadCatalog'.static.ControlBonesForClass(WeaponClass, Secondary);
        for (I = 0; I < Secondary.Length; ++I) Add(Bones, Secondary[I]);
    }
    for (I = 0; I < class'VRReloadFinishCatalog'.default.Profiles.Length; ++I)
        if (class'VRReloadCatalog'.static.ProfileClass(WeaponClass) == class'VRReloadFinishCatalog'.default.Profiles[I].WeaponClass)
        {
            Add(Bones, class'VRReloadFinishCatalog'.default.Profiles[I].Bone);
            for (J = 0; J < 12; ++J) Add(Bones, class'VRReloadFinishCatalog'.default.Profiles[I].FollowBones[J]);
        }
}
