// Local loose-weapon presentation. The exact actor stays in inventory;
// catching only rebinds it. A successful throw admits a separate authority
// contact for a modest stock Zed hit, with no pickup or ammo copy.
class VRLocalWeaponDrops extends Object dependsOn(VRWeaponThrowProfiles);

struct LocalDrop
{
    var VRWeaponRuntime Runtime;
    // One owned actor/ammo ledger, independently released Glock and shield.
    var int Component, ReleaseHand, ContactToken;
    var KFSkeletalMeshComponent Mesh;
    var vector Position, Velocity, Spin, LocalRoot, ReturnFrom, PrimaryGrip, SupportGrip;
    var quat Rotation, LocalRootQ;
    var VRWeaponThrowProfiles.ThrowProfile Profile;
    var vector CenterOfMass, Nose, Tail, Inertia, AngularMomentum;
    var quat BoreQ;
    var float Started, Delay, Radius, LastImpact;
    var int CalibrationEpoch, RoomEpoch, Bounces;
    var bool bResting, bReturning, bSupportContact;
    var bool bPulling;
    var int PullHand;
    var vector PullStart;
    var float PullStarted, PullDuration;
};
var array<LocalDrop> Drops;
var VRHandInventory Inventory;
var VRHandsBridge Bridge;
var float LastTime;
var int NextContactToken;
struct HandMotion
{
    var bool bReady, bCatchOpen, bCatchDown;
    var vector Position, BodyPosition, Linear, Angular, Transport;
    var quat Rotation, ToWorld;
    var float At;
    var int Samples;
};
var HandMotion Motion[2];
var VRThrowRelease LinearRelease, AngularRelease;
var float CatchUntil[2];
struct CatchFeedback
{
    var KFWeapon Weapon;
    var float At, Strength, Duration;
};
var CatchFeedback Echo[2];

function Initialize(VRHandInventory I)
{
    Inventory=I; Bridge=I.Bridge; LastTime=Bridge.WorldInfo.RealTimeSeconds;
    LinearRelease=new(self) class'VRThrowRelease';
    AngularRelease=new(self) class'VRThrowRelease';
    // Short spin window keeps a wrist flick instead of the heavy old weight cap.
    AngularRelease.IgnoreSeconds=0.012; AngularRelease.WindowSeconds=0.045;
}

function Remove(int I)
{
    StopContact(I);
    if (Drops[I].Mesh!=None)
    {
        Drops[I].Mesh.SetHidden(true);
        Bridge.DetachComponent(Drops[I].Mesh);
    }
    Drops.Remove(I,1);
}

function StopContact(int I)
{
    if (I < 0 || I >= Drops.Length || Drops[I].ContactToken <= 0 || Bridge == None) return;
    if (Drops[I].Runtime != None)
    {
        if (Bridge.WorldInfo.NetMode == NM_Client)
            Bridge.RequestNetworkThrownContact(Drops[I].Runtime.Item, Drops[I].ReleaseHand,
                Drops[I].ContactToken, vect(0,0,0), vect(0,0,0), true);
        else class'VRThrownWeaponFlight'.static.Stop(Bridge.PC, Drops[I].Runtime.Item, Drops[I].ContactToken);
    }
    Drops[I].ContactToken = 0;
}

function Cancel(KFWeapon W)
{
    local int I;
    for (I=Drops.Length-1; I>=0; --I)
        if (Drops[I].Runtime==None || Drops[I].Runtime.Item==W) Remove(I);
}

function CancelComponent(KFWeapon W, int Component)
{
    local int I;
    for (I=Drops.Length-1; I>=0; --I)
        if (Drops[I].Runtime==None || (Drops[I].Runtime.Item==W && Drops[I].Component==Component)) Remove(I);
}

function bool ComponentHeld(int I)
{
    local VRWeaponRuntime R;
    R=Drops[I].Runtime;
    if (R==None) return false;
    if (Drops[I].Component==1) return R.PrimaryHand>=0;
    if (Drops[I].Component==2) return R.SupportHand>=0;
    return R.PrimaryHand>=0 || R.SupportHand>=0;
}

function bool CanCatchDrop(int I)
{
    return I>=0 && I<Drops.Length && Eligible(Drops[I].Runtime) && !ComponentHeld(I)
        && Drops[I].Runtime.MechanismPending==0 && !Drops[I].bReturning
        && Bridge.WorldInfo.RealTimeSeconds-Drops[I].Started>=0.12;
}

function bool CatchDrop(int I, int Hand, byte Role, optional bool bGravityReceipt)
{
    local LocalDrop D;
    local VRWeaponRuntime R;
    if (!CanCatchDrop(I) || !FreeHand(Hand, bGravityReceipt)) return false;
    D=Drops[I]; R=D.Runtime;
    if (D.Component!=0) Role=byte(D.Component==2);
    if (!Inventory.CatchLocalComponent(R.Item,Hand,Role,D.Position,D.Rotation,D.Component)) return false;
    CancelComponent(R.Item,D.Component);
    if (Role==0)
    {
        R.CarryArmPrimaryToken=Hand+1;
        R.bCarryReleaseArmed=!Bridge.bToggleGrip; R.bCarrySawRelease=false;
    }
    Caught(D,Hand,Role);
    Inventory.PlaceAll(); CatchUntil[Hand]=0;
    return true;
}

function ResetIntent()
{
    local int H;
    for (H=0; H<2; ++H)
    {
        Motion[H].bReady=false; Motion[H].bCatchOpen=false; Motion[H].bCatchDown=true; CatchUntil[H]=0;
        Echo[H].Weapon=None;
        if (LinearRelease!=None) LinearRelease.Reset(H);
        if (AngularRelease!=None) AngularRelease.Reset(H);
    }
}

function Clear()
{
    ResetIntent();
    while (Drops.Length>0) Remove(Drops.Length-1);
    if (Bridge!=None) LastTime=Bridge.WorldInfo.RealTimeSeconds;
}

function Place(int I)
{
    local quat Q;
    Q=QuatProduct(Drops[I].Rotation,QuatInvert(Drops[I].LocalRootQ));
    Drops[I].Mesh.SetRotation(QuatToRotator(Q));
    Drops[I].Mesh.SetTranslation(Drops[I].Position-QuatRotateVector(Q,Drops[I].LocalRoot));
    Drops[I].Mesh.ForceUpdate(false);
}

function bool Begin(VRWeaponRuntime R, int ReleaseHand)
{
    local LocalDrop D;
    local AnimTree Tree;
    local AnimNodeSequence Seq;
    local name Root;
    local quat Q;
    local vector Muzzle, Bore, Center, HandAt;
    local int I,P;
    local array<name> Bones;
    if (Bridge==None || R==None || KFWeap_DualBase(R.Item)!=None || !R.IsCurrent() || R.Presenter==None
        || R.Item.MySkelMesh==None || R.Item.MySkelMesh.SkeletalMesh==None
        || !Inventory.ContextValid() || !Inventory.Input.ContextValid()) return false;
    P=R.Presenter.ActiveProfile;
    if (P<0 || P>=R.Presenter.WeaponProfiles.Length
        || R.Presenter.WeaponProfiles[P].bPhysicalDualGauntlets
        || (!R.Presenter.WeaponProfiles[P].bFirearm && !R.Presenter.WeaponProfiles[P].bPhysicalMelee)) return false;
    D.ReleaseHand=ReleaseHand;
    if (R.Item.Class==class'KFWeap_SMG_G18') D.Component=R.SupportHand==ReleaseHand ? 2 : 1;
    Root=D.Component==2 ? 'LW_Weapon' : R.Presenter.WeaponProfiles[P].RootBone;
    if (Root=='' || R.Item.MySkelMesh.MatchRefBone(Root)<0) return false;
    D.Position=R.Item.MySkelMesh.GetBoneLocation(Root);
    D.Rotation=R.Item.MySkelMesh.GetBoneQuaternion(Root);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(D.Position)
        || !class'VRHandRolePose'.static.ValidQuaternion(D.Rotation)) return false;
    CancelComponent(R.Item,D.Component);
    if (Drops.Length>=8) Remove(0);
    D.Mesh=new(Bridge) class'KFSkeletalMeshComponent';
    if (D.Mesh==None) return false;
    D.Mesh.SetSkeletalMesh(R.Item.MySkelMesh.SkeletalMesh);
    D.Mesh.AnimSets=R.Item.MySkelMesh.AnimSets;
    for (I=0; I<D.Mesh.SkeletalMesh.Materials.Length; ++I)
        D.Mesh.SetMaterial(I,R.Item.MySkelMesh.GetMaterial(I));
    D.Mesh.SetAbsolute(true,true,true);
    D.Mesh.SetActorCollision(false,false); D.Mesh.SetTraceBlocking(false,false);
    D.Mesh.SetBlockRigidBody(false); D.Mesh.CastShadow=false;
    D.Mesh.bCastDynamicShadow=false; D.Mesh.bUpdateSkelWhenNotRendered=true;
    D.Mesh.bTickAnimNodesWhenNotRendered=false;
    D.Mesh.SetDepthPriorityGroup(SDPG_World);
    D.Mesh.SetHidden(true);
    Tree=new(Bridge) class'AnimTree';
    Seq=new(Tree) class'AnimNodeSequence'; Seq.NodeName='VRLocalDropIdle';
    Seq.bNoNotifies=true; Seq.bPlaying=false;
    Tree.Children[0].Anim=Seq; Tree.Children[0].Weight=1;
    D.Mesh.SetAnimTreeTemplate(Tree); Bridge.AttachComponent(D.Mesh);
    Seq=AnimNodeSequence(D.Mesh.FindAnimNode('VRLocalDropIdle'));
    if (Seq!=None) { Seq.SetAnim(R.Presenter.WeaponProfiles[P].IdleAnimation); Seq.SetPosition(0,false); Seq.bPlaying=false; }
    // Preserve hidden magazine/spare-round geometry without copying any ammo.
    R.Item.MySkelMesh.GetBoneNames(Bones);
    for (I=0; I<Bones.Length; ++I)
        if (class'VRBoneVisibility'.static.IsHiddenIndex(R.Item.MySkelMesh,I)) class'VRBoneVisibility'.static.SetVisible(D.Mesh, Bones[I], false);
    if (D.Component!=0)
        class'VRBoneVisibility'.static.SetVisible(D.Mesh,D.Component==2 ? 'RW_Weapon' : 'LW_Weapon',false);
    D.Mesh.ForceSkelUpdate(); D.Mesh.ForceUpdate(false);
    class'VRLocalDropPose'.static.Capture(R.Item.MySkelMesh, D.Mesh, Root);
    D.LocalRoot=D.Mesh.GetBoneLocation(Root); D.LocalRootQ=D.Mesh.GetBoneQuaternion(Root);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(D.LocalRoot)
        || !class'VRHandRolePose'.static.ValidQuaternion(D.LocalRootQ))
    { Bridge.DetachComponent(D.Mesh); return false; }
    D.Runtime=R; D.Started=Bridge.WorldInfo.RealTimeSeconds;
    // Contacts are captured from this exact frozen pose, including a moved
    // pump and gun scale. Calibration offsets alone describe the idle pose.
    D.PrimaryGrip=QuatRotateVector(QuatInvert(D.Rotation),R.Presenter.PrimaryGripWorld()-D.Position);
    if (D.Component==2)
        D.PrimaryGrip=QuatRotateVector(QuatInvert(D.Rotation),Bridge.Hands[ReleaseHand].Position-D.Position);
    D.bSupportContact=Inventory.CarryEligible(R)
        && R.Presenter.GetSupportGripWorld(R.Item, D.SupportGrip, Q);
    if (D.bSupportContact)
        D.SupportGrip=QuatRotateVector(QuatInvert(D.Rotation),D.SupportGrip-D.Position);
    else D.SupportGrip=D.PrimaryGrip;
    if (R.Presenter.WeaponProfiles[P].SupportBone=='') D.SupportGrip=D.PrimaryGrip;
    if (D.Component!=0) { D.bSupportContact=false; D.SupportGrip=D.PrimaryGrip; }
    D.Profile=class'VRWeaponThrowProfiles'.static.ForWeapon(R.Item);
    D.BoreQ=QuatFromRotator(R.Presenter.WeaponProfiles[P].BoreRotation);
    Bore=QuatRotateVector(D.BoreQ,vect(1,0,0));
    if (R.Item.MySkelMesh.GetSocketWorldLocationAndRotation(R.Presenter.WeaponProfiles[P].MuzzleSocket,Muzzle)
        && class'VRReloadMotionGuard'.static.ValidPosition(Muzzle)
        && VSize(Muzzle-D.Position)<160)
        D.Nose=QuatRotateVector(QuatInvert(D.Rotation),Muzzle-D.Position);
    else D.Nose=D.PrimaryGrip+Bore*D.Profile.SizeCm.X*0.35;
    D.Tail=D.Nose-Bore*D.Profile.SizeCm.X*0.5;
    D.CenterOfMass=D.PrimaryGrip+(D.Nose-D.PrimaryGrip)*D.Profile.Balance
        -QuatRotateVector(D.BoreQ,vect(0,0,1))*D.Profile.SizeCm.Z*0.03;
    // Tracked space is 100 UU/metre, so kg*cm^2 is already kg*UU^2. A quarter
    // of it made every contact impulse spin the gun instead of bouncing it.
    D.Inertia=class'VRWeaponThrowProfiles'.static.Inertia(D.Profile);
    D.Radius=FClamp(FMin(D.Profile.SizeCm.Y,D.Profile.SizeCm.Z)*0.25,1.0,4.0);
    if (ReleaseHand>=0 && ReleaseHand<2 && Motion[ReleaseHand].bReady
        && Motion[ReleaseHand].Samples>=2 && D.Started-Motion[ReleaseHand].At<=0.05)
    {
        D.Velocity=QuatRotateVector(Motion[ReleaseHand].ToWorld,
            LinearRelease.Release(ReleaseHand,D.Started,Motion[ReleaseHand].Linear));
        D.Spin=QuatRotateVector(Motion[ReleaseHand].ToWorld,
            AngularRelease.Release(ReleaseHand,D.Started,Motion[ReleaseHand].Angular));
        class'VRWeaponThrowProfiles'.static.Release(D.Profile,QuatProduct(D.Rotation,D.BoreQ),D.Velocity,D.Spin);
        Center=D.Position+QuatRotateVector(D.Rotation,D.CenterOfMass);
        HandAt=ReleaseHand==0 ? Bridge.LeftPosition : Bridge.RightPosition;
        D.Velocity+=(D.Spin cross (Center-HandAt))+Motion[ReleaseHand].Transport;
        if (VSize(D.Velocity)>1400) D.Velocity=Normal(D.Velocity)*1400;
    }
    D.AngularMomentum=class'VRWeaponThrowProfiles'.static.Momentum(QuatProduct(D.Rotation,D.BoreQ),D.Inertia,D.Spin);
    D.CalibrationEpoch=Bridge.NativeCalibrationEpoch; D.RoomEpoch=Bridge.NativeRoomSpaceEpoch;
    D.Delay=Bridge.WorldDropReturnSeconds;
    if (D.Delay!=D.Delay || D.Delay<1 || D.Delay>300) D.Delay=5;
    Drops.AddItem(D); Place(Drops.Length-1); D.Mesh.SetHidden(false);
    return true;
}

// Called after the held-role release succeeds, never on a failed/stale toss.
function Released(KFWeapon W, int Hand)
{
    local int I;
    local vector Center;
    if (Hand<0 || Hand>1) return;
    Echo[Hand].Weapon=None;
    for (I=Drops.Length-1; I>=0; --I)
        if (Drops[I].Runtime!=None && Drops[I].Runtime.Item==W && Drops[I].ReleaseHand==Hand)
        {
            if (Drops[I].Component != 2 && Drops[I].ContactToken == 0
                && VSizeSq(Drops[I].Velocity) >= Square(220.0))
            {
                ++NextContactToken;
                if (NextContactToken <= 0) NextContactToken = 1;
                Drops[I].ContactToken = NextContactToken;
                Center = Drops[I].Position + QuatRotateVector(Drops[I].Rotation, Drops[I].CenterOfMass);
                if (Bridge.WorldInfo.NetMode == NM_Client)
                    Bridge.RequestNetworkThrownContact(W, Hand, NextContactToken, Center, Drops[I].Velocity);
                else class'VRThrownWeaponFlight'.static.Begin(Bridge.PC, Bridge.Human, W,
                    NextContactToken, Center, Drops[I].Velocity);
            }
            class'VRWorldHandlingAudio'.static.Play(Bridge,W.Class,false,Bridge.PalmPosition(Hand),Bridge);
            Bridge.QueueHandHaptic(1<<Hand,FClamp(0.12+0.04*Sqrt(Drops[I].Profile.MassKg),0.14,0.32),
                0.010+0.002*Sqrt(Drops[I].Profile.MassKg));
            return;
        }
}

function Caught(LocalDrop D, int Hand, byte Role)
{
    local vector Center, Grip, HandVelocity, Relative;
    local float Strength, Duration;
    Center=D.Position+QuatRotateVector(D.Rotation,D.CenterOfMass);
    Grip=D.Position+QuatRotateVector(D.Rotation,Role==1 ? D.SupportGrip : D.PrimaryGrip);
    if (Motion[Hand].bReady && Motion[Hand].Samples>=2 && Bridge.WorldInfo.RealTimeSeconds-Motion[Hand].At<=0.05)
        HandVelocity=QuatRotateVector(Motion[Hand].ToWorld,Motion[Hand].Linear)+Motion[Hand].Transport;
    Relative=D.Velocity+(D.Spin cross (Grip-Center))-HandVelocity;
    class'VRWeaponThrowProfiles'.static.CatchPulse(D.Profile,VSize(Relative),Strength,Duration);
    Bridge.QueueHandHaptic(1<<Hand,Strength,Duration);
    Echo[Hand].Weapon=D.Runtime.Item;
    Echo[Hand].At=Bridge.WorldInfo.RealTimeSeconds+Duration+0.012;
    Echo[Hand].Strength=Strength*0.35; Echo[Hand].Duration=Duration*0.45;
    class'VRWorldHandlingAudio'.static.Play(Bridge,D.Runtime.Item.Class,true,Bridge.PalmPosition(Hand),Bridge);
}

function UpdateFeedback(float Now)
{
    local int H;
    local VRWeaponRuntime R;
    for (H=0; H<2; ++H)
    {
        if (Echo[H].Weapon==None) continue;
        R=Inventory.GetHeldForHand(H);
        if (R==None || R.Item!=Echo[H].Weapon || !Inventory.CatchPoseContextValid(H))
        { Echo[H].Weapon=None; continue; }
        if (Now<Echo[H].At) continue;
        if (Now-Echo[H].At<0.04) Bridge.QueueHandHaptic(1<<H,Echo[H].Strength,Echo[H].Duration);
        Echo[H].Weapon=None;
    }
}

function bool Eligible(VRWeaponRuntime R)
{
    local int P;
    if (R==None || KFWeap_DualBase(R.Item)!=None || !R.IsCurrent() || R.Presenter==None || R.Item.MySkelMesh==None) return false;
    P=R.Presenter.ActiveProfile;
    return P>=0 && P<R.Presenter.WeaponProfiles.Length
        && !R.Presenter.WeaponProfiles[P].bPhysicalDualGauntlets
        && (R.Presenter.WeaponProfiles[P].bFirearm || R.Presenter.WeaponProfiles[P].bPhysicalMelee);
}

function SampleMotion()
{
    local int H;
    local float Now,DT,Angle,Alpha;
    local vector P,V,A,Axis,Transport;
    local quat Q,MapQ,D;
    local HandMotion S;
    if (!Inventory.Input.ContextValid() || Bridge.NativeHeadTracked==0
        || Bridge.NativeRecenterRequested!=0 || Bridge.NativeMenuActive!=0)
    { ResetIntent(); return; }
    Now=Bridge.WorldInfo.RealTimeSeconds;
    for (H=0; H<2; ++H)
    {
        // Losing the other controller must not erase this hand's one-handed
        // throw. Each room-space history has its own tracking admission.
        if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bridge.NativeRoomMotionMask & (1<<H))==0
            || Inventory.Input.IsSelectorOpen(H))
        {
            Motion[H].bReady=false; Motion[H].bCatchOpen=false; CatchUntil[H]=0;
            LinearRelease.Reset(H); AngularRelease.Reset(H); continue;
        }
        P=H==0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
        Q=QuatFromRotator(H==0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation);
        MapQ=QuatProduct(QuatFromRotator(H==0 ? Bridge.LeftRotation : Bridge.RightRotation),QuatInvert(Q));
        S=Motion[H]; DT=Now-S.At;
        if (!class'VRReloadMotionGuard'.static.ValidPosition(P)
            || !class'VRHandRolePose'.static.ValidQuaternion(MapQ))
        { Motion[H].bReady=false; continue; }
        if (S.bReady && DT>0 && DT<=0.08 && Abs(QuatDot(MapQ,S.ToWorld))>=0.999
            && VSize(P-S.Position)<=FMin(60,2+1800*DT))
        {
            V=(P-S.Position)/DT;
            // Room-space swing deliberately excludes locomotion. Add the
            // body's real-time displacement once at release so walking carries
            // a toss forward, including during Zed Time. Reject teleport jumps.
            Transport=(Bridge.Human.Location-S.BodyPosition)/DT;
            if (!class'VRGrenadeThrow'.static.Bounded(Transport,1200))
            { Motion[H].bReady=false; LinearRelease.Reset(H); AngularRelease.Reset(H); continue; }
            if (VSize(Transport)>700) Transport=Normal(Transport)*700;
            S.Transport=Transport;
            D=QuatProduct(Q,QuatInvert(S.Rotation));
            if (D.W<0) { D.X=-D.X; D.Y=-D.Y; D.Z=-D.Z; D.W=-D.W; }
            Axis.X=D.X; Axis.Y=D.Y; Axis.Z=D.Z;
            Angle=2*ACos(FClamp(D.W,-1,1));
            A=VSizeSq(Axis)>0.000001 ? Normal(Axis)*(Angle/DT) : vect(0,0,0);
            if (class'VRReloadMotionGuard'.static.ValidPosition(A))
            {
                // Bound spin without discarding valid translation from a fast
                // knife wrist flick. Real pose/space discontinuities still reset.
                if (VSize(A)>40) A=Normal(A)*40;
                LinearRelease.Add(H,V,Now); AngularRelease.Add(H,A,Now);
                Alpha=FClamp(DT/0.015,0,1);
                S.Linear+=(V-S.Linear)*Alpha; S.Angular+=(A-S.Angular)*Alpha; ++S.Samples;
            }
            else S.bReady=false;
        }
        else if (DT!=0) S.bReady=false;
        if (!S.bReady)
        {
            S.Linear=vect(0,0,0); S.Angular=vect(0,0,0); S.Transport=vect(0,0,0); S.Samples=0;
            LinearRelease.Reset(H); AngularRelease.Reset(H);
        }
        S.Position=P; S.BodyPosition=Bridge.Human.Location;
        S.Rotation=Q; S.ToWorld=MapQ; S.At=Now; S.bReady=true; Motion[H]=S;
    }
}

function int GravityIndex(KFSkeletalMeshComponent Mesh)
{
    local int I;
    if (Mesh==None) return -1;
    for (I=0; I<Drops.Length; ++I)
        if (Drops[I].Mesh==Mesh) return I;
    return -1;
}

function bool GravityAvailable(KFSkeletalMeshComponent Mesh)
{
    local int I;
    I=GravityIndex(Mesh);
    return I>=0 && CanCatchDrop(I) && !Drops[I].bReturning
        && Bridge.WorldInfo.RealTimeSeconds-Drops[I].Started>=0.12
        && Drops[I].CalibrationEpoch==Bridge.NativeCalibrationEpoch
        && Drops[I].RoomEpoch==Bridge.NativeRoomSpaceEpoch;
}

function vector GravityCenter(KFSkeletalMeshComponent Mesh)
{
    local int I;
    I=GravityIndex(Mesh);
    if (I<0) return vect(0,0,0);
    return Drops[I].Position+QuatRotateVector(Drops[I].Rotation,Drops[I].PrimaryGrip);
}

function bool BeginGravity(KFSkeletalMeshComponent Mesh, int Hand)
{
    local int I;
    I=GravityIndex(Mesh);
    if (Hand<0 || Hand>1 || !GravityAvailable(Mesh) || Drops[I].bPulling) return false;
    StopContact(I);
    Drops[I].bPulling=true; Drops[I].PullHand=Hand;
    Drops[I].PullStart=Drops[I].Position;
    Drops[I].PullStarted=Bridge.WorldInfo.RealTimeSeconds;
    Drops[I].PullDuration=FClamp(VSize(GravityCenter(Mesh)-Bridge.PalmPosition(Hand))/650.0,0.25,0.8);
    Drops[I].bResting=false;
    return true;
}

function EndGravity(KFSkeletalMeshComponent Mesh, int Hand)
{
    local int I;
    I=GravityIndex(Mesh);
    if (I<0 || !Drops[I].bPulling || Drops[I].PullHand!=Hand) return;
    Drops[I].bPulling=false;
    Drops[I].Started=Bridge.WorldInfo.RealTimeSeconds;
    Drops[I].Velocity=vect(0,0,0); Drops[I].Spin=vect(0,0,0);
    Drops[I].AngularMomentum=vect(0,0,0);
}

// The frozen component is local presentation, never a pickup or payload.
// Smooth arrival continually resolves the current palm while the exact owned
// runtime remains unchanged. Return 1 when ready, 0 in flight, -1 invalid.
function int StepGravity(KFSkeletalMeshComponent Mesh, int Hand)
{
    local int I;
    local float Age,U,S;
    local vector Goal, Next, At, Normal, CenterOffset;
    I=GravityIndex(Mesh);
    if (I<0 || !GravityAvailable(Mesh) || !Drops[I].bPulling || Drops[I].PullHand!=Hand) return -1;
    Age=Bridge.WorldInfo.RealTimeSeconds-Drops[I].PullStarted;
    if (Age>Drops[I].PullDuration+0.5) return -1;
    U=FClamp(Age/Drops[I].PullDuration,0,1); S=U*U*(3-2*U);
    // PrimaryGrip stores an authored wrist contact, including component2's
    // captured shield wrist. Land that contact on the tracked wrist exactly.
    Goal=Bridge.Hands[Hand].Position-QuatRotateVector(Drops[I].Rotation,Drops[I].PrimaryGrip);
    Next=Drops[I].PullStart+(Goal-Drops[I].PullStart)*S;
    // Receiver movement can put a wall across a path that was clear at lock.
    // Sweep the actual new segment and keep the owned loose item at contact;
    // a tracking jump or an obstruction must never become a teleport through it.
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Next)
        || !class'VRGrenadeThrow'.static.Bounded(Next-Drops[I].Position,160))
    { EndGravity(Mesh,Hand); return -1; }
    // Match the receiver sphere used by loose physics. A rotated gun's grip
    // root can sit below the floor while its physical center remains clear.
    CenterOffset=QuatRotateVector(Drops[I].Rotation,Drops[I].CenterOfMass);
    if (Bridge.Trace(At,Normal,Next+CenterOffset,Drops[I].Position+CenterOffset,false,
        vect(1,1,1)*FMax(1,Drops[I].Radius))!=None)
    {
        Drops[I].Position=At-CenterOffset+Normal*0.5;
        EndGravity(Mesh,Hand); Place(I); return -1;
    }
    Drops[I].Position=Next;
    Place(I);
    return U>=1 ? 1 : 0;
}

function bool CatchGravity(KFSkeletalMeshComponent Mesh, int Hand)
{
    local int I;
    I=GravityIndex(Mesh);
    return I>=0 && Drops[I].bPulling && Drops[I].PullHand==Hand && CatchDrop(I,Hand,0,true);
}

// Direct contact with an already held gun keeps its support/transfer input;
// the generous airborne zone must not steal that nearby deliberate squeeze.
function bool HeldContactReserved(int H)
{
    local VRWeaponRuntime R;
    local vector At, Palm;
    local quat Q;
    R=Inventory.Registry.GetPrimary(1-H);
    if (R==None || R.Presenter==None) return false;
    Palm=Bridge.PalmPosition(H);
    if (VSize(Palm-R.Presenter.PrimaryGripWorld())<=12) return true;
    return R.Presenter.GetSupportGripWorld(R.Item,At,Q) && VSize(Palm-At)<=12;
}

function bool FreeHand(int H, optional bool bGravityReceipt)
{
    return Inventory.CatchPoseContextValid(H) && Inventory.Registry.GetPrimary(H)==None
        && Inventory.Registry.GetSupport(H)==None && !Inventory.HasGauntletHand(H)
        && !Inventory.HasWorldGrab(H) && !Inventory.IsTransferPending(H)
        && !Inventory.Input.HandCarrying(H)
        && (bGravityReceipt || (!Inventory.Input.InBodyZone(H) && !HeldContactReserved(H)))
        && !Inventory.Input.IsSelectorOpen(0) && !Inventory.Input.IsSelectorOpen(1)
        && (Inventory.Input.Reloads==None || !Inventory.Input.Reloads.CoversHand(H))
        && (Inventory.GravityPull==None || !Inventory.GravityPull.OwnsHand(H));
}

function float CatchDistance(int I, vector Palm, out byte Role)
{
    local vector A,B,AB;
    local float PrimaryDistance,SupportDistance,T;
    A=Drops[I].Position+QuatRotateVector(Drops[I].Rotation,Drops[I].PrimaryGrip);
    B=Drops[I].Position+QuatRotateVector(Drops[I].Rotation,Drops[I].SupportGrip);
    PrimaryDistance=VSize(Palm-A); SupportDistance=VSize(Palm-B);
    Role=byte(Drops[I].bSupportContact && Bridge.bSupportHandCarry && SupportDistance<PrimaryDistance
        && SupportDistance<=(Drops[I].bResting ? 12 : 28));
    // Retain the existing receiver-to-grip catch corridor. A genuine nearby
    // foregrip contact now selects carry instead of moving to the trigger.
    AB=B-A;
    if (VSizeSq(AB)>0.01) T=FClamp(((Palm-A) dot AB)/VSizeSq(AB),0,1);
    return VSize(Palm-(A+AB*T));
}

// After reload/pocket admission and before ordinary grip actions. A fresh open
// then squeeze creates one short catch window; holding a fist never vacuums guns.
function UpdateCatch()
{
    local int H,I,Best;
    local byte Role,BestRole;
    local float Value,Now,Distance,Nearest,Radius;
    local bool Down;
    Now=Bridge.WorldInfo.RealTimeSeconds;
    for (H=0; H<2; ++H)
    {
        if (!FreeHand(H)) { Motion[H].bCatchOpen=false; Motion[H].bCatchDown=true; CatchUntil[H]=0; continue; }
        Value=H==0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
        Down=(Bridge.NativeGripMask & (1<<H))!=0 && Value>=0.65 && Value<=1.01;
        if (Inventory.Input.GripReleased(H)) Motion[H].bCatchOpen=true;
        if (Down && !Motion[H].bCatchDown && Motion[H].bCatchOpen) { CatchUntil[H]=Now+0.16; Motion[H].bCatchOpen=false; }
        Motion[H].bCatchDown=Down;
        if (!Down || CatchUntil[H]<=Now) continue;
        Best=-1; Nearest=100000;
        for (I=0; I<Drops.Length; ++I)
        {
            if (!CanCatchDrop(I)) continue;
            Radius=Drops[I].bResting ? 12 : 28;
            Distance=CatchDistance(I,Bridge.PalmPosition(H),Role);
            if (Distance<=Radius && Distance<Nearest
                && Bridge.FastTrace(Drops[I].Position,Bridge.PalmPosition(H))) { Best=I; BestRole=Role; Nearest=Distance; }
        }
        if (Best<0) continue;
        CatchDrop(Best,H,BestRole);
    }
}

// Three swept contact spheres cover the receiver, muzzle and rear of the gun.
// Zed body contact also bounces the visual; stock authority handles reactions.
function Advance(int Index, float DT, float Now)
{
    local LocalDrop D;
    local vector Center, NextRoot, Points[3], From, To, At, N, HitAt, HitNormal, Arm, PointVelocity, Impulse, Response, BodyVelocity, RelativeVelocity;
    local quat OldQ;
    local float Fraction, BestFraction, Travel, Speed, Denominator, Restitution;
    local int J;
    local Actor Hit;
    local KFPawn_Monster Zed;
    local bool bBodyContact;
    local TraceHitInfo Info;
    local PhysicalMaterial Surface;
    D=Drops[Index]; OldQ=D.Rotation;
    Center=D.Position+QuatRotateVector(D.Rotation,D.CenterOfMass);
    D.Velocity.Z=FMax(D.Velocity.Z-950*class'VRWeaponThrowProfiles'.const.TossGravityScale*DT,-1400);
    class'VRWeaponThrowProfiles'.static.RotateBody(D.Rotation,D.BoreQ,D.Inertia,D.AngularMomentum,D.Spin,DT,
        class'VRWeaponThrowProfiles'.static.MaxSpin(D.Profile));
    NextRoot=Center+D.Velocity*DT-QuatRotateVector(D.Rotation,D.CenterOfMass);
    Points[0]=D.CenterOfMass; Points[1]=D.Nose; Points[2]=D.Tail;
    BestFraction=2;
    for (J=0; J<3; ++J)
    {
        From=D.Position+QuatRotateVector(OldQ,Points[J]);
        To=NextRoot+QuatRotateVector(D.Rotation,Points[J]);
        Travel=VSize(To-From);
        if (Travel<0.0001) continue;
        Hit=Bridge.Trace(At,N,To,From,false,vect(1,1,1)*D.Radius,Info);
        if (Hit==None) continue;
        Fraction=FClamp(VSize(At-From)/Travel,0,1);
        if (Fraction>=BestFraction) continue;
        BestFraction=Fraction; HitAt=At-N*D.Radius; HitNormal=N; Surface=Info.PhysMaterial;
    }
    // Use the same six-unit center sweep as the authority reaction. Never
    // collide with the player's own body or manufacture damage from the mesh.
    From=Center; To=Center+D.Velocity*DT; Travel=VSize(To-From);
    if (Travel>0.0001)
        foreach Bridge.TraceActors(class'KFPawn_Monster',Zed,At,N,To,From,vect(6,6,6))
        {
            if (Zed==None || Zed.bDeleteMe || Zed.Health<=0) continue;
            Fraction=FClamp(VSize(At-From)/Travel,0,1);
            if (Fraction>=BestFraction) continue;
            BestFraction=Fraction; HitAt=At; HitNormal=N; Surface=None; bBodyContact=true;
            // The toss advances in real seconds, including during Zed Time.
            BodyVelocity=Zed.Velocity*FClamp(Bridge.WorldInfo.TimeDilation*Zed.CustomTimeDilation,0,20);
        }
    if (BestFraction>1) D.Position=NextRoot;
    else
    {
        // A muzzle/tail can hit a wall before the center. Cancel authority's
        // original trajectory here; body contact finishes on authority time.
        if (!bBodyContact) { StopContact(Index); D.ContactToken=0; }
        D.Position+=(NextRoot-D.Position)*BestFraction+HitNormal*0.5;
        D.Rotation=QuatSlerp(OldQ,D.Rotation,BestFraction,true);
        Center=D.Position+QuatRotateVector(D.Rotation,D.CenterOfMass);
        Arm=HitAt-Center;
        D.Spin=class'VRWeaponThrowProfiles'.static.SpinFor(QuatProduct(D.Rotation,D.BoreQ),D.Inertia,D.AngularMomentum);
        PointVelocity=D.Velocity-BodyVelocity+(D.Spin cross Arm);
        Speed=FMax(-(PointVelocity dot HitNormal),0);
        Response=class'VRWeaponThrowProfiles'.static.SpinFor(QuatProduct(D.Rotation,D.BoreQ),D.Inertia,Arm cross HitNormal);
        Denominator=1.0/D.Profile.MassKg+(HitNormal dot (Response cross Arm));
        Restitution=(bBodyContact ? 0.12 : 0.22)/(1.0+0.04*D.Profile.MassKg);
        Impulse=HitNormal*((1.0+Restitution)*Speed/FMax(Denominator,0.001));
        D.Velocity+=Impulse/D.Profile.MassKg;
        // Damping belongs to contact-relative motion: a moving torso carries
        // the gun along instead of erasing its world motion at impact.
        RelativeVelocity=D.Velocity-BodyVelocity;
        D.Velocity-=(RelativeVelocity-HitNormal*(RelativeVelocity dot HitNormal))*0.24;
        D.AngularMomentum=(D.AngularMomentum+(Arm cross Impulse))*0.60;
        // A bounce can redirect the tumble but never exceed the toss's own limit.
        D.Spin=class'VRWeaponThrowProfiles'.static.SpinFor(QuatProduct(D.Rotation,D.BoreQ),D.Inertia,D.AngularMomentum);
        if (VSize(D.Spin)>class'VRWeaponThrowProfiles'.static.MaxSpin(D.Profile))
            D.AngularMomentum=class'VRWeaponThrowProfiles'.static.Momentum(QuatProduct(D.Rotation,D.BoreQ),D.Inertia,
                Normal(D.Spin)*class'VRWeaponThrowProfiles'.static.MaxSpin(D.Profile));
        ++D.Bounces;
        if (Speed>65 && D.Bounces<=4 && Now-D.LastImpact>=0.12)
        {
            class'VRWorldHandlingAudio'.static.Impact(Bridge,D.Runtime.Item.Class,HitAt,Surface);
            D.LastImpact=Now;
        }
        if (!bBodyContact && HitNormal.Z>0.45 && ((VSize(D.Velocity)<85 && Speed<90) || D.Bounces>=5))
        {
            D.bResting=true; D.Velocity=vect(0,0,0); D.Spin=vect(0,0,0); D.AngularMomentum=vect(0,0,0);
        }
        else D.Spin=class'VRWeaponThrowProfiles'.static.SpinFor(QuatProduct(D.Rotation,D.BoreQ),D.Inertia,D.AngularMomentum);
    }
    Drops[Index]=D;
}

function Update()
{
    local int I,Steps;
    local float Now,Age,Remaining,Slice,Alpha;
    local VRWeaponRuntime R;
    if (Bridge==None) return;
    Now=Bridge.WorldInfo.RealTimeSeconds;
    Remaining=FClamp(Now-LastTime,0,0.1); LastTime=Now;
    if (!Inventory.ContextValid() || Inventory.Input==None || !Inventory.Input.ContextValid()
        || Bridge.NativeHeadTracked==0 || Bridge.NativeValidMask==0
        || !class'VRReloadMotionGuard'.static.ValidPosition(Bridge.HeadPosition))
    { Clear(); return; }
    UpdateFeedback(Now);
    for (I=Drops.Length-1; I>=0; --I)
    {
        R=Drops[I].Runtime;
        if (R==None || !R.IsCurrent() || ComponentHeld(I)
            || Drops[I].CalibrationEpoch!=Bridge.NativeCalibrationEpoch || Drops[I].RoomEpoch!=Bridge.NativeRoomSpaceEpoch)
        { Remove(I); continue; }
        // Gravity flight is advanced by the owning hand's pull state, using
        // the same exact component identity through arrival and catch retry.
        if (Drops[I].bPulling)
        {
            if (Now-Drops[I].PullStarted<=Drops[I].PullDuration+0.5) { Place(I); continue; }
            EndGravity(Drops[I].Mesh,Drops[I].PullHand);
        }
        Age=Now-Drops[I].Started;
        if (Age>=Drops[I].Delay+0.25) { Remove(I); continue; }
        if (Age>=Drops[I].Delay)
        {
            if (!Drops[I].bReturning)
            { StopContact(I); Drops[I].bReturning=true; Drops[I].ReturnFrom=Drops[I].Position; }
            Alpha=FClamp((Age-Drops[I].Delay)/0.25,0,1);
            Alpha=Alpha*Alpha*(3-2*Alpha);
            Drops[I].Position=Drops[I].ReturnFrom+(Bridge.HeadPosition-vect(0,0,40)-Drops[I].ReturnFrom)*Alpha;
        }
        else if (!Drops[I].bResting)
        {
            Steps=0;
            for (Slice=FMin(Remaining,1.0/120.0); Steps<12 && Slice>0; ++Steps)
            {
                Advance(I,Slice,Now);
                if (Drops[I].bResting) break;
                Slice=FMin(FMax(Remaining-(Steps+1)/120.0,0),1.0/120.0);
            }
        }
        Place(I);
    }
}
