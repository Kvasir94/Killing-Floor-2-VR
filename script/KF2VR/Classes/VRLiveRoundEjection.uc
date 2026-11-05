// Local presentation for rounds already removed by the chamber ledger.
// Reuse the stock cartridge's geometry/material and the shared falling props;
// these props never carry recoverable ammunition or change weapon state.
class VRLiveRoundEjection extends Object;

var StaticMesh RoundMesh;
var name CachedShape;
var vector Centre, Extent;
// Loose rounds must not evict magazines that can still return their ammo.
var VRDroppedMagazines Props;

function Initialize(VRHandsBridge Bridge)
{
    Props = new(self) class'VRDroppedMagazines';
    Props.Initialize(Bridge);
    // R22: ejected cases are cosmetic and clear after about 10 s.
    Props.Linger = class'VRDroppedMagazines'.const.CaseLinger;
}

function Tick(float Delta)
{
    if (Props != None) Props.Tick(Delta);
}

function Shutdown()
{
    if (Props != None) Props.Shutdown();
    Props = None;
}

// Local/standalone originals supply the actual live-round exit. Dedicated
// authority uses its accepted hand frame instead of loading first-person rigs.
static function bool RecoveryPort(KFWeapon W, out vector At, out rotator Facing)
{
    local KFMuzzleFlash Ejector;
    local name Socket;
    if (W == None || W.bDeleteMe || W.MySkelMesh == None) return false;
    if (class'VRBreakCatalog'.static.SwingOutCylinder(W) && W.MySkelMesh.MatchRefBone('RW_Cylinder') >= 0)
    {
        At = W.MySkelMesh.GetBoneLocation('RW_Cylinder');
        Facing = QuatToRotator(W.MySkelMesh.GetBoneQuaternion('RW_Cylinder'));
        return true;
    }
    Ejector = W.MuzzleFlash != None ? W.MuzzleFlash : W.MuzzleFlashTemplate;
    if (Ejector == None && W.MuzzleFlashTemplateName != "")
        Ejector = KFMuzzleFlash(DynamicLoadObject(W.MuzzleFlashTemplateName, class'KFMuzzleFlash', true));
    Socket = Ejector != None ? Ejector.ShellEjectSocketName : class'KFMuzzleFlash'.default.ShellEjectSocketName;
    return W.MySkelMesh.GetSocketWorldLocationAndRotation(Socket, At, Facing);
}

// The world recovery actor uses the same audited original cartridge cuts as
// local ejection. Dedicated servers publish only family/kind metadata; asset
// loading is client-side and never participates in the paid ammo ledger.
// Pure family metadata for dedicated authority admission. Never load a
// first-person mesh or KF2VRHands package on the dedicated server.
static function bool RecoverySupported(class<KFWeapon> Family)
{
    local name Shape;
    local int I;
    Family = class'VRWeaponDropState'.static.FamilyFor(Family);
    if (Family == None) return false;
    if (class'VRBreakCatalog'.static.ProfileClass(Family) == class'KFWeap_Revolver_SW500'
        || class'VRBreakCatalog'.static.ProfileClass(Family) == class'KFWeap_HRG_Revolver_Buckshot') return true;
    I = class'VRReloadCatalog'.static.FindClass(Family);
    if (I >= 0) Shape = class'VRReloadCatalog'.default.Profiles[I].MeshName;
    if (Shape == '')
    {
        I = class'VRPumpCatalog'.static.FindClass(Family);
        if (I >= 0) Shape = class'VRPumpCatalog'.default.Profiles[I].MeshName;
    }
    if (Shape == '')
    {
        I = class'VRBreakCatalog'.static.FindClass(Family);
        if (I >= 0) Shape = class'VRBreakCatalog'.default.Profiles[I].MeshName;
    }
    switch (Shape)
    {
        case 'Wep_1stP_9mm_Rig':
        case 'Wep_1stP_M1911_Rig':
        case 'Wep_1stP_Deagle_Rig':
        case 'Wep_1stP_Medic_Pistol_Rig':
        case 'WEP_1P_HRG_93R_Pistol_Rig':
        case 'Wep_1stP_AF2001_Rig':
        case 'Wep_1P_RiotShield_Rig':
        case 'Wep_1stP_Medic_SMG_Rig':
        case 'Wep_1stP_KRISS_Rig':
        case 'Wep_1stP_HK_UMP_Rig':
        case 'Wep_1stP_MP5RAS_Rig':
        case 'Wep_1stP_AK12_Rig':
        case 'Wep_1stP_L85A2_Rig':
        case 'Wep_1stP_AR15_9mm_Rig':
        case 'Wep_1stP_SCAR_Rig':
        case 'Wep_1stP_MP7_Rig':
        case 'Wep_1stP_P90_Rig':
        case 'Wep_1stP_Saiga12_Rig':
        case 'WEP_1stP_FNFAL_Rig':
        case 'Wep_1stP_M16_M203_Rig':
        case 'Wep_1stP_HRG_IncendiaryRifle_Rig':
        case 'WEP_1stP_G36C_Rig':
        case 'WEP_1stP_Famas_Rig':
        case 'WEP_1stP_M14_EBR':
        case 'WEP_1stP_Mosin_Rig':
        case 'Wep_1stP_ChiappaRhino_Rig':
        case 'WEP_1stP_HRG_CranialPopper_Rig':
        case 'Wep_1stP_Bleeder_Rig':
        case 'Wep_1stP_Medic_Shotgun_Rig':
        case 'Wep_1stP_G18C_Rig':
        case 'Wep_1stP_HRG_Teslauncher_Rig':
        case 'Wep_1stP_Medic_GrenadeLauncher_Rig':
        case 'Wep_1stP_Medic_Assault_Rig':
        case 'Wep_1stP_MB500_Rig':
        case 'Wep_1stP_DragonsBreath_Rig':
        case 'Wep_1stP_M4Shotgun_Rig':
        case 'Wep_1stP_HZ12_Rig':
        case 'Wep_1stP_Frost_Shotgun_Axe_Rig':
        case 'Wep_1stP_Winchester_Rig':
        case 'Wep_1stP_Centerfire_Rig':
        case 'Wep_1stP_M99_Rig':
        case 'Wep_1stP_CompoundBow_Rig':
        case 'Wep_1stP_Crossbow_Rig':
            return true;
        default: return false;
    }
}

static function bool RecoveryVisual(class<KFWeapon> Family, out StaticMesh Asset,
    out MaterialInterface Surface0)
{
    local SkeletalMesh Rig;
    local name Shape;
    local string MeshPath;
    local int MaterialSlot;
    Asset = None; Surface0 = None;
    if (Family == None) return false;
    Rig = SkeletalMesh(DynamicLoadObject(Family.default.FirstPersonMeshName, class'SkeletalMesh', true));
    if (Rig == None) return false;
    Shape = Rig.Name;
    MeshPath = "KF2VRHands.VRAmmo_Live_" $ Shape;
    switch (Shape)
    {
        case 'Wep_1stP_9mm_Rig':
        case 'Wep_1stP_M1911_Rig':
        case 'Wep_1stP_Deagle_Rig':
        case 'Wep_1stP_Medic_Pistol_Rig':
        case 'WEP_1P_HRG_93R_Pistol_Rig':
        case 'Wep_1stP_AF2001_Rig':
        case 'Wep_1P_RiotShield_Rig':
        case 'Wep_1stP_Medic_SMG_Rig':
        case 'Wep_1stP_KRISS_Rig':
        case 'Wep_1stP_HK_UMP_Rig':
        case 'Wep_1stP_MP5RAS_Rig':
        case 'Wep_1stP_AK12_Rig':
        case 'Wep_1stP_L85A2_Rig':
        case 'Wep_1stP_AR15_9mm_Rig':
        case 'Wep_1stP_SCAR_Rig':
        case 'Wep_1stP_MP7_Rig':
        case 'Wep_1stP_P90_Rig':
        case 'Wep_1stP_Saiga12_Rig':
        case 'WEP_1stP_FNFAL_Rig':
        case 'Wep_1stP_M16_M203_Rig':
        case 'Wep_1stP_HRG_IncendiaryRifle_Rig':
        case 'WEP_1stP_G36C_Rig':
        case 'WEP_1stP_Famas_Rig':
        case 'WEP_1stP_M14_EBR':
        case 'WEP_1stP_Mosin_Rig':
        case 'Wep_1stP_ChiappaRhino_Rig':
        case 'WEP_1stP_HRG_CranialPopper_Rig':
        case 'Wep_1stP_Bleeder_Rig':
            break;
        case 'Wep_1stP_Medic_Shotgun_Rig': MaterialSlot = 1; break;
        case 'Wep_1stP_G18C_Rig':
            MeshPath = "KF2VRHands.VRAmmo_Live_Wep_1stP_9mm_Rig";
            Rig = SkeletalMesh(DynamicLoadObject(class'KFWeap_Pistol_9mm'.default.FirstPersonMeshName, class'SkeletalMesh', true));
            break;
        case 'Wep_1stP_HRG_Teslauncher_Rig':
        case 'Wep_1stP_Medic_GrenadeLauncher_Rig':
        case 'Wep_1stP_Medic_Assault_Rig':
            MeshPath = "KF2VRHands.VRAmmo_Live_Wep_1stP_M16_M203_Rig";
            Surface0 = MaterialInterface(DynamicLoadObject("WEP_1P_M16_M203_MAT.Wep_1stP_M16_MIC", class'MaterialInterface', true));
            break;
        case 'Wep_1stP_MB500_Rig':
        case 'Wep_1stP_DragonsBreath_Rig':
        case 'Wep_1stP_M4Shotgun_Rig':
        case 'Wep_1stP_HZ12_Rig':
        case 'Wep_1stP_Frost_Shotgun_Axe_Rig':
        case 'Wep_1stP_Winchester_Rig':
        case 'Wep_1stP_Centerfire_Rig':
        case 'Wep_1stP_M99_Rig':
        case 'Wep_1stP_CompoundBow_Rig':
        case 'Wep_1stP_Crossbow_Rig':
            MeshPath = "KF2VRHands.VRAmmo_" $ Shape;
            break;
        default: return false;
    }
    Asset = StaticMesh(DynamicLoadObject(MeshPath, class'StaticMesh', true));
    if (Surface0 == None && Rig != None && MaterialSlot < Rig.Materials.Length)
        Surface0 = Rig.Materials[MaterialSlot];
    return Asset != None && Surface0 != None;
}

function bool LoadShape(VRHandsBridge Bridge, name Shape, optional string MeshPath)
{
    local StaticMeshComponent Measure;
    if (Shape == CachedShape && RoundMesh != None) return true;
    if (MeshPath == "") MeshPath = "KF2VRHands.VRAmmo_Live_" $ Shape;
    RoundMesh = StaticMesh(DynamicLoadObject(MeshPath, class'StaticMesh', true));
    CachedShape = '';
    if (RoundMesh == None) return false;
    Measure = new(Bridge) class'StaticMeshComponent';
    if (Measure == None) return false;
    Measure.SetAbsolute(true, true, true);
    Measure.SetActorCollision(false, false);
    Measure.SetTraceBlocking(false, false);
    Measure.CastShadow = false;
    Measure.SetHidden(true);
    Measure.SetStaticMesh(RoundMesh);
    Bridge.AttachComponent(Measure);
    Measure.ForceUpdate(true);
    Centre = Measure.Bounds.Origin; Extent = Measure.Bounds.BoxExtent;
    Bridge.DetachComponent(Measure);
    if (Measure.GetNumElements() != 1 || Extent.X <= 0 || Extent.Y <= 0 || Extent.Z <= 0) return false;
    CachedShape = Shape;
    return true;
}

function int Emit(VRInteractiveReload Session, int Count)
{
    if (Session == None) return 0;
    return EmitWeapon(Session.Bridge, Session.Gun, Count, Session.GunDropVelocity(vect(0,0,0)));
}

function int EmitWeapon(VRHandsBridge Bridge, KFWeapon W, int Count, optional vector Motion,
    optional bool bPaidRecovery)
{
    local SkeletalMesh Donor;
    local MaterialInterface Surface;
    local name Shape, RoundBone;
    local string MeshPath;
    local vector Port, At, Launch;
    local rotator PortRotation;
    local quat PortQ, RoundQ;
    local float Scale;
    local int I, Emitted;
    local bool bTwin, bDonor;
    local KFMuzzleFlash Ejector;
    local name EjectSocket;
    if (Bridge == None || Props == None || Count < 1 || Count > 2) return 0;
    if (W == None || W.bDeleteMe || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) return 0;
    // This flag comes only from an accepted authority debit receipt. Audited
    // families exported their exact paid world payload before that debit;
    // failed exports reject it. Lose-ammo-Off cosmetic cycling never sets it.
    if (bPaidRecovery && RecoverySupported(W.Class)) return Count;
    // Stock creates the live emitter lazily on the first shot. A manual rack
    // before that shot still uses its authored port, without creating effects.
    Ejector = W.MuzzleFlash != None ? W.MuzzleFlash : W.MuzzleFlashTemplate;
    if (Ejector == None && W.MuzzleFlashTemplateName != "")
        Ejector = KFMuzzleFlash(DynamicLoadObject(W.MuzzleFlashTemplateName, class'KFMuzzleFlash', true));
    EjectSocket = Ejector != None ? Ejector.ShellEjectSocketName : class'KFMuzzleFlash'.default.ShellEjectSocketName;
    Shape = W.MySkelMesh.SkeletalMesh.Name;
    RoundBone = 'RW_Bullets1';
    switch (Shape)
    {
        case 'Wep_1stP_9mm_Rig':
        case 'Wep_1stP_M1911_Rig':
        case 'Wep_1stP_Deagle_Rig':
        case 'Wep_1stP_Medic_Pistol_Rig':
        case 'WEP_1P_HRG_93R_Pistol_Rig':
        case 'Wep_1stP_AF2001_Rig':
        case 'Wep_1P_RiotShield_Rig':
        case 'Wep_1stP_Medic_SMG_Rig':
        case 'Wep_1stP_KRISS_Rig':
        case 'Wep_1stP_HK_UMP_Rig':
        case 'Wep_1stP_MP5RAS_Rig':
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'Wep_1stP_AK12_Rig':
        case 'Wep_1stP_L85A2_Rig':
        case 'Wep_1stP_AR15_9mm_Rig':
        case 'Wep_1stP_SCAR_Rig':
        case 'Wep_1stP_MP7_Rig':
        case 'Wep_1stP_P90_Rig':
        case 'Wep_1stP_Saiga12_Rig':
        case 'WEP_1stP_FNFAL_Rig':
        case 'Wep_1stP_M16_M203_Rig':
        case 'Wep_1stP_HRG_IncendiaryRifle_Rig':
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'WEP_1stP_G36C_Rig':
            RoundBone = 'RW_Bullets2';
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'WEP_1stP_Famas_Rig':
            RoundBone = 'RW_Famas_Shell2';
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'Wep_1stP_Medic_Shotgun_Rig':
            Surface = W.MySkelMesh.GetMaterial(1);
            break;
        case 'Wep_1stP_G18C_Rig':
            bDonor = true;
            Shape = 'Wep_1stP_9mm_Rig';
            Donor = SkeletalMesh(DynamicLoadObject(class'KFWeap_Pistol_9mm'.default.FirstPersonMeshName, class'SkeletalMesh', true));
            if (Donor != None && Donor.Materials.Length > 0) Surface = Donor.Materials[0];
            break;
        case 'Wep_1stP_HRG_Teslauncher_Rig':
        case 'Wep_1stP_Medic_GrenadeLauncher_Rig':
        case 'Wep_1stP_Medic_Assault_Rig':
            // These rifle rigs supply only magazine-top blocks or partial
            // cartridges. Reuse a complete stock rifle cartridge with its
            // own matching surface; the Teslauncher also inherits M16M203.
            bDonor = true;
            Shape = 'Wep_1stP_M16_M203_Rig';
            Surface = MaterialInterface(DynamicLoadObject("WEP_1P_M16_M203_MAT.Wep_1stP_M16_MIC", class'MaterialInterface', true));
            break;
        case 'Wep_1stP_MB500_Rig':
        case 'Wep_1stP_DragonsBreath_Rig':
            RoundBone = 'RW_Shell1';
            MeshPath = "KF2VRHands.VRAmmo_" $ Shape;
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'Wep_1stP_Winchester_Rig':
        case 'Wep_1stP_Centerfire_Rig':
            RoundBone = 'RW_Bullet1';
            MeshPath = "KF2VRHands.VRAmmo_" $ Shape;
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'WEP_1stP_M14_EBR':
            RoundBone = 'RW_Bullet1';
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'Wep_1stP_M99_Rig':
            RoundBone = 'RW_Shell1';
            MeshPath = "KF2VRHands.VRAmmo_" $ Shape;
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        case 'WEP_1stP_Mosin_Rig':
            RoundBone = 'RW_Shell1';
            Surface = W.MySkelMesh.GetMaterial(0);
            break;
        default: return 0;
    }
    if (Surface == None || !LoadShape(Bridge, Shape, MeshPath) || W.MySkelMesh.MatchRefBone(RoundBone) < 0
        || !W.MySkelMesh.GetSocketWorldLocationAndRotation(EjectSocket, Port, PortRotation)) return 0;
    bTwin = Shape == 'Wep_1stP_AF2001_Rig';
    if (Count == 2 && (!bTwin || W.MySkelMesh.MatchRefBone('RW_Bullets2') < 0)) return 0;
    Scale = W.MySkelMesh.Scale * W.MySkelMesh.Scale3D.X * W.DrawScale * W.DrawScale3D.X;
    if (!(Scale > 0.01 && Scale < 100)) Scale = 1.0;
    PortQ = QuatFromRotator(PortRotation);
    for (I = 0; I < Count; ++I)
    {
        // Both donors' bullet-to-weapon bind rotations are identity. Other
        // cuts retain their own live bone frame, independently of launch.
        RoundQ = W.MySkelMesh.GetBoneQuaternion(bDonor ? 'RW_Weapon' : (I == 1 ? 'RW_Bullets2' : RoundBone));
        Launch.X = 150 + FRand() * 100;
        Launch.Y = -15 + FRand() * 30;
        Launch.Z = FRand() * 100;
        At = Port + QuatRotateVector(RoundQ, Centre * Scale);
        // AF2011 supplies one port socket. Carry the second round across by
        // its actual chamber separation, without inventing a barrel offset.
        if (I == 1) At += W.MySkelMesh.GetBoneLocation('RW_Bullets2') - W.MySkelMesh.GetBoneLocation('RW_Bullets1');
        if (Props.Drop(RoundMesh, Surface, None, At, RoundQ,
            QuatRotateVector(PortQ, Launch) + Motion, Scale, Centre, Extent)) ++Emitted;
    }
    return Emitted;
}
