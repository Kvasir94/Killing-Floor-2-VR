// Local receipt ledger for own streaming sessions. These slots are per exact
// weapon, independent of the two initial/foreign action lanes.
class KF2VRNetWorldTrickClient extends Object dependsOn(KF2VRNetTypes,KF2VRNetWorldTrick);

struct LocalLease
{
    var int Token,Committed,CommittedHand,SettleRequest,SettleSerial,SettleEvent,LocalItemId;
    var byte CommittedAction,GripRole;
    var KFWeapon Weapon;
    var VRHandsBridge Bridge;
    var VRWorldDropPrediction Prediction;
    var bool bEntryComplete,bAborted,bAbortConfirmed,bWorld,bReply,bAccepted,bRecovery;
    var vector Root;
    var quat RootQ;
    var KF2VRNetTypes.NetHeldState Held;
    var float SettleAt,EntryAt,NextAbort;
};

var KF2VRNetWorldDropChannel Host;
var array<LocalLease> Leases;

function bool Tracks(int Token,KFWeapon W)
{
    local int I;
    local VRWeaponRuntime R;
    I=Find(Token,W); R=Runtime(I);
    return R!=None && (R.WorldTrickPending==Token
        || (R.WorldTrickPending==0 && R.WorldDropped==1 && Leases[I].bWorld));
}

function int Find(int Token,KFWeapon W)
{
    local int I;
    for (I=0; I<Leases.Length; ++I)
        if (Leases[I].Token==Token && Leases[I].Weapon==W) return I;
    return -1;
}

function VRWeaponRuntime Runtime(int I)
{
    local VRWeaponRuntime R;
    if (I<0 || I>=Leases.Length || Leases[I].Bridge==None
        || Leases[I].Bridge.HandInventory==None) return None;
    R=Leases[I].Bridge.HandInventory.Registry.FindItem(Leases[I].Weapon);
    return (R!=None && (Leases[I].LocalItemId==0 || R.ItemId==Leases[I].LocalItemId)) ? R : None;
}

function RegisterIntent(VRHandsBridge Bridge,KFWeapon W,int Request,int Hand,byte EntryAction)
{
    local LocalLease L;
    local VRWeaponRuntime R;
    local int I;
    if (Request<=0 || Bridge==None || W==None || Leases.Length>=16) return;
    I=Find(Request,W);
    if (I>=0) return;
    L.Token=Request; L.Weapon=W; L.Bridge=Bridge;
    L.Committed=Request; L.CommittedAction=EntryAction;
    L.CommittedHand=Hand; L.bWorld=EntryAction==0;
    L.EntryAt=Host.WorldInfo.RealTimeSeconds;
    Leases.AddItem(L); R=Runtime(Leases.Length-1);
    if (R!=None) { R.WorldTrickPending=L.Token; Leases[Leases.Length-1].LocalItemId=R.ItemId; }
}

function Register(VRWorldDropPrediction P,byte EntryAction)
{
    local int I;
    if (P==None) return;
    I=Find(P.LeaseToken,P.OwnedWeapon);
    if (I>=0) Leases[I].Prediction=P;
}

function bool EntryResolved(KFWeapon W,int Request,bool bAccepted)
{
    local int I;
    local VRWeaponRuntime R;
    local VRWorldDropPrediction P;
    I=Find(Request,W);
    if (I<0) return false;
    P=Leases[I].Prediction;
    if (!bAccepted)
    {
        // Existing action reader has already checked this exact entry receipt.
        R=Runtime(I);
        if (R!=None && R.WorldTrickPending==Leases[I].Token) R.WorldTrickPending=0;
        if (P!=None && !P.bDeleteMe) P.Destroy();
        Leases.Remove(I,1); return true;
    }
    Leases[I].bEntryComplete=true;
    if (P!=None && !P.bDeleteMe)
    { P.Deadline=Host.WorldInfo.RealTimeSeconds+3.0; }
    return true;
}

function int Send(VRWorldDropPrediction P,byte Action)
{
    local int I,Request;
    local KF2VRNetTypes.NetWorldTrickEvent E;
    local VRWeaponRuntime R;
    if (P==None || P.bConfirmedAcquire) return 0;
    I=Find(P.LeaseToken,P.OwnedWeapon);
    if (I<0 || Leases[I].bAborted) return 0;
    R=Runtime(I);
    if (R==None || (R.WorldTrickPending!=0 && R.WorldTrickPending!=P.LeaseToken)) return 0;
    Request=Host.NextWorldRequest();
    if (Request<=0) return 0;
    E.Request=Request; E.Predecessor=P.LatestEvent; E.Action=Action;
    if (Action==1)
    {
        E.Hand=P.VisualHand; E.Palm=P.ContactPalm; E.Body=P.ContactBody;
        E.BodyQ=P.ContactRotation; E.Elapsed=P.ContactAt-P.ReleasedAt;
        E.ContactAge=Host.WorldInfo.RealTimeSeconds-P.ContactAt;
    }
    else
    {
        E.Hand=P.VisualHand; E.Palm=P.RethrowPalm; E.bRoot=P.bSavedRethrowRoot;
        E.Root=E.bRoot ? P.SavedRethrowRoot : P.RethrowPalm;
        E.RootQ=E.bRoot ? P.SavedRethrowRootQ : P.RethrowRotation;
        E.Linear=P.RethrowLinear; E.Angular=P.RethrowAngular;
        E.EscrowSerial=Host.Source.NextWeaponActionSerial();
        if (E.EscrowSerial<=0) return 0;
    }
    Host.ServerTrickEvent(Host.BoundWorld,Host.BoundConnection,Host.BoundPawn,P.LeaseToken,P.OwnedWeapon,E);
    R.WorldTrickPending=P.LeaseToken;
    P.Deadline=Host.WorldInfo.RealTimeSeconds+3.0;
    P.LatestEvent=Request;
    if (Action==0) { P.ReleaseRequest=Request; P.AuthorityProp=None; }
    else P.ContactRequest=Request;
    return Request;
}

function Progress(int Token,int EventId,byte Action,int Hand,KFWeapon W,int ItemId,int Predecessor,
    byte GripRole,vector Root,quat RootQ)
{
    local int I;
    local VRWeaponRuntime R;
    local VRWorldDropObserverHub Hub;
    I=Find(Token,W);
    if (I<0 || EventId<Leases[I].Committed) return;
    Leases[I].Committed=EventId; Leases[I].CommittedAction=Action; Leases[I].CommittedHand=Hand;
    Leases[I].GripRole=GripRole; Leases[I].Root=Root; Leases[I].RootQ=RootQ; Leases[I].bWorld=Action==0;
    R=Runtime(I);
    if (R!=None && R.WorldTrickPending==Token) R.WorldDropped=int(Action==0);
    if (Action==1)
    {
        Hub=class'VRWorldDropObserverHub'.static.Find(Host);
        if (Hub!=None) Hub.Remember(Host.Human,ItemId,Predecessor,true);
    }
    if (Leases[I].Prediction!=None && !Leases[I].Prediction.bDeleteMe)
    {
        Leases[I].Prediction.ReleasedItemId=ItemId;
        Leases[I].Prediction.Deadline=Host.WorldInfo.RealTimeSeconds+3.0;
    }
}

function Settled(int Token,int Request,int Serial,int EventId,KFWeapon W,int ItemId,int Hand,bool bAccepted,
    byte GripRole,vector Root,quat RootQ,KF2VRNetTypes.NetHeldState Held)
{
    local int I;
    I=Find(Token,W);
    if (I<0 || Leases[I].SettleRequest!=Request || Leases[I].SettleSerial!=Serial
        || Leases[I].SettleEvent!=EventId) return;
    Leases[I].bReply=true; Leases[I].bAccepted=bAccepted && EventId==Leases[I].Committed; Leases[I].Held=Held;
    // A settlement retires one candidate. Later progress owns the current
    // hand and pose even when this older candidate's rejection arrives last.
    if (Leases[I].bAccepted)
    {
        Leases[I].CommittedHand=Hand; Leases[I].GripRole=GripRole;
        Leases[I].Root=Root; Leases[I].RootQ=RootQ;
    }
    if (Leases[I].Prediction!=None) Leases[I].Prediction.ReleasedItemId=ItemId;
}

function Aborted(int Token,KFWeapon W,bool bWorld,int Committed)
{
    local int I;
    local VRWeaponRuntime R;
    local VRWorldDropPrediction P;
    I=Find(Token,W);
    if (I<0) return;
    Leases[I].bAborted=true; Leases[I].bAbortConfirmed=true; Leases[I].bWorld=bWorld; Leases[I].Committed=Committed;
    R=Runtime(I); P=Leases[I].Prediction;
    if (bWorld)
    {
        if (R!=None) { R.WorldDropped=1; if (R.WorldTrickPending==Token) R.WorldTrickPending=0; }
        if (P!=None && !P.bDeleteMe)
        {
            P.bVisualHeld=false; P.bReleasedAgain=true;
            P.ReleaseRequest=Committed; P.AuthorityProp=None;
            P.Deadline=Host.WorldInfo.RealTimeSeconds+1.0;
        }
    }
}

function RequestSettlement(int I,bool bRecovery)
{
    local int Serial,Request,Hand;
    local VRWeaponRuntime R;
    if (Leases[I].SettleRequest>0) return;
    R=Runtime(I);
    if (R==None || R.WorldTrickPending!=Leases[I].Token) return;
    Hand=Leases[I].CommittedHand;
    if (bRecovery)
    {
        Hand=-1;
        if (Host.Source.HeldState.LeftWeapon==Leases[I].Weapon) Hand=0;
        else if (Host.Source.HeldState.RightWeapon==Leases[I].Weapon) Hand=1;
    }
    if (Hand>1 || (Hand<0 && !bRecovery)) return;
    Serial=Host.Source.NextWeaponActionSerial(); Request=Host.NextWorldRequest();
    if (Serial<=0 || Request<=0) return;
    Leases[I].SettleRequest=Request; Leases[I].SettleSerial=Serial;
    Leases[I].SettleEvent=Leases[I].Committed; Leases[I].bReply=false; Leases[I].bRecovery=bRecovery;
    Leases[I].SettleAt=Host.WorldInfo.RealTimeSeconds;
    Leases[I].Weapon.SyncCurrentAmmoCount(255,Serial);
    Host.ServerSettleTrick(Host.BoundWorld,Host.BoundConnection,Host.BoundPawn,Request,Leases[I].Token,
        Leases[I].Weapon,Serial,Leases[I].Committed,Hand,Host.HandGeneration(Hand),bRecovery);
}

function bool SettlementStillCurrent(int I)
{
    local int Hand;
    Hand=Leases[I].CommittedHand;
    if (Hand<0) return Host.Source.HeldState.LeftWeapon!=Leases[I].Weapon
        && Host.Source.HeldState.RightWeapon!=Leases[I].Weapon;
    if (Hand==0) return Host.Source.HeldState.LeftWeapon==Leases[I].Weapon
        && Host.Source.HeldState.LeftGeneration==Leases[I].Held.LeftGeneration;
    return Host.Source.HeldState.RightWeapon==Leases[I].Weapon
        && Host.Source.HeldState.RightGeneration==Leases[I].Held.RightGeneration;
}

function Update()
{
    local int I,Token;
    local VRWeaponRuntime R;
    local VRWorldDropPrediction P;
    for (I=Leases.Length-1; I>=0; --I)
    {
        R=Runtime(I); P=Leases[I].Prediction;
        if (R==None || !Host.Ready() || (R.WorldTrickPending!=0 && R.WorldTrickPending!=Leases[I].Token))
        {
            // Ready is handshake/pawn/connection lifetime, not pose tracking.
            // Lost calibration therefore follows authority recovery below;
            // a retired transport only clears its own exact runtime token.
            if (R!=None && R.WorldTrickPending==Leases[I].Token) R.WorldTrickPending=0;
            if (P!=None && !P.bDeleteMe) P.Destroy();
            Leases.Remove(I,1); continue;
        }
        if (Leases[I].bReply && R.WeaponReceiptSerial==Leases[I].SettleSerial)
        {
            Host.Source.AdoptWorldDropHeldState(Leases[I].Held);
            // Progress can also overtake an accepted candidate between its
            // reply and the separate stock-weapon marker becoming visible.
            if (Leases[I].SettleEvent!=Leases[I].Committed
                || (!Leases[I].bRecovery && P!=None && P.LatestEvent!=Leases[I].SettleEvent))
                Leases[I].bAccepted=false;
            if (Leases[I].bAccepted && !SettlementStillCurrent(I))
            {
                Leases[I].bAccepted=false; Leases[I].bAborted=true; Leases[I].bAbortConfirmed=false;
            }
            if (Leases[I].bAccepted && R.WorldTrickPending==Leases[I].Token
                && (Leases[I].bRecovery || (P!=None && !P.bDeleteMe && P.bVisualHeld
                    && P.LatestEvent==Leases[I].SettleEvent)))
            {
                if (Leases[I].Bridge.HandInventory.WorldDrops.ApplyTrickSettlement(P,Leases[I].Weapon,
                    Leases[I].CommittedHand,Leases[I].GripRole,Leases[I].Root,Leases[I].RootQ,
                    Leases[I].Token,Leases[I].bRecovery)) Leases.Remove(I,1);
                continue;
            }
            Leases[I].SettleRequest=0; Leases[I].SettleSerial=0; Leases[I].bReply=false;
        }
        else if (Leases[I].SettleRequest>0 && (R.WeaponReceiptSerial>Leases[I].SettleSerial
            || Host.WorldInfo.RealTimeSeconds-Leases[I].SettleAt>3.0))
        {
            Token=Host.NextWorldRequest();
            if (Token>0) Host.ServerAbortTrick(Host.BoundWorld,Host.BoundConnection,Host.BoundPawn,
                Token,Leases[I].Token,Leases[I].Weapon);
            Leases[I].SettleRequest=0; Leases[I].SettleSerial=0; Leases[I].bReply=false;
            Leases[I].bAborted=true;
        }
        if (!Leases[I].bEntryComplete && Host.WorldInfo.RealTimeSeconds-Leases[I].EntryAt>3.0)
        { Leases[I].bEntryComplete=true; Leases[I].bAborted=true; }
        if (!Leases[I].bEntryComplete || Leases[I].SettleRequest>0) continue;
        if (Leases[I].bAborted)
        {
            if (!Leases[I].bAbortConfirmed)
            {
                if (Host.WorldInfo.RealTimeSeconds>=Leases[I].NextAbort)
                {
                    Token=Host.NextWorldRequest();
                    if (Token>0) Host.ServerAbortTrick(Host.BoundWorld,Host.BoundConnection,Host.BoundPawn,
                        Token,Leases[I].Token,Leases[I].Weapon);
                    Leases[I].NextAbort=Host.WorldInfo.RealTimeSeconds+0.25;
                }
                continue;
            }
            if (Leases[I].bWorld)
            {
                if (P!=None && !P.bDeleteMe && P.AuthorityProp!=None) P.BeginAuthorityBlend();
                if (P==None || P.bDeleteMe) Leases.Remove(I,1);
            }
            else RequestSettlement(I,true);
            continue;
        }
        if (P==None || P.bDeleteMe)
        {
            Token=Host.NextWorldRequest();
            if (Token>0) Host.ServerAbortTrick(Host.BoundWorld,Host.BoundConnection,Host.BoundPawn,
                Token,Leases[I].Token,Leases[I].Weapon);
            Leases[I].bAborted=true; continue;
        }
        if (P.bVisualHeld && Leases[I].Committed==P.LatestEvent && Leases[I].CommittedAction==1)
            RequestSettlement(I,false);
        else if (!P.bVisualHeld && Leases[I].Committed==P.LatestEvent && Leases[I].CommittedAction==0
            && P.AuthorityProp!=None)
        {
            P.BeginAuthorityBlend();
            if (R.WorldDropped==1 && R.WorldTrickPending==Leases[I].Token) R.WorldTrickPending=0;
        }
    }
}

function Shutdown()
{
    local int I;
    local VRWeaponRuntime R;
    for (I=Leases.Length-1; I>=0; --I)
    {
        R=Runtime(I);
        // The lifetime is being explicitly retired with its connection/pawn.
        if (R!=None && R.WorldTrickPending==Leases[I].Token) R.WorldTrickPending=0;
        if (Leases[I].Prediction!=None && !Leases[I].Prediction.bDeleteMe) Leases[I].Prediction.Destroy();
    }
    Leases.Length=0;
}
