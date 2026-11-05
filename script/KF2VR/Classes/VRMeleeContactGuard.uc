// Authority admission for a reported physical contact. This bounds a claim;
// the network strike ledger separately validates identity, cadence and victims.
class VRMeleeContactGuard extends Object abstract;

// Allow a moving limb and a delayed contact to differ from the current server
// bounds. The bound is measured from the actual collision geometry, so a large
// Zed does not need a larger arbitrary center-to-contact allowance.
const ContactSlack = 64.0;
const MaximumReach = 450.0;

static function bool FinitePosition(vector P)
{
    return P.X > -100000000 && P.X < 100000000
        && P.Y > -100000000 && P.Y < 100000000
        && P.Z > -100000000 && P.Z < 100000000;
}

static function bool NearBounds(vector Point, box Bounds, float Slack)
{
    local vector Gap;
    if (!FinitePosition(Point) || Bounds.IsValid == 0
        || !FinitePosition(Bounds.Min) || !FinitePosition(Bounds.Max)
        || Bounds.Min.X > Bounds.Max.X || Bounds.Min.Y > Bounds.Max.Y || Bounds.Min.Z > Bounds.Max.Z
        || !(Slack >= 0 && Slack <= ContactSlack)) return false;
    Gap.X = FMax(FMax(Bounds.Min.X - Point.X, Point.X - Bounds.Max.X), 0);
    Gap.Y = FMax(FMax(Bounds.Min.Y - Point.Y, Point.Y - Bounds.Max.Y), 0);
    Gap.Z = FMax(FMax(Bounds.Min.Z - Point.Z, Point.Z - Bounds.Max.Z), 0);
    return VSizeSq(Gap) <= Slack * Slack;
}

static function bool PlausibleReach(vector Body, vector Contact, vector HandOrigin)
{
    return FinitePosition(Body) && FinitePosition(Contact) && FinitePosition(HandOrigin)
        && class'VRGrenadeThrow'.static.Bounded(Contact - Body, MaximumReach)
        && class'VRGrenadeThrow'.static.Bounded(HandOrigin - Body, MaximumReach)
        && class'VRGrenadeThrow'.static.Bounded(Contact - HandOrigin, MaximumReach);
}

// Trace with the same world-only semantics as stock melee FastTrace. Pawns
// along the path must not eat another contact in a cleave. A wall/destructible
// may itself be the target, but only at the reported end of the trace.
static function bool VisibleContact(Actor Source, Actor Victim, vector Origin, vector Contact,
    optional bool bRequireTarget)
{
    local Actor Blocker;
    local vector At, HitNormal, End;
    End = Contact;
    // Only a solid target needs a ray past its reported surface. Extending
    // through a pawn contact can hit the floor just behind a grounded corpse.
    if (Pawn(Victim) == None) End += Normal(Contact - Origin) * 4;
    Blocker = Source.Trace(At, HitNormal, End, Origin, false);
    return (!bRequireTarget && Blocker == None) || (Blocker == Victim
        && class'VRGrenadeThrow'.static.Bounded(At - Contact, ContactSlack));
}

// A ragdoll can straddle a corner: its aggregate bounds center need not be
// visible from an exposed head or limb. Associate the claim with its actual
// mesh collision or a nearby authored hit-zone bone, never that midpoint.
static function bool CorpseContact(Actor Source, Pawn Victim, vector Contact)
{
    local KFPawn Body;
    local vector Point;
    local int I;
    if (Victim.Mesh == None) return false;
    if (Source.PointCheckComponent(Victim.Mesh, Contact, vect(4,4,4))) return true;
    Body = KFPawn(Victim);
    if (Body == None) return false;
    for (I = 0; I < Body.HitZones.Length; ++I)
    {
        if (Body.HitZones[I].BoneName == '' || Victim.Mesh.MatchRefBone(Body.HitZones[I].BoneName) < 0) continue;
        Point = Victim.Mesh.GetBoneLocation(Body.HitZones[I].BoneName, 0);
        if (FinitePosition(Point) && class'VRGrenadeThrow'.static.Bounded(Point - Contact, ContactSlack)
            && Source.FastTrace(Point, Contact)) return true;
    }
    return false;
}

static function bool Valid(KFPawn_Human Source, Actor Victim, vector Contact, vector HandOrigin)
{
    local box Bounds;
    local Pawn TargetPawn;
    local vector Eye;
    if (Source == None || Source.bDeleteMe || Source.Role != ROLE_Authority || Source.Health <= 0
        || Source.Controller == None || Source.Controller.Pawn != Source
        || Victim == None || Victim == Source || Victim.bDeleteMe || Victim.Role != ROLE_Authority
        || Victim.WorldInfo != Source.WorldInfo || Victim.IsA('Weapon')
        || (Victim != Source.WorldInfo && !Victim.bCanBeDamaged && !Victim.bWorldGeometry && !Victim.bBlockActors)
        || !FinitePosition(Victim.Location)
        || !PlausibleReach(Source.Location, Contact, HandOrigin)) return false;
    TargetPawn = Pawn(Victim);
    // BSP reports WorldInfo rather than a component actor; its exact endpoint
    // is checked below instead of treating its level-sized bounds as a victim.
    if (Victim != Source.WorldInfo)
    {
        Victim.GetComponentsBoundingBox(Bounds);
        if (!NearBounds(Contact, Bounds, ContactSlack)) return false;
    }
    Eye = Source.GetPawnViewLocation();
    if (!FinitePosition(Eye) || !VisibleContact(Source, Victim, HandOrigin, Contact, Victim == Source.WorldInfo)
        || !VisibleContact(Source, Victim, Eye, Contact, Victim == Source.WorldInfo)) return false;
    // A claimed point just outside the bounds must not authorize a pawn on
    // the far side of a wall. Dead pawns still take stock corpse damage/gore;
    // validate their exposed contact independently of the ragdoll's center.
    if (TargetPawn != None)
    {
        if (TargetPawn.Health <= 0) return CorpseContact(Source, TargetPawn, Contact);
        if (!Source.FastTrace(TargetPawn.Location, Contact)) return false;
    }
    return true;
}
