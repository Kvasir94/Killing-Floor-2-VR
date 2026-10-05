// Stock TF2 launcher: eight rounds, eight deployed bombs, 4 s charge,
// release-to-fire, 0.8 s arming delay and explicit remote detonation.
class VRWeap_StickybombLauncher extends VRSourceWeapon;

var array<VRStickyBomb> Bombs;
var float ChargeStartedAt, ReloadAt;
var bool bCharging, bSourceReloading;
var float LastShotAt, ReloadStartedAt, ReloadEndedAt, DrawStartedAt;
var VRStickyMechanism Mechanism;

simulated function Activate()
{
    Super.Activate();
    DrawStartedAt = WorldInfo.TimeSeconds;
}

simulated function PruneBombs()
{
    local int I;
    for (I = Bombs.Length - 1; I >= 0; --I)
        if (Bombs[I] == None || Bombs[I].bDeleteMe || Bombs[I].bDetonated) Bombs.Remove(I, 1);
}

simulated function StartFire(byte FireModeNum)
{
    if (!CanUseSourceWeapon()) return;
    if (FireModeNum == 0)
    {
        if (bPrimaryHeld) return;
        bPrimaryHeld = true;
        BeginCharge();
    }
    else if (FireModeNum == 1)
    {
        if (bSecondaryHeld) return;
        bSecondaryHeld = true;
        DetonateBombs();
    }
    else if (FireModeNum == 2) SourceReload();
}

simulated function BeginCharge()
{
    if (bCharging || WorldInfo.TimeSeconds < NextPrimaryTime) return;
    if (AmmoCount[0] <= 0) { SourceReload(); return; }
    bSourceReloading = false;
    bCharging = true;
    ChargeStartedAt = WorldInfo.TimeSeconds;
    StartSourceLoop('StickyCharge');
}

simulated function StopFire(byte FireModeNum)
{
    if (FireModeNum == 0)
    {
        bPrimaryHeld = false;
        if (bCharging && CanUseSourceWeapon()) LaunchSticky();
    }
    if (FireModeNum == 1) bSecondaryHeld = false;
}

simulated function LaunchSticky()
{
    local VRStickyBomb Bomb;
    local vector Direction, Start, Right, Up, InitialVelocity;
    local float Charge;
    if (!bCharging || AmmoCount[0] <= 0 || !CanUseSourceWeapon()) return;
    Charge = FClamp((WorldInfo.TimeSeconds - ChargeStartedAt) / 4.0, 0, 1);
    bCharging = false;
    StopSourceLoop();
    Start = SourceOrigin(); Direction = SourceDirection();
    Bomb = Spawn(class'VRStickyBomb', self,, Start, rotator(Direction),, true);
    if (Bomb == None) return;
    // Source inches -> this adapter's centimetres, including the launcher's
    // upward toss. Gravity is independent of the current KF2 map's gravity.
    GetAxes(bTrackedPose ? TrackedAim : rotator(Direction), Direction, Right, Up);
    InitialVelocity = Direction * Lerp(2286, 6096, Charge) + Up * (508 + (FRand() * 2 - 1) * 25.4)
        + Right * (FRand() * 2 - 1) * 25.4;
    Bomb.InitializeFlight(self, InitialVelocity, Charge);
    --AmmoCount[0];
    NextPrimaryTime = WorldInfo.TimeSeconds + 0.6;
    PruneBombs();
    if (Bombs.Length >= 8)
    {
        // TF2 detonates the oldest when the ninth is created. This forced
        // eviction does not turn the new bomb into an impact grenade.
        Bombs[0].Detonate(true);
        Bombs.Remove(0, 1);
    }
    Bombs.AddItem(Bomb);
    LastShotAt = WorldInfo.TimeSeconds;
    PlaySourceSound('StickyFire');
    class'VRSourceEffects'.static.Emit(self, 'StickyMuzzle', Start, rotator(Direction));
    `log("KF2VR_STICKY action=launch charge=" $ Charge @ "speed=" $ Bomb.Speed @ "ammo=" $ AmmoCount[0] @ "deployed=" $ Bombs.Length);
}

simulated function DetonateBombs()
{
    local int I;
    if (!CanUseSourceWeapon()) return;
    PruneBombs();
    PlaySourceSound('StickyDetonate');
    for (I = 0; I < Bombs.Length; ++I)
        if (Bombs[I] != None) Bombs[I].Detonate();
    PruneBombs();
}

simulated function SourceReload()
{
    if (!CanUseSourceWeapon() || bCharging || bSourceReloading || AmmoCount[0] >= 8 || SpareAmmoCount[0] <= 0) return;
    bSourceReloading = true;
    ReloadStartedAt = WorldInfo.TimeSeconds;
    ReloadAt = WorldInfo.TimeSeconds + 1.09;
    PlaySourceSound('StickyBoltBack');
}

simulated function CancelSourceInput()
{
    // Tracking loss/menu/swap cancels a charge without firing on release.
    bCharging = false;
    bSourceReloading = false;
    Super.CancelSourceInput();
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (Instigator == None || Instigator.Health <= 0)
    {
        RemoveBombs();
        return;
    }
    if (!CanUseSourceWeapon()) return;
    if (Mechanism == None) Mechanism = new(self) class'VRStickyMechanism';
    Mechanism.Initialize(self);
    if (bCharging && WorldInfo.TimeSeconds - ChargeStartedAt >= 4) LaunchSticky();
    if (bPrimaryHeld && !bCharging) BeginCharge();
    if (bSourceReloading && WorldInfo.TimeSeconds >= ReloadAt)
    {
        if (AmmoCount[0] < 8 && SpareAmmoCount[0] > 0)
        {
            ++AmmoCount[0]; --SpareAmmoCount[0];
            PlaySourceSound('StickyReload');
            ReloadAt = WorldInfo.TimeSeconds + 0.67;
        }
        if (AmmoCount[0] >= 8 || SpareAmmoCount[0] <= 0)
        { bSourceReloading = false; ReloadEndedAt = WorldInfo.TimeSeconds; PlaySourceSound('StickyBoltForward'); }
    }
    if (!bCharging && !bPrimaryHeld && AmmoCount[0] == 0 && !bSourceReloading) SourceReload();
    // Holding secondary repeats arming checks, matching TF2: a bomb pressed
    // too early can detonate as soon as it arms while the button stays held.
    if (bSecondaryHeld)
    {
        PruneBombs();
        DetonateArmedBombs();
    }
    Mechanism.Update();
}

simulated function DetonateArmedBombs()
{
    local int I;
    for (I = 0; I < Bombs.Length; ++I) if (Bombs[I] != None) Bombs[I].Detonate();
}

simulated function RemoveBombs()
{
    local int I;
    for (I = 0; I < Bombs.Length; ++I) if (Bombs[I] != None) Bombs[I].Destroy();
    Bombs.Length = 0;
}

simulated event Destroyed()
{
    if (Mechanism != None) Mechanism.DestroyPresentation();
    RemoveBombs();
    Super.Destroyed();
}

defaultproperties
{
    FirstPersonMeshName="KF2VRSource.StickybombLauncher"
    PickupMeshName=""
    MagazineCapacity(0)=8
    SpareAmmoCapacity(0)=24
    InitialSpareMags(0)=3
    GroupPriority=201
    LastShotAt=-100
    ReloadEndedAt=-100
    DrawStartedAt=-100
}
