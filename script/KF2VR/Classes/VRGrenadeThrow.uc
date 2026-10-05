// Shared solo/server transaction. Physical release never enters GrenadeFiring:
// its EndState unconditionally spawns a second, animation-timed projectile.
class VRGrenadeThrow extends Object abstract;

static function bool Bounded(vector Value, float Limit)
{
    return Value.X >= -Limit && Value.X <= Limit
        && Value.Y >= -Limit && Value.Y <= Limit
        && Value.Z >= -Limit && Value.Z <= Limit && VSizeSq(Value) <= Limit * Limit;
}

// Shared authority assistance preserves direction and gentle drops. A 4 m/s
// swing gets 2.8x speed, capped at the stock base grenade launch speed.
static function vector AssistedVelocity(vector Measured)
{
    local float HandSpeed, Gain;
    HandSpeed = VSize(Measured);
    Gain = 1.0 + 1.8 * FClamp(HandSpeed / 400.0, 0.0, 1.0);
    return Normal(Measured) * FMin(HandSpeed * Gain, 2500.0);
}

static function bool Launch(Actor Spawner, KFPawn_Human Human, KFWeapon WeaponOwner,
    class<KFProj_Grenade> GrenadeClass, int Hand, vector Position, vector Velocity,
    vector Head)
{
    local KFInventoryManager Inv;
    local KFWeapon Candidate;
    local KFProj_Grenade Projectile;
    local vector HitLocation, HitNormal;
    local bool bOwned;
    local int FireMode;
    if (Spawner == None || Spawner.Role != ROLE_Authority || Human == None
        || Human.Role != ROLE_Authority || Human.Health <= 0 || Human.bDeleteMe
        || (Human.bNoWeaponFiring && !Human.IsDoingSpecialMove(SM_GrappleVictim))
        || Hand < 0 || Hand > 1 || WeaponOwner == None || WeaponOwner.bDeleteMe
        || WeaponOwner.Owner != Human || WeaponOwner.Instigator != Human
        || WeaponOwner.InvManager != Human.InvManager || GrenadeClass == None
        || Human.GetPerk() == None || Human.GetPerk().GetGrenadeClass() != GrenadeClass
        || !Bounded(Position - Human.Location, 240) || !Bounded(Head - Human.Location, 160)
        || !Bounded(Velocity, 1800)) return false;
    Inv = KFInventoryManager(Human.InvManager);
    if (Inv == None || Inv.GrenadeCount == 0 || Inv.bServerTraderMenuOpen) return false;
    foreach Inv.InventoryActors(class'KFWeapon', Candidate)
    {
        if (Candidate.IsInState('GrenadeFiring')) return false;
        // Stock refuses a toss for 0.35 s after a Zed grab spins the player
        // (KFSM_GrappleCombined stamps the held weapon) so the grenade cannot
        // land at their own feet; the medic grenade opts out. The stamp sits on
        // whichever weapon was held at the grab, so check every carried gun.
        if (Candidate.ZedGrabGrenadeTossCooldown > Human.WorldInfo.TimeSeconds
            && !GrenadeClass.default.bAllowTossDuringZedGrabRotation) return false;
        if (Candidate == WeaponOwner) bOwned = true;
    }
    if (!bOwned || Spawner.Trace(HitLocation, HitNormal, Position, Head, false, vect(6,6,6)) != None)
        return false;

    Velocity = AssistedVelocity(Velocity);
    Spawner.Instigator = Human;
    Projectile = Spawner.Spawn(GrenadeClass, WeaponOwner,, Position, rotator(Velocity));
    if (Projectile == None || Projectile.bDeleteMe) return false;
    // Same base initialization as KFWeapon.SpawnProjectile, without a weapon
    // subclass's multi-projectile override or camera-based aim adjustment.
    FireMode = class'KFWeapon'.const.GRENADE_FIREMODE;
    if (WeaponOwner.InstantHitDamage.Length > FireMode && WeaponOwner.InstantHitDamageTypes.Length > FireMode)
    {
        Projectile.Damage = WeaponOwner.GetModifiedDamage(FireMode);
        Projectile.MyDamageType = WeaponOwner.InstantHitDamageTypes[FireMode];
    }
    Projectile.InitialPenetrationPower = WeaponOwner.GetInitialPenetrationPower(FireMode);
    Projectile.PenetrationPower = Projectile.InitialPenetrationPower;
    Projectile.UpgradeDamageMod = WeaponOwner.GetUpgradeDamageMod();
    Projectile.Init(Normal(Velocity));
    Projectile.WeaponFireMode = FireMode;
    Projectile.bFiredFromLeftHandWeapon = Hand == 0;
    // Init applies stock Speed/TossZ. Replace both with this release sample;
    // zero speed is a deliberate drop, never a camera-directed fallback.
    Projectile.Velocity = Velocity;
    Projectile.Speed = VSize(Velocity);
    Projectile.MaxSpeed = FMax(Projectile.MaxSpeed, Projectile.Speed);
    Inv.ConsumeGrenades();
    WeaponOwner.SetWeakZedGrabCooldownOnPawn(WeaponOwner.GrenadeTossWeakZedGrabCooldown);
    `log("KF2VR grenade path=physical-authority hand=" $ Hand $ " owner=" $ WeaponOwner
        $ " projectile=" $ Projectile $ " position=" $ Position $ " velocity=" $ Velocity
        $ " count=" $ Inv.GrenadeCount $ " netmode=" $ Spawner.WorldInfo.NetMode);
    return true;
}
