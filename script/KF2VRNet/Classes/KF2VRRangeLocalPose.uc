// Range-only telemetry over ordinary solo hands. No second input, inventory
// or gameplay bridge: the existing native-driven presenter remains owner.
class KF2VRRangeLocalPose extends KF2VRNetPose;
var VRHandsBridge Bridge;
var float NextSample, LastSample;
var int Sequence;
var KFWeapon PreviousWeapon[2];
var int PreviousAmmo[2], ShotSerial[2];

function byte ReadHandPose(int Hand)
{
    local int Curl;
    if (Bridge.HandInventory!=None && Bridge.HandInventory.Registry!=None
        && (Bridge.HandInventory.Registry.GetPrimary(Hand)!=None
            || Bridge.HandInventory.Registry.GetSupport(Hand)!=None)) return 79;
    if (Bridge.FreeHandPose==None) return 0;
    Curl=Clamp(Round(Bridge.FreeHandPose.Amount[Hand]*15),0,15);
    return byte(Curl<=2 ? 48|Curl : Curl);
}

function SampleHeld(int Hand, rotator Root, out KF2VRNetTypes.NetPoseSample S)
{
    local VRWeaponRuntime R, WristRuntime;
    local VRWeaponPresenter P;
    local KFWeapon W;
    local vector At;
    local rotator Aim;
    local KF2VRNetTypes.NetWeaponVisual Look;
    if (Bridge.HandInventory==None || Bridge.HandInventory.Registry==None) return;
    R=Bridge.HandInventory.GetHeldForHand(Hand);
    if (R!=None) W=R.Item;
    Look=SampleWeapon(W,R!=None ? R.ItemId : 0,None);
    if (W!=None && W==PreviousWeapon[Hand] && W.IsFiring() && W.AmmoCount[0]<PreviousAmmo[Hand])
        ShotSerial[Hand]=(ShotSerial[Hand]+1)&65535;
    PreviousWeapon[Hand]=W;
    PreviousAmmo[Hand]=W!=None ? W.AmmoCount[0] : 0;
    Look.ShotSequence=ShotSerial[Hand];
    if (Hand==0) LeftWeapon=Look; else RightWeapon=Look;
    if (W!=None && W.MySkelMesh!=None && R.Presenter!=None)
    {
        P=R.Presenter;
        // Same authored optical/root anchor as the network presentation.
        if (P.bCalibrated && P.ActiveProfile>=0 && P.ActiveProfile<P.WeaponProfiles.Length)
        {
            if (class'VRWeaponBlockShapes'.static.PublishesRoot(P.ActiveProfile))
            {
                At=W.MySkelMesh.GetBoneLocation(P.WeaponProfiles[P.ActiveProfile].RootBone);
                Aim=QuatToRotator(W.MySkelMesh.GetBoneQuaternion(P.WeaponProfiles[P.ActiveProfile].RootBone));
            }
            else if (!W.MySkelMesh.GetSocketWorldLocationAndRotation(P.WeaponProfiles[P.ActiveProfile].MuzzleSocket,At,Aim))
                W=None;
            if (W!=None)
            {
                if (class'VRCompoundBowAuthority'.static.Supports(W)) Aim=P.LaserMuzzleRotation;
                if (Hand==0)
                { S.LeftMuzzlePosition=(At-TargetPawn.Location)<<Root; S.LeftMuzzleRotation=Normalize(Aim-Root); S.PresentationFlags=S.PresentationFlags|2; }
                else
                { S.MuzzlePosition=(At-TargetPawn.Location)<<Root; S.MuzzleRotation=Normalize(Aim-Root); S.PresentationFlags=S.PresentationFlags|1; }
            }
        }
    }
    WristRuntime=R;
    if (WristRuntime==None) WristRuntime=Bridge.HandInventory.Registry.GetSupport(Hand);
    if (WristRuntime==None || WristRuntime.Presenter==None) return;
    P=WristRuntime.Presenter;
    if (P.Arms==None || P.FreeHandPose==None || !P.FreeHandPose.bReady || !P.bCalibrated
        || (WristRuntime.NativePoseReady!=1 && !P.FreshCarryVisual(Hand))) return;
    // Read the rendered stock-animation wrist, including its anatomical basis.
    At=P.RenderedHandPosition(Hand);
    Aim=QuatToRotator(QuatProduct(P.RenderedHandRotation(Hand),QuatInvert(P.FreeHandPose.WristBasis[Hand])));
    if (Hand==0)
    { S.LeftWristPosition=(At-TargetPawn.Location)<<Root; S.LeftWristRotation=Normalize(Aim-Root); S.PresentationFlags=S.PresentationFlags|4; }
    else
    { S.RightWristPosition=(At-TargetPawn.Location)<<Root; S.RightWristRotation=Normalize(Aim-Root); S.PresentationFlags=S.PresentationFlags|8; }
}

function AddPart(out KF2VRNetTypes.NetPoseSample S,KFWeapon W,int Hand,name Bone,
    SkelControlSingleBone Control,vector RestPosition,quat RestRotation)
{
    local KF2VRNetTypes.NetMechanismPart Part;
    local VRWeaponRuntime R;
    local int I;
    if (W==None || Hand<0 || Hand>1 || Bone=='' || Control==None || Control.ControlStrength<=0
        || Control.BoneTranslationSpace!=BCS_WorldSpace || Control.BoneRotationSpace!=BCS_WorldSpace) return;
    R=Bridge.HandInventory.GetHeldForHand(Hand);
    if (R==None || R.Item!=W) return;
    Part.Hand=Hand; Part.Bone=Bone; Part.Flags=5; Part.Generation=R.ItemId;
    if (W.MySkelMesh!=None && W.MySkelMesh.MatchRefBone(Bone)>=0
        && class'VRBoneVisibility'.static.IsHidden(W.MySkelMesh,Bone)) Part.Flags=Part.Flags|2;
    Part.Translation=QuatRotateVector(QuatInvert(RestRotation),Control.BoneTranslation-RestPosition);
    Part.Rotation=Normalize(QuatToRotator(QuatProduct(QuatInvert(RestRotation),QuatFromRotator(Control.BoneRotation))));
    if (!class'KF2VRNetTypes'.static.ValidMechanism(Part)) return;
    for (I=0; I<S.Mechanisms.Length; ++I)
        if (S.Mechanisms[I].Hand==Hand && S.Mechanisms[I].Bone==Bone) { S.Mechanisms[I]=Part; return; }
    if (S.Mechanisms.Length<32) S.Mechanisms.AddItem(Part);
}
function SampleAction(out KF2VRNetTypes.NetPoseSample S,VRManualPump A)
{
    local int I;
    local vector At;
    local quat Q;
    if (A==None || A.Gun==None || A.Gun.MySkelMesh==None || A.Tree==None) return;
    At=A.RootPos(); Q=A.RootQ();
    for (I=0; I<A.Parts.Length; ++I)
        AddPart(S,A.Gun,A.GunHand,A.Parts[I].Bone,A.Parts[I].Control,
            At+QuatRotateVector(Q,A.Parts[I].IdleLocal*A.GunScale()),QuatProduct(Q,A.Parts[I].IdleLocalQ));
}
function AddAmmo(out KF2VRNetTypes.NetPoseSample S,StaticMeshComponent C,KFWeapon W,
    int Hand,int Slot,int PropSlot,int Serial,optional bool bSeated)
{
    local KF2VRNetTypes.NetReloadProp P;
    local VRWeaponRuntime R;
    local rotator Root;
    if (C==None || C.HiddenGame || C.StaticMesh==None || W==None || Hand<0 || Hand>1
        || S.ReloadProps.Length>=5) return;
    R=Bridge.HandInventory.GetHeldForHand(1-Hand);
    if (R==None || R.Item!=W) return;
    P.SourceHand=1-Hand; P.Generation=R.ItemId; P.bSeated=bSeated;
    P.Hand=bSeated ? 1-Hand : Hand; P.AmmoSlot=Slot; P.PropSlot=PropSlot; P.CarrySerial=Serial;
    P.Family=class'VRReloadCatalog'.static.ProfileClass(W.Class);
    P.SkinId=class'VRWeaponPair'.static.VisibleSkin(W);
    Root.Yaw=NormalizeRotAxis(TargetPawn.Rotation.Yaw);
    P.Position=(C.Translation-TargetPawn.Location)<<Root; P.Rotation=Normalize(C.Rotation-Root);
    P.Scale=C.Scale3D*C.Scale;
    if (class'KF2VRNetTypes'.static.ValidReloadProp(P)) S.ReloadProps.AddItem(P);
}
function SampleActions(out KF2VRNetTypes.NetPoseSample S)
{
    local VRInteractiveReload R;
    local VRWeaponRuntime Held;
    local KF2VRNetTypes.NetMechanismPart P;
    local array<name> Bones;
    local int I,J,Hand;
    if (Bridge.HandInventory==None || Bridge.HandInventory.Input==None) return;
    R=Bridge.HandInventory.Input.Reloads;
    if (R==None) return;
    SampleAction(S,R.Pump); SampleAction(S,R.ManualAction); SampleAction(S,R.BreakAction);
    SampleAction(S,R.M32Action); SampleAction(S,R.FinishAction);
    SampleAction(S,R.DualCylinders[0]); SampleAction(S,R.DualCylinders[1]);
    SampleAction(S,R.Mechanism); SampleAction(S,R.Vampire); SampleAction(S,R.Secondary);
    if (R.Gun!=None && R.RigSample!=None && R.MagazineProfileIndex>=0)
    {
        AddPart(S,R.Gun,R.GunHand,R.RackBone,R.RackControl,R.RootLocation(R.RigSample.RackRestLocal),R.RootQuat(R.RigSample.RackRestLocalQ));
        AddPart(S,R.Gun,R.GunHand,R.FollowBone,R.FollowControl,R.RootLocation(R.RigSample.FollowRestLocal),R.RootQuat(R.RigSample.FollowRestLocalQ));
    }
    if (R.Gun!=None && R.LeverPath!=None && R.LeverPath.Path.Length>0)
        for (I=0; I<R.LeverControls.Length && I<3; ++I)
            AddPart(S,R.Gun,R.GunHand,R.LeverPath.Bones[I],R.LeverControls[I],
                R.RootLocation(R.LeverPath.Path[0].P[I]),R.RootQuat(R.LeverPath.Path[0].Q[I]));
    for (Hand=0; Hand<2; ++Hand)
    {
        Held=Bridge.HandInventory.GetHeldForHand(Hand);
        if (Held==None || Held.Item==None || Held.Item.MySkelMesh==None) continue;
        class'KF2VRNetMechanismCatalog'.static.Collect(Held.Item.Class,Bones);
        for (I=0; I<Bones.Length && S.Mechanisms.Length<32; ++I)
        {
            if (Held.Item.MySkelMesh.MatchRefBone(Bones[I])<0) continue;
            for (J=0; J<S.Mechanisms.Length; ++J)
                if (S.Mechanisms[J].Hand==Hand && S.Mechanisms[J].Bone==Bones[I]) break;
            if (J<S.Mechanisms.Length) continue;
            P.Hand=Hand; P.Bone=Bones[I]; P.Generation=Held.ItemId;
            P.Flags=(R.EnabledFor(Held.Item) && R.SessionHolds(Held.Item)) ? 4 : 0;
            if (class'VRBoneVisibility'.static.IsHidden(Held.Item.MySkelMesh,Bones[I])) P.Flags=P.Flags|2;
            S.Mechanisms.AddItem(P);
        }
    }
    if (R.bActive && (R.HandMode==1 || R.HandMode==4) && !R.bRecoveredMagazineSession)
    {
        AddAmmo(S,R.HandAmmo,R.Gun,R.OffHand(),0,0,R.CarriedAmmoSerial);
        if (R.ShellBundle!=None && R.ShellBundle.bPlaced)
            for (I=0; I<3; ++I) AddAmmo(S,R.ShellBundle.Props[I],R.Gun,R.OffHand(),0,I+1,R.CarriedAmmoSerial);
    }
    if (R.bActive && (R.HandAmmo==None || R.HandAmmo.HiddenGame))
        AddAmmo(S,R.SeatedAmmo,R.Gun,R.OffHand(),0,0,R.CarriedAmmoSerial,true);
    if (R.Secondary!=None && R.Secondary.bActive && R.Secondary.bCarryingAmmo && !R.Secondary.bRecoveredMagazine)
        AddAmmo(S,R.Secondary.SecondaryAmmo,R.Secondary.Gun,R.Secondary.OffHand(),1,4,R.Secondary.CarriedAmmoSerial);
}

simulated event Tick(float DeltaTime)
{
    local VRHandsBridge B;
    local KF2VRNetTypes.NetPoseSample S;
    local KF2VRNetTypes.NetWeaponVisual Empty;
    local rotator Root;
    if (WorldInfo.NetMode!=NM_Standalone) return;
    if (Bridge==None || Bridge.bDeleteMe || Bridge.Human==None || Bridge.Human.bDeleteMe)
    {
        Bridge=None;
        foreach WorldInfo.AllActors(class'VRHandsBridge',B)
            if (B.RootBridge==None && B.PC!=None && B.PC.IsLocalPlayerController()
                && B.Human!=None && B.Human==B.PC.Pawn)
            { Bridge=B; break; }
    }
    if (Bridge==None || Bridge.NativeConnection!=1 || Bridge.Human.Health<=0)
    { ExpirePose(); return; }
    if (WorldInfo.RealTimeSeconds<NextSample) return;
    NextSample=FMax(NextSample+class'KF2VRNetTypes'.const.ClientPoseInterval,WorldInfo.RealTimeSeconds);
    if (TargetPawn!=Bridge.Human) Initialize(Bridge.Human,1,1,PawnEpoch+1,1);
    Root.Yaw=NormalizeRotAxis(TargetPawn.Rotation.Yaw);
    S.WorldEpoch=WorldEpoch; S.ConnectionEpoch=ConnectionEpoch;
    S.PawnEpoch=PawnEpoch; S.CalibrationEpoch=CalibrationEpoch;
    Sequence=(Sequence+1)&65535; S.Sequence=Sequence;
    S.ReferenceEpoch=Max(0,Bridge.NativeCalibrationEpoch);
    S.TrackingFlags=(Bridge.NativeValidMask&3)<<1;
    if (Bridge.NativeHeadTracked!=0) S.TrackingFlags=S.TrackingFlags|1;
    S.HeadPosition=(Bridge.HeadPosition-TargetPawn.Location)<<Root;
    S.HeadRotation=Normalize(Bridge.NativeHeadRotation-Root);
    S.EyeHeight=Clamp(Round(TargetPawn.BaseEyeHeight),1,128);
    if ((S.TrackingFlags&2)!=0)
    {
        S.LeftPosition=(Bridge.LeftPosition-TargetPawn.Location)<<Root;
        S.LeftRotation=Normalize(Bridge.LeftRotation-Root);
        S.LeftGripRotation=Normalize(Bridge.NativeLeftGripRotation-Root);
        S.LeftHandPose=ReadHandPose(0);
    }
    if ((S.TrackingFlags&4)!=0)
    {
        S.RightPosition=(Bridge.RightPosition-TargetPawn.Location)<<Root;
        S.RightRotation=Normalize(Bridge.RightRotation-Root);
        S.RightGripRotation=Normalize(Bridge.NativeRightGripRotation-Root);
        S.RightHandPose=ReadHandPose(1);
    }
    S.SampleMillis=int(WorldInfo.RealTimeSeconds*1000)&65535;
    S.RootYaw=Root.Yaw; S.PresentationFlags=64;
    LeftWeapon=Empty; RightWeapon=Empty;
    if ((S.TrackingFlags&2)!=0) SampleHeld(0,Root,S);
    if ((S.TrackingFlags&4)!=0) SampleHeld(1,Root,S);
    SampleActions(S);
    bIndependentWeapons=true;
    if (!class'KF2VRNetTypes'.static.IsValidSample(S)) { ExpirePose(); return; }
    PublishPose(S,TargetPawn,false);
    LastSample=WorldInfo.RealTimeSeconds;
}

function bool PlayerContactHand(KFPawn_Human User,int Hand,out vector At,out byte Pose,out int Revision)
{
    if (User==None || User!=TargetPawn || User.Health<=0 || Hand<0 || Hand>1
        || WorldInfo.RealTimeSeconds-LastSample>class'KF2VRNetTypes'.const.PoseLeaseSeconds
        || (Snapshot.Sample.TrackingFlags&(2<<Hand))==0) return false;
    At=Snapshot.RootPosition+((Hand==0 ? Snapshot.Sample.LeftPosition : Snapshot.Sample.RightPosition)>>Snapshot.RootRotation);
    Pose=Hand==0 ? Snapshot.Sample.LeftHandPose : Snapshot.Sample.RightHandPose;
    Revision=Snapshot.Revision;
    return true;
}
defaultproperties
{
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
}
