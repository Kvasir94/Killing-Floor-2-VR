// Entry rays can miss a strike that a moving Zed has already enclosed.
// Require overlap with its actual mesh collision before assigning a hit zone.
class VRPhysicalContactOverlap extends Object abstract;

static function bool Find(Actor Source, KFPawn Victim, vector Start, vector End, out ImpactInfo Impact)
{
    local vector Point, Bone;
    local ImpactInfo Empty;
    local float Distance, Best;
    local int Sample, I, Zone;
    if (Source == None || Victim == None || Victim.Mesh == None) return false;
    for (Sample = 0; Sample < 2; ++Sample)
    {
        Point = Sample == 0 ? Start : End;
        // A zero extent proves the strike itself is inside the mesh; it does
        // not enlarge the Zed's collision or borrow its locomotion cylinder.
        if (!Source.PointCheckComponent(Victim.Mesh, Point, vect(0,0,0))
            || !Source.FastTrace(Point, Start)) continue;
        Best = 100000000;
        Zone = INDEX_NONE;
        for (I = 0; I < Victim.HitZones.Length; ++I)
        {
            if (Victim.HitZones[I].BoneName == '' || (I == HZI_HEAD && Victim.IsHeadless())
                || Victim.Mesh.MatchRefBone(Victim.HitZones[I].BoneName) < 0) continue;
            Bone = Victim.Mesh.GetBoneLocation(Victim.HitZones[I].BoneName, 0);
            Distance = VSizeSq(Bone - Point);
            if (Distance >= Best) continue;
            Best = Distance;
            Zone = I;
        }
        if (Zone == INDEX_NONE) continue;
        Impact = Empty;
        Impact.HitActor = Victim;
        Impact.HitLocation = Point;
        Impact.HitNormal = -Normal(End - Start);
        Impact.HitInfo.HitComponent = Victim.Mesh;
        Impact.HitInfo.BoneName = Victim.HitZones[Zone].ZoneName;
        return true;
    }
    return false;
}
