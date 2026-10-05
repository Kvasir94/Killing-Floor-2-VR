// Shared solo/server dosh toss from a physical flick. Stock ServerThrowMoney
// tosses along the camera; this runs the same KFInventory_Money.DropFrom
// transaction (amount, debit, pickup and dialog unchanged) from the hand at
// its measured velocity, then watches the wad for a small Zed to stagger.
class VRDoshThrow extends Object abstract;

static function bool Toss(Actor Spawner, KFPawn_Human Human, vector Position, vector Velocity, vector Head)
{
    local Inventory Inv, Money;
    local KFDroppedPickup_Cash Cash, Thrown;
    local KFInventoryManager KFInv;
    local VRDoshFlight Flight;
    local vector HitLocation, HitNormal;
    local float Speed;
    if (Spawner == None || Spawner.Role != ROLE_Authority || Human == None || Human.Role != ROLE_Authority
        || Human.bDeleteMe || Human.Health <= 0 || Human.InvManager == None
        || Human.PlayerReplicationInfo == None || Human.PlayerReplicationInfo.Score < 1
        || !class'VRGrenadeThrow'.static.Bounded(Position - Human.Location, 240)
        || !class'VRGrenadeThrow'.static.Bounded(Head - Human.Location, 160)
        || !class'VRGrenadeThrow'.static.Bounded(Velocity, 1800)) return false;
    KFInv = KFInventoryManager(Human.InvManager);
    if (KFInv != None && KFInv.bServerTraderMenuOpen) return false;
    if (Spawner.Trace(HitLocation, HitNormal, Position, Head, false, vect(4,4,4)) != None) return false;
    foreach Human.InvManager.InventoryActors(class'Inventory', Inv)
        if (Inv.DroppedPickupClass == class'KFDroppedPickup_Cash') { Money = Inv; break; }
    if (Money == None) return false;
    // A gentle version of the grenade assistance, capped well below a grenade.
    Speed = VSize(Velocity);
    Velocity = Normal(Velocity) * FMin(Speed * (1.0 + FClamp(Speed / 400.0, 0.0, 1.0)), 1100.0);
    // DropFrom raises the spawn by half the eye height and scales speed by 1.6.
    Position.Z -= Human.BaseEyeHeight / 2;
    Money.DropFrom(Position, Velocity / 1.6);
    foreach Spawner.DynamicActors(class'KFDroppedPickup_Cash', Cash)
        if (Cash.Instigator == Human && Cash.CreationTime == Spawner.WorldInfo.TimeSeconds) Thrown = Cash;
    if (Thrown == None) return false;
    Flight = Spawner.Spawn(class'VRDoshFlight', Human,, Thrown.Location);
    if (Flight != None) Flight.Begin(Thrown, Human);
    `log("KF2VR_DOSH toss amount=" $ Thrown.CashAmount $ " velocity=" $ Thrown.Velocity
        $ " netmode=" $ Spawner.WorldInfo.NetMode);
    return true;
}
