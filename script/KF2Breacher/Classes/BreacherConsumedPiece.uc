// Permanent local mark on an original pawn's connected piece. Never clones a
// mesh, reparents a retained limb, or hides/terminates a skeleton subtree.
// Each observer owns its mark after the replicated burst resolves its payload;
// a server corpse/channel expiring does not resurrect a client's ragdoll.
class BreacherConsumedPiece extends Actor;

var KFPawn_Monster Payload;
var name PieceRoot;
var array<name> ConsumedBones;
var SkeletalMeshComponent NativeConsumedMesh;
var int NativeConsumedCount, NativeConsumedReady, NativeQueryResult;
var int NativeConsumedIndices[1024];
var SkeletalMesh SnapshotMesh;
var PhysicsAssetInstance AppliedPhysics;
var bool bSnapshot;
var float BornAt;

static simulated function name ConnectedRoot(SkeletalMeshComponent Mesh, name Bone)
{
    local name ParentBone;
    local int Depth;
    if (Mesh == None || Bone == '' || Mesh.MatchRefBone(Bone) == INDEX_NONE) return '';
    for (Depth=0; Depth<1024; ++Depth)
    {
        if (Mesh.PhysicsAssetInstance != None && Mesh.IsBrokenConstraint(Bone)) return Bone;
        ParentBone=Mesh.GetParentBone(Bone);
        if (ParentBone=='' || ParentBone==Bone) return Bone;
        Bone=ParentBone;
    }
    return '';
}

static simulated function bool IsConsumed(KFPawn_Monster M, name Bone)
{
    local BreacherConsumedPiece P;
    if (M==None || Bone=='') return false;
    foreach M.DynamicActors(class'BreacherConsumedPiece',P)
        if (!P.bDeleteMe && P.Payload==M && P.CanConsume() && (P.ConsumedBones.Find(Bone)!=INDEX_NONE || P.PieceRoot==Bone)) return true;
    return false;
}

static simulated function BreacherConsumedPiece Consume(KFPawn_Monster M, name SelectedRoot)
{
    local BreacherConsumedPiece P;
    local int Count;
    if (M==None || M.bDeleteMe || M.Mesh==None || SelectedRoot=='' || M.Mesh.MatchRefBone(SelectedRoot)==INDEX_NONE) return None;
    foreach M.DynamicActors(class'BreacherConsumedPiece',P)
    {
        if (P.bDeleteMe) continue;
        if (P.Payload==M && P.PieceRoot==SelectedRoot) return P;
        if (++Count>=64) return None;
    }
    P=M.Spawn(class'BreacherConsumedPiece',M,,M.Location);
    if (P==None) return None;
    P.Payload=M;
    P.PieceRoot=SelectedRoot;
    P.Tag=SelectedRoot;
    P.Snapshot();
    return P;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    BornAt=WorldInfo.TimeSeconds;
}

simulated function Snapshot()
{
    local array<name> Names;
    local int I;
    if (bSnapshot || Payload==None || Payload.Mesh==None || Payload.Mesh.PhysicsAssetInstance==None) return;
    // Snapshot the current connected set ONCE. Later severing does not expand
    // or redirect the already consumed set to the part still in another hand.
    Payload.Mesh.GetBoneNames(Names);
    if (Names.Length==0 || Names.Length>1024 || ConnectedRoot(Payload.Mesh,PieceRoot)!=PieceRoot) return;
    for (I=0; I<Names.Length; ++I)
        if (ConnectedRoot(Payload.Mesh,Names[I])==PieceRoot) ConsumedBones.AddItem(Names[I]);
    if (ConsumedBones.Length==0) return;
    bSnapshot=true;
    RefreshMesh();
}

simulated function bool CanConsume()
{
    return Payload!=None && !Payload.bDeleteMe && Payload.Mesh!=None
        && ((Payload.Health<=0 && Payload.bPlayedDeath)
            || (Payload.Mesh.PhysicsAssetInstance!=None && Payload.Mesh.IsBrokenConstraint(PieceRoot)));
}

simulated function RefreshMesh()
{
    local int I, Index;
    if (!bSnapshot || Payload==None || Payload.Mesh==None) return;
    NativeConsumedReady=0;
    NativeConsumedMesh=Payload.Mesh;
    SnapshotMesh=Payload.Mesh.SkeletalMesh;
    NativeConsumedCount=0;
    for (I=0; I<ConsumedBones.Length && NativeConsumedCount<1024; ++I)
    {
        Index=NativeConsumedMesh.MatchRefBone(ConsumedBones[I]);
        if (Index!=INDEX_NONE) NativeConsumedIndices[NativeConsumedCount++]=Index;
    }
    AppliedPhysics=None;
    if (CanConsume()) DisableBodies();
    NativeConsumedReady=(NativeConsumedCount>0 && CanConsume()) ? 1 : 0;
}

simulated function DisableBodies()
{
    local int I;
    local RB_BodyInstance Body;
    if (NativeConsumedMesh==None || NativeConsumedMesh.PhysicsAssetInstance==None) return;
    // Select exact body names, not TermBodiesBelow/HideBone's hierarchy.
    for (I=0; I<ConsumedBones.Length; ++I)
    {
        Body=NativeConsumedMesh.FindBodyInstanceNamed(ConsumedBones[I]);
        if (Body==None || !Body.IsValidBodyInstance()) continue;
        Body.SetBlockRigidBody(false);
        Body.EnableCollisionResponse(false);
        Body.SetContactReportForceThreshold(-1);
    }
    AppliedPhysics=NativeConsumedMesh.PhysicsAssetInstance;
}

// Stock-only synchronous query for KF2VR, with collision disabled. The caller
// supplies its exact component and reference-bone index in HitLocation.X.
simulated event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    local int I, Index;
    NativeQueryResult=0;
    SetDrawScale(1);
    if (!bSnapshot || !CanConsume() || Other!=Payload || OtherComp!=NativeConsumedMesh) return;
    Index=int(HitLocation.X);
    if (HitLocation.X!=float(Index) || Index<0 || Index>=1024) return;
    for (I=0; I<NativeConsumedCount; ++I)
        if (NativeConsumedIndices[I]==Index) { NativeQueryResult=1; SetDrawScale(2); return; }
}

// Physics reconstruction can reuse the same PhysicsAssetInstance address.
// The retention owner explicitly reapplies exact consumed-body exclusions.
simulated event UnTouch(Actor Other)
{
    if (Other!=Payload || !CanConsume()) return;
    if (!bSnapshot) Snapshot();
    if (!bSnapshot) return;
    if (NativeConsumedMesh!=Payload.Mesh || SnapshotMesh!=Payload.Mesh.SkeletalMesh) RefreshMesh();
    DisableBodies();
}

simulated event Tick(float Delta)
{
    if (Payload==None || Payload.bDeleteMe || Payload.Mesh==None) { Destroy(); return; }
    if (!CanConsume())
    {
        NativeConsumedReady=0;
        if (WorldInfo.TimeSeconds-BornAt>2) Destroy();
        return;
    }
    if (!bSnapshot)
    {
        Snapshot();
        // Dedicated corpses have no local ragdoll; retain only their exact
        // canonical-root tombstone, without guessing descendant ownership.
        if (!bSnapshot && WorldInfo.NetMode!=NM_DedicatedServer && WorldInfo.TimeSeconds-BornAt>2) Destroy();
        return;
    }
    if (NativeConsumedMesh!=Payload.Mesh || SnapshotMesh!=Payload.Mesh.SkeletalMesh) RefreshMesh();
    else if (AppliedPhysics!=NativeConsumedMesh.PhysicsAssetInstance) DisableBodies();
    if (bSnapshot && NativeConsumedCount>0) NativeConsumedReady=1;
}

simulated event Destroyed()
{
    NativeConsumedReady=0;
    NativeConsumedMesh=None;
    AppliedPhysics=None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
}
