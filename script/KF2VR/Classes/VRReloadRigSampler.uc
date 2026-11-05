// Read the stock reload on a private, attached reference component. Runtime
// and the asset commandlet share this sampler; no gameplay notify is executed.
// The caller owns attachment, component lifetime and prop/bone compatibility.
class VRReloadRigSampler extends Object;

struct InsertPose
{
    var vector Position;
    var quat Rotation;
};

var array<InsertPose> Path;
var name AmmoTrack;
var vector EntryLocal, SeatLocal, HandLocal;
var quat EntryLocalQ, SeatLocalQ, HandLocalQ;
var float EntryTime, SeatTime, InsertEndTime, InsertLength, PathLength, SeatCorrection;
// A port-loading clip releases its shell before insertion. Free carry uses
// an earlier authored grip while Path retains the short entry-to-seat curve.
var float CarryTime;
var vector CarryLocal;
var quat CarryLocalQ;
// VRReloadCatalog.bSeatAtNotify: the seat is the loaded bone's pose at the
// ammo moment of the reload clip, not its Idle pose.
var bool bSeatAtNotify;
var float ContactDistance;
var bool bRackSampled;
// VRReloadCatalog.ActionKind of the gun being sampled, set by the caller.
var byte ActionKind;
// Caller settings from the catalog, independent of the incoming part's wrist.
var name RackSourceHand;
var bool bRackThumbContact;
var float MaxRackStroke;
var vector RackAxisLocal, RackRestLocal;
var quat RackRestLocalQ;
var float RackStroke;
// The clip that supplied the stroke: an elite empty clip that presses the
// bolt release instead of pulling the handle (AR-15, MP7, Kriss) borrows the
// ordinary empty clip's measurement, since the travel belongs to the gun.
var name RackAnim;
var string FailureReason, RackFailureReason;
// A second action part that rides the rack (VRReloadCatalog.FollowBone): its
// idle rest and its own travel along the rack axis in the same clip. Optional;
// a follower that does not move, rotates or leaves the axis is simply not driven.
var bool bFollowSampled;
var vector FollowRestLocal;
var quat FollowRestLocalQ;
var float FollowStroke;
var string FollowFailureReason;
// The authored offhand contact is distinct from an action bone's pivot. An
// elite reload may only tap the slide release; reuse the same gun's ordinary
// empty-reload grip when it has no authored offhand pull of its own.
var bool bRackHandSampled;
var name RackHandAnim;
var float RackPoseTime, RackHandDistance, RackFingerDistance;
var vector RackHandLocal, RackHandInAction;
var quat RackHandLocalQ, RackHandInActionQ;
var string RackHandFailureReason;

function Reset()
{
    Path.Length = 0;
    AmmoTrack = '';
    EntryLocal = vect(0,0,0); SeatLocal = vect(0,0,0); HandLocal = vect(0,0,0);
    EntryLocalQ = QuatFromRotator(rot(0,0,0));
    SeatLocalQ = EntryLocalQ; HandLocalQ = EntryLocalQ;
    EntryTime = 0; SeatTime = 0; InsertEndTime = 0;
    CarryTime = 0; CarryLocal = vect(0,0,0); CarryLocalQ = EntryLocalQ;
    InsertLength = 0; PathLength = 0; SeatCorrection = 0;
    ContactDistance = 0;
    bRackSampled = false;
    RackAxisLocal = vect(0,0,0); RackRestLocal = vect(0,0,0);
    RackRestLocalQ = EntryLocalQ; RackStroke = 0; RackAnim = '';
    FailureReason = ""; RackFailureReason = "";
    ResetFollower();
    ResetRackHand();
}

function float AmmoNotifyTime(AnimSequence Clip)
{
    local int I;
    if (Clip == None) return 0;
    for (I = 0; I < Clip.Notifies.Length; ++I)
        if (Clip.Notifies[I].Notify != None
            && ClassIsChildOf(Clip.Notifies[I].Notify.Class, class'KFAnimNotify_ReloadAmmo'))
            return Clip.Notifies[I].Time;
    return 0;
}

function ResetFollower()
{
    bFollowSampled = false;
    FollowRestLocal = vect(0,0,0);
    FollowRestLocalQ = QuatFromRotator(rot(0,0,0));
    FollowStroke = 0;
    FollowFailureReason = "";
}

function ResetRackHand()
{
    bRackHandSampled = false; RackHandAnim = '';
    RackPoseTime = 0; RackHandDistance = 0; RackFingerDistance = 0;
    RackHandLocal = vect(0,0,0); RackHandInAction = vect(0,0,0);
    RackHandLocalQ = QuatFromRotator(rot(0,0,0));
    RackHandInActionQ = RackHandLocalQ;
    RackHandFailureReason = "";
}

function Pose(KFSkeletalMeshComponent M, AnimNodeSequence Seq, float Time)
{
    Seq.SetPosition(Time, false);
    Seq.bPlaying = false;
    M.ForceSkelUpdate();
    M.ForceUpdate(false);
}

function Relative(KFSkeletalMeshComponent M, name Root, name Bone,
    out vector Position, out quat Rotation)
{
    local quat InvRoot;
    InvRoot = QuatInvert(M.GetBoneQuaternion(Root));
    Position = QuatRotateVector(InvRoot, M.GetBoneLocation(Bone) - M.GetBoneLocation(Root));
    Rotation = QuatProduct(InvRoot, M.GetBoneQuaternion(Bone));
}

function float RotationMatch(quat A, quat B)
{
    // q and -q describe the same rotation. cos(15 degrees / 2) below accepts
    // only a translating action, not a lever/rotating handle approximated badly.
    return Abs(A.X * B.X + A.Y * B.Y + A.Z * B.Z + A.W * B.W);
}

function float SeatScore(vector Position, quat Rotation)
{
    return VSize(Position - SeatLocal) + 30 * (1 - FMin(RotationMatch(Rotation, SeatLocalQ), 1));
}

// The bone labelled "spare" can be the discarded or retained OLD magazine.
// The five audited rigs have matching local magazine geometry, but their
// incoming bone changes between clips (including the Bullpup elite reload).
// The seat test takes the candidate's closest pose in the same short window
// after the notify that FindInsertEnd searches: the Kriss tactical clip's
// notify fires a tenth of a frame before its magazine crosses the gate.
function bool SelectAmmoTrack(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Root, name Loaded, name Spare, float SequenceLength, float RateScale)
{
    local int I, J;
    local name Candidate;
    local vector Entry, AtNotify, Position;
    local quat EntryQ, AtNotifyQ, Rotation;
    local float Score, BestScore, EndTime, PoseScore, BestPose, CandidateEntry, BestEntry;
    BestScore = 100000;
    BestEntry = EntryTime;
    EndTime = FMin(SequenceLength, SeatTime + 0.16 * RateScale);
    for (I = 0; I < 2; ++I)
    {
        Candidate = I == 0 ? Loaded : Spare;
        if (I == 1 && Candidate == Loaded) continue;
        CandidateEntry = EntryTime;
        Pose(M, Seq, EntryTime);
        Relative(M, Root, Candidate, Entry, EntryQ);
        // Some clips seat well before their ammo notify (Zed MKIII, Freeze
        // Thrower, Healthrower, Tommy Gun tactical, Doshinegun, Bladed
        // pistol, P90 empty): the fixed lead lands on an already seated
        // part, leaving no approach and a hand that has let go. Walking back
        // from that seated pose, the first pose 6 UU out is the incoming
        // part's own final approach, never the earlier outgoing one.
        // The same applies when the lead lands on an overshoot: the Tommy
        // Gun's empty clip slides its drum 1.4 UU past the seat and back, so
        // the lead caught it on the far side and left a 1.3 UU "approach"
        // against the tactical clip's 6.7 UU slide along the same track.
        if (VSize(Entry - SeatLocal) < 6)
            for (J = 1; J <= 64; ++J)
            {
                if (EntryTime - 1.2 * RateScale * float(J) / 64.0 < 0) break;
                Pose(M, Seq, EntryTime - 1.2 * RateScale * float(J) / 64.0);
                Relative(M, Root, Candidate, Position, Rotation);
                if (VSize(Position - SeatLocal) < 6) continue;
                if (VSize(Entry - SeatLocal) < 1
                    || (M.SkeletalMesh.Name == 'WEP_1stP_HRG_Boomy_Rig')
                    || ((Entry - SeatLocal) dot (Position - SeatLocal))
                        < -0.5 * VSize(Entry - SeatLocal) * VSize(Position - SeatLocal))
                {
                    CandidateEntry = EntryTime - 1.2 * RateScale * float(J) / 64.0;
                    Entry = Position; EntryQ = Rotation;
                }
                break;
            }
        BestPose = 100000;
        for (J = 0; J <= 8; ++J)
        {
            Pose(M, Seq, SeatTime + (EndTime - SeatTime) * float(J) / 8.0);
            Relative(M, Root, Candidate, Position, Rotation);
            PoseScore = SeatScore(Position, Rotation);
            if (PoseScore < BestPose) { BestPose = PoseScore; AtNotify = Position; AtNotifyQ = Rotation; }
        }
        // Offline audit: the incoming notify is up to 3.92 UU and 6.4 degrees
        // from the idle seat; the old one is parked or held at another angle.
        // Require real approach motion too, so a stationary loaded copy does
        // not win merely by already being at home. This is an asset gate,
        // independent of the player's considerably wider capture tolerance.
        if (VSize(AtNotify - SeatLocal) > 6 || RotationMatch(AtNotifyQ, SeatLocalQ) < 0.98480775
            || VSize(Entry - AtNotify) <= 0.1
            || VSize(Entry - SeatLocal) <= VSize(AtNotify - SeatLocal) + 0.1) continue;
        Score = SeatScore(AtNotify, AtNotifyQ);
        if (Score < BestScore) { BestScore = Score; AmmoTrack = Candidate; BestEntry = CandidateEntry; }
    }
    // The insertion path and the carried hand are both read from this time.
    EntryTime = BestEntry;
    return AmmoTrack != '';
}

// Ammo timing and full visual seating are different authored events on these
// rigs: the notify can land after the seat (FAMAS Reload_Half seats at 1.20 s,
// notifies at 1.25 s, by when the stock wrist has turned off the magazine, #130)
// or just before it (the Kriss tactical clip). Keep SeatTime unchanged and end
// the insert at the first time the incoming magazine is at its seat, searching
// a short window either side of the notify. The window never reaches back past
// EntryTime, so it cannot find the earlier ejection.
function FindInsertEnd(KFSkeletalMeshComponent M, AnimNodeSequence Seq, name Root,
    float SequenceLength, float RateScale)
{
    local int I;
    local vector Position;
    local quat Rotation;
    local float Time, StartTime, EndTime, Score, BestScore;
    InsertEndTime = SeatTime;
    StartTime = FMax(EntryTime, SeatTime - 0.16 * RateScale);
    EndTime = FMin(SequenceLength, SeatTime + 0.16 * RateScale);
    BestScore = 100000;
    for (I = 0; I <= 64; ++I)
    {
        Time = StartTime + (EndTime - StartTime) * float(I) / 64.0;
        Pose(M, Seq, Time);
        Relative(M, Root, AmmoTrack, Position, Rotation);
        Score = SeatScore(Position, Rotation);
        // Strictly better only: of equal poses the earliest is kept.
        if (Score < BestScore) { BestScore = Score; InsertEndTime = Time; }
        if (VSize(Position - SeatLocal) <= 0.05 && RotationMatch(Rotation, SeatLocalQ) >= 0.99996192) break;
    }
}

// Shorten a long carry approach to the final authored insertion mouth. The
// normal path guard still rejects discontinuities; no seat tolerance changes.
function TrimLongInsertApproach(KFSkeletalMeshComponent M, AnimNodeSequence Seq, name Root,
    optional float MaximumLength=30)
{
    local int I;
    local float Time;
    local vector Position;
    local quat Rotation;
    Pose(M, Seq, EntryTime);
    Relative(M, Root, AmmoTrack, Position, Rotation);
    if (VSize(Position - SeatLocal) < MaximumLength) return;
    for (I = 1; I <= 64; ++I)
    {
        Time = InsertEndTime - (InsertEndTime - EntryTime) * float(I) / 64.0;
        Pose(M, Seq, Time);
        Relative(M, Root, AmmoTrack, Position, Rotation);
        if (VSize(Position - SeatLocal) < 8) continue;
        EntryTime = Time;
        return;
    }
}

// A slide's first maximum can be its locked-back state while the other hand
// still carries the magazine. A nearby non-thumb digit distinguishes an
// authored pull from that plateau or a thumb-only release. The contact limit
// includes the distance between the action pivot and its actual surface.
function float RackFingerContact(KFSkeletalMeshComponent M, name Rack, name Hand)
{
    local int I, Joint;
    local name Finger;
    local string Side, Digit;
    local float Distance;
    local vector ActionPosition;
    Distance = 100000;
    Side = Hand == 'RightHand_1stP' ? "Right" : "Left";
    ActionPosition = M.GetBoneLocation(Rack);
    for (I = 0; I < (bRackThumbContact ? 5 : 4); ++I)
    {
        switch (I)
        {
            case 0: Digit = "Index"; break;
            case 1: Digit = "Middle"; break;
            case 2: Digit = "Ring"; break;
            case 3: Digit = "Pinky"; break;
            case 4: Digit = "Thumb"; break;
        }
        for (Joint = 2; Joint <= 3; ++Joint)
        {
            Finger = name(Side $ "Hand" $ Digit $ Joint $ "_1stP");
            if (M.MatchRefBone(Finger) < 0) continue;
            Distance = FMin(Distance, VSize(M.GetBoneLocation(Finger) - ActionPosition));
        }
    }
    return Distance;
}

function bool FindRackHand(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Anim, name Root, name Rack, name Hand, optional bool bAllowRotation)
{
    local int I;
    local float StartTime, Time, FingerDistance, HandDistance, Score, BestScore, Travel, ContactLimit;
    local vector Position, HandPosition;
    local quat Rotation, HandRotation;
    local AnimSequence Clip;
    Seq.SetAnim(Anim);
    Clip = Seq.AnimSeq;
    if (Clip == None || Clip.SequenceLength <= 0) return false;
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        if (Clip.Notifies[I].Notify != None
            && ClassIsChildOf(Clip.Notifies[I].Notify.Class, class'KFAnimNotify_ReloadAmmo'))
        { StartTime = Clip.Notifies[I].Time; break; }
    }
    // Open-bolt clips may cock before the magazine notify. Their rear-stop
    // plateau can also show the released, open hand rather than its pull grip.
    if (ActionKind == 1) StartTime = 0;
    else if (StartTime <= 0 || StartTime >= Clip.SequenceLength) return false;
    // The P90's charging-handle pivot is inset from its thumb contact surface.
    // Both stock pulls put the thumb 7.1-7.3 UU away; retain the tighter default
    // on other rigs and keep all travel/rotation checks unchanged.
    ContactLimit = M.SkeletalMesh.Name == 'Wep_1stP_P90_Rig' ? 8 : 7;
    BestScore = 100000;
    for (I = 0; I <= 64; ++I)
    {
        Time = StartTime + (Clip.SequenceLength - StartTime) * float(I) / 64.0;
        Pose(M, Seq, Time);
        Relative(M, Root, Rack, Position, Rotation);
        Travel = (Position - RackRestLocal) dot RackAxisLocal;
        if (ActionKind == 1 || M.SkeletalMesh.Name == 'Wep_1stP_Medic_Assault_Rig')
        {
            // Sample the moving pull, before the fingers let go at the stop.
            // HMTech-401 also releases before the rear-stop sample. Its
            // ordinary clip has finger contact during the pull; the elite
            // release-only clip still falls back to that ordinary grip.
            if (Travel < RackStroke * 0.1 || Travel > RackStroke * 0.9) continue;
        }
        else if (Travel < RackStroke * 0.9 || Travel > RackStroke * 1.15) continue;
        if (!bAllowRotation && RotationMatch(Rotation, RackRestLocalQ) < 0.99144486) continue;
        Relative(M, Rack, Hand, HandPosition, HandRotation);
        HandDistance = VSize(HandPosition);
        FingerDistance = RackFingerContact(M, Rack, Hand);
        // Positive comparisons also reject invalid (NaN) poses. Keep this
        // cosmetic gate independent from the proven action mechanics.
        if (!(HandDistance >= 0 && HandDistance <= 24 && FingerDistance >= 0 && FingerDistance <= ContactLimit
            && RotationMatch(HandRotation, HandRotation) >= 0.95
            && RotationMatch(HandRotation, HandRotation) <= 1.05)) continue;
        Score = FingerDistance + HandDistance * 0.05;
        if (Score >= BestScore) continue;
        BestScore = Score;
        RackHandAnim = Anim; RackPoseTime = Time;
        RackHandDistance = HandDistance; RackFingerDistance = FingerDistance;
        RackHandInAction = HandPosition; RackHandInActionQ = HandRotation;
        Relative(M, Root, Hand, RackHandLocal, RackHandLocalQ);
        bRackHandSampled = true;
    }
    return bRackHandSampled;
}

function SampleRack(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Anim, name Root, name Rack, float SequenceLength, optional name Hand, optional name Follow,
    optional float StartTime)
{
    local int I;
    local vector Position, Offset, Farthest;
    local quat Rotation;
    local float Distance, Along, TransverseLimit, From;
    local array<vector> Offsets;

    bRackSampled = false; RackStroke = 0; RackAnim = '';
    RackFailureReason = "";
    ResetFollower();
    ResetRackHand();
    From = StartTime > 0 ? StartTime : SeatTime;
    // An open bolt is cocked wherever the clip does it (the Tommy Gun and
    // Mac-10 cock before the magazine change), so its whole clip is measured.
    if (ActionKind == 1) From = 0;
    if (RackSourceHand != '') Hand = RackSourceHand;
    if (Hand == '') Hand = 'LeftHand_1stP';
    if (Rack == '' || ActionKind == 2) { RackFailureReason = "not-requested"; return; }
    if (M.MatchRefBone(Rack) < 0) { RackFailureReason = "missing-action-bone"; return; }
    Seq.SetAnim('Idle');
    if (Seq.AnimSeq == None || Seq.AnimSeq.SequenceLength <= 0)
    { RackFailureReason = "missing-idle"; return; }
    Pose(M, Seq, 0);
    Relative(M, Root, Rack, RackRestLocal, RackRestLocalQ);
    Seq.SetAnim(Anim);
    if (Seq.AnimSeq == None) { RackFailureReason = "missing-reload"; return; }

    // Sample the action after ammunition has been inserted. The stationary
    // idle pose supplies the closed stop even when the empty reload begins
    // with a pistol's slide locked back. All positions exclude root motion.
    for (I = 0; I <= 64; ++I)
    {
        Pose(M, Seq, From + (SequenceLength - From) * float(I) / 64.0);
        Relative(M, Root, Rack, Position, Rotation);
        // A handle may also turn as it travels (the G36C's folds out, the MP5's
        // and UMP's drop into their notch); only its straight travel is driven.
        Offset = Position - RackRestLocal;
        Offsets.AddItem(Offset);
        Distance = VSize(Offset);
        if (Distance > RackStroke) { RackStroke = Distance; Farthest = Offset; }
    }
    if (RackStroke < 0.5 || RackStroke > (MaxRackStroke > 0 ? MaxRackStroke : 15.0))
    { RackFailureReason = "action-travel-out-of-range"; return; }
    RackAxisLocal = Farthest / RackStroke;
    // Idle is an open bolt's cocked (rear) stop and its farthest point is the
    // empty gun's forward handle: rest there and pull back toward idle.
    if (ActionKind == 1)
    {
        if ((Farthest dot vect(1,0,0)) <= 0) { RackFailureReason = "open-bolt-not-forward"; return; }
        RackRestLocal += Farthest;
        RackAxisLocal = -RackAxisLocal;
        for (I = 0; I < Offsets.Length; ++I) Offsets[I] -= Farthest;
    }
    TransverseLimit = FMax(0.2, RackStroke * 0.2);
    for (I = 0; I < Offsets.Length; ++I)
    {
        Along = Offsets[I] dot RackAxisLocal;
        if (Along < -TransverseLimit
            || VSize(Offsets[I] - RackAxisLocal * Along) > TransverseLimit)
        { RackFailureReason = "nonlinear-action"; return; }
    }
    bRackSampled = true;
    RackAnim = Anim;
    SampleFollower(M, Seq, Anim, Root, Follow, SequenceLength, From);
    Seq.SetAnim(Anim);
    if (M.MatchRefBone(Hand) < 0) { RackHandFailureReason = "missing-action-hand"; return; }
    if (FindRackHand(M, Seq, Anim, Root, Rack, Hand)) return;
    if (Anim == 'Reload_Empty_Elite'
        && FindRackHand(M, Seq, 'Reload_Empty', Root, Rack, Hand)) return;
    // Every grip on a turning handle is taken with it turned.
    if (FindRackHand(M, Seq, Anim, Root, Rack, Hand, true)) return;
    RackHandFailureReason = "no-stock-action-grip";
}

// The follower's travel is measured along the rack axis over the same stretch
// of the clip. It is driven in proportion to the grabbed part's pull, so its
// stroke may differ (the AR-15 bolt carrier outruns its charging handle).
function SampleFollower(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Anim, name Root, name Follow, float SequenceLength, float From)
{
    local int I;
    local vector Position, Offset;
    local quat Rotation;
    local float Along, Transverse, MaxTransverse;
    ResetFollower();
    if (Follow == '') { FollowFailureReason = "not-requested"; return; }
    if (M.MatchRefBone(Follow) < 0) { FollowFailureReason = "missing-follow-bone"; return; }
    Seq.SetAnim('Idle');
    if (Seq.AnimSeq == None || Seq.AnimSeq.SequenceLength <= 0)
    { FollowFailureReason = "missing-idle"; return; }
    Pose(M, Seq, 0);
    Relative(M, Root, Follow, FollowRestLocal, FollowRestLocalQ);
    Seq.SetAnim(Anim);
    if (Seq.AnimSeq == None) { FollowFailureReason = "missing-reload"; return; }
    // An open bolt's follower rests where the empty clip starts (forward).
    if (ActionKind == 1)
    {
        Pose(M, Seq, 0);
        Relative(M, Root, Follow, FollowRestLocal, Rotation);
    }
    for (I = 0; I <= 64; ++I)
    {
        Pose(M, Seq, From + (SequenceLength - From) * float(I) / 64.0);
        Relative(M, Root, Follow, Position, Rotation);
        if (RotationMatch(Rotation, FollowRestLocalQ) < 0.99144486)
        { FollowStroke = 0; FollowFailureReason = "rotating-follower"; return; }
        Offset = Position - FollowRestLocal;
        Along = Offset dot RackAxisLocal;
        Transverse = VSize(Offset - RackAxisLocal * Along);
        if (Along > FollowStroke) FollowStroke = Along;
        if (Transverse > MaxTransverse) MaxTransverse = Transverse;
    }
    if (FollowStroke < 0.5 || FollowStroke > 20)
    { FollowStroke = 0; FollowFailureReason = "follower-travel-out-of-range"; return; }
    if (MaxTransverse > FMax(0.2, FollowStroke * 0.2))
    { FollowStroke = 0; FollowFailureReason = "nonlinear-follower"; return; }
    bFollowSampled = true;
}

// MG3 refills its box before its visual return is complete (and the empty
// ordinary clip notifies after it). Find the final approach to the real idle
// seat; the notify remains the stock ammo timer, never a spatial target.
function bool SampleBoxInsert(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Anim, name Root, name Ammo, name Hand, optional bool bLateBoxNotify,
    optional bool bProjectilePlateau)
{
    local AnimSequence Clip;
    local InsertPose Point;
    local int I, J, Steps;
    local float T, Candidate, EntryWindow;
    local bool bMoved, bStable, bFoundPlateau;
    local vector PlateauLocal;
    local quat PlateauLocalQ;
    Reset();
    if (M == None || M.SkeletalMesh == None || Seq == None || M.MatchRefBone(Root) < 0
        || M.MatchRefBone(Ammo) < 0 || M.MatchRefBone(Hand) < 0) return false;
    Seq.SetAnim(Anim);
    Clip = Seq.AnimSeq;
    if (Clip == None || Clip.SequenceLength <= 0 || Clip.RateScale <= 0) return false;
    SeatTime = AmmoNotifyTime(Clip);
    if (SeatTime <= 0) return false;
    Seq.SetAnim('Idle');
    if (Seq.AnimSeq == None) return false;
    Pose(M, Seq, 0);
    Relative(M, Root, Ammo, SeatLocal, SeatLocalQ);
    Seq.SetAnim(Anim);
    AmmoTrack = Ammo;
    PlateauLocal = SeatLocal; PlateauLocalQ = SeatLocalQ;
    // Minigun notifies after the box has stopped and the hand has withdrawn.
    // Its reload plateau differs slightly from Idle. Use that plateau only
    // to find the approach timing; the final prop still seats at Idle.
    if (bProjectilePlateau)
    {
        // Rail elite seats before its ammo marker, then spins the seated
        // round; the bow's half clip settles its arrow rotation after it.
        // Find the first stable loaded pose after the real approach. Rail's
        // authored seat is 1.47 degrees from Idle: allow two, then retain
        // the one-degree plateau test and the final Idle seat below.
        Steps = int(Clip.SequenceLength * 60.0);
        for (I = 0; I <= Steps; ++I)
        {
            Candidate = float(I) / 60.0;
            Pose(M, Seq, Candidate);
            Relative(M, Root, Ammo, Point.Position, Point.Rotation);
            if (VSize(Point.Position - SeatLocal) > 2) bMoved = true;
            if (!bMoved || Candidate + 3.0 / 60.0 > Clip.SequenceLength
                || VSize(Point.Position - SeatLocal) > 0.2
                || RotationMatch(Point.Rotation, SeatLocalQ) < 0.99984770) continue;
            PlateauLocal = Point.Position; PlateauLocalQ = Point.Rotation;
            bStable = true;
            for (J = 1; J <= 3; ++J)
            {
                Pose(M, Seq, Candidate + float(J) / 60.0);
                Relative(M, Root, Ammo, Point.Position, Point.Rotation);
                if (VSize(Point.Position - SeatLocal) > 0.2
                    || RotationMatch(Point.Rotation, SeatLocalQ) < 0.99984770
                    || VSize(Point.Position - PlateauLocal) > 0.2
                    || RotationMatch(Point.Rotation, PlateauLocalQ) < 0.99996192)
                { bStable = false; break; }
            }
            if (!bStable) continue;
            T = Candidate + 3.0 / 60.0;
            bFoundPlateau = true;
            break;
        }
        if (!bFoundPlateau) { FailureReason = "missing-projectile-plateau"; return false; }
    }
    else if (bLateBoxNotify)
    {
        Pose(M, Seq, SeatTime);
        Relative(M, Root, Ammo, PlateauLocal, PlateauLocalQ);
    }
    if (!bProjectilePlateau)
        T = bLateBoxNotify ? SeatTime : FMin(SeatTime + 0.35 * Clip.RateScale, Clip.SequenceLength);
    Pose(M, Seq, T);
    Relative(M, Root, Ammo, Point.Position, Point.Rotation);
    if (VSize(Point.Position - PlateauLocal) > 0.2
        || RotationMatch(Point.Rotation, PlateauLocalQ) < 0.99996192) return false;
    // Walk back through the final seated plateau, excluding the earlier box
    // ejection. Include rotation so a still-turning box is not called seated.
    for (I = 0; I < 120 && T > 1.0 / 60.0; ++I)
    {
        Pose(M, Seq, T - 1.0 / 60.0);
        Relative(M, Root, Ammo, Point.Position, Point.Rotation);
        if (VSize(Point.Position - PlateauLocal) > 0.2
            || RotationMatch(Point.Rotation, PlateauLocalQ) < 0.99996192) break;
        T -= 1.0 / 60.0;
    }
    InsertEndTime = T;
    EntryTime = T;
    // Use a short physical mouth-to-seat stroke, not the stock hand's long
    // box approach. Eight UU leaves deliberate push travel after capture.
    // The bow translates into the seat before its rotation settles. Reach
    // back far enough to include its actual nocking approach.
    EntryWindow = bProjectilePlateau ? 0.8 : 0.45;
    for (I = 1; I <= 64; ++I)
    {
        EntryTime = FMax(T - EntryWindow * Clip.RateScale * float(I) / 64.0, 0);
        Pose(M, Seq, EntryTime);
        Relative(M, Root, Ammo, Point.Position, Point.Rotation);
        if (VSize(Point.Position - SeatLocal) >= 8) break;
    }
    for (I = 0; I <= 16; ++I)
    {
        Pose(M, Seq, EntryTime + (InsertEndTime - EntryTime) * float(I) / 16.0);
        Relative(M, Root, Ammo, Point.Position, Point.Rotation);
        if (I == 16) { Point.Position = SeatLocal; Point.Rotation = SeatLocalQ; }
        Path.AddItem(Point);
        if (I > 0) PathLength += VSize(Path[I].Position - Path[I - 1].Position);
    }
    EntryLocal = Path[0].Position; EntryLocalQ = Path[0].Rotation;
    InsertLength = VSize(SeatLocal - EntryLocal);
    if (!(InsertLength > 0.1 && PathLength < 30)) { Path.Length = 0; return false; }
    Pose(M, Seq, EntryTime);
    Relative(M, Root, Hand, HandLocal, HandLocalQ);
    CarryTime = EntryTime; CarryLocal = EntryLocal; CarryLocalQ = EntryLocalQ;
    return true;
}

// Long rounds and paired shell grips contact the geometry away from its bone
// origin. Use the existing bone-local prop bounds only for carry sampling;
// rack controls retain their own pivot/contact policy.
function float CarryFingerContact(KFSkeletalMeshComponent M, name Ammo, name Hand,
    vector Centre, vector Extent)
{
    local int I, Joint;
    local name Finger;
    local string Side, Digit;
    local float Distance;
    local vector AmmoPosition, At, Outside;
    local quat InvAmmo;
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Centre)
        || !(VSize(Centre) <= 50 && Extent.X > 0 && Extent.Y > 0 && Extent.Z > 0
            && Extent.X < 50 && Extent.Y < 50 && Extent.Z < 50))
        return RackFingerContact(M, Ammo, Hand);
    AmmoPosition = M.GetBoneLocation(Ammo);
    InvAmmo = QuatInvert(M.GetBoneQuaternion(Ammo));
    if (!class'VRReloadMotionGuard'.static.ValidPosition(AmmoPosition)
        || !class'VRHandRolePose'.static.ValidQuaternion(InvAmmo)) return 100000;
    Distance = 100000;
    Side = Hand == 'RightHand_1stP' ? "Right" : "Left";
    for (I = 0; I < 4; ++I)
    {
        switch (I)
        {
            case 0: Digit = "Index"; break;
            case 1: Digit = "Middle"; break;
            case 2: Digit = "Ring"; break;
            case 3: Digit = "Pinky"; break;
        }
        for (Joint = 2; Joint <= 3; ++Joint)
        {
            Finger = name(Side $ "Hand" $ Digit $ Joint $ "_1stP");
            if (M.MatchRefBone(Finger) < 0) continue;
            At = QuatRotateVector(InvAmmo, M.GetBoneLocation(Finger) - AmmoPosition) - Centre;
            if (!class'VRReloadMotionGuard'.static.ValidPosition(At)) continue;
            Outside.X = FMax(Abs(At.X) - Extent.X, 0);
            Outside.Y = FMax(Abs(At.Y) - Extent.Y, 0);
            Outside.Z = FMax(Abs(At.Z) - Extent.Z, 0);
            Distance = FMin(Distance, VSize(Outside));
        }
    }
    return Distance;
}

// How far the ammunition centre slides in the wrist's frame per ~1/30 s of
// stock motion. A hand carrying a round holds it still; a round sweeping
// through an open palm mid-transfer passes the wrist closely but never rests.
function float HeldMotion(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Ammo, name Hand, float Time, vector Centre)
{
    local vector Before, After, At;
    local quat Q;
    local float Step;
    Step = 0.035 * Seq.AnimSeq.RateScale;
    Pose(M, Seq, FMax(Time - Step, 0));
    Relative(M, Hand, Ammo, At, Q);
    Before = At + QuatRotateVector(Q, Centre);
    Pose(M, Seq, FMin(Time + Step, Seq.AnimSeq.SequenceLength));
    Relative(M, Hand, Ammo, At, Q);
    After = At + QuatRotateVector(Q, Centre);
    return VSize(After - Before) * 0.5;
}

// Read one authored carry contact. Failed candidates leave the caller's pair
// intact; ammo and wrist must come from the same time and root frame.
function bool ReadCarryGrip(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Root, name Ammo, name Hand, float Time, out vector AmmoP, out quat AmmoQ,
    out vector HandP, out quat HandQ, out float Score, vector Centre, vector Extent)
{
    local vector Wrist, At, HandAt;
    local quat WristQ, Q, HandRotation;
    local float FingerDistance, WristDistance, Motion;
    Motion = HeldMotion(M, Seq, Ammo, Hand, Time, Centre);
    Pose(M, Seq, Time);
    Relative(M, Ammo, Hand, Wrist, WristQ);
    FingerDistance = CarryFingerContact(M, Ammo, Hand, Centre, Extent);
    WristDistance = VSize(Wrist);
    if (!(FingerDistance >= 0 && FingerDistance <= 6 && WristDistance >= 0 && WristDistance <= 24)
        || !class'VRHandRolePose'.static.ValidQuaternion(WristQ)) return false;
    Relative(M, Root, Ammo, At, Q);
    Relative(M, Root, Hand, HandAt, HandRotation);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(At)
        || !class'VRReloadMotionGuard'.static.ValidPosition(HandAt)
        || !class'VRHandRolePose'.static.ValidQuaternion(Q)
        || !class'VRHandRolePose'.static.ValidQuaternion(HandRotation)) return false;
    AmmoP = At; AmmoQ = Q; HandP = HandAt; HandQ = HandRotation;
    // Steadiness dominates: the HX25's pass through the palm (f102, 5.7 UU
    // from the wrist) otherwise outscores its rigid thumb-index pinch.
    Score = FingerDistance + WristDistance + 8 * Motion;
    return true;
}

// Free carry can precede the short insertion track (rifles), or acquire its
// contact late in it (HX25). Preserve a valid entry grip; otherwise prefer a
// strong nearby earlier grip, then the first later contact. Never move Path.
function bool FindCarryGrip(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Root, name Ammo, name Hand, float StartTime, float EndTime,
    out float Time, out vector AmmoP, out quat AmmoQ, out vector HandP, out quat HandQ,
    optional vector Centre, optional vector Extent, optional bool bLateOnly)
{
    local int I;
    local float Candidate, Earliest, Score, BestScore, BestTime;
    local vector At, HandAt;
    local quat Q, HandRotation;
    if (M == None || M.SkeletalMesh == None || Seq == None || Seq.AnimSeq == None
        || M.MatchRefBone(Root) < 0 || M.MatchRefBone(Ammo) < 0 || M.MatchRefBone(Hand) < 0
        || !(StartTime >= 0 && EndTime >= StartTime && EndTime <= Seq.AnimSeq.SequenceLength
            && Seq.AnimSeq.SequenceLength < 100000000
            && Seq.AnimSeq.RateScale > 0 && Seq.AnimSeq.RateScale < 100000000)) return false;
    BestScore = 100000;
    BestTime = -1;
    if (ReadCarryGrip(M, Seq, Root, Ammo, Hand, StartTime, AmmoP, AmmoQ, HandP, HandQ, Score, Centre, Extent))
    {
        Time = StartTime;
        // HX25 hands the grenade across near the insertion marker. A merely
        // nearby finger at entry is weaker than its earlier carrying grip.
        if (M.SkeletalMesh.Name != 'Wep_1stP_HX25_Pistol_Rig') return true;
        BestScore = Score; BestTime = StartTime;
    }
    Earliest = FMax(StartTime - 0.8 * Seq.AnimSeq.RateScale, 0);
    for (I = 1; !bLateOnly && I <= 64; ++I)
    {
        Candidate = StartTime - (StartTime - Earliest) * float(I) / 64.0;
        if (!ReadCarryGrip(M, Seq, Root, Ammo, Hand, Candidate, At, Q, HandAt, HandRotation, Score, Centre, Extent)
            || Score >= BestScore) continue;
        BestScore = Score; BestTime = Candidate;
    }
    if (BestTime >= 0)
    {
        if (!ReadCarryGrip(M, Seq, Root, Ammo, Hand, BestTime, AmmoP, AmmoQ, HandP, HandQ, Score, Centre, Extent)) return false;
        Time = BestTime;
        return true;
    }
    for (I = 1; I <= 32; ++I)
    {
        Candidate = StartTime + (EndTime - StartTime) * float(I) / 32.0;
        if (!ReadCarryGrip(M, Seq, Root, Ammo, Hand, Candidate, AmmoP, AmmoQ, HandP, HandQ, Score, Centre, Extent)) continue;
        Time = Candidate;
        return true;
    }
    return false;
}

// Optional magazine carry correction. Keep a valid entry grip unchanged;
// otherwise use the latest nearby authored finger contact before entry.
// Ammo and wrist are always sampled at the same time and in the same frame.
function SampleEarlierCarryGrip(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Root, name Hand)
{
    local int I;
    local float Earliest, Time;
    local vector Wrist;
    local quat WristQ;
    CarryTime = EntryTime; CarryLocal = EntryLocal; CarryLocalQ = EntryLocalQ;
    Earliest = FMax(EntryTime - 0.8 * Seq.AnimSeq.RateScale, 0);
    for (I = 0; I <= 64; ++I)
    {
        Time = EntryTime - (EntryTime - Earliest) * float(I) / 64.0;
        Pose(M, Seq, Time);
        Relative(M, AmmoTrack, Hand, Wrist, WristQ);
        if (RackFingerContact(M, AmmoTrack, Hand) > 6 || VSize(Wrist) > 24) continue;
        CarryTime = Time;
        Relative(M, Root, AmmoTrack, CarryLocal, CarryLocalQ);
        Relative(M, Root, Hand, HandLocal, HandLocalQ);
        return;
    }
}

// The pump shotguns' shell bones exchange roles between ordinary and elite
// clips (the MB500 and Trench Gun share these tracks; VRPumpCatalog).
// There is no meaningful idle shell seat: the incoming shell disappears into
// the tube/port at the stock ammo event. Open-shell clips also release the
// shell before a fixed 0.12-second lead, so find the last authored carry grip
// rather than posing a withdrawn hand around the shell.
function bool SamplePumpInsert(KFSkeletalMeshComponent M, AnimNodeSequence Seq,
    name Anim, name Root, name Hand, float EntryLead)
{
    local AnimSequence Clip;
    local InsertPose Point;
    local int I, J;
    local bool bFoundNotify, bFoundContact, bChooseCarry;
    local float LatestTime, EarliestTime, Distance, HandDistance, BestTime, BestScore, Score, CandidateLength, CarrySearchEnd;
    local vector Position, HandPosition, PreviousPosition, PathPosition;
    local quat Rotation, HandRotation, PathRotation;
    Reset();
    if (M == None || M.SkeletalMesh == None || Seq == None)
    { FailureReason = "missing-component"; return false; }
    if (!class'VRPumpCatalog'.static.CoversMesh(M.SkeletalMesh.Name))
    { FailureReason = "unsupported-pump-rig"; return false; }
    AmmoTrack = class'VRPumpCatalog'.static.FeedTrack(M.SkeletalMesh.Name, Anim);
    if (AmmoTrack == '') { FailureReason = "unsupported-pump-insert"; return false; }
    if (Root == '' || Hand == '' || M.MatchRefBone(Root) < 0
        || M.MatchRefBone(Hand) < 0 || M.MatchRefBone(AmmoTrack) < 0)
    { FailureReason = "missing-insert-bone"; return false; }
    Seq.bNoNotifies = true;
    Seq.bPlaying = false;
    Seq.SetAnim(Anim);
    Clip = Seq.AnimSeq;
    if (Clip == None || Clip.SequenceLength <= 0 || Clip.RateScale <= 0)
    { FailureReason = "invalid-reload"; return false; }
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        if (Clip.Notifies[I].Notify == None
            || !ClassIsChildOf(Clip.Notifies[I].Notify.Class, class'KFAnimNotify_ReloadAmmo')) continue;
        SeatTime = Clip.Notifies[I].Time;
        bFoundNotify = true;
        break;
    }
    if (!bFoundNotify || SeatTime <= 0 || SeatTime > Clip.SequenceLength)
    { FailureReason = "invalid-ammo-notify"; return false; }
    InsertEndTime = SeatTime;
    Pose(M, Seq, SeatTime);
    Relative(M, Root, AmmoTrack, SeatLocal, SeatLocalQ);
    LatestTime = FMax(SeatTime - FClamp(EntryLead, 0, 0.45) * Clip.RateScale, 0);
    EarliestTime = FMax(SeatTime - 0.45 * Clip.RateScale, 0);
    // The MB500 port clip leaves a fingertip near the shell after opening
    // the palm. Among valid authored contacts choose the closest carry pose,
    // rather than the latest withdrawn hand. Tube inserts retain their timing.
    bChooseCarry = class'VRPumpCatalog'.static.CoversMesh(M.SkeletalMesh.Name)
        && (Anim == 'Reload_Open_Shell' || Anim == 'Reload_Open_Shell_Elite');
    BestScore = 100000;
    for (I = 0; I <= 64; ++I)
    {
        EntryTime = LatestTime - (LatestTime - EarliestTime) * float(I) / 64.0;
        Pose(M, Seq, EntryTime);
        Relative(M, Root, AmmoTrack, Position, Rotation);
        Relative(M, AmmoTrack, Hand, HandPosition, HandRotation);
        Distance = RackFingerContact(M, AmmoTrack, Hand);
        HandDistance = VSize(HandPosition);
        if (!(Distance >= 0 && Distance <= 6 && HandDistance >= 0 && HandDistance <= 24
            && VSize(SeatLocal - Position) > 0.1
            && RotationMatch(HandRotation, HandRotation) >= 0.95
            && RotationMatch(HandRotation, HandRotation) <= 1.05)) continue;
        Score = Distance + HandDistance;
        if (bFoundContact && Score >= BestScore) continue;
        if (bChooseCarry)
        {
            // A stronger but earlier grip can precede a long shell approach.
            // Keep the same path-length guard used by the final insert sample.
            PreviousPosition = Position; CandidateLength = 0;
            for (J = 1; J <= 16; ++J)
            {
                Pose(M, Seq, EntryTime + (InsertEndTime - EntryTime) * float(J) / 16.0);
                Relative(M, Root, AmmoTrack, PathPosition, PathRotation);
                CandidateLength += VSize(PathPosition - PreviousPosition);
                PreviousPosition = PathPosition;
            }
            if (CandidateLength >= 30) continue;
        }
        BestScore = Score; BestTime = EntryTime;
        ContactDistance = Distance;
        bFoundContact = true;
        if (!bChooseCarry) break;
    }
    EntryTime = BestTime;
    if (!bFoundContact) { FailureReason = "no-stock-shell-grip"; return false; }
    CarrySearchEnd = EntryTime;
    // The M4 drops its first shell from an overhead carry into the open port,
    // then pushes it forward. Its best finger grip is about 11 UU above the
    // receiver; that is the carry pose, not the physical insertion mouth.
    // Use the authored final approach for acquisition while retaining the
    // exact earlier carry search and finger pose below. Other shotguns keep
    // their existing first-port and tube-loading choreography.
    if (bChooseCarry && M.SkeletalMesh.Name == 'Wep_1stP_M4Shotgun_Rig')
        EntryTime = FMax(EntryTime, SeatTime - FClamp(EntryLead, 0, 0.45) * Clip.RateScale);
    for (I = 0; I <= 16; ++I)
    {
        Pose(M, Seq, EntryTime + (InsertEndTime - EntryTime) * float(I) / 16.0);
        Relative(M, Root, AmmoTrack, Point.Position, Point.Rotation);
        if (!(VSize(Point.Position) >= 0 && VSize(Point.Position) <= 500
            && RotationMatch(Point.Rotation, Point.Rotation) >= 0.95
            && RotationMatch(Point.Rotation, Point.Rotation) <= 1.05))
        { Path.Length = 0; FailureReason = "invalid-shell-pose"; return false; }
        Path.AddItem(Point);
    }
    EntryLocal = Path[0].Position; EntryLocalQ = Path[0].Rotation;
    SeatLocal = Path[16].Position; SeatLocalQ = Path[16].Rotation;
    InsertLength = VSize(SeatLocal - EntryLocal);
    for (I = 1; I < Path.Length; ++I) PathLength += VSize(Path[I].Position - Path[I - 1].Position);
    if (!(InsertLength > 0.1 && PathLength < 30))
    { Path.Length = 0; FailureReason = "invalid-shell-path"; return false; }
    Pose(M, Seq, EntryTime);
    Relative(M, Root, Hand, HandLocal, HandLocalQ);
    CarryTime = EntryTime; CarryLocal = EntryLocal; CarryLocalQ = EntryLocalQ;
    if (class'VRPumpCatalog'.static.CoversMesh(M.SkeletalMesh.Name)
        && (Anim == 'Reload_Open_Shell' || Anim == 'Reload_Open_Shell_Elite'))
    {
        // Search only before entry: the later open palm and the returning
        // hand are not carry grips. This search does not lengthen Path.
        BestScore = 100000;
        for (I = 0; I <= 64; ++I)
        {
            LatestTime = CarrySearchEnd * float(I) / 64.0;
            Pose(M, Seq, LatestTime);
            Relative(M, AmmoTrack, Hand, HandPosition, HandRotation);
            Distance = RackFingerContact(M, AmmoTrack, Hand);
            HandDistance = VSize(HandPosition);
            if (!(Distance >= 0 && Distance <= 6 && HandDistance >= 0 && HandDistance <= 24)) continue;
            Score = Distance + HandDistance;
            if (Score >= BestScore) continue;
            BestScore = Score; CarryTime = LatestTime;
        }
        Pose(M, Seq, CarryTime);
        Relative(M, Root, AmmoTrack, CarryLocal, CarryLocalQ);
        Relative(M, Root, Hand, HandLocal, HandLocalQ);
    }
    return true;
}

// The mesh must be private, attached and at identity. Rack is optional: a
// valid insertion still succeeds when no safe translation action is found.
// The mesh is left on the reload entry pose, with notifies disabled.
function bool Sample(KFSkeletalMeshComponent M, AnimNodeSequence Seq, name Anim,
    name Root, name Spare, name Hand, name Rack, float EntryLead, optional name Loaded, optional name Follow)
{
    local AnimSequence Clip;
    local int I;
    local bool bFoundNotify;
    local InsertPose Point;
    local vector Correction;
    local quat EndQ;
    local float Blend;

    Reset();
    if (M == None || M.SkeletalMesh == None || Seq == None)
    { FailureReason = "missing-component"; return false; }
    Seq.bNoNotifies = true;
    Seq.bPlaying = false;
    if (Loaded == '') Loaded = 'RW_Magazine1';
    if (Root == '' || Spare == '' || Hand == '' || M.MatchRefBone(Root) < 0
        || M.MatchRefBone(Loaded) < 0 || M.MatchRefBone(Spare) < 0 || M.MatchRefBone(Hand) < 0)
    { FailureReason = "missing-insert-bone"; return false; }
    if (Anim == '') { FailureReason = "missing-reload"; return false; }
    if (M.SkeletalMesh.Name == 'Wep_1stP_Minigun_Rig')
        return SampleBoxInsert(M, Seq, Anim, Root, Loaded, Hand, true);
    Seq.SetAnim(Anim);
    Clip = Seq.AnimSeq;
    if (Clip == None || Clip.SequenceLength <= 0 || Clip.RateScale <= 0)
    { FailureReason = "invalid-reload"; return false; }
    // GetReloadAmmoTime returns zero on a missing notify and divides by the
    // clip rate. Inspect the actual event instead of clamping failure to t=0.
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        if (Clip.Notifies[I].Notify == None
            || !ClassIsChildOf(Clip.Notifies[I].Notify.Class, class'KFAnimNotify_ReloadAmmo')) continue;
        SeatTime = Clip.Notifies[I].Time;
        bFoundNotify = true;
        break;
    }
    if (!bFoundNotify || SeatTime <= 0 || SeatTime > Clip.SequenceLength)
    { FailureReason = "invalid-ammo-notify"; return false; }
    EntryTime = FMax(SeatTime - FMax(EntryLead, 0) * Clip.RateScale, 0);
    if (M.FindAnimSequence('Idle') == None)
    { FailureReason = "missing-idle-seat"; return false; }
    Seq.SetAnim('Idle');
    Pose(M, Seq, 0);
    Relative(M, Root, Loaded, SeatLocal, SeatLocalQ);
    Seq.SetAnim(Anim);
    if (bSeatAtNotify)
    {
        Pose(M, Seq, SeatTime);
        Relative(M, Root, Loaded, SeatLocal, SeatLocalQ);
    }
    if (!SelectAmmoTrack(M, Seq, Root, Loaded, Spare, Clip.SequenceLength, Clip.RateScale))
    { FailureReason = "no-incoming-magazine"; return false; }
    FindInsertEnd(M, Seq, Root, Clip.SequenceLength, Clip.RateScale);
    // The reconstructor's empty reload covers more than 30 UU in the fixed
    // entry lead. Keep its authored final eight-unit approach, like box inserts,
    // instead of rejecting an otherwise valid reload for the long hand reach.
    if (M.SkeletalMesh.Name == 'Wep_1stP_HMTech_Mine_Reconstructor_Rig')
        TrimLongInsertApproach(M, Seq, Root);
    // Corrupter's stock carry begins almost thirty units below its well.
    // Only its final approach is an insertion contact, as for box feeds.
    // Its separately sampled earlier carry grip still follows the right hand.
    if (M.SkeletalMesh.Name == 'Wep_1stP_ParasiteImplanter_Rig')
        TrimLongInsertApproach(M, Seq, Root, 8);
    for (I = 0; I <= 16; ++I)
    {
        Pose(M, Seq, EntryTime + (InsertEndTime - EntryTime) * float(I) / 16.0);
        Relative(M, Root, AmmoTrack, Point.Position, Point.Rotation);
        Path.AddItem(Point);
    }
    // Preserve the authored curve, with only its final quarter eased onto the
    // exact idle loaded pose. The prop then meets the real mesh when stock
    // presentation returns, rather than remaining a few units below the well.
    Correction = SeatLocal - Path[16].Position;
    SeatCorrection = VSize(Correction);
    EndQ = Path[16].Rotation;
    if (SeatCorrection > 6 || RotationMatch(EndQ, SeatLocalQ) < 0.98480775)
    { Path.Length = 0; FailureReason = "unseated-magazine"; return false; }
    for (I = 13; I <= 16; ++I)
    {
        Blend = float(I - 12) / 4.0;
        Blend = Blend * Blend * (3 - 2 * Blend);
        Path[I].Position += Correction * Blend;
        Path[I].Rotation = QuatProduct(QuatSlerp(QuatFromRotator(rot(0,0,0)),
            QuatProduct(SeatLocalQ, QuatInvert(EndQ)), Blend, true), Path[I].Rotation);
    }
    Path[16].Position = SeatLocal; Path[16].Rotation = SeatLocalQ;
    EntryLocal = Path[0].Position; EntryLocalQ = Path[0].Rotation;
    InsertLength = VSize(SeatLocal - EntryLocal);
    for (I = 1; I < Path.Length; ++I) PathLength += VSize(Path[I].Position - Path[I - 1].Position);
    SampleRack(M, Seq, Anim, Root, Rack, Clip.SequenceLength, Hand, Follow);
    if (!bRackSampled && Rack != '' && Anim == 'Reload_Empty_Elite')
    {
        Seq.SetAnim('Reload_Empty');
        if (Seq.AnimSeq != None && Seq.AnimSeq.SequenceLength > 0 && AmmoNotifyTime(Seq.AnimSeq) > 0)
            SampleRack(M, Seq, 'Reload_Empty', Root, Rack, Seq.AnimSeq.SequenceLength, Hand, Follow,
                AmmoNotifyTime(Seq.AnimSeq));
    }
    Seq.SetAnim(Anim);
    Pose(M, Seq, EntryTime);
    Relative(M, Root, Hand, HandLocal, HandLocalQ);
    return true;
}
