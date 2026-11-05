// Authority-only contact for an owned weapon's local toss. The weapon stays
// in inventory. One modest stock damage hit per toss; never firing or ammo use.
class VRThrownWeaponFlight extends Actor;

var KFWeapon Item;
var KFPawn_Human Thrower;
var int Token;
var vector FlightPosition, FlightVelocity;
var bool bHitDelivered;
// A local-only thrown item (a reload magazine, a loose round): flinch, no damage.
var bool bFlinchOnly;
var float LastRealTime, ExpiresRealTime;

static function Stop(Actor Spawner, KFWeapon W, int ReleaseToken)
{
    local VRThrownWeaponFlight Flight;
    if (Spawner == None || Spawner.Role != ROLE_Authority) return;
    foreach Spawner.DynamicActors(class'VRThrownWeaponFlight', Flight)
        if (Flight.Owner == Spawner && Flight.Item == W && Flight.Token == ReleaseToken)
            Flight.Destroy();
}

static function Begin(Actor Spawner, KFPawn_Human Human, KFWeapon W,
    int ReleaseToken, vector Position, vector ReleaseVelocity)
{
    local VRThrownWeaponFlight Flight;
    local vector At, Normal;
    if (Spawner == None || Spawner.Role != ROLE_Authority || ReleaseToken <= 0
        || !class'VRWorldDropTransfer'.static.Owns(Human, W)
        || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || !class'VRGrenadeThrow'.static.Bounded(Position - Human.Location, 220)
        || !class'VRGrenadeThrow'.static.Bounded(ReleaseVelocity, 1400)
        || VSizeSq(ReleaseVelocity) < Square(220.0)) return;
    // Do not originate a reaction on the far side of a wall.
    if (Spawner.Trace(At, Normal, Position, Human.GetPawnViewLocation(), false, vect(3,3,3)) != None) return;
    foreach Spawner.DynamicActors(class'VRThrownWeaponFlight', Flight)
        if (Flight.Owner == Spawner && Flight.Item == W) Flight.Destroy();
    Flight = Spawner.Spawn(class'VRThrownWeaponFlight', Spawner,, Position);
    if (Flight == None) return;
    Flight.Item = W; Flight.Thrower = Human; Flight.Token = ReleaseToken;
    Flight.FlightPosition = Position; Flight.FlightVelocity = ReleaseVelocity;
    Flight.LastRealTime = Spawner.WorldInfo.RealTimeSeconds;
    Flight.ExpiresRealTime = Flight.LastRealTime + 5.0;
}

// The server half of a local-only thrown item: the same 120 Hz flight as a
// weapon toss, but its contact only flinches the Zed (VRWorldDropReactions).
static function BeginFlinch(Actor Spawner, KFPawn_Human Human, vector Position, vector ReleaseVelocity)
{
    local VRThrownWeaponFlight Flight;
    local vector At, Normal;
    if (Spawner == None || Spawner.Role != ROLE_Authority || Human == None || Human.Controller == None
        || !class'VRPhysicalInteraction'.static.Allowed(Human)
        || !class'VRGrenadeThrow'.static.Bounded(Position - Human.Location, 220)
        || !class'VRGrenadeThrow'.static.Bounded(ReleaseVelocity, 1400)
        || VSizeSq(ReleaseVelocity) < Square(220.0)) return;
    if (Spawner.Trace(At, Normal, Position, Human.GetPawnViewLocation(), false, vect(3,3,3)) != None) return;
    Flight = Spawner.Spawn(class'VRThrownWeaponFlight', Spawner,, Position);
    if (Flight == None) return;
    Flight.Thrower = Human; Flight.bFlinchOnly = true;
    Flight.FlightPosition = Position; Flight.FlightVelocity = ReleaseVelocity;
    Flight.LastRealTime = Spawner.WorldInfo.RealTimeSeconds;
    Flight.ExpiresRealTime = Flight.LastRealTime + 3.0;
}

// Select the closest living enemy before the clipped wall endpoint. This
// replaces the loose-magazine reaction helper: TakeDamage owns afflictions.
function bool HitZed(vector From, vector To)
{
    local KFPawn_Monster Zed, Victim;
    local vector At, N, HitAt, RelativeVelocity;
    local float Distance, BestDistance, Speed;
    local int Damage;
    local TraceHitInfo HitInfo;
    if (bHitDelivered || Thrower == None || Thrower.Controller == None
        || VSizeSq(To - From) < 0.0001) return false;
    BestDistance = 1000000;
    foreach TraceActors(class'KFPawn_Monster', Zed, At, N, To, From, vect(6,6,6))
    {
        if (Zed == None || Zed.bDeleteMe || Zed.Health <= 0 || !Zed.bCanBeDamaged
            || Zed.GetTeamNum() == Thrower.GetTeamNum() || !FastTrace(At, From)) continue;
        Distance = VSizeSq(At - From);
        if (Distance >= BestDistance) continue;
        BestDistance = Distance; Victim = Zed; HitAt = At;
    }
    if (Victim == None) return false;
    // A body contact terminates this flight even if too slow to hurt. Bounces
    // are visual and cannot generate additional authority damage afterward.
    bHitDelivered = true;
    if (bFlinchOnly)
    {
        class'VRWorldDropReactions'.static.Flinch(Victim, Normal(FlightVelocity), Thrower);
        return true;
    }
    // Flight speed is real-time; stock pawn velocity is per game second.
    RelativeVelocity = FlightVelocity - Victim.Velocity
        * FClamp(WorldInfo.TimeDilation * Victim.CustomTimeDilation, 0, 20);
    Speed = VSize(RelativeVelocity);
    if (Speed >= 220)
    {
        Damage = Clamp(1 + int(4.0 * FClamp((Speed - 220) / 1180, 0, 1) + 0.5), 1, 5);
        Victim.TakeDamage(Damage, Thrower.Controller, HitAt,
            Normal(RelativeVelocity) * FMin(Speed * 0.2, 200),
            class'VRDT_ThrownWeaponImpact', HitInfo, Item);
    }
    return true;
}

event Tick(float DeltaTime)
{
    local vector Next, At, Normal;
    local float Remaining, Step;
    local Actor Wall;
    if (Role != ROLE_Authority || bHitDelivered || WorldInfo.RealTimeSeconds >= ExpiresRealTime
        || Thrower == None || (!bFlinchOnly && !class'VRWorldDropTransfer'.static.Owns(Thrower, Item))
        || !class'VRPhysicalInteraction'.static.Allowed(Thrower))
    { Destroy(); return; }
    // Match the local toss's gravity, velocity cap and 120 Hz integration.
    Remaining = FClamp(WorldInfo.RealTimeSeconds - LastRealTime, 0, 0.1);
    LastRealTime = WorldInfo.RealTimeSeconds;
    while (Remaining > 0.00001)
    {
        Step = FMin(Remaining, 1.0 / 120.0); Remaining -= Step;
        FlightVelocity.Z = FMax(FlightVelocity.Z - 950 * Step, -1400);
        Next = FlightPosition + FlightVelocity * Step;
        Wall = Trace(At, Normal, Next, FlightPosition, false, vect(3,3,3));
        if (Wall != None) Next = At;
        if (HitZed(FlightPosition, Next) || Wall != None)
        { Destroy(); return; }
        FlightPosition = Next;
    }
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    LifeSpan=5.0
    TickGroup=TG_PostAsyncWork
}
