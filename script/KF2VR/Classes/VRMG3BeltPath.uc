// MG3's authored loose-belt motion, rebased from the moving box to its seat.
// Presentation only: the reload owner retains all stock ammunition authority.
class VRMG3BeltPath extends Object;

struct BeltPose
{
    var vector P[12];
    var quat Q[12];
    var vector Contact;
};
var array<BeltPose> Path;
var array<float> PathS;
var vector GripLocal;
var quat GripQ;
var float GripTime, Length;

function bool Sample(VRInteractiveReload Owner, VRActionPath Ref)
{
    local int I, J;
    local vector P, HandP;
    local quat Q, HandQ;
    local BeltPose Point;
    if (Owner.Gun.Class != class'KFWeap_LMG_MG3' || Ref == None || Ref.Ref == None) return false;
    Path.Length = 0; PathS.Length = 0; Length = 0;
    for (I = 1; I <= 12; ++I)
        if (Ref.Ref.MatchRefBone(name("RW_Bullets" $ I)) < 0) return false;
    Ref.RefSeq.SetAnim('Reload_Empty');
    // Measured cooked MG3 clip: 7.633333 raw seconds. Do not mistake the PSA's
    // frame count or the perk/elite rate for raw animation time.
    if (Ref.RefSeq.AnimSeq == None || Abs(Ref.RefSeq.AnimSeq.SequenceLength - 7.633333) > 0.02) return false;
    Ref.RefRoot = 'RW_Magazine';
    GripTime = 5.2;
    Ref.PoseRef(GripTime);
    Ref.RefRelative('RW_Bullets1', P, Q);
    Ref.RefRelative('LeftHand_1stP', HandP, HandQ);
    if (VSize(HandP - P) > 24 || Owner.RigSample.RackFingerContact(Ref.Ref, 'RW_Bullets1', 'LeftHand_1stP') > 6)
    { Ref.RefRoot = Owner.RootBone; return false; }
    GripLocal = QuatRotateVector(QuatInvert(Q), HandP - P);
    GripQ = QuatProduct(QuatInvert(Q), HandQ);
    for (I = 0; I <= 16; ++I)
    {
        Ref.PoseRef(5.0 + 0.6 * float(I) / 16.0);
        for (J = 0; J < 12; ++J)
        {
            Ref.RefRelative(name("RW_Bullets" $ (J + 1)), P, Q);
            Point.P[J] = Owner.SeatLocal + QuatRotateVector(Owner.SeatLocalQ, P);
            Point.Q[J] = QuatProduct(Owner.SeatLocalQ, Q);
        }
        Point.Contact = Point.P[0] + QuatRotateVector(Point.Q[0], GripLocal);
        if (I > 0) Length += VSize(Point.Contact - Path[I-1].Contact);
        Path.AddItem(Point);
        PathS.AddItem(Length);
    }
    // The final sampled belt must actually be at its feed-tray seat. This
    // rejects box handling segments even when the fingers touch the belt.
    Ref.RefSeq.SetAnim('Idle');
    if (Ref.RefSeq.AnimSeq == None) { Ref.RefRoot = Owner.RootBone; return false; }
    Ref.PoseRef(0);
    for (J = 0; J < 12; ++J)
    {
        Ref.RefRelative(name("RW_Bullets" $ (J + 1)), P, Q);
        P = Owner.SeatLocal + QuatRotateVector(Owner.SeatLocalQ, P);
        if (VSize(P - Path[16].P[J]) > 1) { Ref.RefRoot = Owner.RootBone; return false; }
    }
    Ref.RefRoot = Owner.RootBone;
    if (!(Length >= 4 && Length <= 40 && VSize(Path[16].Contact - Path[0].Contact) >= 4)) return false;
    for (I = 0; I < PathS.Length; ++I) PathS[I] /= Length;
    return true;
}

function PoseAt(float Amount, int Bone, out vector P, out quat Q)
{
    local int I;
    local float F;
    Amount = FClamp(Amount, 0, 1);
    I = 0;
    while (I < 15 && PathS[I+1] < Amount) ++I;
    F = PathS[I+1] - PathS[I] > 0.000001 ? (Amount - PathS[I]) / (PathS[I+1] - PathS[I]) : 1.0;
    P = Path[I].P[Bone] * (1-F) + Path[I+1].P[Bone] * F;
    Q = QuatSlerp(Path[I].Q[Bone], Path[I+1].Q[Bone], F, true);
}

function vector ContactAt(float Amount)
{
    local vector P;
    local quat Q;
    PoseAt(Amount, 0, P, Q);
    return P + QuatRotateVector(Q, GripLocal);
}

function float Project(vector P)
{
    local int I;
    local float F, D, BestD, Best, Denom;
    local vector A, V;
    BestD = 1000000;
    for (I = 0; I < 16; ++I)
    {
        A = Path[I].Contact; V = Path[I+1].Contact - A;
        Denom = V dot V;
        if (Denom < 0.000001) continue;
        F = FClamp(((P - A) dot V) / Denom, 0, 1);
        D = VSize(P - A - V * F);
        if (D < BestD) { BestD = D; Best = PathS[I] + F * (PathS[I+1] - PathS[I]); }
    }
    return Best;
}
