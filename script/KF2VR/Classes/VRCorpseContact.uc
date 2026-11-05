// Torn-off corpses are local ragdolls. Feed real swept contacts into the same
// stock damage path as flat-screen melee; never claim a new server victim.
class VRCorpseContact extends Object abstract;

static function bool Eligible(KFPawn P)
{
    return KFPawn_Monster(P) != None && !P.bDeleteMe && P.bPlayedDeath
        && P.Health <= 0 && P.Physics == PHYS_RigidBody && P.Mesh != None;
}

// A sweep starting inside a hit-zone shape has no entry ray hit. Match the
// live fist/bash fallback using the actual swept segment and nearby bones.
static function bool Overlap(KFPawn P, vector Start, vector End, float Radius, out ImpactInfo Hit)
{
    local int I;
    local vector Point, Segment, Closest;
    local float Along, Distance, Best;
    local bool Found;
    Segment = End - Start; Best = Radius + 8;
    for (I = 0; I < P.HitZones.Length; ++I)
    {
        if (P.HitZones[I].BoneName == '' || (I == HZI_HEAD && P.IsHeadless())) continue;
        Point = P.Mesh.GetBoneLocation(P.HitZones[I].BoneName, 0);
        Along = VSizeSq(Segment) > 0.001 ? FClamp(((Point - Start) dot Segment) / VSizeSq(Segment), 0, 1) : 1.0;
        Closest = Start + Segment * Along;
        Distance = VSize(Point - Closest);
        if (Distance >= Best) continue;
        Best = Distance; Hit.HitLocation = Point; Hit.HitNormal = Normal(Closest - Point);
        Hit.HitInfo.BoneName = P.HitZones[I].ZoneName; Found = true;
    }
    return Found;
}

static function Gather(VRHandsBridge Bridge, vector Start, vector End, float Radius,
    array<Actor> AlreadyHit, out array<ImpactInfo> Contacts)
{
    local KFPawn_Monster P;
    local array<ImpactInfo> Hits;
    local ImpactInfo Closest;
    local vector Direction, Side, Up, Offset, RayStart;
    local float Distance, Best;
    local int Sample, I, Zone;
    local bool Found;
    Contacts.Length = 0;
    if (Bridge == None || Bridge.Human == None || Bridge.WorldInfo.NetMode == NM_DedicatedServer) return;
    Direction = Normal(End - Start);
    Side = Direction cross vect(0,0,1);
    if (VSizeSq(Side) < 0.001) Side = Direction cross vect(0,1,0);
    Side = Normal(Side); Up = Normal(Direction cross Side);
    // Dead pawns need not remain in the live pawn iterator. Broad-phase from
    // the ragdoll root, since its actor cylinder stops following it at death.
    foreach Bridge.DynamicActors(class'KFPawn_Monster', P)
    {
        if (!Eligible(P) || AlreadyHit.Find(P) != INDEX_NONE
            || VSize(P.Mesh.GetBoneLocation(P.Mesh.GetBoneName(0), 0)
            - (Start + End) * 0.5) > VSize(End - Start) * 0.5 + Radius + 180) continue;
        Found = false; Best = 100000000;
        for (Sample = 0; Sample < 9; ++Sample)
        {
            Offset = vect(0,0,0);
            if (Sample > 0)
                Offset = (Side * Cos(float(Sample - 1) * Pi * 0.25)
                    + Up * Sin(float(Sample - 1) * Pi * 0.25)) * Radius;
            RayStart = Start + Offset;
            Hits.Length = 0;
            if (!Bridge.TraceAllPhysicsAssetInteractions(P.Mesh, End + Offset, RayStart, Hits, vect(0,0,0), true)) continue;
            for (I = 0; I < Hits.Length; ++I)
            {
                Distance = VSizeSq(Hits[I].HitLocation - RayStart);
                if (Distance >= Best || !Bridge.FastTrace(Hits[I].HitLocation, RayStart)) continue;
                Closest = Hits[I]; Best = Distance; Found = true;
            }
        }
        if (!Found && (!Overlap(P, Start, End, Radius, Closest)
            || !Bridge.FastTrace(Closest.HitLocation, Start))) continue;
        Closest.HitActor = P;
        Zone = P.HitZones.Find('ZoneName', Closest.HitInfo.BoneName);
        if (Zone == INDEX_NONE)
        {
            Zone = P.HitZones.Find('BoneName', Closest.HitInfo.BoneName);
            if (Zone != INDEX_NONE) Closest.HitInfo.BoneName = P.HitZones[Zone].ZoneName;
        }
        Contacts.AddItem(Closest);
        if (Contacts.Length >= 16) return;
    }
}
