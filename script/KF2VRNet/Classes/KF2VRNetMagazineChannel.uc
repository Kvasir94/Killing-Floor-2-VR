// Owner transport for individual paid magazine payloads. Removal and either
// destination are ordered against the exact stock weapon, never predicted
// reserve credit. World props and local carry share this transaction ledger.
class KF2VRNetMagazineChannel extends Actor dependsOn(VRMagazinePayloadLedger, VRWeaponDropState);

var repnotify KF2VRNetChannel Source;
var repnotify KFPawn_Human Human;
var repnotify int BoundWorld, BoundConnection, BoundPawn;
var VRMagazinePayloadLedger Ledger;
var VRWorldMagazineRegistry Registry;

struct MagazineResult
{
    var int Request, Token, Actual, Remaining, MarkerSerial;
    var byte Action, Hand, PouchSide;
    var byte AmmoSlot;
    var int SecondaryFlags;
    var KFWeapon Weapon;
    var bool bAccepted, bHaveAmmo, bRetired;
    var int Ammo, Reserve, PairRevision;
    var VRWeaponPair Pair;
};

// Two lanes per side, so each hand's paired pistol can remove or seat its own
// magazine at once. Lanes never fence the same weapon; that stays one at a time.
const MagazineLanes = 2;

struct ServingLane
{
    var int Request, Token, Before, Kept, PairSession;
    var byte Action, Hand, Side, Slot;
    var KFWeapon Weapon;
    var VRWorldMagazineRegistry Registry;
    var VRMagazinePayloadLedger Ledger;
    var float Deadline;
    var bool bLoseRounds;
};
var private ServingLane Serving[MagazineLanes];

struct PendingLane
{
    var int Request, Token, PairSession;
    var byte Action, Slot;
    var KFWeapon Weapon;
    var VRWeaponRuntime Runtime;
    var bool bFence;
    var float StartedAt;
    var MagazineResult Result;
};
var private PendingLane Pending[MagazineLanes];
var private int LastRequest;

// Only authority removal creates an open well. Insert consumes that opening;
// the physical reload binder also closes it after an ordinary paid seating.
struct OpenMagazineWell
{
    var KFWeapon Weapon;
    var int RemovalToken, Kept;
};
var private array<OpenMagazineWell> OpenWells;

replication
{
    if (Role == ROLE_Authority)
        Source, Human, BoundWorld, BoundConnection, BoundPawn;
}

function bool Initialize(KF2VRNetChannel InSource, KFPawn_Human InHuman)
{
    if (Role != ROLE_Authority || InSource == None || InHuman == None
        || Owner != InSource.Owner || InHuman.Controller != Owner) return false;
    Source = InSource; Human = InHuman;
    BoundWorld = Source.WorldEpoch; BoundConnection = Source.ConnectionEpoch; BoundPawn = Source.PawnEpoch;
    Registry = class'VRWorldMagazineRegistry'.static.ForDonor(self, Human);
    if (Registry == None) return false;
    Registry.GetWeaponHand = WeaponHand;
    Registry.GetHandPosition = HandPosition;
    Registry.GetHandFrame = HandFrame;
    if (Source.WorldDrops != None) Registry.SetSharingSource(Source.WorldDrops.Registry);
    Ledger = Registry.Ledger;
    return Ledger != None;
}

simulated function bool ContextValid()
{
    return Source != None && !Source.bDeleteMe && Source.bHandshakeAccepted
        && Source.bVRTrackingEnabled && !Source.bSyntheticEnabled
        && Source.NativeWorldDropVersion == 9 && Human != None && !Human.bDeleteMe
        && Human.Health > 0 && Source.Owner == Owner && Human.Controller == Owner
        && Controller(Owner) != None && Controller(Owner).Pawn == Human
        && Source.WorldEpoch == BoundWorld && Source.ConnectionEpoch == BoundConnection
        && Source.PawnEpoch == BoundPawn;
}

simulated function bool Ready()
{
    // NativeWorldDropVersion is authority-local; the held snapshot is its
    // client capability publication. Do not infer a capability from existence.
    return Source != None && !Source.bDeleteMe && Human != None && Human.Health > 0
        && Source.CanRequestHeldWeapons() && Source.HeldState.Human == Human
        && Source.HeldState.NativeWeaponActionVersion == 9
        && Source.WorldEpoch == BoundWorld && Source.ConnectionEpoch == BoundConnection
        && Source.PawnEpoch == BoundPawn;
}

simulated function bool Busy()
{
    local int L;
    ExpireLocal();
    // A listen host owns both sides on the same actor. Its accepted reply
    // remains busy until the local carry owner has drained the receipt too.
    for (L = 0; L < MagazineLanes; ++L)
        if (Serving[L].Request > 0 || Pending[L].Request > 0) return true;
    return false;
}

// No owner lane is free for another request.
simulated function bool Full()
{
    ExpireLocal();
    return FreePendingLane() < 0;
}

simulated function int FreePendingLane()
{
    local int L;
    for (L = 0; L < MagazineLanes; ++L) if (Pending[L].Request <= 0) return L;
    return -1;
}

simulated function int PendingLaneFor(int Request)
{
    local int L;
    if (Request <= 0) return -1;
    for (L = 0; L < MagazineLanes; ++L) if (Pending[L].Request == Request) return L;
    return -1;
}

// Removal, pouch credit, insertion and the FAMAS secondary actions are ordered
// against their weapon's channel marker. Claim and release touch only a payload.
static function bool FencesWeapon(byte Action)
{
    return Action == 0 || Action == 2 || Action == 3 || Action >= 5;
}

// Claim, pouch deposit and release only move a payload lease.
static function bool LeaseAction(byte Action)
{
    return Action == 1 || Action == 2 || Action == 4;
}

// Authority answers within its one-second deadline. A reply or receipt
// marker that never drains must not lock every gun out of the pouch.
// An answered request is left for its reader to settle with the authority's
// own verdict (ReadResult); only one nobody reads at all is dropped later.
simulated function ExpireLocal()
{
    local float Age;
    local int L;
    for (L = 0; L < MagazineLanes; ++L)
    {
        Age = WorldInfo.RealTimeSeconds - Pending[L].StartedAt;
        if (Pending[L].Request <= 0 || Age <= class'KF2VRNetChannel'.const.OwnerReplyDeadline
            || (Pending[L].Result.Request == Pending[L].Request && Age <= 2 * class'KF2VRNetChannel'.const.OwnerReplyDeadline)) continue;
        `log("KF2VR_MAGAZINE_CHANNEL phase=expired request=" $ Pending[L].Request @ "action=" $ Pending[L].Action
            @ "weapon=" $ Pending[L].Weapon @ "reply=" $ (Pending[L].Result.Request == Pending[L].Request)
            @ "marker=" $ Pending[L].Result.MarkerSerial
            @ "receipt=" $ (Pending[L].Runtime != None ? Pending[L].Runtime.WeaponReceiptSerial : -1));
        ClearLocal(L);
    }
}

// True when nothing in flight disturbs the paired session (Session, or a new
// begin with 0) on W. Lease/deposit traffic never replaces a held physical
// reload, and an action on another gun, such as the other paired member, is
// independent of it. On W itself only that session's own removal or seat is.
function bool PreservesPairedSession(KFWeapon W, int Session)
{
    local int L;
    for (L = 0; L < MagazineLanes; ++L)
    {
        if (Serving[L].Request > 0 && !ActionPreserves(Serving[L].Action, Serving[L].Weapon,
            Serving[L].PairSession, W, Session)) return false;
        // A listen host's drained authority leaves the owner's unread receipt,
        // which is still that session's own removal or seat.
        if (Pending[L].Request > 0 && !ActionPreserves(Pending[L].Action, Pending[L].Weapon,
            Pending[L].PairSession, W, Session)) return false;
    }
    return true;
}

function bool ActionPreserves(byte Action, KFWeapon LaneWeapon, int LaneSession, KFWeapon W, int Session)
{
    local VRWeaponPair Pair;
    local int I;
    if (LeaseAction(Action) || LaneWeapon != W) return true;
    if (Session <= 0) return false;
    if (Action == 0) return LaneSession == Session;
    if (Action != 3) return false;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair == None) return false;
    I = Pair.PhysicalMemberIndex(W);
    return I >= 0 && Pair.PhysicalTokens[I] == Session;
}

function bool HandPosition(int Hand, out vector At)
{
    local KFPawn_Human Body;
    local byte Pose;
    local int Revision;
    return Hand >= 0 && Hand <= 1 && Source.ContactHand(Hand, Body, At, Pose, Revision)
        && Body == Human;
}

function bool HandFrame(int Hand, out vector At, out rotator Facing)
{
    local KFPawn_Human Body;
    return Source != None && !Source.bDeleteMe && Hand >= 0 && Hand <= 1
        && Source.ContactHandFrame(Hand, Body, At, Facing) && Body == Human;
}

function bool FreeHand(int Hand)
{
    return Hand >= 0 && Hand <= 1
        && (Hand == 0 ? Source.HeldState.LeftWeapon : Source.HeldState.RightWeapon) == None;
}

// The authority already admitted foregrip-only carry into this exact hand.
// Reload admission may use that contact without granting offensive ownership
// or accepting an unheld inventory actor. Keep role and runtime in agreement.
function bool HeldByHand(KFWeapon W, KF2VRNetItemRuntime R, int Hand)
{
    local bool bCarry;
    if (Hand < 0 || Hand > 1 || Source == None
        || Source.HeldState.Human != Human || R == None || Source.WorldDropRuntime(W) != R
        || R.Item != W || R.NativeReady != 1 || R.WorldDropped != 0
        || (Hand == 0 ? Source.HeldState.LeftWeapon : Source.HeldState.RightWeapon) != W) return false;
    bCarry = (Source.HeldState.CarryMask & (1 << Hand)) != 0;
    return bCarry ? (R.CarryOnly == 1 && class'VRHandsBridge'.static.SupportsCarryWeapon(W)) : R.CarryOnly == 0;
}

function int WeaponHand(KFWeapon W)
{
    local KF2VRNetItemRuntime R;
    local int Hand;
    if (Source == None) return -1;
    R = Source.WorldDropRuntime(W);
    for (Hand = 0; Hand < 2; ++Hand)
        if (HeldByHand(W, R, Hand)) return Hand;
    return -1;
}

function bool OwnedFamilyAvailable(class<KFWeapon> Family)
{
    local KFWeapon W;
    if (Family == None || Human == None || Human.InvManager == None) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (W != None && class'VRWorldDropTransfer'.static.Owns(Human, W)
            && class'VRWeaponDropState'.static.FamilyFor(W.Class) == Family) return true;
    return false;
}

function int WellFor(KFWeapon W)
{
    local int I;
    for (I = 0; I < OpenWells.Length; ++I) if (OpenWells[I].Weapon == W) return I;
    return -1;
}

// Called only by the validated weapon handoff, never by a client action.
// This migrates the opening's permission; it creates no payload or ammo credit.
function AdoptTransferredWell(KFWeapon W, VRWeaponDropState.HandlingState Handling)
{
    local VRWeaponPair Pair;
    if (Role != ROLE_Authority || !ContextValid()
        || !class'VRWorldDropTransfer'.static.Owns(Human, W)
        || !class'VRWeaponDropState'.static.Canonicalize(W, Handling)) return;
    if ((Handling.FeedFlags & 2) == 0 && (Handling.EmptyMagazineFlags & 1) == 0) return;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && !Pair.AdoptPhysicalMagazineWell(W, W.AmmoCount[0])) return;
    RecordWell(W, 1, W.AmmoCount[0]);
}

function RecordWell(KFWeapon W, int Token, int Kept)
{
    local int I;
    local OpenMagazineWell Well;
    for (I = OpenWells.Length - 1; I >= 0; --I)
        if (OpenWells[I].Weapon == None || OpenWells[I].Weapon.bDeleteMe) OpenWells.Remove(I, 1);
    I = WellFor(W);
    Well.Weapon = W; Well.RemovalToken = Token; Well.Kept = Kept;
    if (I < 0) OpenWells.AddItem(Well);
    else OpenWells[I] = Well;
}

// Called by a trusted authority reload binder, not from a client presentation.
function CloseWell(KFWeapon W, int RemovalToken)
{
    local int I;
    I = WellFor(W);
    if (I >= 0 && OpenWells[I].RemovalToken == RemovalToken) OpenWells.Remove(I, 1);
}

function CompactWells()
{
    local int I;
    local VRWeaponPair Pair;
    for (I = OpenWells.Length - 1; I >= 0; --I)
    {
        Pair = class'VRWeaponPair'.static.ForMember(OpenWells[I].Weapon);
        if (!class'VRWorldDropTransfer'.static.Owns(Human, OpenWells[I].Weapon)
            || OpenWells[I].Weapon.AmmoCount[0] > OpenWells[I].Kept
            || (Pair != None && !Pair.MagazineWellOpen(OpenWells[I].Weapon)))
            OpenWells.Remove(I, 1);
    }
}

function InvalidateWeapon(KFWeapon W)
{
    local int I, L;
    I = WellFor(W);
    if (I >= 0) OpenWells.Remove(I, 1);
    for (L = 0; L < MagazineLanes; ++L)
        if (Serving[L].Request > 0 && Serving[L].Weapon == W) Finish(L, false);
}

function Finish(int L, bool bAccepted, optional int Actual)
{
    local MagazineResult Reply;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local KF2VRNetItemRuntime Runtime;
    Reply.Request = Serving[L].Request; Reply.Token = Serving[L].Token; Reply.Action = Serving[L].Action;
    Reply.Hand = Serving[L].Hand; Reply.PouchSide = Serving[L].Side; Reply.Weapon = Serving[L].Weapon;
    Reply.AmmoSlot = Serving[L].Slot;
    Reply.bAccepted = bAccepted; Reply.Actual = Actual;
    if (Serving[L].Ledger != None && Serving[L].Ledger.Read(Serving[L].Token, Payload))
    { Reply.Remaining = Payload.Remaining; Reply.bRetired = Payload.bRetired; }
    else if (bAccepted && Serving[L].Action == 0 && class'VRBreakCatalog'.static.SwingOutCylinder(Serving[L].Weapon))
        Reply.Remaining = Actual; // exact batch debit, independently typed per-cartridge actors
    if (Serving[L].Registry != None) Serving[L].Registry.Refresh(Serving[L].Token);
    if (bAccepted && Serving[L].Action == 2 && KFWeap_AssaultRifle_Doshinegun(Serving[L].Weapon) != None)
        Source.GetPouchAmmo().UpdateCurrency(true);
    Runtime = Source != None ? Source.WorldDropRuntime(Serving[L].Weapon) : None;
    if (Runtime != None && Runtime.NativeReady == 1 && Serving[L].Weapon != None
        && class'VRWorldDropTransfer'.static.Owns(Human, Serving[L].Weapon)
        && (Serving[L].Slot == 0 || class'VRSecondaryReloadCatalog'.static.Supported(Serving[L].Weapon)))
    {
        Reply.bHaveAmmo = true;
        Reply.Ammo = Serving[L].Weapon.AmmoCount[Serving[L].Slot]; Reply.Reserve = Serving[L].Weapon.SpareAmmoCount[Serving[L].Slot];
        if (Serving[L].Slot == 1)
        {
            Reply.Reserve = class'VRFamasMagazine'.static.Reserve(Serving[L].Weapon);
            Reply.SecondaryFlags = Runtime.SecondaryMagazineFlags;
        }
        Reply.Pair = class'VRWeaponPair'.static.ForMember(Serving[L].Weapon);
        if (Reply.Pair != None) Reply.PairRevision = Reply.Pair.Revision;
        if (FencesWeapon(Serving[L].Action) && Runtime.WeaponBarrierSerial == Serving[L].Request)
        {
            // Ordinary corrections precede the receipt marker on this weapon
            // channel. The marker carries ordering, never an ammo count.
            if (Serving[L].Slot == 0) Serving[L].Weapon.ClientForceAmmoUpdate(Reply.Ammo, Reply.Reserve);
            else class'VRSecondaryAmmoPools'.static.CorrectOwner(Serving[L].Weapon);
            Serving[L].Weapon.ClientForceAmmoUpdate(-255, Serving[L].Request);
            Reply.MarkerSerial = Serving[L].Request;
        }
    }
    Serving[L].Request = 0; Serving[L].Token = 0; Serving[L].Weapon = None;
    Serving[L].Ledger = None; Serving[L].Registry = None;
    ClientResolved(Reply);
}

// Returns the admitted lane, or -1 after replying with a refusal. A weapon
// fenced by one lane cannot be fenced by the other until it finishes.
function int Admit(int WE, int CE, int PE, int Request, byte Action, int Token,
    KFWeapon W, int Hand, int Side)
{
    local int L, Other;
    L = -1;
    for (Other = 0; Other < MagazineLanes; ++Other)
    {
        if (Serving[Other].Request <= 0) { if (L < 0) L = Other; }
        else if (FencesWeapon(Action) && FencesWeapon(Serving[Other].Action) && Serving[Other].Weapon == W) L = MagazineLanes;
    }
    if (!ContextValid() || WE != BoundWorld || CE != BoundConnection || PE != BoundPawn
        || Request <= 0 || Request == MaxInt || Request <= LastRequest || L < 0 || L >= MagazineLanes)
    {
        Reject(Request, Token, Action, W, Hand, Side);
        return -1;
    }
    LastRequest = Request;
    Serving[L].Request = Request; Serving[L].Token = Token; Serving[L].Action = Action;
    Serving[L].Registry = Registry; Serving[L].Ledger = Ledger;
    Serving[L].Weapon = W; Serving[L].Hand = byte(Hand); Serving[L].Side = byte(Side);
    Serving[L].Slot = 0;
    Serving[L].Deadline = WorldInfo.RealTimeSeconds + 1.0;
    return L;
}

function Reject(int Request, int Token, byte Action, KFWeapon W, int Hand, int Side)
{
    local MagazineResult Reply;
    Reply.Request = Request; Reply.Token = Token; Reply.Action = Action;
    Reply.Weapon = W; Reply.Hand = byte(Hand); Reply.PouchSide = byte(Side);
    ClientResolved(Reply);
}

// Removal counts are checked against the ordered stock count. This path must
// replace legacy ReportMagazineRemoved for that removal, never also call it.
reliable server function ServerRemove(int WE, int CE, int PE, int Request, KFWeapon W,
    int Before, int Kept, bool bLoseRounds, optional int PairSession)
{
    local int L;
    L = Admit(WE, CE, PE, Request, 0, Request, W, 0, 0);
    if (L < 0) return;
    Serving[L].Before = Before; Serving[L].Kept = Kept;
    Serving[L].bLoseRounds = bLoseRounds;
    Serving[L].PairSession = PairSession;
    UpdateTransaction(L);
}

reliable server function ServerSecondary(int WE, int CE, int PE, int Request, byte Action,
    KFWeapon W, int Before, int Kept, bool Lose)
{
    local int L;
    if (Action < 5 || Action > 7) return;
    L = Admit(WE, CE, PE, Request, Action, Action == 5 ? Request : 0, W, 0, 0);
    if (L < 0) return;
    Serving[L].Slot = 1; Serving[L].Before = Before; Serving[L].Kept = Kept; Serving[L].bLoseRounds = Lose;
    UpdateTransaction(L);
}

reliable server function ServerClaim(int WE, int CE, int PE, int Request, int Token,
    KFWeapon SourceW, byte Hand, optional VRWorldDropMagazine WorldProp)
{
    local vector At;
    local int L;
    local bool OK;
    L = Admit(WE, CE, PE, Request, 1, Token, SourceW, Hand, 0);
    if (L < 0) return;
    Serving[L].Registry = class'VRWorldMagazineRegistry'.static.ForPayload(self, SourceW, Token, WorldProp);
    Serving[L].Ledger = Serving[L].Registry != None ? Serving[L].Registry.Ledger : None;
    WorldProp = Serving[L].Registry != None ? Serving[L].Registry.PropFor(Token) : None;
    if (WorldProp != None) SourceW = WorldProp.SourceWeapon;
    OK = Serving[L].Ledger != None && WorldProp != None && Serving[L].Registry.HandAvailable(Human, Hand)
        && FreeHand(Hand) && HandPosition(Hand, At)
        && WorldProp.CanPickupBy(Human) && OwnedFamilyAvailable(WorldProp.Family)
        && WorldProp.NearHand(At, class'VRInteractiveReload'.default.PocketReach)
        && Serving[L].Ledger.Claim(Token, SourceW, Human, Hand);
    // R22: the same grip scoops the rest of the pile into this payload.
    if (OK) Serving[L].Registry.ScoopInto(Token, Human);
    Finish(L, OK);
}

// The owner decides where its own hands are: a pouch deposit or a seat into
// its own gun is checked against the payload ledger, never hand geometry.
// Only a claim of a world magazine checks reach, since it takes a shared item.
reliable server function ServerPouch(int WE, int CE, int PE, int Request, int Token,
    KFWeapon TargetW, byte Hand, byte Side, optional KFWeapon SourceW, optional VRWorldDropMagazine WorldProp)
{
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local int L;
    L = Admit(WE, CE, PE, Request, 2, Token, TargetW, Hand, Side);
    if (L < 0) return;
    Serving[L].Registry = class'VRWorldMagazineRegistry'.static.ForPayload(self, SourceW, Token, WorldProp);
    Serving[L].Ledger = Serving[L].Registry != None ? Serving[L].Registry.Ledger : None;
    if (Serving[L].Ledger != None && Serving[L].Ledger.Read(Token, Payload)) Serving[L].Slot = Payload.AmmoSlot;
    UpdateTransaction(L);
}

reliable server function ServerInsert(int WE, int CE, int PE, int Request, int Token,
    KFWeapon TargetW, byte Hand, optional KFWeapon SourceW, optional VRWorldDropMagazine WorldProp)
{
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local int L;
    L = Admit(WE, CE, PE, Request, 3, Token, TargetW, Hand, 0);
    if (L < 0) return;
    Serving[L].Registry = class'VRWorldMagazineRegistry'.static.ForPayload(self, SourceW, Token, WorldProp);
    Serving[L].Ledger = Serving[L].Registry != None ? Serving[L].Registry.Ledger : None;
    if (Serving[L].Ledger != None && Serving[L].Ledger.Read(Token, Payload)) Serving[L].Slot = Payload.AmmoSlot;
    UpdateTransaction(L);
}

reliable server function ServerRelease(int WE, int CE, int PE, int Request, int Token, KFWeapon SourceW, byte Hand,
    optional VRWorldDropMagazine WorldProp)
{
    local int L;
    L = Admit(WE, CE, PE, Request, 4, Token, SourceW, Hand, 0);
    if (L < 0) return;
    Serving[L].Registry = class'VRWorldMagazineRegistry'.static.ForPayload(self, SourceW, Token, WorldProp);
    Serving[L].Ledger = Serving[L].Registry != None ? Serving[L].Registry.Ledger : None;
    Finish(L, Serving[L].Ledger != None && Serving[L].Ledger.Release(Token, Human, Hand));
}

function UpdateTransaction(int L)
{
    local KF2VRNetItemRuntime Runtime;
    local VRWeaponRuntime LocalItem;
    local VRHandsBridge LocalBridge;
    local KF2VRNetPlayerController PC;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local int Actual, I, Retained;
    local bool Accepted, bCylinderRemoval;
    local VRWeaponPair Pair;
    if (Serving[L].Request <= 0) return;
    if (!ContextValid() || WorldInfo.RealTimeSeconds >= Serving[L].Deadline
        || !class'VRWorldDropTransfer'.static.Owns(Human, Serving[L].Weapon)) { Finish(L, false); return; }
    Runtime = Source.WorldDropRuntime(Serving[L].Weapon);
    if (Runtime == None || Runtime.NativeReady != 1 || Runtime.WorldDropped != 0
        || Runtime.WeaponBarrierSerial > Serving[L].Request) { Finish(L, false); return; }
    // Earlier stock weapon handlers remain enabled until they reach the marker.
    if (Runtime.WeaponBarrierSerial != Serving[L].Request || Runtime.MechanismPending != 0) return;
    // A listen host fires through the local adapter. Its exact item owns the
    // spent-chamber flag even when a perk preserved the numerical ammo count.
    if (Serving[L].Slot == 1 && Human.IsLocallyControlled())
    {
        PC = KF2VRNetPlayerController(Owner);
        if (PC != None) LocalBridge = VRHandsBridge(PC.LocalVRBridge);
        if (LocalBridge != None && LocalBridge.HeldInventory != None)
            LocalItem = LocalBridge.HeldInventory.FindItem(Serving[L].Weapon);
        if (LocalItem != None && LocalItem.IsCurrent()) Runtime.SecondaryMagazineFlags = LocalItem.SecondaryMagazineFlags;
    }
    if (Serving[L].Action >= 5)
    {
        if (!class'VRFamasMagazine'.static.Supports(Serving[L].Weapon) || Serving[L].Weapon.AmmoCount[1] != Serving[L].Before
            || (!HeldByHand(Serving[L].Weapon, Runtime, 0) && !HeldByHand(Serving[L].Weapon, Runtime, 1)))
        { Finish(L, false); return; }
        if (Serving[L].Action == 5)
        {
            Accepted = class'VRFamasMagazine'.static.Remove(Ledger, Serving[L].Weapon, Serving[L].Token, Serving[L].Kept,
                Serving[L].bLoseRounds, Runtime.SecondaryMagazineFlags, Actual);
            if (Accepted) Registry.PublishPayload(Serving[L].Token);
        }
        else if (Serving[L].Action == 6) Accepted = class'VRFamasMagazine'.static.SeatFresh(Serving[L].Weapon, Runtime.SecondaryMagazineFlags, Actual, Serving[L].Kept);
        else Accepted = class'VRFamasMagazine'.static.Close(Serving[L].Weapon, Runtime.SecondaryMagazineFlags);
        Finish(L, Accepted, Actual); return;
    }
    if (Serving[L].Action == 0)
    {
        Pair = class'VRWeaponPair'.static.ForMember(Serving[L].Weapon);
        // A paired member whose earlier removal receipt was lost still shows
        // its magazine in. Its well is open on both the pair and this channel:
        // acknowledge with nothing removed, as for a single gun below, rather
        // than refusing every later reload until a stock reload closes it.
        I = WellFor(Serving[L].Weapon);
        if (Pair != None && I >= 0 && Pair.MagazineWellOpen(Serving[L].Weapon)
            && Serving[L].Before >= 0 && Serving[L].Weapon.AmmoCount[0] == Serving[L].Before
            && Serving[L].Before <= OpenWells[I].Kept
            && (Source.HeldState.LeftWeapon == Serving[L].Weapon || Source.HeldState.RightWeapon == Serving[L].Weapon))
        {
            Finish(L, true, 0);
            return;
        }
        if (Pair != None)
        {
            if (!class'VRMagazineCarryRecipe'.static.Supports(Serving[L].Weapon)
                || WellFor(Serving[L].Weapon) >= 0
                || (Source.HeldState.LeftWeapon != Serving[L].Weapon && Source.HeldState.RightWeapon != Serving[L].Weapon)
                || !Pair.CanExportPhysicalMagazine(Serving[L].Weapon, Serving[L].PairSession,
                    Serving[L].Kept, Serving[L].bLoseRounds, Actual)
                || !Ledger.CanRegisterRemoved(Serving[L].Weapon, Serving[L].Token, Actual))
            { Finish(L, false); return; }
            Accepted = Ledger.RegisterRemoved(Serving[L].Weapon, Serving[L].Token, Actual);
            if (Accepted)
            {
                Pair.ExportPhysicalMagazine(Serving[L].Weapon, Serving[L].PairSession, Serving[L].Kept,
                    Serving[L].bLoseRounds, Serving[L].Token);
                RecordWell(Serving[L].Weapon, Serving[L].Token, Serving[L].Kept);
                Registry.PublishPayload(Serving[L].Token);
            }
            Finish(L, Accepted, Accepted ? Actual : 0);
            return;
        }
        // The owner lost the receipt of an earlier accepted removal (or took
        // this gun with physical handling off) and still shows the magazine
        // in. The authority's well is already open: acknowledge with nothing
        // removed so both sides agree, instead of refusing every reload.
        I = WellFor(Serving[L].Weapon);
        if (I >= 0 && KFWeap_DualBase(Serving[L].Weapon) == None && Serving[L].Weapon.bReloadFromMagazine
            && Serving[L].Before >= 0 && Serving[L].Weapon.AmmoCount[0] == Serving[L].Before && Serving[L].Before <= OpenWells[I].Kept
            && (Source.HeldState.LeftWeapon == Serving[L].Weapon || Source.HeldState.RightWeapon == Serving[L].Weapon))
        {
            Serving[L].Weapon.ClearTimer('ReloadAmmoTimer'); Serving[L].Weapon.ClearTimer('ReloadStatusTimer');
            if (class'VRInteractiveReload'.static.MagazineReloading(Serving[L].Weapon)) Serving[L].Weapon.AbortReload();
            Finish(L, true, 0);
            return;
        }
        bCylinderRemoval = (!class'VRMagazineCarryRecipe'.static.Supports(Serving[L].Weapon)
            && class'VRMagazineCarryRecipe'.static.WholeLoad(Serving[L].Weapon))
            || class'VRBreakCatalog'.static.SwingOutCylinder(Serving[L].Weapon);
        if (KFWeap_DualBase(Serving[L].Weapon) != None || (!Serving[L].Weapon.bReloadFromMagazine && !bCylinderRemoval)
            || (!class'VRMagazineCarryRecipe'.static.Supports(Serving[L].Weapon) && !bCylinderRemoval)
            || (bCylinderRemoval && (Serving[L].Kept != 0 || !Serving[L].bLoseRounds))
            || Serving[L].Before < 0 || Serving[L].Weapon.AmmoCount[0] != Serving[L].Before
            || WellFor(Serving[L].Weapon) >= 0
            || Serving[L].Kept < 0 || Serving[L].Kept > Min(Serving[L].Before,
                Serving[L].Weapon.Class == class'KFWeap_Pistol_AF2011' ? 2 : 1)
            || (Source.HeldState.LeftWeapon != Serving[L].Weapon && Source.HeldState.RightWeapon != Serving[L].Weapon)
            || (!Serving[L].bLoseRounds && (Serving[L].Weapon.SpareAmmoCount[0] < 0
                || Serving[L].Before - Serving[L].Kept > MaxInt - Serving[L].Weapon.SpareAmmoCount[0]))
            || !Ledger.CanRegisterRemoved(Serving[L].Weapon, Serving[L].Token,
                Serving[L].bLoseRounds ? Serving[L].Before - Serving[L].Kept : 0))
        { Finish(L, false); return; }
        Runtime.MechanismPending = 1;
        // Registration is guaranteed by the preceding synchronous preflight;
        // nevertheless never debit if the bounded ledger refuses it.
        if (class'VRBreakCatalog'.static.SwingOutCylinder(Serving[L].Weapon))
            Accepted = class'VRWorldMagazineRegistry'.static.PreserveLoadedRounds(self, Human, Serving[L].Weapon, Serving[L].Before, 1);
        else Accepted = Ledger.RegisterRemoved(Serving[L].Weapon, Serving[L].Token,
            Serving[L].bLoseRounds ? Serving[L].Before - Serving[L].Kept : 0);
        if (Accepted)
        {
            // End authority's matching stock transaction before changing its
            // baseline. No pending stock notify may load an unseated spare.
            Serving[L].Weapon.ClearTimer('ReloadAmmoTimer'); Serving[L].Weapon.ClearTimer('ReloadStatusTimer');
            if (!bCylinderRemoval && class'VRInteractiveReload'.static.MagazineReloading(Serving[L].Weapon)) Serving[L].Weapon.AbortReload();
            Actual = Serving[L].bLoseRounds ? Serving[L].Before - Serving[L].Kept : 0;
            // No-loss counting returns old magazine contents to the owner's
            // reserve instead of minting a second spendable physical payload.
            if (!Serving[L].bLoseRounds) Serving[L].Weapon.SpareAmmoCount[0] += Serving[L].Before - Serving[L].Kept;
            Serving[L].Weapon.AmmoCount[0] = Serving[L].Kept;
            Serving[L].Weapon.bForceNetUpdate = true;
            if (bCylinderRemoval)
            {
                Serving[L].Weapon.ReloadAmountLeft = Max(Min(Serving[L].Weapon.MagazineCapacity[0], Serving[L].Weapon.SpareAmmoCount[0]), 0);
                Serving[L].Weapon.InitialReloadAmount = Serving[L].Weapon.ReloadAmountLeft;
            }
            else RecordWell(Serving[L].Weapon, Serving[L].Token, Serving[L].Kept);
            if (!class'VRBreakCatalog'.static.SwingOutCylinder(Serving[L].Weapon)) Registry.PublishPayload(Serving[L].Token);
        }
        Runtime.MechanismPending = 0;
        Finish(L, Accepted, Actual);
        return;
    }
    if (Serving[L].Ledger == None || !Serving[L].Ledger.Read(Serving[L].Token, Payload) || Payload.Carrier != Human
        || Payload.Hand != Serving[L].Hand || !FreeHand(Serving[L].Hand)) { Finish(L, false); return; }
    if (Serving[L].Action == 2)
    {
        Runtime.MechanismPending = 1;
        Accepted = Serving[L].Ledger.Pouch(Serving[L].Token, Human, Serving[L].Weapon, Actual);
        Runtime.MechanismPending = 0;
        Finish(L, Accepted, Actual);
        return;
    }
    if (Serving[L].Action == 3)
    {
        if (Serving[L].Slot == 1)
        {
            if (!class'VRFamasMagazine'.static.Supports(Serving[L].Weapon) || (Runtime.SecondaryMagazineFlags & 1) == 0
                || !HeldByHand(Serving[L].Weapon, Runtime, 1-Serving[L].Hand))
            { Finish(L, false); return; }
            Actual = Payload.Remaining;
            Retained = Serving[L].Weapon.AmmoCount[1];
            Accepted = Serving[L].Ledger.Insert(Serving[L].Token, Human, Serving[L].Weapon, Retained, true, true, 1);
            if (Accepted) Runtime.SecondaryMagazineFlags = (Runtime.SecondaryMagazineFlags & 2) | (Retained == 0 ? 2 : 0);
            Finish(L, Accepted, Accepted ? Actual : 0); return;
        }
        I = WellFor(Serving[L].Weapon);
        Retained = Serving[L].Weapon.AmmoCount[0];
        if (I < 0 || Retained < 0 || Retained > OpenWells[I].Kept
            || !HeldByHand(Serving[L].Weapon, Runtime, 1-Serving[L].Hand))
        { Finish(L, false); return; }
        Runtime.MechanismPending = 1;
        Actual = Payload.Remaining;
        // Agreed policy: the complete paid magazine fits even when another
        // player's perk gives this weapon a smaller nominal magazine capacity.
        Accepted = Serving[L].Ledger.Insert(Serving[L].Token, Human, Serving[L].Weapon, Retained, true, true);
        if (Accepted) OpenWells.Remove(I, 1);
        Runtime.MechanismPending = 0;
        Finish(L, Accepted, Accepted ? Actual : 0);
        return;
    }
    Finish(L, false);
}

simulated function VRHandsBridge OwnerBridge()
{
    local KF2VRNetPlayerController PC;
    local VRHandsBridge Bridge;
    PC = KF2VRNetPlayerController(Owner);
    if (PC != None) Bridge = VRHandsBridge(PC.LocalVRBridge);
    return (Bridge != None && Bridge.Human == Human && Bridge.HeldInventory != None) ? Bridge : None;
}

// Every local precondition Start refuses on, so an owner can wait for it
// instead of ending its reload. Only the authority's reply is a verdict.
simulated function bool CanStart(byte Action, KFWeapon W, optional int PairSession)
{
    local int L;
    local VRHandsBridge Bridge;
    local VRWeaponRuntime Runtime;
    if (!Ready() || Full() || !Source.OwnerActionsSettled(
        (Action == 0 || Action == 3) ? W : None, PairSession, LeaseAction(Action), false, true)) return false;
    // The other lane may serve the other hand's gun, never this one's fence.
    for (L = 0; L < MagazineLanes; ++L)
        if (Pending[L].Request > 0 && FencesWeapon(Action) && FencesWeapon(Pending[L].Action)
            && Pending[L].Weapon == W) return false;
    Bridge = OwnerBridge();
    if (Bridge == None) return false;
    if (Action == 1 || Action == 4) return true;
    if (W == None || W.bDeleteMe || W.Owner != Human) return false;
    // An unregistered stowed gun registers in Start; its state is checked there.
    Runtime = Bridge.HeldInventory.FindItem(W);
    return Runtime == None || (Runtime.IsCurrent() && Runtime.NativeReady == 1
        && Runtime.WorldDropped == 0 && Runtime.MechanismPending == 0 && Runtime.CycleEjectRequest == 0);
}

simulated function int Start(byte Action, int Token, KFWeapon W, optional int PairSession, optional byte AmmoSlot)
{
    local int Serial, L;
    local VRHandsBridge Bridge;
    local VRWeaponRuntime Runtime;
    if (!CanStart(Action, W, PairSession)) return 0;
    L = FreePendingLane();
    Bridge = OwnerBridge();
    if (Action == 1 || Action == 4)
    {
        Serial = Source.NextWeaponActionSerial();
        if (Serial <= 0) return 0;
        Pending[L].Request = Serial; Pending[L].Action = Action; Pending[L].Weapon = W; Pending[L].Runtime = None;
        Pending[L].Token = Token; Pending[L].StartedAt = WorldInfo.RealTimeSeconds;
        return Serial;
    }
    // A stowed owned weapon may never have been held. Register its exact
    // receipt target without activating it or publishing a hand assignment.
    Runtime = Bridge.HeldInventory.RegisterItem(W);
    if (Runtime == None || !Runtime.IsCurrent() || Runtime.NativeReady != 1
        || Runtime.WorldDropped != 0 || Runtime.MechanismPending != 0 || Runtime.CycleEjectRequest != 0) return 0;
    Serial = Source.NextWeaponActionSerial();
    if (Serial <= 0) return 0;
    Pending[L].Request = Serial; Pending[L].Action = Action; Pending[L].Weapon = W; Pending[L].Runtime = Runtime;
    Pending[L].Slot = AmmoSlot; Pending[L].StartedAt = WorldInfo.RealTimeSeconds;
    Pending[L].PairSession = PairSession;
    Pending[L].Token = (Action == 0 || Action == 5) ? Serial : Token;
    if (FencesWeapon(Action))
    {
        if (AmmoSlot == 0) W.StopFire(0);
        W.StopFire(1);
        if (Action == 2 && AmmoSlot == 0) Runtime.FlushPrimaryReloadPayment();
        W.SyncCurrentAmmoCount(255, Serial);
        if (AmmoSlot == 1) Runtime.SecondaryMagazinePending = 1;
        else Runtime.MechanismPending = 1;
        Pending[L].bFence = true;
    }
    return Serial;
}

simulated function int BeginRemoval(KFWeapon W, int Kept, bool bLoseRounds, optional int PairSession)
{
    local int Serial, Before;
    Before = W != None ? W.AmmoCount[0] : -1;
    Serial = Start(0, 0, W, PairSession);
    if (Serial > 0) ServerRemove(BoundWorld, BoundConnection, BoundPawn, Serial, W, Before, Kept, bLoseRounds, PairSession);
    return Serial;
}

simulated function int BeginSecondary(byte Action, KFWeapon W, int Kept, bool Lose)
{
    local int Serial;
    if (Action < 5 || Action > 7 || !class'VRFamasMagazine'.static.Supports(W)) return 0;
    Serial = Start(Action, 0, W, 0, 1);
    if (Serial > 0) ServerSecondary(BoundWorld, BoundConnection, BoundPawn, Serial, Action, W, W.AmmoCount[1], Kept, Lose);
    return Serial;
}

simulated function int BeginClaim(int Token, KFWeapon SourceW, int Hand, optional VRWorldDropMagazine WorldProp)
{
    local int Serial;
    if (Hand < 0 || Hand > 1 || Token <= 0) return 0;
    Serial = Start(1, Token, SourceW);
    if (Serial > 0) ServerClaim(BoundWorld, BoundConnection, BoundPawn, Serial, Token, SourceW, byte(Hand), WorldProp);
    return Serial;
}

simulated function int BeginPouch(int Token, KFWeapon TargetW, int Hand, int Side,
    optional KFWeapon SourceW, optional VRWorldDropMagazine WorldProp)
{
    local int Serial;
    if (Hand < 0 || Hand > 1 || Side < 0 || Side > 1 || Token <= 0) return 0;
    Serial = Start(2, Token, TargetW, 0, WorldProp != None ? WorldProp.AmmoSlot : 0);
    if (Serial > 0) ServerPouch(BoundWorld, BoundConnection, BoundPawn, Serial, Token,
        TargetW, byte(Hand), byte(Side), SourceW, WorldProp);
    return Serial;
}

simulated function int BeginInsert(int Token, KFWeapon TargetW, int Hand,
    optional KFWeapon SourceW, optional VRWorldDropMagazine WorldProp)
{
    local int Serial;
    if (Hand < 0 || Hand > 1 || Token <= 0) return 0;
    Serial = Start(3, Token, TargetW, 0, WorldProp != None ? WorldProp.AmmoSlot : 0);
    if (Serial > 0) ServerInsert(BoundWorld, BoundConnection, BoundPawn, Serial, Token, TargetW, byte(Hand), SourceW, WorldProp);
    return Serial;
}

simulated function int BeginRelease(int Token, KFWeapon SourceW, int Hand, optional VRWorldDropMagazine WorldProp)
{
    local int Serial;
    if (Hand < 0 || Hand > 1 || Token <= 0) return 0;
    Serial = Start(4, Token, SourceW);
    if (Serial > 0) ServerRelease(BoundWorld, BoundConnection, BoundPawn, Serial, Token, SourceW, byte(Hand), WorldProp);
    return Serial;
}

reliable client function ClientResolved(MagazineResult Reply)
{
    // Claim/release identify a paid payload, whose donor weapon may disappear
    // independently on either peer. Its transient actor reference must not
    // strand an accepted lease or discard the exact terminal release receipt.
    // Credit/removal/insertion still require their original weapon target.
    local int L;
    local VRHandsBridge Bridge;
    // Replay fault injection (#43): the owner ignores the authority's next
    // replies while the bridge asks, so a scripted run can show a lost reply
    // expiring. VRHandsBridge.TestDropMagazineReplies is always zero in play.
    Bridge = OwnerBridge();
    if (Bridge != None && Bridge.TestDropMagazineReplies > 0)
    {
        --Bridge.TestDropMagazineReplies;
        `log("KF2VR_MAGAZINE_CHANNEL phase=test-dropped request=" $ Reply.Request @ "action=" $ Reply.Action);
        return;
    }
    L = PendingLaneFor(Reply.Request);
    if (L >= 0 && Reply.Action == Pending[L].Action
        && Reply.Token == Pending[L].Token
        && (Reply.Weapon == Pending[L].Weapon || Pending[L].Action == 1 || Pending[L].Action == 4))
        Pending[L].Result = Reply;
}

simulated function ClearLocal(int L)
{
    if (Pending[L].bFence && Pending[L].Slot == 1 && Pending[L].Runtime != None && Pending[L].Runtime.Item == Pending[L].Weapon)
        Pending[L].Runtime.SecondaryMagazinePending = 0;
    if (Pending[L].bFence && Pending[L].Runtime != None && Pending[L].Runtime.Item == Pending[L].Weapon
        && Pending[L].Runtime.MechanismPending == 1 && Pending[L].Runtime.CycleEjectRequest == 0)
        Pending[L].Runtime.MechanismPending = 0;
    Pending[L].bFence = false;
    Pending[L].Request = 0; Pending[L].Token = 0; Pending[L].Weapon = None; Pending[L].Runtime = None;
}

simulated function PublishPresentation(int Token, vector At, rotator Facing, vector Velocity, float Scale,
    optional VRWorldDropMagazine WorldProp, optional vector ExitAxis, optional float ExitDistance, optional int ExitHand=-1)
{
    if (Ready() && Token > 0)
        ServerPresentation(BoundWorld, BoundConnection, BoundPawn, Token, At, Facing, Velocity, Scale, WorldProp, ExitAxis, ExitDistance, ExitHand);
}

reliable server function ServerPresentation(int WE, int CE, int PE, int Token, vector At,
    rotator Facing, vector Velocity, float Scale, optional VRWorldDropMagazine WorldProp,
    optional vector ExitAxis, optional float ExitDistance, optional int ExitHand=-1)
{
    local VRWorldMagazineRegistry PayloadRegistry;
    if (!ContextValid() || WE != BoundWorld || CE != BoundConnection || PE != BoundPawn) return;
    // A removal presentation belongs to this donor's receipt; a carried or
    // released foreign payload must provide its exact replicated world actor.
    if (WorldProp == None) WorldProp = Registry.PropFor(Token);
    if (WorldProp == None) return;
    PayloadRegistry = class'VRWorldMagazineRegistry'.static.ForPayload(self, WorldProp.SourceWeapon, Token, WorldProp);
    if (PayloadRegistry == None) return;
    PayloadRegistry.Refresh(Token);
    WorldProp.PresentFor(Human, At, Facing, Velocity, Scale, ExitAxis, ExitDistance, ExitHand);
}

function ReleaseAllLeases()
{
    local VRWorldMagazineRegistry PayloadRegistry;
    foreach WorldInfo.AllActors(class'VRWorldMagazineRegistry', PayloadRegistry)
        if (PayloadRegistry.Ledger != None) PayloadRegistry.Ledger.ReleaseCarrier(Human);
}

simulated function Abandon()
{
    ServerAbandon(BoundWorld, BoundConnection, BoundPawn);
    ClearAllLocal();
}

simulated function ClearAllLocal()
{
    local int L;
    for (L = 0; L < MagazineLanes; ++L) ClearLocal(L);
}

reliable server function ServerAbandon(int WE, int CE, int PE)
{
    local int L;
    if (WE != BoundWorld || CE != BoundConnection || PE != BoundPawn) return;
    for (L = 0; L < MagazineLanes; ++L) if (Serving[L].Request > 0) Finish(L, false);
    ReleaseAllLeases();
}

// Returns 0 waiting, 1 settled, 2 lifetime abandoned. The carry owner applies
// local mesh/hand changes only after this exact ordered stock receipt.
simulated function byte ReadResult(int Request, VRWeaponRuntime Runtime, out MagazineResult Reply)
{
    local int L;
    ExpireLocal();
    L = PendingLaneFor(Request);
    if (L < 0) return 2;
    if (!Ready()) { ClearLocal(L); return 2; }
    if (Pending[L].Result.Request != Request) return 0;
    // A terminal reply remains meaningful after stock removes its target.
    // There is no current owned ammo to reconcile: accepted spends the mag,
    // rejected preserves it. Neither waits forever on a now-unowned marker.
    if (Pending[L].Runtime == None || !Pending[L].Runtime.IsCurrent())
    { Reply = Pending[L].Result; ClearLocal(L); return 1; }
    if (Runtime == None) Runtime = Pending[L].Runtime;
    // The reply is the authority's verdict. Waiting for its marker only orders
    // the stock count corrections; an overtaken marker (serials only rise)
    // means they landed, and a late one must not turn an accepted debit into
    // a local refusal. Either way settle with the reply itself.
    if (WorldInfo.RealTimeSeconds - Pending[L].StartedAt <= class'KF2VRNetChannel'.const.OwnerReplyDeadline)
    {
        if (Pending[L].Result.MarkerSerial > 0)
        {
            if (Runtime == None || Runtime != Pending[L].Runtime || Runtime.Item != Pending[L].Weapon) return 0;
            if (Runtime.WeaponReceiptSerial < Pending[L].Result.MarkerSerial) return 0;
        }
        if (Pending[L].Result.bAccepted && Pending[L].Result.Pair != None
            && Pending[L].Result.Pair.Revision < Pending[L].Result.PairRevision) return 0;
    }
    Reply = Pending[L].Result;
    ClearLocal(L);
    return 1;
}

event Tick(float DeltaTime)
{
    local int L;
    if (Role != ROLE_Authority) return;
    CompactWells();
    for (L = 0; L < MagazineLanes; ++L) UpdateTransaction(L);
}

simulated event Destroyed()
{
    if (Role == ROLE_Authority) ReleaseAllLeases();
    ClearAllLocal();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bReplicateMovement=false
    bHidden=true
    bKillDuringLevelTransition=true
    NetUpdateFrequency=30
}
