// Authority-only watcher for one physically thrown wad. The first ordinary Zed
// it passes through while still flying fast is staggered once, through the
// stock stumble affliction; large Zeds and bosses are ignored. The wad itself
// is the stock pickup and lands, and can be collected, as usual.
class VRDoshFlight extends Actor;

var KFDroppedPickup_Cash Cash;
var KFPawn_Human Thrower;
var vector LastLocation;
var float Expires, MinHitSpeed;

function Begin(KFDroppedPickup_Cash InCash, KFPawn_Human InThrower)
{
    Cash = InCash; Thrower = InThrower;
    LastLocation = Cash.Location;
    Expires = WorldInfo.TimeSeconds + 2.0;
}

event Tick(float DeltaTime)
{
    local KFPawn_Monster Zed;
    local vector HitLocation, HitNormal;
    if (Cash == None || Cash.bDeleteMe || Thrower == None || Thrower.bDeleteMe
        || WorldInfo.TimeSeconds > Expires || Cash.Physics != PHYS_Falling
        || VSize(Cash.Velocity) < MinHitSpeed)
    {
        Destroy();
        return;
    }
    foreach TraceActors(class'KFPawn_Monster', Zed, HitLocation, HitNormal, Cash.Location, LastLocation, vect(8,8,8))
    {
        if (Zed.Health <= 0 || Zed.IsLargeZed() || Zed.IsABoss()) continue;
        Zed.TakeDamage(1, Thrower.Controller, HitLocation, Normal(Cash.Velocity) * 2000,
            class'VRDT_DoshStagger',, Cash);
        `log("KF2VR_DOSH stagger zed=" $ Zed $ " speed=" $ VSize(Cash.Velocity));
        Destroy();
        return;
    }
    LastLocation = Cash.Location;
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    TickGroup=TG_PostAsyncWork
    MinHitSpeed=300.0
}
