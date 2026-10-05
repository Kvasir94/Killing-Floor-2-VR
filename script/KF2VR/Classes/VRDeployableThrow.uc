// Shared solo/server throw of a held deployable (C4, Sentinel, HRG Bombardier)
// from the releasing hand at its measured velocity. Stock WeaponThrowing plays
// the arm animation and spawns along the view 0.25 s later; this runs the same
// bookkeeping each weapon's ProjectileFire does (charge list, turret list,
// owner weapon, upgrade, skin) without the state, the animation or the aim.
class VRDeployableThrow extends Object abstract;

static function bool Handles(KFWeapon W)
{
    return KFWeap_Thrown_C4(W) != None || KFWeap_AutoTurret(W) != None || KFWeap_HRG_Warthog(W) != None;
}

// Stock launch speed caps: C4 flies at 1200 UU/s, the drones at ThrowStrength.
static function float SpeedCap(KFWeapon W)
{
    if (KFWeap_AutoTurret(W) != None) return KFWeap_AutoTurret(W).ThrowStrength;
    if (KFWeap_HRG_Warthog(W) != None) return KFWeap_HRG_Warthog(W).ThrowStrength;
    return class'KFProj_Thrown_C4'.default.Speed;
}

// The grenade assistance curve under each deployable's own stock speed.
static function vector AssistedVelocity(KFWeapon W, vector Measured)
{
    local float HandSpeed, Gain;
    HandSpeed = VSize(Measured);
    Gain = 1.0 + 1.8 * FClamp(HandSpeed / 400.0, 0.0, 1.0);
    return Normal(Measured) * FMin(HandSpeed * Gain, SpeedCap(W));
}

// A drone limit reached replaces the oldest, as the stock trigger does; it is
// refused while the previous drone is still in flight or deploying.
static function bool ReplaceTurret(KFWeapon W, KFPlayerController KFPC)
{
    local KFWeap_AutoTurret Turret;
    local KFWeap_HRG_Warthog Warthog;
    Turret = KFWeap_AutoTurret(W);
    Warthog = KFWeap_HRG_Warthog(W);
    if (Turret != None)
    {
        if (Turret.KFPC == None) Turret.KFPC = KFPC;
        if (KFPC.DeployedTurrets.Length < Turret.MaxTurretsDeployed) return true;
        if (!Turret.bTurretReadyToUse) return false;
        Turret.Detonate();
    }
    else if (Warthog != None)
    {
        if (Warthog.KFPC == None) Warthog.KFPC = KFPC;
        if (KFPC.DeployedTurrets.Length < Warthog.MaxTurretsDeployed) return true;
        if (!Warthog.bTurretReadyToUse) return false;
        Warthog.Detonate();
    }
    return true;
}

static function bool SpawnDeployable(KFWeapon W, KFPawn_Human Human, KFPlayerController KFPC,
    vector Position, vector Velocity)
{
    local KFProj_Thrown_C4 Charge;
    local KFPawn_AutoTurret Turret;
    local KFPawn_HRG_Warthog Warthog;
    local rotator Facing;
    local int FireMode;
    // Drones land upright, facing along the throw (or the body when dropped).
    Facing = Human.Rotation;
    if (VSize2D(Velocity) > 50) Facing.Yaw = rotator(Velocity).Yaw;
    Facing.Pitch = 0; Facing.Roll = 0;
    if (KFWeap_AutoTurret(W) != None)
    {
        Turret = W.Spawn(class'KFPawn_AutoTurret', W,, Position, Facing,, true);
        if (Turret == None) return false;
        Turret.OwnerWeapon = KFWeap_AutoTurret(W);
        Turret.SetPhysics(PHYS_Falling);
        Turret.Velocity = Velocity;
        Turret.UpdateInstigator(Human);
        Turret.UpdateWeaponUpgrade(W.CurrentWeaponUpgradeIndex);
        Turret.SetTurretState(ETS_Throw);
        KFPC.DeployedTurrets.AddItem(Turret);
        KFWeap_AutoTurret(W).NumDeployedTurrets = KFPC.DeployedTurrets.Length;
        KFWeap_AutoTurret(W).SetReadyToUse(false);
    }
    else if (KFWeap_HRG_Warthog(W) != None)
    {
        Warthog = W.Spawn(class'KFPawn_HRG_Warthog', W,, Position, Facing,, true);
        if (Warthog == None) return false;
        Warthog.OwnerWeapon = KFWeap_HRG_Warthog(W);
        Warthog.SetPhysics(PHYS_Falling);
        Warthog.Velocity = Velocity;
        Warthog.UpdateInstigator(Human);
        Warthog.UpdateWeaponUpgrade(W.CurrentWeaponUpgradeIndex);
        Warthog.SetTurretState(ETS_Throw);
        KFPC.DeployedTurrets.AddItem(Warthog);
        KFWeap_HRG_Warthog(W).NumDeployedTurrets = KFPC.DeployedTurrets.Length;
        KFWeap_HRG_Warthog(W).SetReadyToUse(false);
    }
    else
    {
        // Owner is the weapon: the charge reports its own detonation back to it.
        Charge = W.Spawn(class'KFProj_Thrown_C4', W,, Position);
        if (Charge == None || Charge.bDeleteMe) return false;
        // KFWeapon.SpawnProjectile for THROW_FIREMODE, not the idle DETONATE mode.
        FireMode = class'KFWeap_ThrownBase'.const.THROW_FIREMODE;
        if (W.InstantHitDamage.Length > FireMode && W.InstantHitDamageTypes.Length > FireMode)
        {
            Charge.Damage = W.GetModifiedDamage(FireMode);
            Charge.MyDamageType = W.InstantHitDamageTypes[FireMode];
        }
        Charge.InitialPenetrationPower = W.GetInitialPenetrationPower(FireMode);
        Charge.PenetrationPower = Charge.InitialPenetrationPower;
        Charge.UpgradeDamageMod = W.GetUpgradeDamageMod();
        Charge.Init(Normal(Velocity));
        // Init applies stock Speed/TossZ; the release sample replaces both,
        // and zero speed places the charge at the hand.
        Charge.Velocity = Velocity;
        Charge.Speed = VSize(Velocity);
        Charge.MaxSpeed = FMax(Charge.MaxSpeed, Charge.Speed);
        if (W.SkinItemId > 0)
        {
            Charge.WeaponSkinId = W.SkinItemId;
            Charge.SetWeaponSkin(W.SkinItemId);
            Charge.bNetDirty = true;
        }
        KFWeap_Thrown_C4(W).DeployedCharges.AddItem(Charge);
        KFWeap_Thrown_C4(W).NumDeployedCharges = KFWeap_Thrown_C4(W).DeployedCharges.Length;
    }
    W.bForceNetUpdate = true;
    return true;
}

static function bool Launch(Actor Spawner, KFPawn_Human Human, KFWeapon W, int Hand,
    vector Position, vector Velocity, vector Head)
{
    local KFInventoryManager Inv;
    local KFPlayerController KFPC;
    local vector HitLocation, HitNormal;
    if (Spawner == None || Spawner.Role != ROLE_Authority || Human == None
        || Human.Role != ROLE_Authority || Human.Health <= 0 || Human.bDeleteMe
        || Hand < 0 || Hand > 1 || !Handles(W) || W.bDeleteMe
        || W.Owner != Human || W.Instigator != Human || W.InvManager != Human.InvManager
        || !class'VRGrenadeThrow'.static.Bounded(Position - Human.Location, 240)
        || !class'VRGrenadeThrow'.static.Bounded(Head - Human.Location, 160)
        || !class'VRGrenadeThrow'.static.Bounded(Velocity, 1800)) return false;
    Inv = KFInventoryManager(Human.InvManager);
    KFPC = KFPlayerController(Human.Controller);
    if (Inv == None || Inv.bServerTraderMenuOpen || KFPC == None || W.AmmoCount[0] <= 0
        || W.IsInState('WeaponThrowing') || W.IsInState('WeaponDetonating')) return false;
    if (Spawner.Trace(HitLocation, HitNormal, Position, Head, false, vect(6,6,6)) != None) return false;
    if (!ReplaceTurret(W, KFPC)) return false;
    Velocity = AssistedVelocity(W, Velocity);
    if (!SpawnDeployable(W, Human, KFPC, Position, Velocity)) return false;
    // Stock throws, then moves the next charge from spare after
    // ConsumeSpareAmmoDelay. The hold's cooldown supplies that delay, so the
    // authority refills at once and tells a remote owner, which never predicts.
    W.ConsumeAmmo(class'KFWeap_ThrownBase'.const.THROW_FIREMODE);
    if (W.AmmoCount[0] < W.MagazineCapacity[0] && W.SpareAmmoCount[0] > 0)
    {
        W.AmmoCount[0] += 1;
        W.SpareAmmoCount[0] -= 1;
    }
    if (!Human.IsLocallyControlled()) W.ClientForceAmmoUpdate(W.AmmoCount[0], W.SpareAmmoCount[0]);
    W.SetWeakZedGrabCooldownOnPawn(W.GrenadeTossWeakZedGrabCooldown);
    `log("KF2VR_DEPLOYABLE throw hand=" $ Hand $ " weapon=" $ W.Class.Name $ " position=" $ Position
        $ " velocity=" $ Velocity $ " ammo=" $ W.AmmoCount[0] $ "+" $ W.SpareAmmoCount[0]
        $ " netmode=" $ Spawner.WorldInfo.NetMode);
    return true;
}
