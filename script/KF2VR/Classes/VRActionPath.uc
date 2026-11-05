// An action that moves along the motion one of its own clips shows (a lever's
// throw, a bolt's lift and pull): up to three bones sampled from the closed to
// the open pose, and the point where the stock hand holds the handle. The hand
// is projected onto that point's path; the bones follow, set by instance-only
// controls on the gun's own AnimTree.
class VRActionPath extends Object;

struct PathPose
{
    var vector P[5];
    var quat Q[5];
    var vector C;
};
var array<PathPose> Path;
var array<float> PathS;
var name Bones[5];
var int BoneCount;
var vector GripLocal, GrabOffset;
// The grab rides the handle: the hand's offset from the contact in the first
// bone's own frame, so a swinging lever or turning bolt handle carries it
// round with the part instead of leaving it fixed in the gun's frame.
var vector GrabLocal;
var quat GripQ;
var float GripTime;
var float Amount, Length, OpenTime, StartTime;

var KFSkeletalMeshComponent Ref;
var AnimNodeSequence RefSeq;
var name RefRoot;

// A private, hidden copy of the gun's mesh to pose any of its clips on.
function bool PrepareRef(VRHandsBridge B, KFWeapon W, name Root)
{
    local AnimTree Template;
    if (B == None || W == None || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) return false;
    if (Ref == None)
    {
        Template = new(B) class'AnimTree';
        RefSeq = new(Template) class'AnimNodeSequence';
        RefSeq.NodeName = 'VRActionPathReference';
        RefSeq.bNoNotifies = true;
        Template.Children[0].Anim = RefSeq;
        Template.Children[0].Weight = 1;
        Ref = new(B) class'KFSkeletalMeshComponent';
        Ref.bUpdateSkelWhenNotRendered = true;
        Ref.bTickAnimNodesWhenNotRendered = false;
        Ref.CastShadow = false;
        Ref.bCastDynamicShadow = false;
        Ref.SetHidden(true);
        Ref.SetAnimTreeTemplate(Template);
    }
    if (Ref.SkeletalMesh != W.MySkelMesh.SkeletalMesh) Ref.SetSkeletalMesh(W.MySkelMesh.SkeletalMesh);
    Ref.AnimSets = W.MySkelMesh.AnimSets;
    RefRoot = Root;
    RefSeq = AnimNodeSequence(Ref.FindAnimNode('VRActionPathReference'));
    return RefSeq != None && Ref.MatchRefBone(Root) >= 0;
}

function PoseRef(float Time)
{
    RefSeq.SetPosition(Time, false);
    RefSeq.bPlaying = false;
    Ref.ForceSkelUpdate();
    Ref.ForceUpdate(false);
}

function RefRelative(name Bone, out vector InRoot, out quat InRootQ)
{
    local quat InvRoot;
    InvRoot = QuatInvert(Ref.GetBoneQuaternion(RefRoot));
    InRoot = QuatRotateVector(InvRoot, Ref.GetBoneLocation(Bone) - Ref.GetBoneLocation(RefRoot));
    InRootQ = QuatProduct(InvRoot, Ref.GetBoneQuaternion(Bone));
}

// Samples the action's opening in one of the gun's clips: from the last still
// moment before the handle moves to the first moment it is fully open, with
// the point where the stock hand holds the handle.
function bool SampleClip(VRHandsBridge B, KFWeapon W, name Root, name Clip, name Hand,
    optional bool bWristContact)
{
    local bool bOk;
    Path.Length = 0; PathS.Length = 0;
    if (BoneCount == 0 || !PrepareRef(B, W, Root)) return false;
    B.AttachComponent(Ref);
    RefSeq.SetAnim(Clip);
    bOk = RefSeq.AnimSeq != None && RefSeq.AnimSeq.SequenceLength > 0 && Sample(Hand, bWristContact);
    B.DetachComponent(Ref);
    return bOk;
}

function bool Sample(name Hand, optional bool bWristContact)
{
    local vector P0, P, HandP, Best;
    local quat Q0, Q, HandQ;
    local float T, L, MaxD, GripD, Total;
    local int I, J;
    local PathPose Pose;
    if (Ref.MatchRefBone(Bones[0]) < 0 || Ref.MatchRefBone(Hand) < 0) return false;
    L = RefSeq.AnimSeq.SequenceLength;
    // Opening precedes loading. A closing slap can overshoot the open angle
    // (Stoner/Bastion), so it must not become the opening path's endpoint.
    for (I = 0; I < RefSeq.AnimSeq.Notifies.Length; ++I)
        if (KFAnimNotify_ReloadAmmo(RefSeq.AnimSeq.Notifies[I].Notify) != None
            && RefSeq.AnimSeq.Notifies[I].Time > 0)
            L = FMin(L, RefSeq.AnimSeq.Notifies[I].Time);
    PoseRef(0);
    RefRelative(Bones[0], P0, Q0);
    MaxD = 0;
    for (I = 0; I <= 120; ++I)
    {
        PoseRef(L * float(I) / 120.0);
        RefRelative(Bones[0], P, Q);
        MaxD = FMax(MaxD, Distance(P0, Q0, P, Q));
    }
    if (MaxD < 1.0) return false;
    OpenTime = -1;
    for (I = 0; I <= 120 && OpenTime < 0; ++I)
    {
        T = L * float(I) / 120.0;
        PoseRef(T);
        RefRelative(Bones[0], P, Q);
        if (Distance(P0, Q0, P, Q) >= MaxD * 0.97) OpenTime = T;
    }
    StartTime = 0;
    for (I = 0; I <= 120; ++I)
    {
        T = OpenTime * float(I) / 120.0;
        PoseRef(T);
        RefRelative(Bones[0], P, Q);
        if (Distance(P0, Q0, P, Q) <= MaxD * 0.03) StartTime = T;
    }
    GripD = 1000000;
    for (I = 0; I <= 24; ++I)
    {
        T = FMax(0, StartTime - 0.25) + (OpenTime - FMax(0, StartTime - 0.25)) * float(I) / 24.0;
        PoseRef(T);
        RefRelative(Bones[0], P, Q);
        RefRelative(Hand, HandP, HandQ);
        if (VSize(HandP - P) < GripD)
        {
            GripD = VSize(HandP - P);
            Best = QuatRotateVector(QuatInvert(Q), HandP - P);
            // Keep the wrist orientation and finger pose from the same
            // stock contact that supplies the action's motion path.
            GripQ = QuatProduct(QuatInvert(Q), HandQ);
            GripTime = T;
        }
    }
    GripLocal = GripD < 30 ? Best : vect(0,0,0);
    Total = 0;
    for (I = 0; I <= 16; ++I)
    {
        PoseRef(StartTime + (OpenTime - StartTime) * float(I) / 16.0);
        for (J = 0; J < BoneCount; ++J) RefRelative(Bones[J], Pose.P[J], Pose.Q[J]);
        Pose.C = Pose.P[0] + QuatRotateVector(Pose.Q[0], GripLocal);
        // A lever is held by curling fingers while the wrist pivots relative
        // to it. Its actual stock wrist path avoids welding that wrist to the
        // lever's long radius; the controlled bones keep their full throw.
        if (bWristContact) RefRelative(Hand, Pose.C, HandQ);
        if (I > 0) Total += VSize(Pose.C - Path[I - 1].C);
        Path.AddItem(Pose);
        PathS.AddItem(Total);
    }
    if (Total < 0.5) { Path.Length = 0; PathS.Length = 0; return false; }
    for (I = 0; I < PathS.Length; ++I) PathS[I] /= Total;
    Length = Total;
    PoseRef(StartTime);
    return true;
}

// Distance of a pose from the closed one: travel plus a turn's lever arm.
static function float Distance(vector P0, quat Q0, vector P, quat Q)
{
    local quat Delta;
    Delta = QuatProduct(QuatInvert(Q0), Q);
    return VSize(P - P0) + 8.0 * Acos(FClamp(Abs(Delta.W), 0, 1));
}

function int Segment(float S, out float F)
{
    local int I;
    S = FClamp(S, 0, 1);
    I = 1;
    while (I < PathS.Length - 1 && PathS[I] < S) ++I;
    F = (PathS[I] - PathS[I - 1]) > 0.0001 ? (S - PathS[I - 1]) / (PathS[I] - PathS[I - 1]) : 1.0;
    return I;
}

function PoseAt(float S, int Bone, out vector P, out quat Q)
{
    local int I;
    local float F;
    I = Segment(S, F);
    P = Path[I - 1].P[Bone] * (1 - F) + Path[I].P[Bone] * F;
    Q = QuatSlerp(Path[I - 1].Q[Bone], Path[I].Q[Bone], F, true);
}

function vector ContactLocal(float S)
{
    local int I;
    local float F;
    I = Segment(S, F);
    return Path[I - 1].C * (1 - F) + Path[I].C * F;
}

// Attach a root-local hand to the handle where the action stands now.
function Grab(vector LocalHand, float S)
{
    local vector P;
    local quat Q;
    PoseAt(S, 0, P, Q);
    GrabLocal = QuatRotateVector(QuatInvert(Q), LocalHand - ContactLocal(S));
}

// The action amount whose handle-carried grab point is nearest the hand: the
// hand moves the part as if it held it, through the whole swing.
function float ProjectGrab(vector LocalHand)
{
    local int I;
    local vector A, B;
    local float F, D, BestD, BestS;
    BestD = 1000000; BestS = 0;
    for (I = 1; I < Path.Length; ++I)
    {
        A = Path[I - 1].C + QuatRotateVector(Path[I - 1].Q[0], GrabLocal);
        B = Path[I].C + QuatRotateVector(Path[I].Q[0], GrabLocal);
        F = VSize(B - A) > 0.0001 ? FClamp(((LocalHand - A) dot (B - A)) / ((B - A) dot (B - A)), 0, 1) : 0.0;
        D = VSize(LocalHand - (A + (B - A) * F));
        if (D < BestD) { BestD = D; BestS = PathS[I - 1] + (PathS[I] - PathS[I - 1]) * F; }
    }
    return BestS;
}

// As Project, but only along the path within a fifth of its travel of From,
// so a held part follows the hand continuously and can never jump to a far
// stretch of its own path (a cover snapping shut, a folded linkage crossing).
function float ProjectNearby(vector LocalHand, float From)
{
    local int I;
    local vector A, V;
    local float F, S, D, BestD, Best;
    Best = From; BestD = 1000000;
    for (I = 1; I < Path.Length; ++I)
    {
        if (PathS[I] < From - 0.20 || PathS[I-1] > From + 0.20) continue;
        A = Path[I-1].C; V = Path[I].C - A;
        F = (V dot V) > 0.000001 ? FClamp(((LocalHand-A) dot V) / (V dot V), 0, 1) : 0.0;
        S = PathS[I-1] + (PathS[I]-PathS[I-1]) * F;
        D = VSize(LocalHand-A-V*F);
        if (D < BestD) { BestD = D; Best = S; }
    }
    return Best;
}

// The point of the contact path nearest a root-local hand position.
function float Project(vector LocalHand)
{
    local int I;
    local vector A, B;
    local float F, D, BestD, BestS;
    BestD = 1000000; BestS = 0;
    for (I = 1; I < Path.Length; ++I)
    {
        A = Path[I - 1].C; B = Path[I].C;
        F = VSize(B - A) > 0.0001 ? FClamp(((LocalHand - A) dot (B - A)) / ((B - A) dot (B - A)), 0, 1) : 0.0;
        D = VSize(LocalHand - (A + (B - A) * F));
        if (D < BestD) { BestD = D; BestS = PathS[I - 1] + (PathS[I] - PathS[I - 1]) * F; }
    }
    return BestS;
}
