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

// Magazine-fed guns whose firing action is manually cycled. Keep these out
// of Profiles: FindClass/Covers/FeedTrack exclusively describe shell loading.
struct CycleOnlyProfile
{
    var class<KFWeapon> WeaponClass;
    var float ShotPumpStroke, ReloadPumpStroke, BoltTravelScale;
    var string PumpBack, PumpForward;
    // The part the hand pumps (RW_Pump when empty). bEveryShot: every stock
    // Shoot clip strokes it (not Shoot_Last), rather than HZ12's two-shot pair.
    var name PumpBone;
    var bool bEveryShot;
};
var array<CycleOnlyProfile> CycleOnlyProfiles;

static function int CycleOnlyIndex(class<KFWeapon> W)
{
    local int I;
    for (I = 0; I < default.CycleOnlyProfiles.Length; ++I)
        if (default.CycleOnlyProfiles[I].WeaponClass == W) return I;
    return -1;
}

static function bool CycleOnly(KFWeapon W)
{
    return W != None && CycleOnlyIndex(W.Class) >= 0;
}

static function name PumpBoneForClass(class<KFWeapon> W)
{
    local int I;
    I = CycleOnlyIndex(W);
    return (I >= 0 && default.CycleOnlyProfiles[I].PumpBone != '') ? default.CycleOnlyProfiles[I].PumpBone : 'RW_Pump';
}

// Whether this stock shot clip leaves a manual cycle owed. Shell pumps always
// do; HZ12 pumps on the second of its pair; the Beluga after every Shoot clip
// except the empty-magazine Shoot_Last, whose reload racks it instead.
static function bool ShotOwesCycle(KFWeapon W, name Sequence)
{
    local int I;
    I = W == None ? -1 : CycleOnlyIndex(W.Class);
    if (I < 0) return true;
    if (default.CycleOnlyProfiles[I].bEveryShot) return InStr(Caps(string(Sequence)), "_LAST") < 0;
    return W.ShouldPlayFireLast(0);
}

static function float BoltTravelScale(KFWeapon W)
{
    local int I;
    I = W == None ? -1 : CycleOnlyIndex(W.Class);
    return I >= 0 ? default.CycleOnlyProfiles[I].BoltTravelScale : 1.0;
}

static function int FindClass(class<KFWeapon> W)
{
    local int I;
    for (I = 0; I < default.Profiles.Length; ++I)
        if (default.Profiles[I].WeaponClass == W) return I;
    return -1;
}

// A gun whose fore-end (RW_Pump) the support hand pumps: there the support
// grip is a working control, so only these catch at it (Kvasir94, 2026-10-31).
static function bool ForeEndPump(class<KFWeapon> W)
{
    local int I;
    I = FindClass(W);
    if (I >= 0) return default.Profiles[I].bPumpAction;
    return PumpBoneForClass(W) == 'RW_Pump' && CycleOnlyIndex(W) >= 0;
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
    if (I >= 0) return bReload ? default.Profiles[I].ReloadPumpStroke : default.Profiles[I].ShotPumpStroke;
    I = W == None ? -1 : CycleOnlyIndex(W.Class);
    if (I < 0) return 0;
    return bReload ? default.CycleOnlyProfiles[I].ReloadPumpStroke : default.CycleOnlyProfiles[I].ShotPumpStroke;
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
    I = CycleOnlyIndex(W);
    if (I >= 0)
    {
        if (Which == 0) Path = default.CycleOnlyProfiles[I].PumpBack;
        else if (Which == 1) Path = default.CycleOnlyProfiles[I].PumpForward;
        return Path == "" ? None : AkEvent(DynamicLoadObject(Path, class'AkEvent', true));
    }
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
    // HZ12's Shoot_Last/Reload_Empty PSA fore-end travel; its bolt travels
    // 6.487 UU over the same 10.700 UU stroke. Magazine insertion stays in
    // VRReloadCatalog; this entry grants no incremental shell feed.
    CycleOnlyProfiles(0)=(WeaponClass=class'KFWeap_Shotgun_HZ12',ShotPumpStroke=10.700,ReloadPumpStroke=10.700,BoltTravelScale=0.6063,PumpBack="WW_WEP_HZ12.Play_WEP_HZ12_Back",PumpForward="WW_WEP_HZ12.Play_WEP_HZ12_FWD")
    // Beluga Beat: its PSA strokes RW_ChargingHandle straight back along the
    // bore 18.0 UU in every Shoot clip and 18.5 UU closing Reload_Empty, with
    // the left wrist riding it (11.6 UU throughout); stock handling events.
    CycleOnlyProfiles(1)=(WeaponClass=class'KFWeap_HRG_SonicGun',ShotPumpStroke=18.000,ReloadPumpStroke=18.500,BoltTravelScale=1.0,PumpBack="WW_WEP_HRG_SonicGun.Play_WEP_HRG_SonicGun_Pull_Back",PumpForward="WW_WEP_HRG_SonicGun.Play_WEP_HRG_SonicGun_Close",PumpBone=RW_ChargingHandle,bEveryShot=true)
    // The Beluga was built on the Seal Squeal: the same 18.0/18.5 UU handle
    // strokes in its Shoot clips and Reload_Empty, none on Shoot_Last.
    CycleOnlyProfiles(2)=(WeaponClass=class'KFWeap_RocketLauncher_SealSqueal',ShotPumpStroke=18.000,ReloadPumpStroke=18.500,BoltTravelScale=1.0,PumpBack="WW_WEP_SealSqueal.Play_WEP_SealSqueal_Handling_GunCheck_PullBack_01",PumpForward="WW_WEP_SealSqueal.Play_WEP_SealSqueal_Handling_GunCheck_Forward_01",PumpBone=RW_ChargingHandle,bEveryShot=true)
    Profiles(0)=(WeaponClass=class'KFWeap_Shotgun_MB500',MeshName=Wep_1stP_MB500_Rig,ShotPumpStroke=11.341,ReloadPumpStroke=12.477,PumpBack="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_PumpBack",PumpForward="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_PumpForward",InsertA="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_ShellInsertA",InsertB="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_ShellInsertB",InsertTrack=RW_Shell1,InsertEliteTrack=RW_Shell2,OpenShellTrack=RW_Shell2,bPumpAction=true)
    Profiles(1)=(WeaponClass=class'KFWeap_Shotgun_DragonsBreath',MeshName=Wep_1stP_DragonsBreath_Rig,PumpBack="WW_WEP_SA_DragonsBreath.Play_SA_DragonsBreath_Handling_RackBack",PumpForward="WW_WEP_SA_DragonsBreath.Play_SA_DragonsBreath_Handling_RackForward",InsertB="WW_WEP_SA_DragonsBreath.Play_SA_DragonsBreath_Handling_ShellInsert",InsertTrack=RW_Shell1,InsertEliteTrack=RW_Shell2,OpenShellTrack=RW_Shell2,bPumpAction=true)
    // M4: its own ShellInsert is the contact and the MB500's ShellInsertB the
    // seat, as its clips play them; its bolt events ride the stock clip.
    // Lever actions (roadmap wave 9): rounds through the side gate on RW_Bullet1
    // in every clip; the lever works on the stock clock of the open-and-load clip.
    // As on the Frost Fang, the stock right fingers carry each round (1.5-3 UU
    // from it in every insert clip) while the left holds the fore-end, so the
    // left-hand sampler found no grip and every reload fell back to stock.
    Profiles(3)=(WeaponClass=class'KFWeap_Rifle_Winchester1894',InsertHand=1,MeshName=Wep_1stP_Winchester_Rig,PumpBack="WW_WEP_SA_Winchester.Play_LAR_Open",PumpForward="WW_WEP_SA_Winchester.Play_LAR_Close",InsertB="WW_WEP_SA_Winchester.Play_LAR_Bullet_Insert",PortInsert="WW_WEP_SA_Winchester.Play_LAR_Empty_Reload",InsertTrack=RW_Bullet1,InsertEliteTrack=RW_Bullet1,OpenShellTrack=RW_Bullet1,LeverBones[0]=RW_Finger_Lever,LeverBones[1]=RW_Bolt,LeverBones[2]=RW_Locking_Bolt)
    Profiles(4)=(WeaponClass=class'KFWeap_Rifle_CenterfireMB464',InsertHand=1,MeshName=Wep_1stP_Centerfire_Rig,PumpBack="WW_WEP_SA_Winchester.Play_LAR_Open",PumpForward="WW_WEP_SA_Winchester.Play_LAR_Close",InsertB="WW_WEP_SA_Winchester.Play_LAR_Bullet_Insert",PortInsert="WW_WEP_SA_Winchester.Play_LAR_Empty_Reload",InsertTrack=RW_Bullet1,InsertEliteTrack=RW_Bullet1,OpenShellTrack=RW_Bullet1,LeverBones[0]=RW_Finger_Lever,LeverBones[1]=RW_Bolt,LeverBones[2]=RW_Locking_Bolt)
    // M32 (roadmap wave 10): grenades go one at a time into the open canister
    // on RW_Shell_Reload. VRM32Action admits foregrip opening and closure;
    // stock still pays each round and indexes its cylinder after seating.
    // Its rounds are separate meshes, so the prop is that mesh.
    Profiles(5)=(WeaponClass=class'KFWeap_GrenadeLauncher_M32',MeshName=Wep_1stP_M32_MGL_Rig,InsertB="WW_WEP_M32.Play_M32_Canister_In",InsertTrack=RW_Shell_Reload,EmptyInsertClip=Reload_Empty_Insert,HalfInsertClip=Reload_Half_Insert,AmmoMaterialMesh="WEP_1P_M32_MGL_MESH.Wep_1stP_M32_MGL_Shell")
    // 2026-10-02: the Frost Fang loads shell by shell into its breech (no
    // pump; the first shell of an empty reload goes in with the bolt open).
    Profiles(6)=(WeaponClass=class'KFWeap_Rifle_FrostShotgunAxe',MeshName=Wep_1stP_Frost_Shotgun_Axe_Rig,InsertB="WW_WEP_FrostFang.Play_FrostFang_Insert",PortInsert="WW_WEP_FrostFang.Play_FrostFang_OpenShell",InsertTrack=RW_Shell_01,InsertEliteTrack=RW_Shell_01,OpenShellTrack=RW_Shell_01,InsertHand=1,LeverBones[0]=RW_Finger_Lever,LeverBones[1]=RW_Bolt,LeverBones[2]=RW_Hammer)
    Profiles(2)=(WeaponClass=class'KFWeap_Shotgun_M4',MeshName=Wep_1stP_M4Shotgun_Rig,PumpBack="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_BoltBack",PumpForward="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_BoltForward",InsertA="WW_WEP_SA_M4.Play_WEP_SA_M4_Handling_ShellInsert",InsertB="WW_WEP_SA_MB500.Play_WEP_SA_MB500_Handling_ShellInsertB",InsertTrack=RW_Shell1,InsertEliteTrack=RW_Shell2,OpenShellTrack=RW_Shell1)
}
