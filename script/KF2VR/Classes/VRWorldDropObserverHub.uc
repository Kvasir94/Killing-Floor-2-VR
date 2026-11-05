// Client-local relevance notifications and compact exact-item high watermarks.
// Transform work belongs to observers; discovery never runs at tracking rate.
class VRWorldDropObserverHub extends Actor;

struct ObservedProp
{
    var VRWorldDropGun Prop;
    var MeshComponent Mesh;
    var bool bApplied, bMeshWasHidden, bIdentitySettled;
    var float IdentityDeadline;
};
struct ItemStamp
{
    var KFPawn_Human Human;
    var int ItemId, Request;
    var bool bClosed;
};
var private array<ObservedProp> Props;
var private array<Actor> Observers;
var private array<ItemStamp> Stamps;

static function VRWorldDropObserverHub Find(Actor Context)
{
    local VRWorldDropObserverHub Hub;
    if (Context == None || Context.WorldInfo.NetMode == NM_DedicatedServer
        || Context.WorldInfo.NetMode == NM_Standalone) return None;
    foreach Context.DynamicActors(class'VRWorldDropObserverHub', Hub) return Hub;
    return Context.Spawn(class'VRWorldDropObserverHub');
}

simulated event PostBeginPlay()
{
    local VRWorldDropGun P;
    Super.PostBeginPlay();
    // One bootstrap scan handles a pose actor becoming relevant after props.
    foreach DynamicActors(class'VRWorldDropGun', P)
        if (P.RemoteRole != ROLE_None || P.Role < ROLE_Authority) RegisterProp(P);
    SetTimer(0.1, true, 'Compact');
}

simulated function RegisterObserver(Actor Observer)
{
    local int I;
    if (Observer == None || VRWorldDropObserver(Observer) == None || Observers.Find(Observer) != INDEX_NONE) return;
    Observers.AddItem(Observer);
    for (I = 0; I < Props.Length; ++I)
        if (Props[I].Prop != None && !Props[I].Prop.bDeleteMe)
            VRWorldDropObserver(Observer).WorldDropAvailable(Props[I].Prop);
    Refresh();
}

simulated function UnregisterObserver(Actor Observer)
{
    Observers.RemoveItem(Observer);
    Refresh();
}

simulated function RegisterProp(VRWorldDropGun P)
{
    local int I, J;
    local ObservedProp Entry;
    if (P == None || P.bDeleteMe || (P.RemoteRole == ROLE_None && P.Role == ROLE_Authority)) return;
    for (I = 0; I < Props.Length; ++I) if (Props[I].Prop == P) break;
    if (I == Props.Length)
    {
        Entry.Prop = P; Entry.IdentityDeadline = WorldInfo.RealTimeSeconds + 0.25;
        Props.AddItem(Entry);
    }
    for (J = 0; J < Observers.Length; ++J)
        if (Observers[J] != None && !Observers[J].bDeleteMe)
            VRWorldDropObserver(Observers[J]).WorldDropAvailable(P);
    RefreshOne(I);
}

simulated function UnregisterProp(VRWorldDropGun P)
{
    local int I;
    for (I = Props.Length - 1; I >= 0; --I) if (Props[I].Prop == P) Props.Remove(I, 1);
}

simulated function VRWorldDropGun Resolve(KFPawn_Human Human, int ItemId, int Request)
{
    local int I;
    local VRWorldDropGun P;
    for (I = 0; I < Props.Length; ++I)
    {
        P = Props[I].Prop;
        if (P != None && !P.bDeleteMe && P.DropOwner == Human
            && P.ReleasedItemId == ItemId && P.ReleaseRequestId == Request) return P;
    }
    return None;
}

simulated function VRWorldDropGun ResolveOwned(KFPawn_Human Human, KFWeapon Weapon, int Request, optional int LeaseToken)
{
    local int I;
    local VRWorldDropGun P;
    for (I = 0; I < Props.Length; ++I)
    {
        P = Props[I].Prop;
        if (P != None && !P.bDeleteMe && P.DropOwner == Human && P.OwnedWeapon == Weapon
            && ((Request > 0 && P.ReleaseRequestId == Request)
                || (LeaseToken > 0 && P.WorldTrickLeaseToken == LeaseToken))) return P;
    }
    return None;
}

simulated function bool Closed(KFPawn_Human Human, int ItemId, int Request)
{
    local int I;
    for (I = 0; I < Stamps.Length; ++I)
        if (Stamps[I].Human == Human && Stamps[I].ItemId == ItemId)
            return Stamps[I].Request > Request || (Stamps[I].Request == Request && Stamps[I].bClosed);
    return false;
}

simulated function Remember(KFPawn_Human Human, int ItemId, int Request, bool bClosed)
{
    local int I, J;
    local ItemStamp Stamp;
    if (Human == None || ItemId <= 0 || Request <= 0) return;
    for (I = 0; I < Stamps.Length; ++I)
        if (Stamps[I].Human == Human && Stamps[I].ItemId == ItemId) break;
    if (I == Stamps.Length)
    { Stamp.Human = Human; Stamp.ItemId = ItemId; Stamps.AddItem(Stamp); }
    if (Stamps[I].Request > Request) return;
    if (Stamps[I].Request == Request) bClosed = bClosed || Stamps[I].bClosed;
    Stamps[I].Request = Request; Stamps[I].bClosed = bClosed;
    if (bClosed)
        for (J = 0; J < Observers.Length; ++J)
            if (Observers[J] != None && !Observers[J].bDeleteMe)
                VRWorldDropObserver(Observers[J]).WorldDropClosed(Human, ItemId, Request);
    Refresh();
}

simulated function RefreshOne(int Index)
{
    local VRWorldDropGun P;
    local bool bHide;
    local int J;
    P = Props[Index].Prop;
    if (P == None || P.bDeleteMe) return;
    // Public death loot has its own authority lifetime and no release nonce.
    // A private pickup can receive its mesh before identity: defer only its
    // first render, with a bounded fallback if those references never resolve.
    if (P.bPublic || (P.DropOwner != None && P.ReleasedItemId > 0 && P.ReleaseRequestId > 0)
        || WorldInfo.RealTimeSeconds >= Props[Index].IdentityDeadline) Props[Index].bIdentitySettled = true;
    bHide = P.bOwnerVisualSuppressed;
    if (!P.bPublic)
    {
        bHide = bHide || !Props[Index].bIdentitySettled
            || (P.ReleaseRequestId > 0 && Closed(P.DropOwner, P.ReleasedItemId, P.ReleaseRequestId));
        for (J = 0; J < Observers.Length && !bHide; ++J)
            if (Observers[J] != None && !Observers[J].bDeleteMe)
                bHide = VRWorldDropObserver(Observers[J]).ShouldHideWorldDrop(P);
    }
    if (bHide)
    {
        if (!Props[Index].bApplied)
        {
            Props[Index].bMeshWasHidden = P.PresentationHidden() && !P.bOwnerVisualSuppressed;
        }
        else if (Props[Index].Mesh != P.MyMeshComp)
            Props[Index].bMeshWasHidden = P.PresentationHidden() && !P.bOwnerVisualSuppressed;
        Props[Index].Mesh = P.MyMeshComp;
        Props[Index].bApplied = true;
        // Component visibility is local. Actor bHidden on a listen server
        // would replicate one viewer's buffering decision to every client.
        P.SetPresentationHidden(true);
    }
    else if (Props[Index].bApplied)
    {
        P.SetPresentationHidden(Props[Index].bMeshWasHidden);
        Props[Index].bApplied = false;
    }
}

simulated function Refresh()
{
    local int I;
    for (I = 0; I < Props.Length; ++I) RefreshOne(I);
}

simulated function Compact()
{
    local int I;
    local bool bRefresh;
    for (I = Props.Length - 1; I >= 0; --I)
        if (Props[I].Prop == None || Props[I].Prop.bDeleteMe) Props.Remove(I, 1);
        else if (!Props[I].bIdentitySettled && WorldInfo.RealTimeSeconds >= Props[I].IdentityDeadline)
        { Props[I].bIdentitySettled = true; bRefresh = true; }
    for (I = Observers.Length - 1; I >= 0; --I)
        if (Observers[I] == None || Observers[I].bDeleteMe)
        { Observers.Remove(I, 1); bRefresh = true; }
    // One scalar stamp per exact item, never per toss/catch. A pawn lifetime
    // bounds identity: stamps cannot suppress another pawn's legitimate prop.
    for (I = Stamps.Length - 1; I >= 0; --I)
        if (Stamps[I].Human == None || Stamps[I].Human.bDeleteMe || Stamps[I].Human.Health <= 0)
        { Stamps.Remove(I, 1); bRefresh = true; }
    if (bRefresh) Refresh();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bReplicateMovement=false
    Physics=PHYS_None
}
