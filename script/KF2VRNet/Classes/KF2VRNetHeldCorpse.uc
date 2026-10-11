// A bounded continuation of an already authenticated living physics hold.
// Dedicated stock death destroys the knockdown ragdoll, disables mesh traces
// and gives the pawn two seconds. Preserve only this SAME authoritative mesh,
// using its last measured physics pose; never create a substitute shield.
class KF2VRNetHeldCorpse extends Actor;

struct BodyPose
{
    var name Bone;
    var matrix Frame;
    var vector LinearVelocity;
    var bool bBroken;
};
var KFPawn_Monster Subject;
var SkeletalMeshComponent HeldMesh;
var SkeletalMesh HeldModel;
var PhysicsAsset HeldAsset;
var array<BodyPose> Pose;
var name GripBone[2];
var float LastGrip[2], SnapshotTime;
var bool bReady, bRestored, bChangedPhysics, bClosing;
var bool bSavedZeroTrace, bSavedExtentTrace, bSavedRigidBlock;
var ETickingGroup SavedActorTick, SavedMeshTick;
var float CorpseLifeRemaining, CorpseSince, ReleasedUntil;
// Planned only from authenticated authority hands and authored gore joints.
// Never inferred from a client's detached pose or from InjuredHitZones alone.
var array<name> RendCuts;
var name RendHands[2];

static function KF2VRNetHeldCorpse Find(KF2VRNetPlayerController PC, KFPawn_Monster M)
{
    local KF2VRNetHeldCorpse H;
    foreach PC.DynamicActors(class'KF2VRNetHeldCorpse',H)
        if (H.Subject==M && H.Owner==PC && !H.bDeleteMe) return H;
    return None;
}

static function KF2VRNetHeldCorpse Begin(KF2VRNetPlayerController PC, KFPawn_Monster M)
{
    local KF2VRNetHeldCorpse H;
    if (PC==None || PC.Role!=ROLE_Authority || M==None || M.bDeleteMe) return None;
    foreach PC.DynamicActors(class'KF2VRNetHeldCorpse',H)
        if (H.Subject==M && !H.bDeleteMe)
            return H.Owner==PC ? H : None;
    // No fresh corpse claims: the dedicated server has no reliable copy of
    // an arbitrary client's already torn-off ragdoll or visual dismemberment.
    if (M.Health<=0 || M.bPlayedDeath || M.Physics!=PHYS_RigidBody || M.Mesh==None) return None;
    H=PC.Spawn(class'KF2VRNetHeldCorpse',PC);
    if (H==None) return None;
    H.Subject=M; H.Instigator=PC.Pawn; H.HeldMesh=M.Mesh; H.HeldModel=M.Mesh.SkeletalMesh; H.HeldAsset=M.Mesh.PhysicsAsset;
    if (!H.CapturePose()) { H.Destroy(); return None; }
    return H;
}

function bool SameGeometry()
{
    return Subject!=None && !Subject.bDeleteMe && HeldMesh!=None && Subject.Mesh==HeldMesh
        && HeldMesh.SkeletalMesh==HeldModel && HeldMesh.PhysicsAsset==HeldAsset;
}

function bool CapturePose(optional bool bForce)
{
    local int I;
    local RB_BodyInstance B;
    local BodyPose P;
    local array<BodyPose> Measured;
    if (!SameGeometry() || Subject.Health<=0 || Subject.bPlayedDeath || Subject.Physics!=PHYS_RigidBody
        || HeldAsset==None || HeldMesh.PhysicsAssetInstance==None
        || HeldAsset.BodySetup.Length==0 || HeldAsset.BodySetup.Length>128) return false;
    if (!bForce && bReady && WorldInfo.RealTimeSeconds-SnapshotTime<0.04) return true;
    for (I=0; I<HeldAsset.BodySetup.Length; ++I)
    {
        if (HeldAsset.BodySetup[I]==None) return false;
        P.Bone=HeldAsset.BodySetup[I].BoneName;
        B=HeldMesh.FindBodyInstanceNamed(P.Bone);
        if (P.Bone=='' || B==None || !B.IsValidBodyInstance()) return false;
        P.Frame=B.GetUnrealWorldTM(); P.LinearVelocity=B.GetUnrealWorldVelocity();
        if (!class'VRBodyHold'.static.FiniteVector(MatrixGetOrigin(P.Frame))
            || !class'VRBodyHold'.static.FiniteVector(P.LinearVelocity)) return false;
        P.bBroken=HeldMesh.IsBrokenConstraint(P.Bone);
        Measured.AddItem(P);
    }
    Pose=Measured; SnapshotTime=WorldInfo.RealTimeSeconds; bReady=true;
    return true;
}

// Validate the real asset graph, including named live constraint instances.
// Requiring the authored tree to match the skeleton also makes PieceRoot's
// broken-ancestor query truthful for downstream charge/throw ownership.
function bool RendGraphValid()
{
    local int I, Index;
    local RB_ConstraintSetup C;
    local RB_BodyInstance B;
    local name Parent;
    if (!SameGeometry() || HeldAsset==None || HeldMesh.PhysicsAssetInstance==None
        || HeldAsset.BodySetup.Length==0 || HeldAsset.BodySetup.Length>128
        || HeldAsset.ConstraintSetup.Length==0 || HeldAsset.ConstraintSetup.Length>256
        || HeldMesh.PhysicsAssetInstance.Constraints.Length!=HeldAsset.ConstraintSetup.Length) return false;
    for (I=0; I<HeldAsset.BodySetup.Length; ++I)
    {
        if (HeldAsset.BodySetup[I]==None) return false;
        B=class'VRBodyHold'.static.BodyFor(HeldMesh,HeldAsset.BodySetup[I].BoneName);
        if (B==None || !B.IsValidBodyInstance()) return false;
    }
    for (I=0; I<HeldAsset.ConstraintSetup.Length; ++I)
    {
        C=HeldAsset.ConstraintSetup[I];
        if (C==None || C.JointName=='' || C.ConstraintBone1!=C.JointName
            || C.ConstraintBone1==C.ConstraintBone2 || C.ConstraintBone2=='') return false;
        Index=HeldMesh.FindConstraintIndex(C.JointName);
        if (Index!=I || HeldMesh.PhysicsAssetInstance.Constraints[I]==None
            || HeldMesh.PhysicsAssetInstance.Constraints[I].ConstraintIndex!=I
            || HeldAsset.FindBodyIndex(C.ConstraintBone1)==INDEX_NONE
            || HeldAsset.FindBodyIndex(C.ConstraintBone2)==INDEX_NONE) return false;
        Parent=HeldMesh.GetParentBone(C.ConstraintBone1);
        if (Parent=='' || Subject.GetRBBoneFromBoneName(Parent)!=C.ConstraintBone2) return false;
    }
    return true;
}

// Exact physical graph reachability, with optional planned edges removed.
// This does not assume that a hit-zone label necessarily splits the hands.
function bool RendConnected(name A, name B, bool bPlan)
{
    local array<name> Seen;
    local int Cursor, I;
    local name Next;
    local RB_ConstraintSetup C;
    Seen.AddItem(A);
    for (Cursor=0; Cursor<Seen.Length && Cursor<128; ++Cursor)
    {
        if (Seen[Cursor]==B) return true;
        for (I=0; I<HeldAsset.ConstraintSetup.Length; ++I)
        {
            C=HeldAsset.ConstraintSetup[I];
            if (HeldMesh.PhysicsAssetInstance.Constraints[I].bTerminated
                || (bPlan && RendCuts.Find(C.JointName)!=INDEX_NONE)) continue;
            Next='';
            if (C.ConstraintBone1==Seen[Cursor]) Next=C.ConstraintBone2;
            else if (C.ConstraintBone2==Seen[Cursor]) Next=C.ConstraintBone1;
            if (Next!='' && Seen.Find(Next)==INDEX_NONE) Seen.AddItem(Next);
        }
    }
    return false;
}

function CancelRend()
{
    RendCuts.Length=0; RendHands[0]=''; RendHands[1]='';
}

function bool PlanRend(int Zone, name A, name B, class<KFDamageType> DamageType)
{
    local KFCharacterInfo_Monster Info;
    local KFGoreJointInfo Joint;
    local int I, J, K, Index;
    local name Cut;
    CancelRend();
    if (Subject==None || Subject.Health<=0 || Subject.bPlayedDeath || DamageType==None
        || Zone<0 || Zone>=Subject.HitZones.Length || A==B || !RendGraphValid()) return false;
    if (HeldAsset.FindBodyIndex(A)==INDEX_NONE || HeldAsset.FindBodyIndex(B)==INDEX_NONE
        || !RendConnected(A,B,false)) return false;
    Info=Subject.GetCharacterMonsterInfo();
    if (Info==None || Info.GoreJointSettings.Length>128) return false;
    Cut=Subject.HitZones[Zone].BoneName;
    for (I=0; I<Info.GoreJointSettings.Length; ++I)
        if (Info.GoreJointSettings[I]!=None && Info.GoreJointSettings[I].HitBoneName==Cut)
        {
            if (Joint!=None) return false;
            Joint=Info.GoreJointSettings[I];
        }
    if (Joint==None || Joint.bNonBreakableJoint || !DamageType.static.CanDismemberHitZone(Subject.HitZones[Zone].ZoneName)) return false;
    RendCuts.AddItem(Cut);
    if (Joint.DependentBreakGore.Length>32) { CancelRend(); return false; }
    for (J=0; J<Joint.DependentBreakGore.Length; ++J)
    {
        if (Joint.DependentBreakGore[J].ConstrainToDamageGroups.Length!=0
            && Joint.DependentBreakGore[J].ConstrainToDamageGroups.Find(DGT_None)==INDEX_NONE
            && Joint.DependentBreakGore[J].ConstrainToDamageGroups.Find(DamageType.default.GoreDamageGroup)==INDEX_NONE) continue;
        if (Joint.DependentBreakGore[J].DependentBones.Length>32) { CancelRend(); return false; }
        for (K=0; K<Joint.DependentBreakGore[J].DependentBones.Length; ++K)
        {
            Cut=Joint.DependentBreakGore[J].DependentBones[K].BoneName;
            // Stock BreakConstraint returns immediately for a missing index:
            // gore-only dependent bones are cosmetic, not physical edges.
            // Skip that exact no-op; never substitute an ancestor constraint.
            if (HeldMesh.FindConstraintIndex(Cut)==INDEX_NONE) continue;
            if (RendCuts.Find(Cut)==INDEX_NONE) RendCuts.AddItem(Cut);
            if (RendCuts.Length>32) { CancelRend(); return false; }
        }
    }
    for (I=0; I<RendCuts.Length; ++I)
    {
        Index=HeldMesh.FindConstraintIndex(RendCuts[I]);
        if (Index==INDEX_NONE || Index>=HeldAsset.ConstraintSetup.Length
            || HeldAsset.ConstraintSetup[Index].JointName!=RendCuts[I]) { CancelRend(); return false; }
    }
    if (RendConnected(A,B,true) || !CapturePose(true)) { CancelRend(); return false; }
    RendHands[0]=A; RendHands[1]=B;
    return true;
}

function bool ApplyRendCuts()
{
    local int I;
    if (RendCuts.Length==0) return true;
    if (!Subject.bPlayedDeath || Subject.Health>0 || !RendGraphValid()) return false;
    for (I=0; I<RendCuts.Length; ++I)
        if (!HeldMesh.IsBrokenConstraint(RendCuts[I])) HeldMesh.BreakConstraint(RendCuts[I]);
    for (I=0; I<RendCuts.Length; ++I)
        if (!HeldMesh.IsBrokenConstraint(RendCuts[I])) return false;
    Subject.bHasBrokenConstraints=true;
    if (RendConnected(RendHands[0],RendHands[1],false)
        || class'VRBodyHold'.static.SamePiece(HeldMesh,RendHands[0],RendHands[1])) return false;
    CancelRend();
    return true;
}

// Only the controller's validated grip stream calls this. The two leases are
// independent; loss of one hand must not cancel the other hand's piece.
function bool Refresh(byte Hand, name Bone)
{
    if (Hand>1 || !SameGeometry() || Bone=='' || HeldMesh.MatchRefBone(Bone)==INDEX_NONE) return false;
    if (class'VRBodyHold'.static.Consumed(HeldMesh,Bone)) return false;
    GripBone[Hand]=Bone; LastGrip[Hand]=WorldInfo.RealTimeSeconds;
    if (Subject.Health>0 && !Subject.bPlayedDeath) return true;
    if (!Subject.bPlayedDeath) return false;
    if (!bRestored && !RestoreCorpse()) return false;
    if (bRestored) Subject.LifeSpan=FMax(Subject.LifeSpan,2.0);
    return bRestored;
}

function bool RestoreCorpse()
{
    local int I;
    local RB_BodyInstance B;
    if (!bReady || !SameGeometry() || !Subject.bPlayedDeath
        || WorldInfo.RealTimeSeconds-SnapshotTime>1.5) return false;
    CorpseLifeRemaining=Subject.LifeSpan; CorpseSince=WorldInfo.TimeSeconds;
    bSavedZeroTrace=HeldMesh.BlockZeroExtent; bSavedExtentTrace=HeldMesh.BlockNonZeroExtent;
    bSavedRigidBlock=HeldMesh.BlockRigidBody;
    SavedActorTick=Subject.TickGroup; SavedMeshTick=HeldMesh.TickGroup;
    // A listen server may already have a real death ragdoll. Do not replace
    // its fresh death pose with the older living pose.
    if (Subject.Physics!=PHYS_RigidBody || HeldMesh.PhysicsAssetInstance==None)
    {
        Subject.PrepareRagdoll();
        if (!Subject.InitRagdoll()) return false;
        bChangedPhysics=true;
        // Validate every named body before restoring any transform.
        for (I=0; I<Pose.Length; ++I)
        {
            if (class'VRBodyHold'.static.Consumed(HeldMesh,Pose[I].Bone)) continue;
            B=HeldMesh.FindBodyInstanceNamed(Pose[I].Bone);
            if (B==None || !B.IsValidBodyInstance()) { StopGeometry(); return false; }
        }
        for (I=0; I<Pose.Length; ++I)
            if (Pose[I].bBroken && !HeldMesh.IsBrokenConstraint(Pose[I].Bone)) HeldMesh.BreakConstraint(Pose[I].Bone);
        for (I=0; I<Pose.Length; ++I)
        {
            if (class'VRBodyHold'.static.Consumed(HeldMesh,Pose[I].Bone)) continue;
            B=HeldMesh.FindBodyInstanceNamed(Pose[I].Bone);
            B.SetFixed(false);
            HeldMesh.SetRBPosition(MatrixGetOrigin(Pose[I].Frame),Pose[I].Bone);
            HeldMesh.SetRBRotation(MatrixGetRotator(Pose[I].Frame),Pose[I].Bone);
            HeldMesh.AddImpulse(Pose[I].LinearVelocity-B.GetUnrealWorldVelocity(),
                MatrixGetOrigin(Pose[I].Frame),Pose[I].Bone,true);
        }
        HeldMesh.SetRBChannel(RBCC_DeadPawn);
        HeldMesh.SetRBCollidesWithChannel(RBCC_BlockingVolume,false);
        HeldMesh.SetTickGroup(TG_PostAsyncWork); Subject.SetTickGroup(TG_PostAsyncWork);
    }
    if (!ApplyRendCuts()) { StopGeometry(); return false; }
    HeldMesh.SetTraceBlocking(true,true);
    HeldMesh.SetBlockRigidBody(true);
    HeldMesh.bUpdateKinematicBonesFromAnimation=false;
    HeldMesh.bNoSkeletonUpdate=false;
    HeldMesh.WakeRigidBody();
    ReapplyConsumedMasks();
    Subject.LifeSpan=FMax(Subject.LifeSpan,2.0);
    bRestored=true;
    return true;
}

// InitRagdoll/global block changes can reuse the same PhysicsAssetInstance.
// Force the exact optional piece mask now, not on a later pointer-change tick.
function ReapplyConsumedMasks()
{
    local Actor Marker;
    if (!SameGeometry()) return;
    foreach DynamicActors(class'Actor',Marker)
        if (!Marker.bDeleteMe && Marker.Class.Name=='BreacherConsumedPiece' && Marker.Owner==Subject)
            Marker.UnTouch(Subject);
}

function Release(byte Hand, optional vector Throw)
{
    if (Hand>1) return;
    GripBone[Hand]=''; LastGrip[Hand]=0;
    if (GripBone[0]=='' && GripBone[1]=='')
    {
        // A deliberate thrown corpse keeps its actual collision for the same
        // bounded impact window; it no longer has a hand-ownership lease.
        if (bRestored && !IsZero(Throw)) ReleasedUntil=WorldInfo.RealTimeSeconds+5;
        else Destroy();
    }
}

function StopGeometry()
{
    if (!SameGeometry() || !Subject.bPlayedDeath) return;
    // Only reverse physics introduced by this helper; a normal listen-server
    // ragdoll remains a stock corpse. Never resurrect or re-open replication.
    if (bRestored || bChangedPhysics)
    {
        HeldMesh.SetTraceBlocking(bSavedZeroTrace,bSavedExtentTrace);
        HeldMesh.SetBlockRigidBody(bSavedRigidBlock);
    }
    if (bChangedPhysics)
    {
        Subject.TermRagdoll();
        HeldMesh.SetTickGroup(SavedMeshTick); Subject.SetTickGroup(SavedActorTick);
        bChangedPhysics=false;
    }
    if (WorldInfo.NetMode==NM_DedicatedServer) Subject.LifeSpan=2.0;
    else Subject.LifeSpan=FMax(0.1,CorpseLifeRemaining-(WorldInfo.TimeSeconds-CorpseSince));
    ReapplyConsumedMasks();
}

event Tick(float Delta)
{
    local byte Hand;
    local KF2VRNetPlayerController PC;
    PC=KF2VRNetPlayerController(Owner);
    if (PC==None || PC.bDeleteMe || PC.Pawn==None || PC.Pawn!=Instigator || PC.Pawn.Health<=0 || !SameGeometry())
    { Destroy(); return; }
    for (Hand=0; Hand<2; ++Hand)
        if (GripBone[Hand]!='' && (WorldInfo.RealTimeSeconds-LastGrip[Hand]>0.75
            || class'VRBodyHold'.static.Consumed(HeldMesh,GripBone[Hand])))
        {
            PC.ExpireServerGrab(Hand,Subject);
            if (bDeleteMe) return;
        }
    if (GripBone[0]=='' && GripBone[1]=='')
    {
        if (!bRestored || WorldInfo.RealTimeSeconds>=ReleasedUntil) { Destroy(); return; }
        Subject.LifeSpan=FMax(Subject.LifeSpan,2.0);
        return;
    }
    if (Subject.Health>0 && !Subject.bPlayedDeath) CapturePose();
    else if (Subject.bPlayedDeath)
    {
        if (!bRestored && !RestoreCorpse()) { Destroy(); return; }
        Subject.LifeSpan=FMax(Subject.LifeSpan,2.0);
    }
}

event Destroyed()
{
    local KF2VRNetPlayerController PC;
    if (!bClosing)
    {
        bClosing=true;
        PC=KF2VRNetPlayerController(Owner);
        if (PC!=None && !PC.bDeleteMe)
        {
            if (GripBone[0]!='') PC.ExpireServerGrab(0,Subject);
            if (GripBone[1]!='') PC.ExpireServerGrab(1,Subject);
        }
        StopGeometry();
    }
    Super.Destroyed();
}

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
}
