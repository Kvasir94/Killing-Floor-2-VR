// One exact own-weapon session. The channel transports discrete input events;
// existing registry/held/pair writers still own every inventory mutation.
class KF2VRNetWorldTrick extends Object dependsOn(KF2VRNetTypes,VRWeaponDropState);

var KF2VRNetWorldDropChannel Host;
var KFWeapon Weapon;
var int Token,ItemId,WorldEpoch,ConnectionEpoch,PawnEpoch,Calibration;
var int LastReceived,LastCommitted,CurrentHand;
var int LastEscrowSerial;
var byte TailAction,CurrentAction,CurrentGripRole;
var bool bEntryPending,bAborted,bSettled;
var float LastProgressAt;
var VRWorldDropGun Prop;
var VRWeaponDropState.HandlingState Handling;
var vector CurrentRoot;
var quat CurrentRootQ;
var array<NetWorldTrickEvent> Events;
var int SettleRequest,SettleSerial,SettleEvent,SettleHand,SettleGeneration;
var bool bRecoverySettlement;
var float SettleDeadline;

function bool Initialize(KF2VRNetWorldDropChannel Channel,KFWeapon W,int LeaseToken,int Hand,byte EntryAction,int EntrySerial)
{
    local int Revision;
    Host=Channel; Weapon=W; Token=LeaseToken;
    if (Host==None || Host.Source==None || W==None || LeaseToken<=0
        || !Host.Registry.Owns(W) || !Host.Source.WorldDropIdentity(W,ItemId,Revision)) return false;
    WorldEpoch=Host.Source.WorldEpoch; ConnectionEpoch=Host.Source.ConnectionEpoch;
    PawnEpoch=Host.Source.PawnEpoch; Calibration=Host.Source.CalibrationEpoch;
    LastReceived=Token; LastCommitted=Token; CurrentHand=Hand;
    LastEscrowSerial=EntrySerial;
    CurrentAction=EntryAction; TailAction=EntryAction; bEntryPending=true;
    LastProgressAt=Host.WorldInfo.RealTimeSeconds;
    return true;
}

function bool IdentityValid()
{
    local int Id,Revision;
    return Host!=None && Host.ContextValid() && Host.Registry.Owns(Weapon)
        && Host.Source.WorldEpoch==WorldEpoch && Host.Source.ConnectionEpoch==ConnectionEpoch
        && Host.Source.PawnEpoch==PawnEpoch
        && Host.Source.WorldDropIdentity(Weapon,Id,Revision) && Id==ItemId;
}

function bool Gate(bool bEnable)
{
    local KF2VRNetItemRuntime R;
    R=Host.Source.WorldDropRuntime(Weapon);
    if (R==None || R.Item!=Weapon || R.NativeReady!=1) return false;
    if (bEnable)
    {
        if (R.WorldTrickPending!=0 && R.WorldTrickPending!=Token) return false;
        R.WorldTrickPending=Token;
    }
    else if (R.WorldTrickPending==Token) R.WorldTrickPending=0;
    return true;
}

function Activate(VRWorldDropGun EntryProp,VRWeaponDropState.HandlingState Snapshot,
    optional byte GripRole,optional vector Root,optional quat RootQ)
{
    if (!IdentityValid() || !Gate(true)) { Abort(); return; }
    Prop=EntryProp; Handling=Snapshot; CurrentGripRole=GripRole;
    CurrentRoot=Root; CurrentRootQ=RootQ; bEntryPending=false;
    if (Prop!=None) { Prop.WorldTrickLeaseToken=Token; Prop.bNetDirty=true; }
    LastProgressAt=Host.WorldInfo.RealTimeSeconds;
}

function bool Enqueue(NetWorldTrickEvent E)
{
    local vector FreshHand;
    if (bAborted || !IdentityValid() || Host.Source.CalibrationEpoch!=Calibration
        || E.Request<=LastReceived || E.Predecessor!=LastReceived
        || E.Action>1 || E.Action==TailAction || E.Hand<0 || E.Hand>1
        || Events.Length>=64 || !Host.HandPosition(E.Hand,FreshHand)
        || !class'VRReloadMotionGuard'.static.ValidPosition(E.Palm)
        || VSizeSq(E.Palm-FreshHand)>Square(45.0) || !Host.FastTrace(E.Palm,FreshHand))
    { Abort(); return false; }
    if (E.Action==1)
    {
        if (!class'VRReloadMotionGuard'.static.ValidPosition(E.Body)
            || !class'VRHandRolePose'.static.ValidQuaternion(E.BodyQ)
            || E.Elapsed!=E.Elapsed || E.Elapsed<0
            || E.ContactAge!=E.ContactAge || E.ContactAge<0 || E.ContactAge>0.10)
        { Abort(); return false; }
    }
    else
    {
        if (E.EscrowSerial<=LastEscrowSerial || E.EscrowSerial==MaxInt
            || !class'VRReloadMotionGuard'.static.ValidPosition(E.Root)
            || !class'VRHandRolePose'.static.ValidQuaternion(E.RootQ)
            || !class'VRReloadMotionGuard'.static.ValidPosition(E.Linear)
            || !class'VRReloadMotionGuard'.static.ValidPosition(E.Angular)
            || VSizeSq(E.Root-E.Palm)>Square(E.bRoot ? 110.0 : 35.0)
            || !Host.FastTrace(E.Root,E.Palm))
        { Abort(); return false; }
    }
    E.ReceivedAt=Host.WorldInfo.RealTimeSeconds;
    E.HandEpoch=Host.TrickHandEpoch(E.Hand);
    if (!bEntryPending && !Gate(true)) { Abort(); return false; }
    bSettled=false; Events.AddItem(E); LastReceived=E.Request; TailAction=E.Action;
    if (E.Action==0) LastEscrowSerial=E.EscrowSerial;
    return true;
}

function bool AdvanceOne()
{
    local NetWorldTrickEvent E;
    local KF2VRNetTypes.NetWorldTransition Transition;
    local KF2VRNetItemRuntime R;
    local byte GripRole;
    local vector Root;
    local quat RootQ;
    if (bEntryPending || bAborted || Events.Length==0) return false;
    E=Events[0];
    if (E.Predecessor!=LastCommitted || !IdentityValid() || Host.Source.CalibrationEpoch!=Calibration
        || E.HandEpoch!=Host.TrickHandEpoch(E.Hand)
        || Host.WorldInfo.RealTimeSeconds-E.ReceivedAt>3.0) { Abort(); return false; }
    if (!Host.TrickMayAdvance(self,E.Hand,E.Request)) return false;
    if (!Host.Source.WorldPairedSessionsAllow(Weapon,E.Hand)) return false;
    R=Host.Source.WorldDropRuntime(Weapon);
    if (R==None || R.WorldTrickPending!=Token || R.MechanismPending!=0) { Abort(); return false; }
    if (E.Action==1)
    {
        if (CurrentAction!=0 || Prop==None || Prop.bDeleteMe || Prop.bReturning
            || Prop.OwnedWeapon!=Weapon || Prop.DropOwner!=Host.Human
            || Prop.ReleaseRequestId!=E.Predecessor) { Abort(); return false; }
        if (!Host.Source.CanReceiveWorldContact(E.Hand)) return false;
        if (!Prop.PredictedContact(E.Palm,E.Body,E.BodyQ,E.Elapsed,E.Hand,Host.Registry.bSupportCatch,
            GripRole,Root,RootQ)) { Abort(); return false; }
        Prop.bCatchPending=true;
        Transition=Host.Source.CaptureWorldTransition(E.Hand,0,1,E.Request,ItemId,Prop,E.Request);
        Handling=Prop.Handling;
        if (!Host.Registry.CompleteOwnedCatch(Prop,E.Hand,GripRole,Root,RootQ))
        { Prop.bCatchPending=false; Abort(); return false; }
        Prop=None; CurrentGripRole=GripRole; CurrentRoot=Root; CurrentRootQ=RootQ;
        Transition.Generation=Host.HandGeneration(E.Hand);
        Host.Source.PublishWorldTransition(Transition);
    }
    else
    {
        if (CurrentAction!=1 || CurrentHand!=E.Hand
            || (E.Hand==0 ? Host.Source.HeldState.LeftWeapon : Host.Source.HeldState.RightWeapon)!=Weapon
            || R.WorldDropped!=0 || !class'VRWorldDropGun'.static.ReleaseActionReady(Weapon))
        { Abort(); return false; }
        Host.TrickDispatch=self; Host.TrickDispatchRequest=E.EscrowSerial;
        Prop=Host.Registry.Release(Weapon,E.Hand,E.Root,QuatToRotator(E.RootQ),E.Linear,E.Angular,
            E.bRoot,E.Palm,Handling);
        Host.TrickDispatch=None; Host.TrickDispatchRequest=0;
        if (Prop==None) { Abort(); return false; }
        Prop.WorldTrickLeaseToken=Token;
        Prop.RememberRelease(E.Request,ItemId,Host.HandGeneration(E.Hand),E.Angular);
        Host.Source.PublishWorldTransition(Host.Source.CaptureWorldTransition(E.Hand,
            Host.HandGeneration(E.Hand),0,E.Request,ItemId,Prop));
    }
    Host.RecordTrickHandCommit(E.Hand);
    if (!Gate(true)) { Abort(); return false; }
    CurrentAction=E.Action; CurrentHand=E.Hand; LastCommitted=E.Request;
    Events.Remove(0,1); LastProgressAt=Host.WorldInfo.RealTimeSeconds;
    Host.ClientTrickProgress(Token,LastCommitted,CurrentAction,CurrentHand,Weapon,ItemId,E.Predecessor,
        CurrentGripRole,CurrentRoot,CurrentRootQ,Host.Source.HeldState);
    return true;
}

function RequestSettlement(int Request,int Serial,int EventId,int Hand,int Generation,bool bRecovery)
{
    if (!IdentityValid() || SettleRequest>0 || Serial<=0 || Serial==MaxInt
        || Hand>1 || (Hand<0 && !(bRecovery && CurrentAction==2)) || (!bRecovery && bAborted)) return;
    if (bRecovery && !Gate(true)) return;
    SettleRequest=Request; SettleSerial=Serial; SettleEvent=EventId; SettleHand=Hand;
    SettleGeneration=Generation; bRecoverySettlement=bRecovery;
    SettleDeadline=Host.WorldInfo.RealTimeSeconds+1.0;
}

function UpdateSettlement()
{
    local KF2VRNetItemRuntime R;
    local bool bAccepted;
    if (SettleRequest<=0) return;
    R=Host.Source.WorldDropRuntime(Weapon);
    if (R!=None && IdentityValid() && Host.WorldInfo.RealTimeSeconds<SettleDeadline
        && R.WeaponBarrierSerial<SettleSerial) return;
    bAccepted=R!=None && IdentityValid() && R.WeaponBarrierSerial==SettleSerial
        && Events.Length==0 && !bEntryPending && CurrentHand==SettleHand
        && (bRecoverySettlement || (!bAborted && LastCommitted==SettleEvent));
    if (bAccepted && CurrentAction==2)
        bAccepted=bRecoverySettlement && SettleHand==-1
            && Host.Source.HeldState.LeftWeapon!=Weapon && Host.Source.HeldState.RightWeapon!=Weapon;
    else if (bAccepted)
        bAccepted=CurrentAction==1 && SettleHand>=0 && Host.HandGeneration(SettleHand)==SettleGeneration
            && (SettleHand==0 ? Host.Source.HeldState.LeftWeapon : Host.Source.HeldState.RightWeapon)==Weapon;
    if (bAccepted) { Gate(false); bSettled=true; }
    if (R!=None && R.NativeReady==1) Weapon.ClientForceAmmoUpdate(-255,SettleSerial);
    Host.ClientTrickSettled(Token,SettleRequest,SettleSerial,SettleEvent,Weapon,ItemId,SettleHand,
        bAccepted,CurrentGripRole,CurrentRoot,CurrentRootQ,Host.Source.HeldState);
    SettleRequest=0; SettleSerial=0;
}

function Abort()
{
    local bool bWorld;
    if (bAborted || Host==None) return;
    bAborted=true; Events.Length=0;
    bWorld=Host.Registry!=None && Host.Registry.IsDropped(Weapon);
    if (bWorld) Gate(false);
    else
    {
        CurrentHand=-1;
        if (Host.Source.HeldState.LeftWeapon==Weapon) CurrentHand=0;
        else if (Host.Source.HeldState.RightWeapon==Weapon) CurrentHand=1;
        CurrentAction=byte(CurrentHand>=0 ? 1 : 2);
        if (CurrentHand>=0) CurrentGripRole=byte((Host.Source.HeldState.CarryMask & (1<<CurrentHand))!=0);
        Gate(true);
    }
    // A held recovery keeps its native lease gate until an exact fresh marker.
    Host.ClientTrickAborted(Token,Weapon,bWorld,LastCommitted,Host.Source.HeldState);
}

function Shutdown()
{
    // A trick sets bCatchPending only for the length of its own commit
    // (AdvanceOne); it never holds it here. Clearing it would wipe a fresh catch
    // reservation the channel made on this same dropped gun just before
    // BeginTrick retired this trick, and every owner re-grab then failed.
    Events.Length=0;
    Gate(false);
}
