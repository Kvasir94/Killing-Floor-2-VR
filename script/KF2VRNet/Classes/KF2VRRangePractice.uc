// Explicit player-operated in-memory practice. No files, automation or input replay.
class KF2VRRangePractice extends VRRangePracticeBase dependsOn(KF2VRNetTypes);
struct PracticeFrame
{
    var KF2VRNetTypes.NetPoseSnapshot Pose;
    var float At;
    var vector Velocity;
    var bool bCrouched;
};
var KF2VRRangeDummy Dummy;
var KF2VRNetPose DummyPose, SourcePose;
var array<PracticeFrame> Frames;
var bool bRecording, bPlaying;
var float Started, NextSample;
var int FrameIndex, LastRevision, Sequence;
var vector DummyOrigin, TossOrigin;
var rotator DummyFacing;
var float TossSpeedScale, RepeatSeconds, NextToss;
var bool bRepeatToss, bTossToward;
var KFPawn_Human TossUser;
var array<VRWorldMagazineRegistry> BenchRegistries;
var int BenchSerial;
var KF2VRRangeLocalPose LocalPose;

event PostBeginPlay()
{
    Super.PostBeginPlay();
    if (Role==ROLE_Authority && WorldInfo.NetMode==NM_Standalone)
        LocalPose=Spawn(class'KF2VRRangeLocalPose',self);
}
function bool PlayerContactHand(KFPawn_Human User,int Hand,out vector At,out byte Pose,out int Revision)
{
    return LocalPose!=None && LocalPose.PlayerContactHand(User,Hand,At,Pose,Revision);
}

function bool SpawnMagazine(KFPawn_Human H, bool bPartial)
{
    local KFWeapon W;
    local VRWorldMagazineRegistry R;
    local VRWorldDropMagazine P;
    local int I, Rounds;
    W=KFWeapon(H.Weapon);
    if (W==None || class'VRReloadCatalog'.static.FindClass(class'VRWeaponDropState'.static.FamilyFor(W.Class))<0)
    { StatusText="Hold a supported detachable-magazine gun"; return false; }
    for (I=0; I<BenchRegistries.Length; ++I)
        if (BenchRegistries[I]!=None && !BenchRegistries[I].bDeleteMe && BenchRegistries[I].Human==H) break;
    if (I==BenchRegistries.Length)
    {
        R=Spawn(class'VRWorldMagazineRegistry');
        if (R==None) return false;
        R.bIndependentLedger=true; R.bPublic=true; R.Human=H;
        R.Ledger=new(R) class'VRMagazinePayloadLedger';
        R.Reactions=new(R) class'VRWorldDropReactions';
        if (!R.Ledger.Initialize(R,H)) { R.Destroy(); return false; }
        BenchRegistries.AddItem(R);
    }
    R=BenchRegistries[I];
    Rounds=Max(1,W.MagazineCapacity[0]);
    if (bPartial) Rounds=Max(1,Rounds/2);
    ++BenchSerial;
    // Explicit range ammo grant. Register through the same authority ledger
    // as a paid removal, isolated from live reload sequence IDs.
    if (!R.Ledger.RegisterRemoved(W,BenchSerial,Rounds)) return false;
    R.Ledger.SetPublic(BenchSerial,true);
    P=R.PublishPayload(BenchSerial);
    if (P==None) return false;
    P.SetLocation(vect(-500,-1250,125));
    P.bRemovalPresented=true; P.Linear=vect(0,0,0);
    StatusText="Magazine ready: "$Rounds$" rounds";
    return true;
}
function ClearLooseMagazines()
{
    local VRWorldDropMagazine P;
    if (Role!=ROLE_Authority) return;
    foreach WorldInfo.AllActors(class'VRWorldDropMagazine',P)
    {
        // A live hand lease or guided extraction is still an interaction.
        if (P.bDeleteMe || P.Carrier!=None || P.ExitRegistry!=None || P.bLocalLease) continue;
        if (P.Registry!=None && !P.Registry.bDeleteMe && P.Registry.Ledger!=None)
        {
            if (P.Registry.Ledger.DiscardLoose(P.RemovalToken)) P.Destroy();
        }
        // Older solo ejections carry their paid rounds on the actor itself.
        // They have no ledger token or later publication to invalidate.
        else if (P.RemovalToken==0) P.Destroy();
    }
    StatusText="Loose magazines cleared";
}

event Trigger(Actor Other, Pawn EventInstigator)
{
    local KFPawn_Human H;
    if (Other==None || Role!=ROLE_Authority) return;
    H=KFPawn_Human(EventInstigator);
    if (H==None) return;
    switch (Other.Tag)
    {
    case 'FreshMag': SpawnMagazine(H,false); break;
    case 'PartialMag': SpawnMagazine(H,true); break;
    case 'ClearMags': ClearLooseMagazines(); break;
    case 'RespawnDummy': RespawnDummy(H,vect(-900,-1100,100),rot(0,0,0)); break;
    case 'Record': StartRecording(H); break;
    case 'StopRecord': StopRecording(); break;
    case 'Play': PlayRecording(); break;
    case 'HoldPose': HoldPose(H); break;
    case 'TossUp': bTossToward=false; TossNearest(H,false); break;
    case 'TossToward': bTossToward=true; TossNearest(H,true); break;
    case 'TossSlow': TossSpeedScale=0.65; break;
    case 'TossFast': TossSpeedScale=1.3; break;
    case 'TossRepeat': bRepeatToss=true; TossUser=H; NextToss=WorldInfo.RealTimeSeconds+RepeatSeconds; break;
    case 'TossInterval': RepeatSeconds=RepeatSeconds>=5 ? 2 : 5; break;
    case 'TossStop': bRepeatToss=false; TossUser=None; break;
    case 'Reset':
        bRepeatToss=false; TossUser=None; ClearLooseMagazines();
        bRecording=false; bPlaying=false; Frames.Length=0;
        if (DummyPose!=None) DummyPose.Destroy();
        if (Dummy!=None) Dummy.Destroy();
        DummyPose=None; Dummy=None; StatusText="Practice stations reset";
        break;
    case 'ClearDummy':
    case 'ResetDummy':
        bRecording=false; bPlaying=false; Frames.Length=0;
        if (DummyPose!=None) DummyPose.Destroy();
        if (Dummy!=None) Dummy.Destroy();
        DummyPose=None; Dummy=None;
        StatusText="Dummy cleared";
        break;
    }
}

function bool ContactHand(int Hand, out KFPawn_Human Body, out vector At, out byte Pose, out int Revision)
{
    local KF2VRNetTypes.NetPoseSample S;
    if (bRecording || Dummy==None || Dummy.bDeleteMe || DummyPose==None || Frames.Length==0) return false;
    S=DummyPose.Snapshot.Sample;
    if ((S.TrackingFlags & (Hand==0 ? 2 : 4))==0) return false;
    Body=Dummy; Revision=DummyPose.Snapshot.Revision;
    At=Dummy.Location+((Hand==0 ? S.LeftPosition : S.RightPosition) >> Dummy.Rotation);
    Pose=Hand==0 ? S.LeftHandPose : S.RightHandPose;
    return true;
}

function bool RespawnDummy(KFPawn_Human Source, vector At, rotator Facing)
{
    if (Role != ROLE_Authority || Source == None) return false;
    if (DummyPose != None) DummyPose.Destroy();
    if (Dummy != None) Dummy.Destroy();
    DummyOrigin=At; DummyFacing=Facing;
    Dummy=Spawn(class'KF2VRRangeDummy',,,At,Facing,,true);
    if (Dummy == None) return false;
    Dummy.AppearanceSource=Source;
    Dummy.BindAppearance();
    DummyPose=Spawn(class'KF2VRNetPose');
    if (DummyPose == None) { Dummy.Destroy(); return false; }
    // This is a separate presentation actor, never the user's owning channel.
    // Its own identity stays constant for this dummy lifetime only.
    DummyPose.Initialize(Dummy,1,1,1,1);
    DummyPose.bIndependentWeapons=true;
    return HoldPose(Source);
}

function KF2VRNetPose FindSource(KFPawn_Human Source)
{
    local KF2VRNetPose P;
    foreach WorldInfo.AllActors(class'KF2VRNetPose',P)
        if (P != DummyPose && P.TargetPawn == Source && P.Snapshot.Sample.TrackingFlags != 0) return P;
    return None;
}
function bool StartRecording(KFPawn_Human Source)
{
    SourcePose=FindSource(Source);
    if (SourcePose == None) { StatusText="No live VR tracking available"; return false; }
    Frames.Length=0; FrameIndex=0; LastRevision=-1;
    bRecording=true; bPlaying=false; Started=WorldInfo.RealTimeSeconds;
    StatusText="Recording up to 20 seconds";
    return true;
}
function StopRecording() { bRecording=false; StatusText="Recording stopped: "$Frames.Length$" frames"; }
function bool PlayRecording()
{
    if (Frames.Length==0 || Dummy == None || Dummy.bDeleteMe)
    { StatusText="Respawn a dummy and record a clip first"; return false; }
    bRecording=false; bPlaying=true; FrameIndex=0; Started=WorldInfo.RealTimeSeconds;
    StatusText="Loop playing; walk around the dummy";
    return true;
}
function bool HoldPose(KFPawn_Human Source)
{
    local PracticeFrame F;
    SourcePose=FindSource(Source);
    if (SourcePose == None) { StatusText="No live VR tracking available"; return false; }
    F.Pose=SourcePose.Snapshot; F.At=0;
    F.bCrouched=Source.bIsCrouched;
    Frames.Length=0; Frames.AddItem(F);
    bRecording=false; bPlaying=false; FrameIndex=0;
    StatusText="Pose held; empty open hand enables high fives";
    return true;
}
function PresentFrame()
{
    local KF2VRNetTypes.NetPoseSample S;
    local vector Offset;
    local rotator Facing;
    if (DummyPose == None || Dummy == None || Dummy.bDeleteMe || Frames.Length==0) return;
    S=Frames[FrameIndex].Pose.Sample;
    S.WorldEpoch=1; S.ConnectionEpoch=1; S.PawnEpoch=1; S.CalibrationEpoch=1;
    Sequence=(Sequence+1)&65535; S.Sequence=Sequence;
    S.SampleMillis=int(WorldInfo.RealTimeSeconds*1000)&65535;
    Offset=(Frames[FrameIndex].Pose.RootPosition-Frames[0].Pose.RootPosition) << Frames[0].Pose.RootRotation;
    Facing=DummyFacing;
    Facing.Yaw=NormalizeRotAxis(Facing.Yaw+Frames[FrameIndex].Pose.RootRotation.Yaw-Frames[0].Pose.RootRotation.Yaw);
    S.RootYaw=Facing.Yaw;
    Dummy.SetLocation(DummyOrigin+(Offset >> DummyFacing)); Dummy.SetRotation(Facing);
    Dummy.ApplyCrouch(Frames[FrameIndex].bCrouched);
    Dummy.Velocity=(Frames[FrameIndex].Velocity << Frames[0].Pose.RootRotation) >> DummyFacing;
    DummyPose.LeftWeapon=Frames[FrameIndex].Pose.LeftWeapon;
    DummyPose.RightWeapon=Frames[FrameIndex].Pose.RightWeapon;
    DummyPose.PublishPose(S,Dummy,true);
}
event Tick(float DeltaTime)
{
    local PracticeFrame F;
    local float Now, Duration;
    if (Role != ROLE_Authority) return;
    Now=WorldInfo.RealTimeSeconds;
    if (bRepeatToss && Now>=NextToss)
    {
        NextToss=Now+RepeatSeconds;
        if (TossUser==None || TossUser.bDeleteMe || TossUser.Health<=0) bRepeatToss=false;
        else TossNearest(TossUser,bTossToward);
    }
    if (Now<NextSample) return;
    NextSample=FMax(NextSample+class'KF2VRNetTypes'.const.ClientPoseInterval,Now);
    if (bRecording)
    {
        if (SourcePose==None || SourcePose.bDeleteMe || Now-Started>=20 || Frames.Length>=2400)
            StopRecording();
        else if (SourcePose.Snapshot.Revision!=LastRevision && SourcePose.Snapshot.Sample.TrackingFlags!=0)
        {
            F.Pose=SourcePose.Snapshot; F.At=Now-Started;
            if (SourcePose.TargetPawn!=None)
            {
                F.Velocity=SourcePose.TargetPawn.Velocity;
                F.bCrouched=SourcePose.TargetPawn.bIsCrouched;
            }
            Frames.AddItem(F); LastRevision=F.Pose.Revision;
        }
        return;
    }
    if (bPlaying && Frames.Length>1)
    {
        Duration=Frames[Frames.Length-1].At;
        if (Now-Started>Duration) { Started=Now; FrameIndex=0; }
        while (FrameIndex+1<Frames.Length && Frames[FrameIndex+1].At<=Now-Started) ++FrameIndex;
    }
    PresentFrame();
}

// Relaunch only loose props at the marked pad. Ownership, ammo and catch
// authority remain in their production ledgers; held objects are untouched.
function bool TossNearest(KFPawn_Human Source, bool bTowardPlayer)
{
    local VRWorldDropGun Gun, BestGun;
    local VRWorldDropMagazine Mag, BestMag;
    local vector V, At;
    local float Distance, Best;
    if (Role!=ROLE_Authority || Source==None) return false;
    Best=Square(180);
    foreach WorldInfo.AllActors(class'VRWorldDropGun',Gun)
        if (!Gun.bDeleteMe && !Gun.bReturning && !Gun.bCatchPending && Gun.CanPickupBy(Source))
        {
            Distance=VSizeSq(Gun.Location-TossOrigin);
            if (Distance<Best) { Best=Distance; BestGun=Gun; }
        }
    foreach WorldInfo.AllActors(class'VRWorldDropMagazine',Mag)
        if (!Mag.bDeleteMe && Mag.Carrier==None && Mag.ExitRegistry==None && Mag.CanPickupBy(Source))
        {
            Distance=VSizeSq(Mag.Location-TossOrigin);
            if (Distance<Best) { Best=Distance; BestMag=Mag; BestGun=None; }
        }
    if (BestGun==None && BestMag==None)
    { StatusText="Place a loose gun or magazine on the toss pad"; return false; }
    At=TossOrigin+vect(0,0,50);
    V=vect(0,0,400);
    if (bTowardPlayer) V=(Source.Location+vect(0,0,35)-At)*1.25+vect(0,0,300);
    V*=TossSpeedScale;
    if (VSize(V)>650) V=Normal(V)*650;
    if (BestGun!=None)
    {
        BestGun.ClearEmbedded(true); BestGun.SetLocation(At);
        BestGun.SetPhysics(PHYS_RigidBody);
        if (BestGun.MyMeshComp==None) return false;
        BestGun.MyMeshComp.SetRBPosition(At);
        BestGun.MyMeshComp.SetRBLinearVelocity(V);
        BestGun.MyMeshComp.SetRBAngularVelocity(vect(0,2,0));
        BestGun.Velocity=V; BestGun.bGrounded=false;
        BestGun.PreviousPosition=BestGun.GrabPosition(); BestGun.bHavePrevious=true;
        BestGun.GripHistoryCount=0; BestGun.GripHistoryNext=0;
        BestGun.ReleasedAt=WorldInfo.RealTimeSeconds; BestGun.WorldReleasedAt=WorldInfo.TimeSeconds;
        BestGun.InvalidateBallisticContact(); BestGun.bForceNetUpdate=true;
    }
    else
    {
        BestMag.SetLocation(At); BestMag.Linear=V; BestMag.Angular=vect(0,2,0);
        BestMag.bGrounded=false; BestMag.LooseElapsed=0;
        BestMag.NextLooseUpdate=WorldInfo.RealTimeSeconds;
        BestMag.Started=WorldInfo.TimeSeconds; BestMag.bForceNetUpdate=true;
    }
    return true;
}
event Destroyed()
{
    if (LocalPose!=None) LocalPose.Destroy();
    if (DummyPose!=None) DummyPose.Destroy();
    if (Dummy!=None) Dummy.Destroy();
    Super.Destroyed();
}
defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    TossOrigin=(X=900,Y=-1100,Z=0)
    TossSpeedScale=1.0
    RepeatSeconds=3.0
    Tag=VRRangePractice
    TickGroup=TG_PreAsyncWork
}
