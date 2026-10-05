// Tube-fed shotguns with physical shell loading. The rigs share one reload
// choreography of single-shell clips (names, timings and incoming-shell tracks
// read from their PSA exports, 2026-10-01); the tracks are per gun below.
class VRPumpCatalog extends Object;

struct PumpProfile
{
    var class<KFWeapon> WeaponClass;
    var name MeshName;
    // Stock handling events. InsertA (first contact) may be empty: the Trench
    // Gun records one insertion sound, which is the seat.
    var string PumpBack, PumpForward, InsertA, InsertB;
    // The seat of an open-and-load clip when it records its own (a lever gun
    // chambers its first round with a different sound from the gate).
    var string PortInsert;
    // Incoming-shell bone of Reload_Insert, Reload_Insert_Elite and both
    // open-and-load clips (the M4 drops that shell into its ejection port).
    var name InsertTrack, InsertEliteTrack, OpenShellTrack;
    // A pump action: pumped by hand after every shot and racked to close a
    // reload. The semi-automatic M4 does neither; its stock clip closes the bolt.
    var bool bPumpAction;
    // Root-relative RW_Pump stroke measured from the stock PSA: Shoot for
    // shot cycling, Reload_Open_Shell for empty-reload opening/closing.
    // Zero keeps the existing fallback for rigs not measured here.
    var float ShotPumpStroke, ReloadPumpStroke;
    // A lever action's moving parts, the lever first: on an empty reload the
    // hand throws it open before the first round and closes it after.
    var name LeverBones[3];
    // A gun whose insert clips have their own names (the M32's
    // Reload_Empty_Insert/Reload_Half_Insert), sampled on InsertTrack.
    var name EmptyInsertClip, HalfInsertClip;
    // A round drawn from its own mesh rather than cut from the gun (the M32's
    // grenades are separate meshes): that mesh's first material.
    var string AmmoMaterialMesh;
    // The stock hand that loads (0 left, 1 right): the Frost Fang's left hand
    // holds the axe while its right hand carries each shell in.
    var byte InsertHand;
};
var array<PumpProfile> Profiles;

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

static function bool CoversMesh(name MeshName)
{
    local int I;
    for (I = 0; I < default.Profiles.Length; ++I)
        if (default.Profiles[I].MeshName == MeshName) return true;
    return false;
}

static function bool PumpAction(KFWeapon W)
{
    local int I;
    I = W == None ? -1 : FindClass(W.Class);
    return I >= 0 && default.Profiles[I].bPumpAction;
}

static function float PumpStroke(KFWeapon W, bool bReload)
{
    local int I;
    I = W == None ? -1 : FindClass(W.Class);
    if (I < 0) return 0;
    return bReload ? default.Profiles[I].ReloadPumpStroke : default.Profiles[I].ShotPumpStroke;
}

static function bool IsLever(KFWeapon W)
{
    local int I;
    I = W == None ? -1 : FindClass(W.Class);
    return I >= 0 && default.Profiles[I].LeverBones[0] != '';
}

static function name FeedTrack(name MeshName, name Clip)
{
    local int I;
    for (I = 0; I < default.Profiles.Length; ++I)
    {
        if (default.Profiles[I].MeshName != MeshName) continue;
        if (Clip == default.Profiles[I].EmptyInsertClip || Clip == default.Profiles[I].HalfInsertClip)
            return default.Profiles[I].InsertTrack;
        switch (Clip)
        {
            case 'Reload_Insert': return default.Profiles[I].InsertTrack;
            case 'Reload_Insert_Elite': return default.Profiles[I].InsertEliteTrack;
            case 'Reload_Open_Shell':
            case 'Reload_Open_Shell_Elite': return default.Profiles[I].OpenShellTrack;
        }
    }
    return '';
}

static function AkEvent LoadSound(class<KFWeapon> W, int Which)
{
    local int I;
    local string Path;
    I = FindClass(W);
    if (I < 0) return None;
    switch (Which)
    {
        case 0: Path = default.Profiles[I].PumpBack; break;
        case 1: Path = default.Profiles[I].PumpForward; break;
        case 2: Path = default.Profiles[I].InsertA; break;
        case 3: Path = default.Profiles[I].InsertB; break;
        case 4: Path = default.Profiles[I].PortInsert; break;
    }
    return Path == "" ? None : AkEvent(DynamicLoadObject(Path, class'AkEvent', true));
}

defaultproperties
{
    Profiles(0)=(WeaponClass=class'KFWeap_Shotgun_MB500',MeshName=Wep_1stP_MB500_Rig,ShotPumpStroke=11.341,ReloadPumpStroke=12.477,PumpBack="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_PumpBack",PumpForward="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_PumpForward",InsertA="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_ShellInsertA",InsertB="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_ShellInsertB",InsertTrack=RW_Shell1,InsertEliteTrack=RW_Shell2,OpenShellTrack=RW_Shell2,bPumpAction=true)
    Profiles(1)=(WeaponClass=class'KFWeap_Shotgun_DragonsBreath',MeshName=Wep_1stP_DragonsBreath_Rig,PumpBack="WW_WEP_SA_DragonsBreath.Play_SA_DragonsBreath_Handling_RackBack",PumpForward="WW_WEP_SA_DragonsBreath.Play_SA_DragonsBreath_Handling_RackForward",InsertB="WW_WEP_SA_DragonsBreath.Play_SA_DragonsBreath_Handling_ShellInsert",InsertTrack=RW_Shell1,InsertEliteTrack=RW_Shell2,OpenShellTrack=RW_Shell2,bPumpAction=true)
    // M4: its own ShellInsert is the contact and the MB500's ShellInsertB the
    // seat, as its clips play them; its bolt events ride the stock clip.
    // Lever actions (roadmap wave 9): rounds through the side gate on RW_Bullet1
    // in every clip; the lever works on the stock clock of the open-and-load clip.
    Profiles(3)=(WeaponClass=class'KFWeap_Rifle_Winchester1894',MeshName=Wep_1stP_Winchester_Rig,PumpBack="WW_WEP_SA_Winchester.Play_LAR_Open",PumpForward="WW_WEP_SA_Winchester.Play_LAR_Close",InsertB="WW_WEP_SA_Winchester.Play_LAR_Bullet_Insert",PortInsert="WW_WEP_SA_Winchester.Play_LAR_Empty_Reload",InsertTrack=RW_Bullet1,InsertEliteTrack=RW_Bullet1,OpenShellTrack=RW_Bullet1,LeverBones[0]=RW_Finger_Lever,LeverBones[1]=RW_Bolt,LeverBones[2]=RW_Locking_Bolt)
    Profiles(4)=(WeaponClass=class'KFWeap_Rifle_CenterfireMB464',MeshName=Wep_1stP_Centerfire_Rig,PumpBack="WW_WEP_SA_Winchester.Play_LAR_Open",PumpForward="WW_WEP_SA_Winchester.Play_LAR_Close",InsertB="WW_WEP_SA_Winchester.Play_LAR_Bullet_Insert",PortInsert="WW_WEP_SA_Winchester.Play_LAR_Empty_Reload",InsertTrack=RW_Bullet1,InsertEliteTrack=RW_Bullet1,OpenShellTrack=RW_Bullet1,LeverBones[0]=RW_Finger_Lever,LeverBones[1]=RW_Bolt,LeverBones[2]=RW_Locking_Bolt)
    // M32 (roadmap wave 10): grenades go one at a time into the open canister
    // on RW_Shell_Reload; the canister opens, indexes and closes on its stock
    // clips. Its rounds are separate meshes, so the prop is that mesh.
    Profiles(5)=(WeaponClass=class'KFWeap_GrenadeLauncher_M32',MeshName=Wep_1stP_M32_MGL_Rig,InsertB="WW_WEP_M32.Play_M32_Canister_In",InsertTrack=RW_Shell_Reload,EmptyInsertClip=Reload_Empty_Insert,HalfInsertClip=Reload_Half_Insert,AmmoMaterialMesh="WEP_1P_M32_MGL_MESH.Wep_1stP_M32_MGL_Shell")
    // 2026-10-02: the Frost Fang loads shell by shell into its breech (no
    // pump; the first shell of an empty reload goes in with the bolt open).
    Profiles(6)=(WeaponClass=class'KFWeap_Rifle_FrostShotgunAxe',MeshName=Wep_1stP_Frost_Shotgun_Axe_Rig,InsertB="WW_WEP_FrostFang.Play_FrostFang_Insert",PortInsert="WW_WEP_FrostFang.Play_FrostFang_OpenShell",InsertTrack=RW_Shell_01,InsertEliteTrack=RW_Shell_01,OpenShellTrack=RW_Shell_01,InsertHand=1)
    Profiles(2)=(WeaponClass=class'KFWeap_Shotgun_M4',MeshName=Wep_1stP_M4Shotgun_Rig,PumpBack="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_BoltBack",PumpForward="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_BoltForward",InsertA="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_ShellInsert",InsertB="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_ShellInsertB",InsertTrack=RW_Shell1,InsertEliteTrack=RW_Shell2,OpenShellTrack=RW_Shell1)
}
