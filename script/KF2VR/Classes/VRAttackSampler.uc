// Which arm strikes at each impact of a Zed's melee attack (#210), measured
// from the stock animation itself: an off-screen copy of the Zed's mesh and
// AnimSets is posed at each KFAnimNotify_MeleeImpact of the attack clip, and
// the hand moving faster relative to the chest (over +-SampleSpan) struck.
// Results are cached per mesh and clip, so a server measures each clip once.
// The same measurement is dumped for the reverse-engineering notes by the
// replay op `attacksides` (tools/replay).
class VRAttackSampler extends Actor;

struct ImpactSide
{
    var AnimNotify Notify; // the stock KFAnimNotify_MeleeImpact
    var float Time;      // seconds into the clip
    var float Duration;  // swipe window, 0 for a single hit
    var int Sides;       // VRLivingArmLoss SIDE_LEFT / SIDE_RIGHT mask
    var float LeftSpeed, RightSpeed;
};

struct ClipSides
{
    var SkeletalMesh Mesh;
    var name Clip;
    var int Sides;       // union over the clip's impacts
    var array<ImpactSide> Impacts;
};

var SkeletalMeshComponent Probe;
var array<ClipSides> Cache;
var float SampleSpan;        // seconds either side of the impact
var float BothRatio;         // slower hand at least this fraction of the faster: both

static function VRAttackSampler Get(WorldInfo W)
{
    local VRAttackSampler S;
    foreach W.DynamicActors(class'VRAttackSampler', S) return S;
    return W.Spawn(class'VRAttackSampler');
}

function name HandBone(KFPawn_Monster M, int Side)
{
    local int I;
    local name Best;
    for (I = 0; I < M.HitZones.Length; ++I)
    {
        if (class'VRLivingArmLoss'.static.Side(M, I) != Side) continue;
        // The hand zone if there is one, else the farthest arm zone listed.
        if (M.HitZones[I].ZoneName == 'lhand' || M.HitZones[I].ZoneName == 'rhand') return M.HitZones[I].BoneName;
        Best = M.HitZones[I].BoneName;
    }
    return Best;
}

function name ChestBone(KFPawn_Monster M)
{
    local int I;
    for (I = 0; I < M.HitZones.Length; ++I)
        if (M.HitZones[I].ZoneName == 'chest') return M.HitZones[I].BoneName;
    return '';
}

function vector Relative(name Bone, name Chest)
{
    return Probe.GetBoneLocation(Bone, 1) - (Chest != '' ? Probe.GetBoneLocation(Chest, 1) : vect(0,0,0));
}

function vector PoseAt(AnimNodeSequence Seq, float T, name Bone, name Chest)
{
    Seq.SetPosition(FClamp(T, 0, Seq.GetAnimPlaybackLength()), false);
    Probe.ForceSkelUpdate();
    return Relative(Bone, Chest);
}

// Measure (or recall) one clip of M's. Index into Cache, or -1.
function int Measure(KFPawn_Monster M, name Clip)
{
    local AnimNodeSequence Seq;
    local AnimSequence Data;
    local ClipSides Entry;
    local ImpactSide Hit;
    local name LeftHand, RightHand, Chest;
    local float T, Faster, Slower;
    local int I;
    if (M == None || M.Mesh == None || M.Mesh.SkeletalMesh == None || Clip == '') return -1;
    for (I = 0; I < Cache.Length; ++I)
        if (Cache[I].Mesh == M.Mesh.SkeletalMesh && Cache[I].Clip == Clip) return I;
    Entry.Mesh = M.Mesh.SkeletalMesh;
    Entry.Clip = Clip;
    Seq = AnimNodeSequence(Probe.Animations);
    if (Seq != None)
    {
        if (Probe.SkeletalMesh != M.Mesh.SkeletalMesh) Probe.SetSkeletalMesh(M.Mesh.SkeletalMesh);
        Probe.AnimSets = M.Mesh.AnimSets;
        Seq.SetAnim(Clip);
        Data = Seq.AnimSeq;
        LeftHand = HandBone(M, class'VRLivingArmLoss'.const.SIDE_LEFT);
        RightHand = HandBone(M, class'VRLivingArmLoss'.const.SIDE_RIGHT);
        Chest = ChestBone(M);
        if (Data != None && LeftHand != '' && RightHand != '')
            for (I = 0; I < Data.Notifies.Length; ++I)
            {
                if (KFAnimNotify_MeleeImpact(Data.Notifies[I].Notify) == None) continue;
                Hit.Notify = Data.Notifies[I].Notify;
                Hit.Time = Data.Notifies[I].Time;
                Hit.Duration = Data.Notifies[I].Duration;
                T = Hit.Time + Hit.Duration * 0.5;
                Hit.LeftSpeed = VSize(PoseAt(Seq, T + SampleSpan, LeftHand, Chest) - PoseAt(Seq, T - SampleSpan, LeftHand, Chest)) / (2 * SampleSpan);
                Hit.RightSpeed = VSize(PoseAt(Seq, T + SampleSpan, RightHand, Chest) - PoseAt(Seq, T - SampleSpan, RightHand, Chest)) / (2 * SampleSpan);
                Faster = FMax(Hit.LeftSpeed, Hit.RightSpeed);
                Slower = FMin(Hit.LeftSpeed, Hit.RightSpeed);
                if (Faster <= 0) Hit.Sides = 3;
                else if (Slower >= Faster * BothRatio) Hit.Sides = 3;
                else Hit.Sides = Hit.LeftSpeed > Hit.RightSpeed ? class'VRLivingArmLoss'.const.SIDE_LEFT : class'VRLivingArmLoss'.const.SIDE_RIGHT;
                Entry.Sides = Entry.Sides | Hit.Sides;
                Entry.Impacts.AddItem(Hit);
            }
    }
    // A clip with no measurable impact counts as using both arms.
    if (Entry.Impacts.Length == 0) Entry.Sides = 3;
    Cache.AddItem(Entry);
    return Cache.Length - 1;
}

// The arms the impact nearest Position (seconds into Clip) uses.
function int SidesAt(KFPawn_Monster M, name Clip, float Position)
{
    local int I, J, Best;
    local float D, BestD;
    I = Measure(M, Clip);
    if (I < 0) return 3;
    if (Cache[I].Impacts.Length == 0) return Cache[I].Sides;
    BestD = -1;
    for (J = 0; J < Cache[I].Impacts.Length; ++J)
    {
        D = Abs(Position - (Cache[I].Impacts[J].Time + Cache[I].Impacts[J].Duration * 0.5));
        if (BestD < 0 || D < BestD) { BestD = D; Best = J; }
    }
    return Cache[I].Impacts[Best].Sides;
}

function int SidesOfClip(KFPawn_Monster M, name Clip)
{
    local int I;
    I = Measure(M, Clip);
    return I < 0 ? 3 : Cache[I].Sides;
}

// The melee clip M is playing, or ''.
function name MeleeClip(KFPawn_Monster M)
{
    local KFSM_MeleeAttack Attack;
    if (M == None || !M.IsDoingSpecialMove(SM_MeleeAttack) || M.SpecialMove >= M.SpecialMoves.Length) return '';
    Attack = KFSM_MeleeAttack(M.SpecialMoves[M.SpecialMove]);
    return Attack != None ? Attack.AnimName : '';
}

// The arms one stock impact notify uses. The clip it belongs to is measured
// on first use (the Zed is playing it, so MeleeClip names it).
function int SidesOfNotify(KFPawn_Monster M, AnimNotify Notify)
{
    local int I, J, Pass;
    for (Pass = 0; Pass < 2; ++Pass)
    {
        for (I = 0; I < Cache.Length; ++I)
            if (Cache[I].Mesh == M.Mesh.SkeletalMesh)
                for (J = 0; J < Cache[I].Impacts.Length; ++J)
                    if (Cache[I].Impacts[J].Notify == Notify) return Cache[I].Impacts[J].Sides;
        if (Pass == 0 && Measure(M, MeleeClip(M)) < 0) break;
    }
    return 3;
}
defaultproperties
{
    Begin Object Class=AnimNodeSequence Name=SampleSequence
    End Object
    Begin Object Class=SkeletalMeshComponent Name=SampleMesh
        Animations=SampleSequence
        bUpdateSkelWhenNotRendered=false
        HiddenGame=true
        HiddenEditor=true
        CastShadow=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    Probe=SampleMesh
    Components.Add(SampleMesh)
    SampleSpan=0.05
    BothRatio=0.6
    bHidden=true
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
}
