// Audited detachable-magazine rigs. Exact classes exclude paired and derivative weapons
// whose loaded/spare geometry or stock reload contract has not been checked.
class VRReloadCatalog extends Object;

struct MagazineProfile
{
    var class<KFWeapon> WeaponClass;
    var name MeshName;
    var name RackBone;
    var int MaterialIndex;
    // The gun's slot for the prop's second mesh section, when its magazine
    // spans two (generate_reload_props.py writes sections in ascending slot
    // order). A one-section prop ignores it.
    var int Section1MaterialIndex;
    // A pistol whose slide locks back on the last round (AS2 slideLockOnEmptyMag;
    // its AK and M4 do not). The live gun must also carry KF2's own lock pose.
    var bool bSlideLock;
    // A second action part that rides the rack without being grabbed: the
    // AR-15, SCAR and MP7 rigs animate the bolt carrier and the charging handle
    // as separate children of the receiver, so pulling the handle alone would
    // leave the bolt shut. Its own stroke is measured from the empty reload.
    var name FollowBone;
    // Real loaded geometry under a spare-magazine bone name (the FAMAS's M26
    // magazine is RW_Magazine2): never hidden as a spare; the incoming
    // magazine is then the loaded bone's own return.
    var name KeepBone;
    // A gun whose magazine is not RW_Magazine1/RW_Magazine2 (the Blunderbuss
    // swaps its RW_Cylinder; the spare RW_Cylinder2 rides the hidden arm).
    var name LoadedBone, SpareBone;
    // A part stock seats into a moving assembly (the Freeze Thrower's open
    // chamber) or that stock finishes sliding home after its ammo moment (the
    // Ballistic Bouncer's canister): the hand seats it where the stock clip
    // has it at that moment, and the clip carries it on.
    var bool bSeatAtNotify;
    // Some clips withdraw the hand before the insertion lead. Sample an
    // earlier finger contact for free carry without extending the seat path.
    var bool bEarlierCarryGrip;
    // A third material slot (the Bouncer's canister: body, glass, trim).
    var int Section2MaterialIndex;
    // Nothing leaves the gun at the start (a fired rocket, the Doshinegun's
    // spent dosh): no old magazine drops.
    var bool bNoEject;
    // The loaded bone rests with the hidden arm in Idle (the Doshinegun's
    // wad) and is hidden like a spare outside reloads.
    var bool bParkedLoaded;
    // Parts that leave and return with the loaded bone but hang from the gun
    // (the Pulverizer's four shells and spring plate on its clip).
    var name LoadedExtras[5];
    // How the empty reload works the action, read from the stock empty clip:
    // 0 rack (pull to the rear stop, the spring returns it), 1 open bolt (an
    // empty gun's handle sits forward; pulling it to the rear cocks it and it
    // stays there: Tommy Gun, Mac-10), 2 none (the empty reload only swaps
    // the magazine: Zed MKIII), 3 notch lock (pulled fully back before the
    // magazine and let go, the handle parks in its notch; once loaded, it is
    // released by a pull and let-go, a slap: MP5, UMP).
    var byte ActionKind;
};
var array<MagazineProfile> Profiles;

static function int FindClass(class<KFWeapon> WeaponClass)
{
    local int I;
    for (I = 0; I < default.Profiles.Length; ++I)
        if (default.Profiles[I].WeaponClass == WeaponClass) return I;
    return -1;
}

// Shared by runtime preflight and the data-only SDK check. An unavailable or
// replaced asset must leave the stock reload and its visible geometry alone.
static function bool HasAssets(int Index, KFSkeletalMeshComponent M, StaticMesh Prop, MaterialInterface Surface)
{
    if (Index < 0 || Index >= default.Profiles.Length || M == None || M.SkeletalMesh == None
        || Prop == None || Surface == None) return false;
    return M.SkeletalMesh.Name == default.Profiles[Index].MeshName
        && Prop.Name == name("VRAmmo_" $ default.Profiles[Index].MeshName)
        && M.MatchRefBone('RW_Weapon') >= 0 && M.MatchRefBone(MagazineBone(Index, false)) >= 0
        && M.MatchRefBone(MagazineBone(Index, true)) >= 0 && M.MatchRefBone('LeftHand_1stP') >= 0
        && M.MatchRefBone(default.Profiles[Index].RackBone) >= 0
        && (default.Profiles[Index].FollowBone == '' || M.MatchRefBone(default.Profiles[Index].FollowBone) >= 0);
}

// The weapon's stock EmptyMagBlend lock must hold this profile's action, so
// the idle empty gun, the reload and a recovered lock all show one state.
// The loaded (or, with bSpare, the spare) magazine bone of a profile.
static function name MagazineBone(int Index, bool bSpare)
{
    if (Index >= 0 && Index < default.Profiles.Length)
    {
        if (!bSpare && default.Profiles[Index].LoadedBone != '') return default.Profiles[Index].LoadedBone;
        if (bSpare && default.Profiles[Index].SpareBone != '') return default.Profiles[Index].SpareBone;
    }
    return bSpare ? 'RW_Magazine2' : 'RW_Magazine1';
}

static function name KeptBone(KFWeapon W)
{
    local int I;
    if (W == None) return '';
    for (I = 0; I < default.Profiles.Length; ++I)
        if (default.Profiles[I].WeaponClass == W.Class) return default.Profiles[I].KeepBone;
    return '';
}

static function bool SlideLocks(KFWeapon W)
{
    local int Index;
    if (W == None) return false;
    Index = FindClass(W.Class);
    return Index >= 0 && default.Profiles[Index].bSlideLock && W.EmptyMagBlendNode != None
        && W.BonesToLockOnEmpty.Find(default.Profiles[Index].RackBone) != INDEX_NONE;
}

static function bool UsableSample(VRReloadRigSampler Sample, bool bEmpty)
{
    return Sample != None && Sample.Path.Length == 17 && Sample.SeatTime > 0
        && Sample.InsertLength > 0.1 && Sample.PathLength < 30
        && (!bEmpty || Sample.bRackSampled || Sample.ActionKind == 2);
}

static function byte ActionKindOf(int Index)
{
    if (Index < 0 || Index >= default.Profiles.Length) return 0;
    return default.Profiles[Index].ActionKind;
}

defaultproperties
{
    Profiles(0)=(WeaponClass=class'KFWeap_Pistol_Colt1911',MeshName=Wep_1stP_M1911_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    Profiles(1)=(WeaponClass=class'KFWeap_Pistol_Deagle',MeshName=Wep_1stP_Deagle_Rig,RackBone=RW_Slide,MaterialIndex=0,bSlideLock=true)
    Profiles(2)=(WeaponClass=class'KFWeap_Pistol_Medic',MeshName=Wep_1stP_Medic_Pistol_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    Profiles(3)=(WeaponClass=class'KFWeap_AssaultRifle_AK12',MeshName=Wep_1stP_AK12_Rig,RackBone=RW_Bolt,MaterialIndex=0)
    Profiles(4)=(WeaponClass=class'KFWeap_AssaultRifle_Bullpup',MeshName=Wep_1stP_L85A2_Rig,RackBone=RW_Bolt,MaterialIndex=0)
    Profiles(5)=(WeaponClass=class'KFWeap_Pistol_9mm',MeshName=Wep_1stP_9mm_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    // 2026-09-28 expansion: closed-bolt rifles, SMGs and the AA-12. None carries
    // a stock lock pose, so every empty reload racks from the closed action.
    Profiles(6)=(WeaponClass=class'KFWeap_Rifle_M14EBR',MeshName=WEP_1stP_M14_EBR,RackBone=RW_Bolt,MaterialIndex=0)
    Profiles(7)=(WeaponClass=class'KFWeap_Shotgun_AA12',MeshName=Wep_1stP_AA12_Rig,RackBone=RW_ChargingHandle,MaterialIndex=0)
    Profiles(8)=(WeaponClass=class'KFWeap_SMG_Medic',MeshName=Wep_1stP_Medic_SMG_Rig,RackBone=RW_Bolt,MaterialIndex=0)
    Profiles(9)=(WeaponClass=class'KFWeap_AssaultRifle_AR15',MeshName=Wep_1stP_AR15_9mm_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(10)=(WeaponClass=class'KFWeap_AssaultRifle_SCAR',MeshName=Wep_1stP_SCAR_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(11)=(WeaponClass=class'KFWeap_SMG_MP7',MeshName=Wep_1stP_MP7_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(12)=(WeaponClass=class'KFWeap_SMG_Kriss',MeshName=Wep_1stP_KRISS_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0)
    Profiles(13)=(WeaponClass=class'KFWeap_SMG_P90',MeshName=Wep_1stP_P90_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0)
    // 2026-09-30 wave, actions read from each stock empty clip: the G36C holds
    // open on KF2's own lock pose like the pistols; the Tommy Gun and Mac-10
    // are open-bolt guns cocked by one pull; the Zed MKIII has no action step;
    // the UMP's bolt catch has no stock lock pose and the MP5 slap is a plain pull.
    Profiles(14)=(WeaponClass=class'KFWeap_AssaultRifle_Thompson',MeshName=Wep_1stP_TommyGun_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt,ActionKind=1)
    Profiles(15)=(WeaponClass=class'KFWeap_SMG_Mac10',MeshName=Wep_1stP_MAC10_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt,ActionKind=1)
    Profiles(16)=(WeaponClass=class'KFWeap_AssaultRifle_G36C',MeshName=WEP_1stP_G36C_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,bSlideLock=true,FollowBone=RW_Bolt)
    Profiles(17)=(WeaponClass=class'KFWeap_ZedMKIII',MeshName=WEP_1stP_ZEDMKIII_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,ActionKind=2)
    Profiles(18)=(WeaponClass=class'KFWeap_HRG_Stunner',MeshName=Wep_1stP_HRG_Stunner_Rig,RackBone=RW_ChargingHandle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(19)=(WeaponClass=class'KFWeap_Shotgun_S12',MeshName=Wep_1stP_Saiga12_Rig,RackBone=RW_Bolt,MaterialIndex=0)
    Profiles(20)=(WeaponClass=class'KFWeap_SMG_HK_UMP',MeshName=Wep_1stP_HK_UMP_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt,ActionKind=3)
    Profiles(21)=(WeaponClass=class'KFWeap_SMG_MP5RAS',MeshName=Wep_1stP_MP5RAS_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt,ActionKind=3)
    // Two-material medic magazines: body and rounds use different slots.
    // Their fold-out handle rides the bolt, as on the HMTech-201.
    Profiles(22)=(WeaponClass=class'KFWeap_Shotgun_Medic',MeshName=Wep_1stP_Medic_Shotgun_Rig,RackBone=RW_Bolt,MaterialIndex=0,Section1MaterialIndex=1)
    Profiles(23)=(WeaponClass=class'KFWeap_AssaultRifle_Medic',MeshName=Wep_1stP_Medic_Assault_Rig,RackBone=RW_Bolt,MaterialIndex=0,Section1MaterialIndex=1)
    // 2026-09-30 pistols (roadmap wave 6). The Glock 18C and 93R hold their
    // slide back on KF2's own lock pose. The Disrupter's upper is one piece
    // with its frame (its RW_Bolt animates no geometry): no action step.
    Profiles(24)=(WeaponClass=class'KFWeap_Pistol_G18C',MeshName=Wep_1stP_G18C_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    Profiles(25)=(WeaponClass=class'KFWeap_HRG_93R',MeshName=WEP_1P_HRG_93R_Pistol_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    Profiles(26)=(WeaponClass=class'KFWeap_HRG_Energy',MeshName=WEP_1stP_HRG_Energy_Rig,RackBone=RW_Bolt,MaterialIndex=0,ActionKind=2)
    // 2026-10-01 MKb.42 (roadmap wave 7): an open-bolt gun like the Tommy Gun; its
    // charging handle is the bolt's child, and its eject cover never moves.
    Profiles(27)=(WeaponClass=class'KFWeap_AssaultRifle_MKB42',MeshName=Wep_1stP_MKB42_Rig,RackBone=RW_Bolt,MaterialIndex=0,ActionKind=1)
    // 2026-10-01 roadmap wave 12, read from each PSA: the FAMAS racks its
    // RW_Charging_Rod (8 UU; RW_Charging_Handle is the carry handle and never
    // moves); the FN FAL's and M16's handles drive their bolts (the M16's latch
    // is the handle's child); none of the rifles locks open. The AF2011's
    // slide holds back on its last shot. The FAMAS M26 and the M203 keep their
    // stock AltReloading.
    Profiles(28)=(WeaponClass=class'KFWeap_AssaultRifle_FAMAS',MeshName=WEP_1stP_Famas_Rig,RackBone=RW_Charging_Rod,MaterialIndex=0,KeepBone=RW_Magazine2)
    Profiles(29)=(WeaponClass=class'KFWeap_AssaultRifle_FNFal',MeshName=WEP_1stP_FNFAL_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(30)=(WeaponClass=class'KFWeap_AssaultRifle_M16M203',MeshName=Wep_1stP_M16_M203_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(31)=(WeaponClass=class'KFWeap_Pistol_AF2011',MeshName=Wep_1stP_AF2001_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    // 2026-10-01 roadmap wave 13: the Blunderbuss pulls its loaded RW_Cylinder
    // 48 UU out and the same bone returns refilled (Reload_Empty 0.5-1.0 s);
    // RW_Cylinder2 stays with the hidden arm. It has no action step: the
    // flintlock's hammer and frizzen stay on the stock clip after the seat.
    Profiles(32)=(WeaponClass=class'KFWeap_Pistol_Blunderbuss',MeshName=Wep_1stP_Blunderbuss_Rig,RackBone=RW_Hammer,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Cylinder,SpareBone=RW_Cylinder2)
    // 2026-10-01 roadmap waves 14-16, read from each PSA and checked offline
    // against the sampler's seat rules: magazines, batteries, tanks, rocket
    // pods and rockets. Most have no action step (ActionKind 2): their other
    // parts (Microwave Gun barrel, CaulkBurn handle, Nailgun air) stay on the
    // stock clip with their sounds. Where the loaded magazine returns refilled
    // on its own bone, LoadedBone and SpareBone name it. The riot-shield G18's
    // slide and the Boomy's open bolt hold back after the last shot.
    Profiles(33)=(WeaponClass=class'KFWeap_Shotgun_Nailgun',MeshName=Wep_1stP_Nail_ShotGun_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2)
    Profiles(34)=(WeaponClass=class'KFWeap_HRG_Nailgun',MeshName=Wep_1stP_HRG_Nailgun_PDW_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2)
    Profiles(35)=(WeaponClass=class'KFWeap_AssaultRifle_HRGIncendiaryRifle',MeshName=WEP_1stP_HRG_IncendiaryRifle_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,FollowBone=RW_Bolt)
    Profiles(36)=(WeaponClass=class'KFWeap_AssaultRifle_HRGTeslauncher',MeshName=WEP_1stP_HRG_Teslauncher_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0)
    Profiles(37)=(WeaponClass=class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher',MeshName=Wep_1stP_Medic_GrenadeLauncher_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0)
    Profiles(38)=(WeaponClass=class'KFWeap_HRG_Boomy',MeshName=Wep_1stP_HRG_Boomy_Rig,RackBone=RW_Charging_Handle,MaterialIndex=0,bSlideLock=true,ActionKind=1)
    Profiles(39)=(WeaponClass=class'KFWeap_SMG_G18',MeshName=Wep_1P_RiotShield_Rig,RackBone=RW_Bolt,MaterialIndex=0,bSlideLock=true)
    Profiles(40)=(WeaponClass=class'KFWeap_AssaultRifle_LazerCutter',MeshName=Wep_1stP_Laser_Cutter_Rig,RackBone=RW_Weapon,MaterialIndex=1,ActionKind=2)
    Profiles(41)=(WeaponClass=class'KFWeap_AssaultRifle_Microwave',MeshName=Wep_1stP_Microwave_Assault_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2)
    Profiles(42)=(WeaponClass=class'KFWeap_HVStormCannon',MeshName=WEP_1stP_HVStormCannon_Rig,RackBone=RW_Weapon,MaterialIndex=1,ActionKind=2,Section1MaterialIndex=4)
    Profiles(43)=(WeaponClass=class'KFWeap_Shotgun_HZ12',MeshName=Wep_1stP_HZ12_Rig,RackBone=RW_Pump,MaterialIndex=0,FollowBone=RW_Bolt,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(44)=(WeaponClass=class'KFWeap_HRG_SonicGun',MeshName=WEP_1stP_HRG_SonicGun_Rig,RackBone=RW_ChargingHandle,MaterialIndex=0,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(45)=(WeaponClass=class'KFWeap_RocketLauncher_SealSqueal',MeshName=WEP_1stP_Seal_Squeal_Rig,RackBone=RW_ChargingHandle,MaterialIndex=0,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(46)=(WeaponClass=class'KFWeap_RocketLauncher_Seeker6',MeshName=Wep_1stP_SeekerSix_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(47)=(WeaponClass=class'KFWeap_HRG_Locust',MeshName=Wep_1stP_HRG_Locust_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(48)=(WeaponClass=class'KFWeap_RocketLauncher_ThermiteBore',MeshName=WEP_1stP_Thermite_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine,SpareBone=RW_Magazine)
    Profiles(49)=(WeaponClass=class'KFWeap_ShrinkRayGun',MeshName=WEP_1stP_ShrinkRay_Gun_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine,SpareBone=RW_Magazine)
    Profiles(50)=(WeaponClass=class'KFWeap_Minigun',MeshName=Wep_1stP_Minigun_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine,SpareBone=RW_Magazine)
    Profiles(51)=(WeaponClass=class'KFWeap_Flame_CaulkBurn',MeshName=Wep_1stP_CaulkBurn_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(52)=(WeaponClass=class'KFWeap_Flame_Flamethrower',MeshName=Wep_1stP_Flamethrower_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_GasTank1,SpareBone=RW_GasTank1)
    Profiles(53)=(WeaponClass=class'KFWeap_Beam_Microwave',MeshName=Wep_1stP_Microwave_Gun_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(54)=(WeaponClass=class'KFWeap_HRG_EMP_ArcGenerator',MeshName=Wep_1stP_HRG_ArcGenerator_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(55)=(WeaponClass=class'KFWeap_Blunt_MedicBat',MeshName=Wep_1stP_Medic_Bat_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1)
    Profiles(56)=(WeaponClass=class'KFWeap_GravityImploder',MeshName=Wep_1stP_Gravity_Imploder_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1,bEarlierCarryGrip=true)
    Profiles(57)=(WeaponClass=class'KFWeap_Pistol_Bladed',MeshName=WEP_1stP_BladedPistol_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Container,SpareBone=RW_Container)
    Profiles(58)=(WeaponClass=class'KFWeap_RocketLauncher_RPG7',MeshName=Wep_1stP_RPG7_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Grenade1,SpareBone=RW_Grenade1,bNoEject=true)
    Profiles(59)=(WeaponClass=class'KFWeap_HRG_MedicMissile',MeshName=Wep_1stP_HRG_MedicMissile_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Grenade1,SpareBone=RW_Grenade1,bNoEject=true)
    // 2026-10-01: seated where the stock clip holds them at the ammo moment.
    Profiles(61)=(WeaponClass=class'KFWeap_Ice_FreezeThrower',MeshName=Wep_1stP_CryoGun_Rig,RackBone=RW_Weapon,MaterialIndex=1,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1,bSeatAtNotify=true)
    Profiles(62)=(WeaponClass=class'KFWeap_HRG_Healthrower',MeshName=Wep_1stP_HRG_Healthrower_Rig,RackBone=RW_Weapon,MaterialIndex=1,ActionKind=2,LoadedBone=RW_Magazine1,SpareBone=RW_Magazine1,bSeatAtNotify=true)
    Profiles(63)=(WeaponClass=class'KFWeap_HRG_BallisticBouncer',MeshName=Wep_1stP_HRG_BallisticBouncer_Rig,RackBone=RW_Weapon,MaterialIndex=1,Section1MaterialIndex=2,Section2MaterialIndex=3,ActionKind=2,LoadedBone=RW_Magazine,SpareBone=RW_Magazine,bSeatAtNotify=true)
    Profiles(64)=(WeaponClass=class'KFWeap_Mine_Reconstructor',MeshName=Wep_1stP_HMTech_Mine_Reconstructor_Rig,RackBone=RW_Weapon,MaterialIndex=1,Section1MaterialIndex=2,Section2MaterialIndex=3,ActionKind=2,LoadedBone=RW_Magazine,SpareBone=RW_Magazine,bSeatAtNotify=true)
    // 2026-10-02: the Pulverizer's clip carries four shells; the Doshinegun's
    // wad goes from the hand into its fixed box (seated where the clip has it
    // at the ammo moment).
    Profiles(65)=(WeaponClass=class'KFWeap_Blunt_Pulverizer',MeshName=Wep_1stP_Pulverizer_Rig_New,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Mag1,SpareBone=RW_Mag1,LoadedExtras[0]=RW_Shell1,LoadedExtras[1]=RW_Shell2,LoadedExtras[2]=RW_Shell3,LoadedExtras[3]=RW_Shell4,LoadedExtras[4]=RW_MagSpringPlate1)
    Profiles(66)=(WeaponClass=class'KFWeap_AssaultRifle_Doshinegun',MeshName=Wep_1stP_Doshinegun_Rig,RackBone=RW_Weapon,MaterialIndex=2,ActionKind=2,LoadedBone=RW_Notes2,SpareBone=RW_Notes2,bSeatAtNotify=true,bNoEject=true,bParkedLoaded=true)
    Profiles(60)=(WeaponClass=class'KFWeap_Rifle_ParasiteImplanter',MeshName=Wep_1stP_ParasiteImplanter_Rig,RackBone=RW_Weapon,MaterialIndex=0,ActionKind=2,LoadedBone=RW_Magazine,SpareBone=RW_Magazine)
}
