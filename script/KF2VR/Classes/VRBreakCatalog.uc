// Guns opened by hand, loaded and closed again. A break action swings
// RW_Barrel about its measured hinge axis; a path action (bolt actions,
// revolver cylinders) drives up to three bones along the motion its own
// reload clip shows, sampled from the clip. Each shell is seated by hand, or a
// clip or speedloader loads every round at once. Read from
// each rig's PSA (2026-10-01): the hunting shotgun, M79 and Dragon's Blaze
// tip down about Y (42-88 degrees); the HX25 swings 90 degrees about the bore.
class VRBreakCatalog extends Object;

struct BreakProfile
{
    var class<KFWeapon> WeaponClass;
    var name MeshName;
    // Loaded rounds occupy the last slots; new shells fill from the first.
    var name ShellBones[4];
    var int Capacity;
    var vector HingeAxis;
    var int MaterialIndex;
    // Stock handling events. Latch, Eject and InsertA may be empty; Open and
    // Close may list several events separated by '|', played in order.
    var string Latch, Open, Eject, InsertA, InsertB, Close;
    // A path action: the bones it moves, the first being the handle the hand
    // holds; the hinge axis is then zero (no flick).
    var name PathBones[3];
    // The object the hand brings when it is not a single shell (stripper clip,
    // speedloader); seating it loads every missing round.
    var name ClipBone;
    // A bone hidden for the whole session (the M99's spent case, which leaves
    // as an ejected shell when the bolt opens).
    var name HideBone;
    // A box that is dropped when the action opens (an LMG's ammunition box,
    // dropped once its feed cover is up) and the second material slot of a
    // two-material box.
    var name DropBone;
    var int Section1MaterialIndex;
    // Rounds drawn from their own mesh (the .500's speedloader rounds): the
    // second section takes that mesh's first material instead.
    var string Section1MaterialMesh;
};
var array<BreakProfile> Profiles;

static function int FindClass(class<KFWeapon> W)
{
    local int I;
    for (I = 0; I < default.Profiles.Length; ++I)
        if (default.Profiles[I].WeaponClass == W) return I;
    return -1;
}

static function bool Covers(KFWeapon W)
{
    return W != None && FindClass(W.Class) >= 0;
}

static function bool CylinderReload(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_Revolver_Rem1858'
        || W.Class == class'KFWeap_Revolver_SW500' || W.Class == class'KFWeap_Pistol_ChiappaRhino'
        || W.Class == class'KFWeap_HRG_Revolver_Buckshot' || W.Class == class'KFWeap_Pistol_Flare'
        || W.Class == class'KFWeap_Pistol_HRGWinterbite');
}

static function name ShellBone(class<KFWeapon> W, int Slot)
{
    local int I;
    I = FindClass(W);
    if (I < 0 || Slot < 0 || Slot >= default.Profiles[I].Capacity) return '';
    // Cylinder/clip profiles have no individual shell slots; capacity can be
    // six or seven while the authored shell array contains only four entries.
    if (default.Profiles[I].ClipBone != ''
        || Slot >= ArrayCount(default.Profiles[I].ShellBones)) return '';
    return default.Profiles[I].ShellBones[Slot];
}

static function AkEvent LoadSound(class<KFWeapon> W, string Path)
{
    local int Bar;
    Bar = InStr(Path, "|");
    if (Bar >= 0) Path = Left(Path, Bar);
    return Path == "" ? None : AkEvent(DynamicLoadObject(Path, class'AkEvent', true));
}

static function bool IsPath(class<KFWeapon> W)
{
    local int I;
    I = FindClass(W);
    return I >= 0 && default.Profiles[I].PathBones[0] != '';
}

static function name AmmoBoneOf(class<KFWeapon> W, int Slot)
{
    local int I;
    I = FindClass(W);
    if (I >= 0 && default.Profiles[I].ClipBone != '') return default.Profiles[I].ClipBone;
    return ShellBone(W, Slot);
}

defaultproperties
{
    Profiles(0)=(WeaponClass=class'KFWeap_Shotgun_DoubleBarrel',MeshName=Wep_1stP_Double_Barrel,ShellBones[0]=RW_Shell1,ShellBones[1]=RW_Shell2,Capacity=2,HingeAxis=(Y=1),Open="WW_WEP_SA_Shotgun.Play_SA_WEP_DoubleBarrel_Handling_Open",InsertB="WW_WEP_SA_Shotgun.Play_SA_WEP_DoubleBarrel_Handling_ShellInsert",Close="WW_WEP_SA_Shotgun.Play_SA_WEP_DoubleBarrel_Handling_Close")
    Profiles(1)=(WeaponClass=class'KFWeap_GrenadeLauncher_M79',MeshName=Wep_1stP_M79_Rig,ShellBones[0]=RW_Shell1,Capacity=1,HingeAxis=(Y=1),Latch="WW_WEP_SA_M79.Play_WEP_SA_M79_Handing_Click",Open="WW_WEP_SA_M79.Play_WEP_SA_M79_Handling_BarrelOpen",Eject="WW_WEP_SA_M79.Play_WEP_SA_M79_Handing_ShellEject",InsertA="WW_WEP_SA_M79.Play_WEP_SA_M79_Handling_ShellInsert_A",InsertB="WW_WEP_SA_M79.Play_WEP_SA_M79_Handling_ShellInsert_B",Close="WW_WEP_SA_M79.Play_WEP_SA_M79_Handling_BarrelClose")
    // The HX25 records no opening sound; its clip's unlatch is the PutAway event.
    Profiles(2)=(WeaponClass=class'KFWeap_GrenadeLauncher_HX25',MeshName=Wep_1stP_HX25_Pistol_Rig,ShellBones[0]=RW_Bullet1,Capacity=1,HingeAxis=(X=-1),Open="WW_WEP_SA_HX25.Play_WEP_SA_HX25_Handling_PutAway",InsertB="WW_WEP_SA_HX25.Play_WEP_SA_HX25_Handling_ShellInsert",Close="WW_WEP_SA_HX25.Play_WEP_SA_HX25_Handling_BarrelClose")
    // Dragon's Blaze: four barrels, its shells drawn in material slot 1.
    // 2026-10-01 bolt actions (roadmap wave 8), path actions sampled from their
    // empty clips: the M99's bolt lifts 66 degrees and slides 20 UU; the Mosin's
    // handle lifts 90 degrees while its bolt slides 11.7 UU, and it loads by
    // stripper clip.
    Profiles(4)=(WeaponClass=class'KFWeap_Rifle_M99',MeshName=Wep_1stP_M99_Rig,ShellBones[0]=RW_Shell1,Capacity=1,PathBones[0]=RW_Bolt,HideBone=RW_Empty_Shell1,Open="WW_WEP_M99.Play_WEP_M99_Handling_Reload_BoltUp|WW_WEP_M99.Play_WEP_M99_Handling_Reload_BoltBack",InsertB="WW_WEP_M99.Play_WEP_M99_BulletIn",Close="WW_WEP_M99.Play_WEP_M99_Handling_Reload_BoltFWD|WW_WEP_M99.Play_WEP_M99_Handling_Reload_BoltDown")
    Profiles(5)=(WeaponClass=class'KFWeap_Rifle_MosinNagant',MeshName=WEP_1stP_Mosin_Rig,Capacity=5,ClipBone=RW_StripMag,PathBones[0]=RW_Bolt_Lock,PathBones[1]=RW_Bolt,PathBones[2]=RW_Bolt_Back,Open="WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Up|WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Open",Eject="WW_WEP_MosinNagant.Play_MosinNagant_Handling_Shell_Eject",InsertA="WW_WEP_MosinNagant.Play_MosinNagant_Handling_StripperClip_In",InsertB="WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bullet_Insert",Close="WW_WEP_MosinNagant.Play_MosinNagant_Handling_StripperClip_Out|WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Close|WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Down")
    // 2026-10-01 swing-out revolvers (roadmap wave 10): the cylinder swings 90
    // degrees on RW_Cylinder_Pivot about the bore (a wrist flick closes it) and
    // a speedloader loads every round. Their rounds are the stock bullet
    // meshes, reset to live when the speedloader seats.
    Profiles(6)=(WeaponClass=class'KFWeap_Revolver_SW500',MeshName=Wep_1stP_SW_500_Rig,Capacity=5,HingeAxis=(X=1),ClipBone=RW_Speedloader,Section1MaterialMesh="WEP_1P_SW_500_MESH.Wep_1stP_SW_500_Bullet",PathBones[0]=RW_Cylinder_Pivot,Open="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Cylinder_Open",Eject="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Tap",InsertB="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Speedloader_In",Close="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Cylinder_Close|WW_WEP_SA_SW500.Play_SW500_Hammer")
    Profiles(7)=(WeaponClass=class'KFWeap_Pistol_ChiappaRhino',MeshName=Wep_1stP_ChiappaRhino_Rig,Capacity=6,HingeAxis=(X=1),ClipBone=RW_Speedloader,PathBones[0]=RW_Cylinder_Pivot,Open="WW_WEP_ChiappaRhinos.Play_WEP_ChiappaRhinos_Handling_Chamber_Open",Eject="WW_WEP_ChiappaRhinos.Play_WEP_ChiappaRhinos_Handling_Empty_Bullets",InsertB="WW_WEP_ChiappaRhinos.Play_WEP_ChiappaRhinos_Handling_Insert_Bullets",Close="WW_WEP_ChiappaRhinos.Play_WEP_ChiappaRhinos_Handling_Chamber_Close|WW_WEP_ChiappaRhinos.Play_WEP_ChiappaRhinos_Handling_Cock")
    // 2026-10-01 belt-fed guns (roadmap wave 11): the feed cover swings up
    // (94 degrees on the Stoner and Bastion, 55 on the MG3), the old box drops,
    // a new box with its belt loads every round, the cover closes.
    Profiles(8)=(WeaponClass=class'KFWeap_LMG_Stoner63A',MeshName=Wep_1stP_Stoner63A_Rig,Capacity=75,ClipBone=RW_Magazine1,DropBone=RW_Magazine1,Section1MaterialIndex=1,PathBones[0]=RW_ChamberCover,Open="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Open",Eject="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Remove_Box",InsertA="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Insert_Box",InsertB="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Insert_Belt",Close="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Close")
    Profiles(9)=(WeaponClass=class'KFWeap_HRG_BarrierRifle',MeshName=WEP_1stP_HRG_BarrielRifle_Rig,Capacity=60,ClipBone=RW_Magazine1,DropBone=RW_Magazine1,Section1MaterialIndex=1,PathBones[0]=RW_ChamberCover,Open="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Open",Eject="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Remove_Box",InsertA="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Insert_Box",InsertB="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Insert_Belt",Close="WW_WEP_Stoner.Play_WEP_Stoner_Reload_Close")
    Profiles(10)=(WeaponClass=class'KFWeap_LMG_MG3',MeshName=WEP_1stP_MG3_Rig,Capacity=75,ClipBone=RW_Magazine,DropBone=RW_Magazine,PathBones[0]=RW_ChamberCover,Open="WW_WEP_MG3.Play_WEP_MG3_Reload_Open",Eject="WW_WEP_MG3.Play_WEP_MG3_Reload_Remove_Box",InsertA="WW_WEP_MG3.Play_WEP_MG3_Reload_Insert_Box",InsertB="WW_WEP_MG3.Play_WEP_MG3_Reload_Insert_Belt",Close="WW_WEP_MG3.Play_WEP_MG3_Reload_Close")
    // The 1858 swaps its whole cylinder: the loading lever swings 90 degrees and
    // the pin slides out (its path), the old cylinder drops, a loaded one goes
    // in, then the pin and lever go home and the hammer is cocked.
    Profiles(11)=(WeaponClass=class'KFWeap_Revolver_Rem1858',MeshName=Wep_1stP_Remington_1858_Rig,Capacity=6,ClipBone=RW_Cylinder,DropBone=RW_Cylinder,PathBones[0]=RW_LoadingLever,PathBones[1]=RW_ExtractorPin,PathBones[2]=RW_Plunger,Open="WW_WEP_SA_1858.Play_WEP_SA_1858_Open_Lever|WW_WEP_SA_1858.Play_WEP_SA_1858_Pin_Slide",Eject="WW_WEP_SA_1858.Play_WEP_SA_1858_Cylinder_Out",InsertB="WW_WEP_SA_1858.Play_WEP_SA_1858_Cylinder_In",Close="WW_WEP_SA_1858.Play_WEP_SA_1858_Pin_Slide|WW_WEP_SA_1858.Play_WEP_SA_1858_Close_Lever|WW_WEP_SA_1858.Play_WEP_SA_1858_Hammer_Fast")
    // 2026-10-01 roadmap wave 13, read from each PSA: the Kaboomstick tips 42
    // degrees about Y like the hunting shotgun and plays its events; the
    // Elephant Gun tips 89 degrees and takes four shells (stock carries them in
    // two pairs; here each is seated by hand), drawn in material slot 1; the
    // HRG Buckshot is the .500's cylinder and speedloader with shotshells.
    Profiles(12)=(WeaponClass=class'KFWeap_Shotgun_HRG_Kaboomstick',MeshName=Wep_1stP_HRG_Kaboomstick_Rig,ShellBones[0]=RW_Shell1,ShellBones[1]=RW_Shell2,Capacity=2,HingeAxis=(Y=1),Open="WW_WEP_SA_Shotgun.Play_SA_WEP_DoubleBarrel_Handling_Open",InsertB="WW_WEP_SA_Shotgun.Play_SA_WEP_DoubleBarrel_Handling_ShellInsert",Close="WW_WEP_SA_Shotgun.Play_SA_WEP_DoubleBarrel_Handling_Close")
    Profiles(13)=(WeaponClass=class'KFWeap_Shotgun_ElephantGun',MeshName=Wep_1stP_Quad_Barrel,ShellBones[0]=RW_Shell1,ShellBones[1]=RW_Shell2,ShellBones[2]=RW_Shell3,ShellBones[3]=RW_Shell4,Capacity=4,HingeAxis=(Y=1),MaterialIndex=1,Open="WW_WEP_Quad_Shotgun.Play_Quad_Shotgun_Open",InsertB="WW_WEP_Quad_Shotgun.Play_Quad_Shotgun_BulletIn",Close="WW_WEP_Quad_Shotgun.Play_Quad_Shotgun_Close")
    Profiles(14)=(WeaponClass=class'KFWeap_HRG_Revolver_Buckshot',MeshName=Wep_1stP_HRG_SW_500_Rig,Capacity=5,HingeAxis=(X=1),ClipBone=RW_Speedloader,Section1MaterialMesh="wep_3p_hrg_sw_500_mesh.Wep_3rdP_HRG_SW_500_Bullet",PathBones[0]=RW_Cylinder_Pivot,Open="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Cylinder_Open",Eject="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Tap",InsertB="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Speedloader_In",Close="WW_WEP_SA_SW500.Play_WEP_SA_SW500_Cylinder_Close|WW_WEP_SA_SW500.Play_SW500_Hammer")
    // The Flare Gun breaks open 90 degrees about Y and swaps its whole
    // cylinder, as the 1858 does under its lever (its clip plays the 1858's
    // events); the cylinder rides the hinge.
    Profiles(15)=(WeaponClass=class'KFWeap_Pistol_Flare',MeshName=Wep_1stP_FlareGun_Rig,Capacity=6,HingeAxis=(Y=1),ClipBone=RW_Cylinder,DropBone=RW_Cylinder,Open="WW_WEP_SA_1858.Play_WEP_SA_1858_Open_Lever",Eject="WW_WEP_SA_1858.Play_WEP_SA_1858_Cylinder_Out",InsertB="WW_WEP_SA_1858.Play_WEP_SA_1858_Cylinder_In",Close="WW_WEP_SA_1858.Play_WEP_SA_1858_Close_Lever|WW_WEP_SA_1858.Play_WEP_SA_1858_Hammer_Fast")
    // 2026-10-01: the Winterbite is the Flare Gun's rig; the Scorcher breaks
    // 90 degrees about the bore like the HX25 and plays its events (its spent
    // casing, RW_Empty_Shell, rests on the loaded round and ejects on opening).
    // The Cranial Popper and Hemogoblin swing their cylinder housing 57 degrees
    // about Z while the lock and slide frame retract with it; a speedloader
    // carries their seven darts.
    Profiles(16)=(WeaponClass=class'KFWeap_Pistol_HRGWinterbite',MeshName=Wep_1stP_HRG_Winterbite_Rig,Capacity=6,HingeAxis=(Y=1),ClipBone=RW_Cylinder,DropBone=RW_Cylinder,Open="WW_WEP_SA_1858.Play_WEP_SA_1858_Open_Lever",Eject="WW_WEP_SA_1858.Play_WEP_SA_1858_Cylinder_Out",InsertB="WW_WEP_SA_1858.Play_WEP_SA_1858_Cylinder_In",Close="WW_WEP_SA_1858.Play_WEP_SA_1858_Close_Lever|WW_WEP_SA_1858.Play_WEP_SA_1858_Hammer_Fast")
    Profiles(17)=(WeaponClass=class'KFWeap_Pistol_HRGScorcher',MeshName=Wep_1stP_HRGScorcher_Pistol_Rig,ShellBones[0]=RW_Bullet1,Capacity=1,HingeAxis=(X=-1),HideBone=RW_Empty_Shell,Open="WW_WEP_SA_HX25.Play_WEP_SA_HX25_Handling_PutAway",InsertB="WW_WEP_SA_HX25.Play_WEP_SA_HX25_Handling_ShellInsert",Close="WW_WEP_SA_HX25.Play_WEP_SA_HX25_Handling_BarrelClose")
    Profiles(18)=(WeaponClass=class'KFWeap_HRG_CranialPopper',MeshName=Wep_1stP_HRG_CranialPopper_Rig,Capacity=7,HingeAxis=(Z=-1),ClipBone=RW_Speedloader,PathBones[0]=RW_CylinderHousing,PathBones[1]=RW_CylinderLock,PathBones[2]=RW_SlideFrame,Latch="WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Steam",Open="WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Open|WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Rotate",Eject="WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Pop",InsertB="WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Cartridge",Close="WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Close|WW_WEP_HRG_CranialPopper.Play_WEP_HRG_CranialPopper_Reload_Close_Pop")
    Profiles(19)=(WeaponClass=class'KFWeap_Rifle_Hemogoblin',MeshName=WEP_1stP_Bleeder_Rig,Capacity=7,HingeAxis=(Z=-1),ClipBone=RW_Speedloader,PathBones[0]=RW_CylinderHousing,PathBones[1]=RW_CylinderLock,PathBones[2]=RW_SlideFrame,Latch="WW_WEP_Bleeder.Play_Bleeder_Reload_Steam",Open="WW_WEP_Bleeder.Play_Bleeder_Reload_Open|WW_WEP_Bleeder.Play_Bleeder_Reload_Rotate",Eject="WW_WEP_Bleeder.Play_Bleeder_Reload_Pop",InsertB="WW_WEP_Bleeder.Play_Bleeder_Reload_Cartridge",Close="WW_WEP_Bleeder.Play_Bleeder_Reload_Close|WW_WEP_Bleeder.Play_Bleeder_Reload_Close_Pop|WW_WEP_Bleeder.Play_Bleeder_Reload_Rotate")
    Profiles(3)=(WeaponClass=class'KFWeap_HRG_Dragonbreath',MeshName=Wep_1stP_HRG_MegaDragonsbreath_Rig,ShellBones[0]=RW_Shell1,ShellBones[1]=RW_Shell2,ShellBones[2]=RW_Shell3,ShellBones[3]=RW_Shell4,Capacity=4,HingeAxis=(Y=1),MaterialIndex=1,Open="ww_wep_hrg_megadragonbreath.Play_WEP_HRG_MegaDragonbreath_Open",InsertB="WW_WEP_Quad_Shotgun.Play_Quad_Shotgun_BulletIn",Close="ww_wep_hrg_megadragonbreath.Play_WEP_HRG_MegaDragonbreath_Close")
}
