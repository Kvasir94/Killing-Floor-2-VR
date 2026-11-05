// Stock belt-fed guns' authored belt-laying motion, rebased from the moving box to its seat.
// Presentation only: the reload owner retains all stock ammunition authority.
class VRMG3BeltPath extends Object;

struct BeltPose
{
    var vector P[14];
    var quat Q[14];
    var vector Contact;
};
var array<BeltPose> Path;
var array<float> PathS;
var vector GripLocal;
var quat GripQ;
var float GripTime, Length;
var int BoneCount, SourceHand;
// The player's belt hand is not the stock one: its grip is the mirror image.
var bool bMirrorGrip;
var name BoxBone;

static function bool Covers(KFWeapon W)
{
    return W != None && CoversClass(W.Class);
}

static function bool CoversClass(class<KFWeapon> W)
{
    return W == class'KFWeap_LMG_MG3'
        || W == class'KFWeap_LMG_Stoner63A' || W == class'KFWeap_HRG_BarrierRifle';
}

// The stock belt: RW_Bullets1..BeltRounds, children of the box bone.
static function int BeltRounds(class<KFWeapon> W) { return W == class'KFWeap_LMG_MG3' ? 12 : 14; }
static function name BoxBoneOf(class<KFWeapon> W) { return W == class'KFWeap_LMG_MG3' ? 'RW_Magazine' : 'RW_Magazine1'; }

// The stock Reload_Empty belt from StartTime (the belt out of the box mouth,
// where the hand takes it) to EndTime (laid in the tray), in the seat frame.
// The carried box prop has its belt baked at StartTime's pose
// (tools/generate_reload_props.py RIDING_ROUNDS), so a box seats with its
// belt unmoved and the hand lays it along this path.
function bool Sample(VRInteractiveReload Owner, VRActionPath Ref)
{
    local int I, J;
    local vector P, HandP;
    local quat Q, HandQ;
    local BeltPose Point;
    local float StartTime, EndTime, ClipLength, T, Score, BestScore;
    local name HandBone;
    local vector AmmoP, WristP;
    local quat AmmoQ, WristQ;
    if (!Covers(Owner.Gun) || Ref == None || Ref.Ref == None) return false;
    BoneCount = BeltRounds(Owner.Gun.Class);
    SourceHand = BoneCount == 12 ? 0 : 1;
    bMirrorGrip = Owner.OffHand() != SourceHand;
    BoxBone = BoxBoneOf(Owner.Gun.Class);
    HandBone = SourceHand == 0 ? 'LeftHand_1stP' : 'RightHand_1stP';
    ClipLength = BoneCount == 12 ? 7.633333 : 6.0;
    StartTime = BoneCount == 12 ? 5.0 : 3.3;
    EndTime = BoneCount == 12 ? 5.6 : 3.8;
    Path.Length = 0; PathS.Length = 0; Length = 0;
    for (I = 1; I <= BoneCount; ++I)
        if (Ref.Ref.MatchRefBone(name("RW_Bullets" $ I)) < 0) return false;
    Ref.RefSeq.SetAnim('Reload_Empty');
    // Measured cooked MG3 clip: 7.633333 raw seconds. Do not mistake the PSA's
    // frame count or the perk/elite rate for raw animation time.
    if (Ref.RefSeq.AnimSeq == None || Abs(Ref.RefSeq.AnimSeq.SequenceLength - ClipLength) > 0.02) return false;
    Ref.RefRoot = BoxBone;
    // The steadiest stock hold of the leading round in the first half of the
    // lay, scored as every carry grip is (VRReloadRigSampler.ReadCarryGrip:
    // fingers on it, wrist near it, and the round still in the hand).
    GripTime = StartTime; BestScore = 100000;
    for (I = 0; I <= 16; ++I)
    {
        T = StartTime + (EndTime - StartTime) * 0.5 * float(I) / 16.0;
        if (Owner.RigSample.ReadCarryGrip(Ref.Ref, Ref.RefSeq, BoxBone, 'RW_Bullets1', HandBone, T,
            AmmoP, AmmoQ, WristP, WristQ, Score, vect(0,0,0), vect(0,0,0)) && Score < BestScore)
        { BestScore = Score; GripTime = T; }
    }
    Ref.PoseRef(GripTime);
    Ref.RefRelative('RW_Bullets1', P, Q);
    Ref.RefRelative(HandBone, HandP, HandQ);
    if (VSize(HandP - P) > 24 || Owner.RigSample.RackFingerContact(Ref.Ref, 'RW_Bullets1', HandBone) > 6)
    { Ref.RefRoot = Owner.RootBone; return false; }
    GripLocal = QuatRotateVector(QuatInvert(Q), HandP - P);
    GripQ = QuatProduct(QuatInvert(Q), HandQ);
    for (I = 0; I <= 16; ++I)
    {
        Ref.PoseRef(StartTime + (EndTime - StartTime) * float(I) / 16.0);
        for (J = 0; J < BoneCount; ++J)
        {
            Ref.RefRelative(name("RW_Bullets" $ (J + 1)), P, Q);
            Point.P[J] = Owner.SeatLocal + QuatRotateVector(Owner.SeatLocalQ, P);
            Point.Q[J] = QuatProduct(Owner.SeatLocalQ, Q);
        }
        Point.Contact = Point.P[0] + GripOffset(Point.Q[0]);
        if (I > 0) Length += VSize(Point.Contact - Path[I-1].Contact);
        Path.AddItem(Point);
        PathS.AddItem(Length);
    }
    // The final sampled belt must actually be at its feed-tray seat. This
    // rejects box handling segments even when the fingers touch the belt.
    Ref.RefSeq.SetAnim('Idle');
    if (Ref.RefSeq.AnimSeq == None) { Ref.RefRoot = Owner.RootBone; return false; }
    Ref.PoseRef(0);
    for (J = 0; J < BoneCount; ++J)
    {
        Ref.RefRelative(name("RW_Bullets" $ (J + 1)), P, Q);
        P = Owner.SeatLocal + QuatRotateVector(Owner.SeatLocalQ, P);
        if (VSize(P - Path[16].P[J]) > (BoneCount == 12 ? 1.0 : 2.5)) { Ref.RefRoot = Owner.RootBone; return false; }
    }
    // Stoner/Bastion belt links retain a small authored settling flutter after
    // insertion. End on the actual idle feed pose, without requiring the hand
    // to reproduce that passive motion while the cover is being closed.
    if (BoneCount == 14)
    {
        for (J = 0; J < BoneCount; ++J)
        {
            Ref.RefRelative(name("RW_Bullets" $ (J + 1)), P, Q);
            Path[16].P[J] = Owner.SeatLocal + QuatRotateVector(Owner.SeatLocalQ, P);
            Path[16].Q[J] = QuatProduct(Owner.SeatLocalQ, Q);
        }
        Path[16].Contact = Path[16].P[0] + GripOffset(Path[16].Q[0]);
        Length = 0;
        for (I = 1; I <= 16; ++I)
        {
            Length += VSize(Path[I].Contact - Path[I-1].Contact);
            PathS[I] = Length;
        }
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

// The wrist's offset from a leading round turned by Q, in the seat frame. The
// other hand holds the round mirrored through the root's XZ plane, the same
// reflection VRBreakAction.WristQ gives its rotation.
function vector GripOffset(quat Q)
{
    local vector D;
    D = QuatRotateVector(Q, GripLocal);
    if (bMirrorGrip) D.Y = -D.Y;
    return D;
}

function vector ContactAt(float Amount)
{
    local vector P;
    local quat Q;
    PoseAt(Amount, 0, P, Q);
    return P + GripOffset(Q);
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
