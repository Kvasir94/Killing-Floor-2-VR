// One permanently cabled hook on its own forearm rig. Authority owns the whole
// flight/bite/reel/return transaction, without stock bolt pickups or reloads.
class BreacherRipcord extends KFWeapon;

var BreacherTether ActiveTether;

replication
{
    if (bNetDirty && bNetOwner) ActiveTether;
}

simulated function string GetHumanReadableName() { return "Ripcord (experimental)"; }
simulated function AltFireMode() {}

simulated function bool LineOut()
{
    return ActiveTether!=None && !ActiveTether.bDeleteMe
        && ActiveTether.Phase!=class'BreacherTether'.const.PHASE_DONE;
}

simulated function bool HasAmmo(byte FireModeNum, optional int Amount)
{
    if (FireModeNum<2 && LineOut()) return false;
    return Super.HasAmmo(FireModeNum,Amount);
}

simulated function bool CanReload(optional byte FireModeNum) { return false; }
simulated function bool ShouldAutoReload(byte FireModeNum) { return false; }

// Reload is an explicit recall of this weapon's permanently cabled hook.
// It does not enter stock reload state or transfer any spare ammunition.
// KFWeapon skips its ordinary ServerStartFire RPC for reload input, so the
// owner routes this command separately before stock admission can reject it.
simulated function StartFire(byte FireModeNum)
{
    if (FireModeNum==RELOAD_FIREMODE) { ServerRecall(); return; }
    Super.StartFire(FireModeNum);
}

reliable server function ServerRecall()
{
    if (Instigator==None || Instigator.bDeleteMe || Instigator.Health<=0 || Owner!=Instigator
        || ActiveTether==None || ActiveTether.bDeleteMe || ActiveTether.Launcher!=self
        || ActiveTether.Anchor!=Instigator) return;
    ActiveTether.Finish();
}

simulated state Active
{
    simulated function bool CanPlayIdleFidget(optional bool bOnReload) { return false; }
    simulated function bool PlayIdleFidgetAnim() { return false; }
}

simulated function KFProjectile SpawnProjectile(class<KFProjectile> KFProjClass, vector RealStartLoc, vector AimDir)
{
    local KFProjectile P;
    local BreacherRipcordHarpoon Hook;
    P=Super.SpawnProjectile(KFProjClass,RealStartLoc,AimDir);
    Hook=BreacherRipcordHarpoon(P);
    if (Role==ROLE_Authority && CurrentFireMode<2)
    {
        if (Hook!=None && !Hook.bDeleteMe)
        {
            Hook.Launcher=self;
            ActiveTether=class'BreacherTether'.static.Launch(Hook,Instigator,self);
            Hook.Line=ActiveTether;
        }
        // KFWeapon charges after spawning; recover failed creation next tick.
        if (Hook==None || Hook.bDeleteMe || ActiveTether==None)
        {
            // A refunded launch must never leave a damaging uncabled hook.
            if (Hook!=None && !Hook.bDeleteMe) Hook.Destroy();
            P=None;
            SetTimer(0.01,false,'RecoverFailedShot');
        }
        bNetDirty=true;
        bForceNetUpdate=true;
    }
    return P;
}

function RecoverFailedShot()
{
    if (LineOut()) return;
    AmmoCount[0]=Min(AmmoCount[0]+1,MagazineCapacity[0]);
    ClientForceAmmoUpdate(AmmoCount[0],SpareAmmoCount[0]);
}

// Return exactly the spent hook, never a full magazine or spare round.
function HarpoonReturned(BreacherTether Tether)
{
    if (Role!=ROLE_Authority || Tether!=ActiveTether) return;
    ActiveTether=None;
    AmmoCount[0]=Min(AmmoCount[0]+1,MagazineCapacity[0]);
    ClientForceAmmoUpdate(AmmoCount[0],SpareAmmoCount[0]);
    bNetDirty=true;
    bForceNetUpdate=true;
}

simulated function PutDownWeapon()
{
    if (Role==ROLE_Authority && ActiveTether!=None) ActiveTether.Finish();
    Super.PutDownWeapon();
}

simulated function DetachWeapon()
{
    if (Role==ROLE_Authority && ActiveTether!=None) ActiveTether.Finish();
    Super.DetachWeapon();
}

simulated event Destroyed()
{
    if (Role==ROLE_Authority && ActiveTether!=None) ActiveTether.Finish();
    Super.Destroyed();
}

simulated event PostInitAnimTree(SkeletalMeshComponent SkelComp)
{
    local MaterialInstanceConstant Surface;
    Super.PostInitAnimTree(SkelComp);
    if (SkelComp.SkeletalMesh==None) return;
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRRipcordBody");
    if (Surface!=None) SkelComp.SetMaterial(0,Surface);
}

defaultproperties
{
    PackageKey="KF2VRHands"
    FirstPersonMeshName="KF2VRHands.VRRipcordRig"
    FirstPersonAnimSetNames(0)="KF2VRHands.VRRipcordRig_Anims"
    PickupMeshName="KF2VRHands.VRRipcord"
    AttachmentArchetypeName="KF2Breacher.Default__BreacherRipcordAttachment"
    MuzzleFlashTemplateName=""
    WeaponSelectTexture=None
    Begin Object Name=FirstPersonMesh
        Rotation=(Yaw=16384)
    End Object
    InventorySize=6
    GroupPriority=50
    bHasIronSights=false
    bHasFlashlight=false
    bUseAdditiveMoveAnim=false
    bEnableTiltSkelControl=false
    bUseAnimLenEquipTime=false
    bCheckBoltLockPostReload=false
    bCanBeReloaded=false
    bAllowClientAmmoTracking=false
    EquipTime=0.35
    PutDownTime=0.25
    EquipAnim=Idle
    PutDownAnim=Idle
    IdleAnims(0)=Idle
    IdleFidgetAnims.Empty
    FireAnim=Fire
    FireLastAnim=Fire
    FireSightedAnims.Empty
    BonesToLockOnEmpty.Empty
    PlayerViewOffset=(X=3,Y=7,Z=-2)
    FireOffset=(X=20,Y=0,Z=10)
    WeaponFireTypes(0)=EWFT_Projectile
    WeaponFireTypes(1)=EWFT_Projectile
    FiringStatesArray(0)=WeaponSingleFiring
    FiringStatesArray(1)=WeaponSingleFiring
    WeaponProjectiles(0)=class'BreacherRipcordHarpoon'
    WeaponProjectiles(1)=class'BreacherRipcordHarpoon'
    InstantHitDamage(0)=120
    InstantHitDamage(1)=120
    InstantHitDamageTypes(0)=class'BreacherRipcordDamage'
    InstantHitDamageTypes(1)=class'BreacherRipcordDamage'
    InstantHitDamageTypes(2)=class'KFDT_Bludgeon'
    PenetrationPower(0)=0.0
    PenetrationPower(1)=0.0
    Spread(0)=0.0
    Spread(1)=0.0
    FireInterval(0)=0.55
    FireInterval(1)=0.55
    WeaponFireSnd(0)=(DefaultCue=AkEvent'WW_WEP_SA_Crossbow.Play_WEP_SA_Crossbow_Fire_3P',FirstPersonCue=AkEvent'WW_WEP_SA_Crossbow.Play_WEP_SA_Crossbow_Fire_1P')
    WeaponDryFireSnd(0)=AkEvent'WW_WEP_SA_Crossbow.Play_WEP_SA_Crossbow_DryFire'
    MagazineCapacity(0)=1
    SpareAmmoCapacity(0)=0
    InitialSpareMags(0)=0
    AssociatedPerkClasses.Empty()
    AssociatedPerkClasses(0)=class'BreacherPerk'
    WeaponUpgrades.Empty()
}
