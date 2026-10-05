// Guns whose action the hand works after every shot (VRManualAction): the
// stock fire clip cycles it on its own, so its motion is sampled from that
// clip (Shoot) and the hand drives it instead. Read from each PSA
// (2026-10-01): the Mosin's handle lifts 90 degrees while the bolt slides
// 11.7 UU; the Winchester's and SPX's lever swings 81 degrees, driving the bolt
// 7.5 UU. The M99 holds one round, so every shot empties it into a reload.
class VRCycleCatalog extends Object;

struct CycleProfile
{
    var class<KFWeapon> WeaponClass;
    // The moved bones, the handle the hand holds first.
    var name Bones[3];
    // Stock events; Open and Close may list several separated by '|'. Shot is
    // the fire clip's own after-shot sound, kept when its cycle is muted.
    var string Open, Eject, Close, Shot;
};
var array<CycleProfile> Profiles;

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

defaultproperties
{
    Profiles(0)=(WeaponClass=class'KFWeap_Rifle_MosinNagant',Bones[0]=RW_Bolt_Lock,Bones[1]=RW_Bolt,Bones[2]=RW_Bolt_Back,Open="WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Up|WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Open",Eject="WW_WEP_MosinNagant.Play_MosinNagant_Handling_Shell_Eject",Close="WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Close|WW_WEP_MosinNagant.Play_MosinNagant_Handling_Bolt_Down")
    Profiles(1)=(WeaponClass=class'KFWeap_Rifle_Winchester1894',Bones[0]=RW_Finger_Lever,Bones[1]=RW_Bolt,Bones[2]=RW_Locking_Bolt,Open="WW_WEP_SA_Winchester.Play_LAR_Open",Close="WW_WEP_SA_Winchester.Play_LAR_Close",Shot="WW_WEP_SA_Winchester.Play_LAR_Ring")
    Profiles(2)=(WeaponClass=class'KFWeap_Rifle_CenterfireMB464',Bones[0]=RW_Finger_Lever,Bones[1]=RW_Bolt,Bones[2]=RW_Locking_Bolt,Open="WW_WEP_SA_Winchester.Play_LAR_Open",Close="WW_WEP_SA_Winchester.Play_LAR_Close")
}
