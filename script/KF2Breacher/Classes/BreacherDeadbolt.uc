// Independent forearm forge. Its own rig owns presentation and its ammunition
// transfer uses explicit forge beats, never another weapon's mesh or notifies.
class BreacherDeadbolt extends KFWeapon;

var float ForgeSeatSeconds, ForgeEndSeconds;

simulated function string GetHumanReadableName() { return "Deadbolt (experimental)"; }
// One deliberate shot mode; alternate input never becomes a Nailgun mode.
simulated function AltFireMode() {}

simulated function TimeWeaponReloading()
{
    local float Rate;
    if (ReloadStatus==RS_Reloading || ReloadStatus==RS_Complete)
    {
        ReloadStatus=RS_Complete;
        ReloadComplete();
        return;
    }
    ReloadStatus=RS_Reloading;
    Rate=FMax(0.1,GetReloadRateScale());
    PlayAnimation('Reload',ForgeEndSeconds*Rate);
    // Stock Reloading owns these timers and clears BOTH on cancellation,
    // switching and destruction. PerformReload preserves stock ammo authority,
    // spare conservation, perk capacity and supported client prediction.
    SetTimer(ForgeSeatSeconds*Rate,false,'ReloadAmmoTimer');
    SetTimer(ForgeEndSeconds*Rate,false,'ReloadStatusTimer');
}

simulated function name GetReloadAnimName(bool bTacticalReload) { return 'Reload'; }

// Stock Active tries a fidget when a full/empty-reserve reload is refused.
// This mechanical rig intentionally has no stock gun-check animations.
simulated state Active
{
    simulated function bool CanPlayIdleFidget(optional bool bOnReload) { return false; }
    simulated function bool PlayIdleFidgetAnim() { return false; }
}

// The independent rig has no stock hand/sprint animation tree requirements.
// WeaponSeq preserves KFWeapon's ordinary equip/fire/reload animation API.
simulated event PostInitAnimTree(SkeletalMeshComponent SkelComp)
{
    local MaterialInstanceConstant Surface;
    Super.PostInitAnimTree(SkelComp);
    if (SkelComp.SkeletalMesh==None) return;
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRDeadboltBody");
    if (Surface!=None) SkelComp.SetMaterial(0,Surface);
}

defaultproperties
{
    PackageKey="KF2VRHands"
    FirstPersonMeshName="KF2VRHands.VRDeadboltRig"
    FirstPersonAnimSetNames(0)="KF2VRHands.VRDeadboltRig_Anims"
    PickupMeshName="KF2VRHands.VRDeadbolt"
    // Standard observers reuse the same owned equipment rig.
    AttachmentArchetypeName="KF2Breacher.Default__BreacherDeadboltAttachment"
    MuzzleFlashTemplateName=""
    WeaponSelectTexture=None
    Begin Object Name=FirstPersonMesh
        Rotation=(Yaw=16384)
    End Object
    InventorySize=5
    GroupPriority=75
    bHasIronSights=false
    bHasFlashlight=false
    bUseAdditiveMoveAnim=false
    bEnableTiltSkelControl=false
    bUseAnimLenEquipTime=false
    bCheckBoltLockPostReload=false
    bReloadFromMagazine=true
    // KFWeapon itself defaults to a non-reloadable weapon with no reserves.
    // Capacity alone does not supply ammo or make the forge reachable.
    bCanBeReloaded=true
    EquipTime=0.35
    PutDownTime=0.25
    EquipAnim=Idle
    PutDownAnim=Idle
    IdleAnims(0)=Idle
    IdleFidgetAnims.Empty
    FireAnim=Fire
    FireLastAnim=FireLast
    FireSightedAnims.Empty
    PlayerViewOffset=(X=3,Y=7,Z=-2)
    FireOffset=(X=20,Y=0,Z=10)
    ForgeSeatSeconds=2.4
    ForgeEndSeconds=2.9
    WeaponFireTypes(0)=EWFT_Projectile
    WeaponFireTypes(1)=EWFT_Projectile
    FiringStatesArray(0)=WeaponSingleFiring
    FiringStatesArray(1)=WeaponSingleFiring
    WeaponProjectiles(0)=class'BreacherCascadeProjectile'
    WeaponProjectiles(1)=class'BreacherCascadeProjectile'
    NumPellets(0)=1
    NumPellets(1)=1
    Spread(0)=0.0
    Spread(1)=0.0
    FireInterval(0)=0.55
    FireInterval(1)=0.55
    InstantHitDamage(0)=40
    InstantHitDamage(1)=40
    InstantHitDamageTypes(0)=class'BreacherDeadboltDamage'
    InstantHitDamageTypes(1)=class'BreacherDeadboltDamage'
    InstantHitDamageTypes(2)=class'KFDT_Bludgeon'
    WeaponFireSnd(0)=(DefaultCue=AkEvent'WW_WEP_SA_Railgun.Play_WEP_SA_Railgun_Fire_3P',FirstPersonCue=AkEvent'WW_WEP_SA_Railgun.Play_WEP_SA_Railgun_Fire_1P')
    WeaponFireSnd(1)=(DefaultCue=AkEvent'WW_WEP_SA_Railgun.Play_WEP_SA_Railgun_Fire_3P',FirstPersonCue=AkEvent'WW_WEP_SA_Railgun.Play_WEP_SA_Railgun_Fire_1P')
    WeaponDryFireSnd(0)=AkEvent'WW_WEP_SA_Railgun.Play_WEP_SA_Railgun_DryFire'
    // M99-class pitch, so VRHandsBridge's hand-space kick (sized from these) is the heaviest in the
    // game: about 4 cm with a 0.6 s recovery. The authored Deadbolt take only shakes the gauntlet on
    // top. Desktop camera recoil grows from the same numbers; accepted for this VR-first slice.
    minRecoilPitch=1100
    maxRecoilPitch=1200
    minRecoilYaw=-60
    maxRecoilYaw=60
    RecoilRate=0.045
    bLoopingFireAnim(0)=false
    bLoopingFireAnim(1)=false
    // Temporary slice tuning, not approved progression or perk balance.
    MagazineCapacity(0)=8
    SpareAmmoCapacity(0)=80
    InitialSpareMags(0)=10
    AssociatedPerkClasses.Empty()
    AssociatedPerkClasses(0)=class'BreacherPerk'
    WeaponUpgrades.Empty()
}
