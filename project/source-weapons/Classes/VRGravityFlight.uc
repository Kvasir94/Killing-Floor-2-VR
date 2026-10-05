// Supplies collision damage for thrown bodies, which KF2 does not normally
// treat as player weapons. Swept segments cover fast throws between frames.
class VRGravityFlight extends Actor;
var Actor Body;
var PrimitiveComponent BodyComponent;
var vector PreviousPosition;
var array<KFPawn_Monster> HitZeds;

function Initialize(Actor A, PrimitiveComponent C, Pawn Thrower)
{
    Body = A; BodyComponent = C; Instigator = Thrower;
    PreviousPosition = C.GetPosition();
}

event Tick(float DeltaTime)
{
    local KFPawn_Monster Zed;
    local vector Current, Segment, Closest, Hit, HitNormal;
    local float T, Speed;
    if (Body == None || Body.bDeleteMe || BodyComponent == None || Instigator == None || WorldInfo.NetMode != NM_Standalone)
    { Destroy(); return; }
    Current = BodyComponent.GetPosition();
    Segment = Current - PreviousPosition;
    Speed = VSize(Segment) / FMax(DeltaTime, 0.001);
    if (Speed > 300)
    {
        foreach WorldInfo.AllPawns(class'KFPawn_Monster', Zed)
        {
            if (Zed == Body || Zed.Health <= 0 || HitZeds.Find(Zed) >= 0) continue;
            T = FClamp(((Zed.Location - PreviousPosition) dot Segment) / FMax(VSizeSq(Segment), 1), 0, 1);
            Closest = PreviousPosition + Segment * T;
            if (VSize(Zed.Location - Closest) > Zed.CylinderComponent.CollisionRadius + 38) continue;
            if (Trace(Hit, HitNormal, Zed.Location, PreviousPosition, false) != None) continue;
            HitZeds.AddItem(Zed);
            Zed.TakeDamage(int(FClamp(Speed * 0.5, 150, 2000)), Instigator.Controller, Closest,
                Normal(Segment) * Speed * 40, class'VRDT_SuperGravityGun',, self);
        }
    }
    PreviousPosition = Current;
}

defaultproperties
{
    RemoteRole=ROLE_None
    LifeSpan=4
    bHidden=true
    bCollideActors=false
}
