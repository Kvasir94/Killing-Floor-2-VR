// Raw animation seconds, independent of perk playback rate. These spans are
// the stock part/contact motion, not wall-clock reload payment notifies.
class VRSecondaryReloadCatalog extends Object;

static function bool Supported(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_AssaultRifle_M16M203'
        || W.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle'
        || W.Class == class'KFWeap_AssaultRifle_HRGTeslauncher'
        || W.Class == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher'
        || W.Class == class'KFWeap_AssaultRifle_FAMAS'
        || W.Class == class'KFWeap_Shotgun_S12');
}

// Canonical private reference: perk rate and live primary clip are unrelated.
static function name ReferenceClip(KFWeapon W)
{
    if (W.Class == class'KFWeap_AssaultRifle_FAMAS')
        return W.AmmoCount[1] == 0 ? 'Reload_Secondary_Empty' : 'Reload_Secondary_Half';
    return 'Reload_Secondary';
}

// Physical phases, independent of the narrower wrist-motion sample windows.
// Match the stock event itself; retain its original ordering and gaps in the
// selected clip. 0 opening/removal, 1 seating, 2 closing, -1 unrelated.
static function int SoundPhase(KFWeapon W, name SoundName)
{
    if (!Supported(W)) return -1;
    if (W.Class == class'KFWeap_AssaultRifle_FAMAS')
    {
        if (SoundName == 'Play_WEP_HZ12_Back' || SoundName == 'Play_WEP_HZ12_Mag_Out') return 0;
        if (SoundName == 'Play_WEP_HZ12_Mag_In') return 1;
        if (SoundName == 'Play_WEP_HZ12_FWD') return 2;
    }
    else if (W.Class == class'KFWeap_Shotgun_S12')
    {
        if (SoundName == 'Play_WEP_Saiga12_Handling_AltMagOut') return 0;
        if (SoundName == 'Play_WEP_Saiga12_Handling_AltMagIn') return 1;
    }
    else if (W.Class == class'KFWeap_AssaultRifle_M16M203'
        || W.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle')
    {
        if (SoundName == 'Play_M203_Open_Barrel') return 0;
        if (SoundName == 'Play_M203_Insert_Round') return 1;
        if (SoundName == 'Play_M203_Close_Barrel') return 2;
    }
    else
    {
        if (SoundName == 'Play_WEP_Medic_GrenadeLauncher_SecondaryOpen_01') return 0;
        if (SoundName == 'Play_WEP_Medic_GrenadeLauncher_Grenade_Insert'
            || SoundName == 'Play_WEP_HRG_Teslauncher_ElectricFX_B') return 1;
        if (SoundName == 'Play_WEP_Medic_GrenadeLauncher_SecondaryClose_01') return 2;
        // The same spinner event occurs on either side of the insertion.
        // Its phase is resolved against that clip's insertion notify below.
        if (SoundName == 'Play_WEP_Medic_GrenadeLauncher_Spinner') return 3;
    }
    return -1;
}

// Exact secondary subassemblies from each shipped mesh skeleton. Primary
// magazines, bolts and weapon roots must never be controlled by this session.
static function ControlBones(KFWeapon W, out array<name> Bones)
{
    ControlBonesForClass(W.Class, Bones);
}

static function ControlBonesForClass(class<KFWeapon> WeaponClass, out array<name> Bones)
{
    Bones.Length = 0;
    if (WeaponClass == class'KFWeap_Shotgun_S12') { Bones.AddItem('RW_Launcher'); return; }
    if (WeaponClass == class'KFWeap_AssaultRifle_FAMAS')
    {
        Bones.AddItem('RW_Magazine2'); Bones.AddItem('RW_M26_Shell1');
        Bones.AddItem('RW_Charging_Handle'); return;
    }
    if (WeaponClass == class'KFWeap_AssaultRifle_M16M203'
        || WeaponClass == class'KFWeap_AssaultRifle_HRGIncendiaryRifle')
    {
        Bones.AddItem('RW_ForeGrip'); Bones.AddItem('RW_Empty_Shell1');
    }
    else
    {
        Bones.AddItem('RW_InnerSleeve'); Bones.AddItem('RW_ChamberLength');
        Bones.AddItem('RW_LauncherCrank');
    }
    Bones.AddItem('RW_Pump'); Bones.AddItem('RW_Shell1');
}

// A charging-handle stroke sampled from the stock shot clip instead of the
// reload clip. The FAMAS reload's open window ends with the stock left wrist
// already 15 UU behind and 10 UU below the handle, on its way to the magazine,
// and its close starts with the hand arriving from below: both strokes showed
// that departing pose at full travel (#9, #127). Shoot_Secondary works the
// same handle with the wrist rigid on it (frames 16-26 at 30 fps, one wrist
// offset within 3.5 degrees): 16-20 pulls it 5.4 UU back, 20-26 returns it.
// Used only for a stage whose anchor is this bone.
static function bool ActionStroke(class<KFWeapon> WeaponClass, int Stage, out name Bone,
    out name Clip, out float First, out float Last)
{
    if (WeaponClass != class'KFWeap_AssaultRifle_FAMAS' || (Stage != 0 && Stage != 2)) return false;
    Bone = 'RW_Charging_Handle'; Clip = 'Shoot_Secondary';
    First = Stage == 0 ? 0.533333 : 0.666667;
    Last = Stage == 0 ? 0.666667 : 0.866667;
    return true;
}

// R20: the pump is a support grip. The hand is held on this bone with the
// stock shot clip's wrist and fingers at the moment it has closed on the
// handle (Shoot_Secondary frame 16), so it rides the handle through a stroke.
static function bool PumpGrip(class<KFWeapon> WeaponClass, out name Bone, out name Clip, out float Time)
{
    if (WeaponClass != class'KFWeap_AssaultRifle_FAMAS') return false;
    Bone = 'RW_Charging_Handle'; Clip = 'Shoot_Secondary'; Time = 0.533333;
    return true;
}

static function bool GetProfile(KFWeapon W, name Clip, out name Action, out name Ammo,
    out float OpenStart, out float OpenEnd, out float LoadStart, out float LoadEnd,
    out float CloseStart, out float CloseEnd)
{
    local bool Elite;
    if (!Supported(W)) return false;
    Elite = InStr(string(Clip), "Elite") >= 0;
    if (W.Class == class'KFWeap_AssaultRifle_FAMAS')
    {
        Action = 'RW_Charging_Handle'; Ammo = 'RW_Magazine2';
        if (Clip == 'Reload_Secondary_Half' || Clip == 'Reload_Secondary_Elite_Half')
        {
            Action=Ammo;
            OpenStart=Elite ? 0.243939 : 0.333333;
            OpenEnd=Elite ? 0.348485 : 0.433333;
            CloseStart=0; CloseEnd=0;
            LoadStart=Elite ? 0.696970 : 0.933333;
            LoadEnd=Elite ? 0.940909 : 1.166667;
            return true;
        }
        if (Clip != 'Reload_Secondary_Empty' && Clip != 'Reload_Secondary_Elite_Empty') return false;
        OpenStart=Elite ? 0.2 : 0.333333; OpenEnd=Elite ? 0.4 : 0.666667;
        LoadStart=Elite ? 1.066667 : 1.466667; LoadEnd=Elite ? 1.2 : 1.666667;
        CloseStart=Elite ? 1.4 : 2.133333; CloseEnd=Elite ? 1.6 : 2.333333;
        return true;
    }
    if (Clip != 'Reload_Secondary' && Clip != 'Reload_Secondary_Elite') return false;
    if (W.Class == class'KFWeap_Shotgun_S12')
    {
        // The launcher bone is the removable cartridge, not the primary mag.
        Action='RW_Launcher'; Ammo='RW_Launcher';
        OpenStart=0.6; OpenEnd=0.633333; LoadStart=1.466667; LoadEnd=2.0;
        CloseStart=0; CloseEnd=0;
        return true;
    }
    Action='RW_Pump'; Ammo='RW_Shell1';
    if (W.Class == class'KFWeap_AssaultRifle_M16M203'
        || W.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle')
    {
        OpenStart=Elite ? 0.183333 : 0.266667; OpenEnd=Elite ? 0.4 : 0.5;
        LoadStart=Elite ? 1.1 : 1.4; LoadEnd=Elite ? 1.4 : 1.8;
        CloseStart=Elite ? 1.666667 : 2.2; CloseEnd=Elite ? 1.866667 : 2.4;
    }
    else
    {
        OpenStart=Elite ? 0.133333 : 0.266667; OpenEnd=Elite ? 0.333333 : 0.533333;
        LoadStart=Elite ? 0.866667 : 1.4; LoadEnd=Elite ? 1.133333 : 1.8;
        CloseStart=Elite ? 1.333333 : 2.2; CloseEnd=Elite ? 1.533333 : 2.4;
    }
    return true;
}
