// Local ownership/presentation of one paid magazine payload per hand. The
// same lease goes to a pouch or an existing insertion guide. Only the backend
// changes ammo; there is no legacy instant-credit or reserve prediction path.
class VRMagazineRecovery extends Object dependson(VRDroppedMagazines);

// Alyx-style release velocity for this hand throw (VRThrowRelease).
var VRThrowRelease Thrower;

const ClaimAction = 1;
const PouchAction = 2;
const InsertAction = 3;
const ReleaseAction = 4;

var VRHandsBridge Bridge;
var VRHandInventory Inventory;
var VRDroppedMagazines Dropped;
var VRWorldDropHints Hints;
var bool bShutDown;

struct MagazineCarry
{
    var bool bActive, bClaimed, bGuide, bRequireFresh, bSawOpen, bReleaseQueued;
    var bool bAwaitClaimAdmission, bPouchContactQueued, bGenericCarry;
    var int Slot, Generation, Token, Remaining, Request, Calibration, RoomEpoch;
    var byte Action, Side, QueuedAction, QueuedSide;
    var byte AmmoSlot, PayloadKind;
    var KFWeapon SourceWeapon, TargetWeapon;
    var VRWeaponRuntime InsertRuntime;
    var KFPawn_Human InsertHuman;
    var class<KFWeapon> Family;
    var VRWorldDropMagazine WorldProp;
    var VRReloadHandPose Pose;
    var vector Origin, Velocity, ReleaseVelocity, RoomPosition;
    var quat Rotation, RoomQ, RoomToWorld;
    var float SampleTime;
    var bool bSampleReady, bCarryFramePublished, bPouchExitRequired;
};
var MagazineCarry Carries[2];

// A positive return owns an asynchronous request. ExpectedRemaining describes
// the exact payload; it never authorizes a client-provided reserve credit.
delegate int RequestAction(byte Action, int Hand, KFWeapon SourceW, int RemovalToken,
    KFWeapon TargetW, byte PouchSide, int ExpectedRemaining, optional VRWorldDropMagazine WorldProp) { return 0; }
// 0 pending, 1 terminal (Accepted decides), 2 abandoned lifetime. The binder
// applies the authoritative ammo snapshot before returning a terminal result.
delegate byte ReadAction(int Request, out byte Action, out byte Accepted,
    out KFWeapon TargetW, out int Actual, out int Remaining, out byte Retired) { return 2; }
// The guide binder explicitly calls BeginInsertGuide before taking the payload.
delegate bool TryBeginInsertGuide(VRMagazineRecovery Helper, int Hand, KFWeapon TargetW) { return false; }
delegate ConfirmedPouch(KFWeapon TargetW, int Actual, byte PouchSide, int ReceiptSerial, optional byte AmmoSlot) {}
delegate ConfirmedInsert(VRWeaponRuntime TargetRuntime, int Actual, int Hand, int ReceiptSerial, optional byte AmmoSlot) {}

function bool Initialize(VRHandsBridge B, VRHandInventory I, VRDroppedMagazines D)
{
    local int H;
    if (Bridge != None || B == None || I == None || I.Bridge != B || D == None || D.Bridge != B) return false;
    Bridge = B; Inventory = I; Dropped = D;
    Hints = new(self) class'VRWorldDropHints';
    Hints.bMagazinesOnly = true;
    Hints.Recovery = self;
    Hints.Initialize(B, I);
    for (H = 0; H < 2; ++H) Carries[H].Pose = new(self) class'VRReloadHandPose';
    return true;
}

function bool ContextValid(int Hand)
{
    local int Bit;
    if (Bridge == None || Inventory == None || Hand < 0 || Hand > 1
        || !Inventory.ContextValid() || Inventory.Input == None || !Inventory.Input.ContextValid()
        || Bridge.NativeHeadTracked == 0 || Bridge.NativeRecenterRequested != 0) return false;
    Bit = 1 << Hand;
    return (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bit) != 0
        && (Bridge.NativeRoomMotionMask & Bit) != 0
        && !Inventory.Input.IsSelectorOpen(Hand);
}

function bool Down(int Hand)
{
    local float Value;
    Value = Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
    return (Bridge.NativeGripMask & (1 << Hand)) != 0 && Value >= 0 && Value <= 1;
}

function bool Open(int Hand) { return Inventory.Input.GripReleased(Hand); }

// Deliberately does not call HandCarrying/Reloads.OwnsHand: the root adds this
// helper to those accessors, so doing so would recursively cancel its own hold.
function bool RawHandFree(int Hand)
{
    local VRDualHandInput Controls;
    local VRInteractiveReload Reloads;
    Controls = Inventory.Input;
    if (Inventory.Registry.GetPrimary(Hand) != None || Inventory.Registry.GetSupport(Hand) != None
        || Inventory.HasWorldGrab(Hand) || Inventory.HasGauntletHand(Hand) || Inventory.IsTransferPending(Hand)
        || Controls.IsSelectorOpen(Hand) || (Controls.Grenade != None && Controls.Grenade.IsHeld(Hand))
        || (Controls.Wallet != None && Controls.Wallet.IsBusy(Hand))
        || (Controls.Bow != None && Controls.Bow.OwnsHand(Hand))
        || (Controls.Deployables != None && Controls.Deployables.IsHeld(Hand))
        || (Inventory.WorldDrops != None && Inventory.WorldDrops.OwnsHand(Hand))) return false;
    if (Carries[Hand].bGuide) return true;
    Reloads = Controls.Reloads;
    return Reloads == None || (!(Reloads.bActive && Hand == Reloads.OffHand() && Reloads.HandMode != 0)
        && !(Reloads.bIdleBound && Hand == Reloads.IdleRackHand)
        && !(Reloads.Mechanism != None && Reloads.Mechanism.OwnsHand(Hand))
        && !(Reloads.Vampire != None && Reloads.Vampire.OwnsHand(Hand))
        && !(Reloads.Secondary != None && Reloads.Secondary.OwnsHand(Hand))
        && !(Reloads.Brawlers != None && Reloads.Brawlers.OwnsHand(Hand))
        && !(Reloads.M32Action != None && Reloads.M32Action.OwnsHand(Hand))
        && !(Reloads.FinishAction != None && Reloads.FinishAction.OwnsHand(Hand))
        && !(Reloads.Pump != None && Reloads.Pump.OwnsHand(Hand))
        && !(Reloads.ManualAction != None && Reloads.ManualAction.OwnsHand(Hand))
        && !(Reloads.BreakAction != None && Reloads.BreakAction.OwnsHand(Hand)));
}

function bool Compatible(KFWeapon SourceW, KFWeapon TargetW)
{
    return SourceW != None && !SourceW.bDeleteMe && TargetW != None && !TargetW.bDeleteMe
        && Inventory.Registry.IsOwned(TargetW)
        && class'VRWeaponDropState'.static.FamilyFor(SourceW.Class)
            == class'VRWeaponDropState'.static.FamilyFor(TargetW.Class);
}

function KFWeapon CompatibleOwned(KFWeapon SourceW)
{
    if (SourceW == None || SourceW.bDeleteMe) return None;
    return CompatibleOwnedFamily(class'VRWeaponDropState'.static.FamilyFor(SourceW.Class));
}

// A held gun first, then any owned one still in the inventory. A gun lying
// in the world is never a deposit target: the server refuses it, and Solo
// would otherwise credit a reserve the player cannot reach.
function KFWeapon CompatibleOwnedFamily(class<KFWeapon> Family, optional bool bAllowGround)
{
    local KFWeapon W, GroundGun;
    local VRWeaponRuntime R;
    local int H;
    if (Family == None || Bridge.Human == None || Bridge.Human.InvManager == None) return None;
    for (H = 0; H < 2; ++H)
    {
        R = Inventory.GetHeldForHand(H);
        if (R != None && R.Item != None && !R.Item.bDeleteMe && R.WorldDropped == 0
            && Inventory.Registry.IsOwned(R.Item)
            && class'VRWeaponDropState'.static.FamilyFor(R.Item.Class) == Family) return R.Item;
    }
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (W == None || W.bDeleteMe || !Inventory.Registry.IsOwned(W)
            || class'VRWeaponDropState'.static.FamilyFor(W.Class) != Family) continue;
        R = Inventory.Registry.FindItem(W);
        if (R == None || R.WorldDropped == 0) return W;
        GroundGun = W;
    }
    // A gun lying on the ground is still the player's (#122): its magazines
    // can be picked up and pulled (bAllowGround), as the authority allows,
    // though they never credit its reserve (#175).
    return bAllowGround ? GroundGun : None;
}

function bool CompatibleCarry(int Hand, KFWeapon TargetW)
{
    return TargetW != None && !TargetW.bDeleteMe && Inventory.Registry.IsOwned(TargetW)
        && Carries[Hand].Family != None
        && class'VRWeaponDropState'.static.FamilyFor(TargetW.Class) == Carries[Hand].Family;
}

function bool OwnsHand(int Hand)
{
    return Hand >= 0 && Hand < 2 && Carries[Hand].bActive;
}

function bool CoversHand(int Hand)
{
    return OwnsHand(Hand) && Carries[Hand].Pose != None && Carries[Hand].Pose.bVisible;
}

function bool GetPayload(int Hand, out VRDroppedMagazines.DroppedMagazine Payload)
{
    if (!OwnsHand(Hand) || !Dropped.LeaseValid(Carries[Hand].Slot, Carries[Hand].Generation)) return false;
    Payload = Dropped.Props[Carries[Hand].Slot];
    return true;
}

// bGripEdge is supplied by the input owner; holding over a magazine never
// retries acquisition. An acquired edge may wait for the shared mailbox;
// recipes are preflighted before a local lease is taken.
function bool TryGrab(int Hand, bool bGripEdge)
{
    local int I, Best, Generation, Token, StockHand;
    local float Distance, BestDistance, CarryTime;
    local name CarryAnim, CarryTrack;
    local KFWeapon RigWeapon;
    local VRMagazineCarryRecipe Recipe;
    local VRWorldDropMagazine Prop, BestProp;
    local VRDroppedMagazines.DroppedMagazine P;
    if (!bGripEdge || bShutDown || !ContextValid(Hand) || !Bridge.bRecoverMagazineAmmo
        || OwnsHand(Hand) || !Down(Hand) || !RawHandFree(Hand) || Dropped == None) return false;
    Best = -1;
    foreach Bridge.WorldInfo.AllActors(class'VRWorldDropMagazine', Prop)
    {
        if (!Prop.CanPickupBy(Bridge.Human) || Prop.RemovalToken <= 0 || Prop.Rounds <= 0
            || !Prop.NearHand(Bridge.PalmPosition(Hand), class'VRInteractiveReload'.default.PocketReach)
            || (OwnsHand(0) && Carries[0].WorldProp == Prop)
            || (OwnsHand(1) && Carries[1].WorldProp == Prop)
            || CompatibleOwnedFamily(Prop.Family, true) == None) continue;
        Distance = VSize(Prop.Location - Bridge.PalmPosition(Hand));
        if (BestProp == None || Distance < BestDistance) { BestProp = Prop; BestDistance = Distance; }
    }
    for (I = 0; I < ArrayCount(Dropped.Props); ++I)
    {
        P = Dropped.Props[I];
        if (!P.bLive || P.bLeased || P.WorldProp != None || P.Mesh == None || P.MagClass == None || P.RemovalToken <= 0
            || P.Rounds <= 0 || P.CarryAnim == '' || P.CarryTrack == ''
            || !(P.CarryTime >= 0 && P.CarryTime < 1000000) || P.StockHand < 0 || P.StockHand > 1
            || CompatibleOwnedFamily(class'VRWeaponDropState'.static.FamilyFor(P.MagClass), true) == None) continue;
        Distance = VSize(P.Position - Bridge.PalmPosition(Hand));
        if (Distance <= class'VRInteractiveReload'.default.PocketReach
            && ((Best < 0 && BestProp == None) || Distance < BestDistance))
        { Best = I; BestProp = None; BestDistance = Distance; }
    }
    if (BestProp != None)
    {
        RigWeapon = CompatibleOwnedFamily(BestProp.Family, true);
        Recipe = new(self) class'VRMagazineCarryRecipe';
        if (!Recipe.Sample(Bridge, RigWeapon, CarryAnim, CarryTrack, CarryTime, StockHand, BestProp.AmmoSlot, BestProp.PayloadKind)
            || ((CarryAnim != '' && CarryTrack != '') && !Carries[Hand].Pose.Build(Bridge, RigWeapon.MySkelMesh, CarryAnim, CarryTrack,
                CarryTime, CarryTime, Hand, StockHand))) return false;
        Best = Dropped.ImportWorld(BestProp, CarryAnim, CarryTrack, CarryTime, StockHand);
    }
    if (Best < 0) return false;
    P = Dropped.Props[Best];
    if (BestProp == None && (P.SourceWeapon.MySkelMesh == None || !Carries[Hand].Pose.Build(Bridge, P.SourceWeapon.MySkelMesh,
        P.CarryAnim, P.CarryTrack, P.CarryTime, P.CarryTime, Hand, P.StockHand))) return false;
    if (!Dropped.Acquire(Best, Generation)) { if (BestProp != None) Dropped.Take(Best); return false; }
    Carries[Hand].Slot = Best; Carries[Hand].Generation = Generation;
    Carries[Hand].SourceWeapon = P.SourceWeapon; Carries[Hand].Token = P.RemovalToken;
    Carries[Hand].Remaining = P.Rounds;
    Carries[Hand].AmmoSlot = P.AmmoSlot; Carries[Hand].PayloadKind = P.PayloadKind;
    Carries[Hand].bGenericCarry = P.PayloadKind == 1 && (CarryAnim == '' || CarryTrack == '');
    Carries[Hand].Family = class'VRWeaponDropState'.static.FamilyFor(P.MagClass);
    Carries[Hand].WorldProp = P.WorldProp;
    if (P.WorldProp != None) P.WorldProp.SetLocalLease(true);
    Carries[Hand].Origin = P.Position - QuatRotateVector(P.Rotation, P.Centre * P.Scale);
    Carries[Hand].Rotation = P.Rotation;
    Carries[Hand].bActive = true; Carries[Hand].bClaimed = false;
    Carries[Hand].bGuide = false; Carries[Hand].bRequireFresh = false; Carries[Hand].bSawOpen = false;
    Carries[Hand].bReleaseQueued = false; Carries[Hand].bSampleReady = false;
    Carries[Hand].bCarryFramePublished = false; Carries[Hand].bPouchExitRequired = false;
    Carries[Hand].Calibration = Bridge.NativeCalibrationEpoch; Carries[Hand].RoomEpoch = Bridge.NativeRoomSpaceEpoch;
    // A claim waits for local mailbox preconditions instead of being consumed.
    if (!Bridge.MagazineActionAdmissible(ClaimAction, P.SourceWeapon))
    {
        Carries[Hand].bAwaitClaimAdmission = true;
        return true;
    }
    Token = RequestAction(ClaimAction, Hand, P.SourceWeapon, P.RemovalToken, None, 255, P.Rounds, P.WorldProp);
    if (Token <= 0) { ClearLocal(Hand, true); return false; }
    Carries[Hand].Request = Token; Carries[Hand].Action = ClaimAction;
    Carries[Hand].Pose.Start(Bridge.WorldInfo.RealTimeSeconds);
    Bridge.QueueHandHaptic(1 << Hand, 0.3, 0.01);
    return true;
}

function ClearLocal(int Hand, bool bReturnToWorld)
{
    if (Carries[Hand].WorldProp != None && !Carries[Hand].WorldProp.bDeleteMe)
        Carries[Hand].WorldProp.SetLocalLease(false);
    if (bReturnToWorld && Dropped != None)
        Dropped.ReleaseLease(Carries[Hand].Slot, Carries[Hand].Generation, vect(0,0,0));
    Carries[Hand].Pose.Cancel();
    Carries[Hand].bActive = false; Carries[Hand].bClaimed = false; Carries[Hand].bGuide = false;
    Carries[Hand].bReleaseQueued = false; Carries[Hand].bRequireFresh = false;
    Carries[Hand].bAwaitClaimAdmission = false;
    Carries[Hand].bPouchContactQueued = false;
    Carries[Hand].Request = 0; Carries[Hand].SourceWeapon = None; Carries[Hand].TargetWeapon = None;
    Carries[Hand].InsertRuntime = None;
    Carries[Hand].InsertHuman = None;
    Carries[Hand].Remaining = 0; Carries[Hand].bSampleReady = false;
    Carries[Hand].bCarryFramePublished = false;
    Carries[Hand].Family = None; Carries[Hand].WorldProp = None;
}

// A refused pouch deposit (reserve full, payload spent) leaves the magazine
// with its carrier: still held, it stays in the hand and may be offered again
// after leaving the pouch; let go, it falls as an ordinary release. Neither
// leaves it frozen in the air.
function KeepAfterPouchRefusal(int Hand)
{
    Carries[Hand].Action = ClaimAction;
    Carries[Hand].bPouchContactQueued = false; Carries[Hand].bReleaseQueued = false;
    Carries[Hand].TargetWeapon = None;
    Carries[Hand].bPouchExitRequired = true;
    if (Down(Hand)) return;
    CaptureRelease(Hand, -1);
    SubmitRelease(Hand);
}

function CancelHand(int Hand)
{
    if (!OwnsHand(Hand)) return;
    if (Carries[Hand].bAwaitClaimAdmission) { ClearLocal(Hand, true); return; }
    Carries[Hand].Pose.Cancel();
    Carries[Hand].bRequireFresh = true; Carries[Hand].bSawOpen = false;
    Carries[Hand].bSampleReady = false; Carries[Hand].Velocity = vect(0,0,0);
    Carries[Hand].bCarryFramePublished = false;
    Carries[Hand].ReleaseVelocity = vect(0,0,0);
    Carries[Hand].bReleaseQueued = false;
    Carries[Hand].bPouchContactQueued = false;
    if (Carries[Hand].Request == 0) { Carries[Hand].bGuide = false; Carries[Hand].TargetWeapon = None; }
}

// Room-space velocity excludes stick locomotion and rejects tracking/turn
// discontinuities before they can become a deposit or a manufactured toss.
function bool SampleMotion(int Hand)
{
    local vector P, V;
    local quat Q, MapQ;
    local float Now, DT;
    P = Hand == 0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
    Q = QuatFromRotator(Hand == 0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation);
    MapQ = QuatProduct(QuatFromRotator(Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation), QuatInvert(Q));
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (!class'VRReloadMotionGuard'.static.ValidPosition(P) || !class'VRHandRolePose'.static.ValidQuaternion(MapQ)) return false;
    if (Carries[Hand].bSampleReady)
    {
        DT = Now - Carries[Hand].SampleTime;
        if (DT < 0 || DT > 0.08 || Abs(QuatDot(MapQ, Carries[Hand].RoomToWorld)) < 0.999
            || VSize(P - Carries[Hand].RoomPosition) > FMin(40, 2 + 1200 * DT)) return false;
        if (DT > 0)
        {
            V = QuatRotateVector(MapQ, (P - Carries[Hand].RoomPosition) / DT);
            if (VSize(V) > 700) V = Normal(V) * 700;
            Carries[Hand].Velocity += (V - Carries[Hand].Velocity) * FClamp(DT / 0.035, 0.15, 1);
            if (Thrower != None) Thrower.Add(Hand, V, Now);
        }
    }
    else
    {
        Carries[Hand].Velocity = vect(0,0,0);
        if (Thrower == None) Thrower = new(self) class'VRThrowRelease'; Thrower.Reset(Hand);
    }
    Carries[Hand].RoomPosition = P; Carries[Hand].RoomQ = Q; Carries[Hand].RoomToWorld = MapQ;
    Carries[Hand].SampleTime = Now; Carries[Hand].bSampleReady = true;
    return true;
}

function int NearestPouch(int Hand)
{
    local VRInteractiveReload R;
    local int Side, Best;
    local float Distance, BestDistance;
    R = Inventory.Input.Reloads;
    if (R == None) return -1;
    Best = -1;
    for (Side = 0; Side < 2; ++Side)
    {
        Distance = VSize(Bridge.PalmPosition(Hand) - R.BeltPositionFor(Side));
        if (Distance <= R.BeltRadius && (Best < 0 || Distance < BestDistance)) { Best = Side; BestDistance = Distance; }
    }
    return Best;
}

function SubmitRelease(int Hand)
{
    local int Request;
    local KFWeapon TargetW;
    if (!Carries[Hand].bClaimed || Carries[Hand].Request > 0 || !Carries[Hand].bReleaseQueued) return;
    Carries[Hand].Action = Carries[Hand].QueuedAction;
    Carries[Hand].Side = Carries[Hand].QueuedSide;
    if (Carries[Hand].Action == PouchAction) TargetW = CompatibleOwnedFamily(Carries[Hand].Family);
    // Authority already owns the payload. This bounded presentation message
    // supplies the actual release pose/motion without proposing any ammo count.
    if (Carries[Hand].Action == ReleaseAction
        && Dropped.LeaseValid(Carries[Hand].Slot, Carries[Hand].Generation))
        Bridge.PublishMagazinePresentation(Carries[Hand].Token, Carries[Hand].Origin,
            QuatToRotator(Carries[Hand].Rotation), Carries[Hand].ReleaseVelocity,
            Dropped.Props[Carries[Hand].Slot].Scale, Carries[Hand].WorldProp);
    Request = RequestAction(Carries[Hand].Action, Hand, Carries[Hand].SourceWeapon,
        Carries[Hand].Token, TargetW, Carries[Hand].Side, Carries[Hand].Remaining, Carries[Hand].WorldProp);
    if (Request <= 0) return;
    Carries[Hand].Request = Request; Carries[Hand].TargetWeapon = TargetW;
    Carries[Hand].bReleaseQueued = false;
}

function CaptureRelease(int Hand, int Side, optional bool bContact)
{
    Carries[Hand].bPouchContactQueued = bContact && Side >= 0;
    Carries[Hand].QueuedAction = Side >= 0 ? PouchAction : ReleaseAction;
    Carries[Hand].QueuedSide = Side >= 0 ? byte(Side) : byte(255);
    // Alyx's release: drop the braking frames, average direction at peak speed.
    Carries[Hand].ReleaseVelocity = Thrower != None
        ? Thrower.Release(Hand, Bridge.WorldInfo.RealTimeSeconds, Carries[Hand].Velocity) : Carries[Hand].Velocity;
    Carries[Hand].bReleaseQueued = true;
}

function Poll(int Hand)
{
    local byte Status, Action, Accepted, Retired;
    local int Actual, Remaining, Serial;
    local KFWeapon TargetW;
    local VRWeaponRuntime R;
    if (Carries[Hand].Request <= 0) return;
    Serial = Carries[Hand].Request;
    Status = ReadAction(Serial, Action, Accepted, TargetW, Actual, Remaining, Retired);
    if (Status == 0) return;
    Carries[Hand].Request = 0;
    if (Status != 1) { ClearLocal(Hand, true); return; }
    if (Action != Carries[Hand].Action || Actual < 0 || Remaining < 0
        || (Action != ClaimAction && Remaining > Carries[Hand].Remaining))
    { CancelHand(Hand); return; }
    if (Accepted == 0)
    {
        if (Action == ClaimAction) ClearLocal(Hand, true);
        else if (Action == PouchAction) KeepAfterPouchRefusal(Hand);
        else CancelHand(Hand);
        return;
    }
    if (Action == ClaimAction)
    {
        Carries[Hand].bClaimed = true;
        if (Actual != 0 || Retired != 0)
        { CancelHand(Hand); return; }
        // The world actor's replicated rounds can lag a prior partial pouch.
        // A claim receipt is the authoritative snapshot of this exact token.
        Carries[Hand].Remaining = Remaining;
        if (Dropped.LeaseValid(Carries[Hand].Slot, Carries[Hand].Generation))
            Dropped.Props[Carries[Hand].Slot].Rounds = Remaining;
        return;
    }
    if (Action == ReleaseAction)
    {
        if (Actual != 0 || Remaining != Carries[Hand].Remaining) { CancelHand(Hand); return; }
        Dropped.ReleaseLease(Carries[Hand].Slot, Carries[Hand].Generation, Carries[Hand].ReleaseVelocity);
        ClearLocal(Hand, false);
        return;
    }
    if ((Action != PouchAction && Action != InsertAction) || TargetW != Carries[Hand].TargetWeapon
        || Actual > Carries[Hand].Remaining || Remaining != Carries[Hand].Remaining - Actual
        || (Retired != 0 && Remaining != 0)) { CancelHand(Hand); return; }
    // Acceptance moved the paid payload already. Its feed state belongs to
    // the submitted actor/runtime, independently of tracking, hand ownership,
    // the insertion presentation, or the cosmetic lease surviving the reply.
    if (Action == InsertAction)
    {
        R = Carries[Hand].InsertRuntime;
        if (R != None && R.Inventory == Inventory.Registry && R.Item == TargetW && R.IsCurrent()
            && Carries[Hand].InsertHuman != None && !Carries[Hand].InsertHuman.bDeleteMe
            && Carries[Hand].InsertHuman.Health > 0
            && Inventory.Registry.Human == Carries[Hand].InsertHuman
            && Bridge.Human == Carries[Hand].InsertHuman)
        {
            if (Carries[Hand].AmmoSlot == 0)
            { R.EmptyMagazineEvent(1); R.MagazineFeedEvent(2); }
        }
        else R = None;
    }
    if (Actual > 0 && Dropped.ConsumeLease(Carries[Hand].Slot, Carries[Hand].Generation, Actual) != Actual)
    { CancelHand(Hand); return; }
    Carries[Hand].Remaining = Remaining;
    if (Action == PouchAction && Actual > 0)
    {
        if (Carries[Hand].PayloadKind == 2) Bridge.QueueHandHaptic(1 << Carries[Hand].Side, 0.35, 0.025);
        else ConfirmedPouch(TargetW, Actual, Carries[Hand].Side, Serial, Carries[Hand].AmmoSlot);
    }
    if (Action == InsertAction && R != None) ConfirmedInsert(R, Actual, Hand, Serial, Carries[Hand].AmmoSlot);
    if (Remaining == 0 && Retired != 0)
    {
        // Positive full consumption already retired the slot; zero-round
        // magazines need this explicit visual-only terminal operation.
        if (Actual == 0) Dropped.RetireEmptyLease(Carries[Hand].Slot, Carries[Hand].Generation);
        ClearLocal(Hand, false);
    }
    else CancelHand(Hand); // Remaining payload stays leased for a fresh grip.
}

function bool BeginInsertGuide(int Hand, KFWeapon TargetW)
{
    local VRWeaponRuntime R;
    if (!OwnsHand(Hand) || !ContextValid(Hand) || !Carries[Hand].bClaimed
        || Carries[Hand].Request > 0 || Carries[Hand].bRequireFresh || Carries[Hand].bReleaseQueued
        || !CompatibleCarry(Hand, TargetW)) return false;
    // A recovered cylinder returns through the pouch. Its existing physical
    // cylinder reload owns seating; it is not a detachable magazine well.
    if (Carries[Hand].PayloadKind != 0
        || (Carries[Hand].AmmoSlot == 0 && !class'VRMagazineCarryRecipe'.static.Supports(TargetW))
        || (Carries[Hand].AmmoSlot == 1 && !class'VRFamasMagazine'.static.Supports(TargetW))) return false;
    R = Inventory.GetHeldForHand(1-Hand);
    if (R == None || !R.IsCurrent() || R.Item != TargetW
        || !(Carries[Hand].AmmoSlot == 1 ? (R.SecondaryMagazineFlags & 1) != 0 : R.MagazineOut())
        || R.MechanismPending != 0 || R.SecondaryMagazinePending != 0) return false;
    Carries[Hand].TargetWeapon = TargetW; Carries[Hand].bGuide = true;
    return true;
}

function bool MoveInsertGuide(int Hand, vector Origin, quat Rotation)
{
    if (!OwnsHand(Hand) || !Carries[Hand].bGuide || Carries[Hand].Request > 0
        || !Dropped.MoveLease(Carries[Hand].Slot, Carries[Hand].Generation, Origin, Rotation)) return false;
    Carries[Hand].Origin = Origin; Carries[Hand].Rotation = Rotation;
    return true;
}

// Called only by the existing guide's actual seated crossing.
function bool RequestInsert(int Hand)
{
    local int Request;
    local VRWeaponRuntime R;
    if (!OwnsHand(Hand) || !Carries[Hand].bGuide || Carries[Hand].Request > 0
        || !ContextValid(Hand) || Carries[Hand].bRequireFresh) return false;
    R = Inventory.GetHeldForHand(1-Hand);
    if (R == None || !R.IsCurrent() || R.Item != Carries[Hand].TargetWeapon
        || !(Carries[Hand].AmmoSlot == 1 ? (R.SecondaryMagazineFlags & 1) != 0 : R.MagazineOut())
        || R.MechanismPending != 0 || R.SecondaryMagazinePending != 0 || !CompatibleCarry(Hand, R.Item)) return false;
    Request = RequestAction(InsertAction, Hand, Carries[Hand].SourceWeapon, Carries[Hand].Token,
        Carries[Hand].TargetWeapon, 255, Carries[Hand].Remaining, Carries[Hand].WorldProp);
    if (Request <= 0) return false;
    Carries[Hand].Request = Request; Carries[Hand].Action = InsertAction;
    Carries[Hand].InsertRuntime = R;
    Carries[Hand].InsertHuman = Inventory.Registry.Human;
    return true;
}

function CancelInsertGuide(int Hand)
{
    if (!OwnsHand(Hand) || Carries[Hand].Request > 0) return;
    Carries[Hand].bGuide = false; Carries[Hand].TargetWeapon = None;
}

function Update(float Delta)
{
    local int H, Side, Token;
    local VRWeaponRuntime Target;
    local bool QueuedContact;
    if (Hints != None) Hints.Update(!bShutDown && Bridge.bRecoverMagazineAmmo
        && (ContextValid(0) || ContextValid(1)));
    for (H = 0; H < 2; ++H)
    {
        Poll(H); // Submitted results drain even after context/settings loss.
        if (!OwnsHand(H)) continue;
        if (Carries[H].bAwaitClaimAdmission)
        {
            // No request or authority claim exists yet. Release/cancellation
            // returns the unchanged local lease; holding retries only this edge.
            if (bShutDown || !Bridge.bRecoverMagazineAmmo || !ContextValid(H) || !RawHandFree(H)
                || !Down(H) || Carries[H].Calibration != Bridge.NativeCalibrationEpoch
                || Carries[H].RoomEpoch != Bridge.NativeRoomSpaceEpoch
                || CompatibleOwnedFamily(Carries[H].Family, true) == None
                || !Dropped.LeaseValid(Carries[H].Slot, Carries[H].Generation)
                || VSize(Dropped.Props[Carries[H].Slot].Position - Bridge.PalmPosition(H))
                    > class'VRInteractiveReload'.default.PocketReach)
            { ClearLocal(H, true); continue; }
            if (!Bridge.MagazineActionAdmissible(ClaimAction, Carries[H].SourceWeapon)) continue;
            Token = RequestAction(ClaimAction, H, Carries[H].SourceWeapon, Carries[H].Token,
                None, 255, Carries[H].Remaining, Carries[H].WorldProp);
            if (Token <= 0) { ClearLocal(H, true); continue; }
            Carries[H].bAwaitClaimAdmission = false;
            Carries[H].Request = Token; Carries[H].Action = ClaimAction;
            Carries[H].Pose.Start(Bridge.WorldInfo.RealTimeSeconds);
            Bridge.QueueHandHaptic(1 << H, 0.3, 0.01);
            continue;
        }
        if (!Dropped.LeaseValid(Carries[H].Slot, Carries[H].Generation))
        {
            CancelHand(H);
            if (Carries[H].bClaimed && Carries[H].Request == 0)
            { CaptureRelease(H, -1); Carries[H].ReleaseVelocity = vect(0,0,0); SubmitRelease(H); }
            else if (Carries[H].Request == 0) ClearLocal(H, false);
            continue;
        }
        if (bShutDown || !Bridge.bRecoverMagazineAmmo)
        {
            CancelHand(H);
            if (Carries[H].bClaimed && Carries[H].Request == 0)
            { CaptureRelease(H, -1); Carries[H].ReleaseVelocity = vect(0,0,0); SubmitRelease(H); }
            continue;
        }
        if (!ContextValid(H) || !RawHandFree(H)
            || Carries[H].Calibration != Bridge.NativeCalibrationEpoch || Carries[H].RoomEpoch != Bridge.NativeRoomSpaceEpoch)
        {
            CancelHand(H);
            Carries[H].Calibration = Bridge.NativeCalibrationEpoch; Carries[H].RoomEpoch = Bridge.NativeRoomSpaceEpoch;
            continue;
        }
        if (!SampleMotion(H)) { CancelHand(H); continue; }
        if (Carries[H].Request > 0)
        {
            // Capture the first actual release while claim is in flight.
            // Later hand motion cannot turn an outside release into a deposit.
            if (Carries[H].Action == ClaimAction && !Carries[H].bRequireFresh
                && !Carries[H].bReleaseQueued && Open(H)) CaptureRelease(H, NearestPouch(H));
            continue;
        }
        if (Carries[H].bRequireFresh)
        {
            // A cancelled carry is still an authority lease. Opening the
            // hand must release it, rather than strand a floating prop until
            // another squeeze or a weapon switch happens.
            if (Open(H) && Carries[H].bClaimed)
            {
                Carries[H].bRequireFresh = false;
                CaptureRelease(H, -1); SubmitRelease(H); continue;
            }
            if (Open(H)) Carries[H].bSawOpen = true;
            if (Down(H) && Carries[H].bSawOpen)
            {
                Carries[H].bRequireFresh = false; Carries[H].bSawOpen = false;
                Carries[H].bCarryFramePublished = false;
                Carries[H].Pose.Start(Bridge.WorldInfo.RealTimeSeconds);
            }
            continue;
        }
        // Exact near-well admission wins over an overlapping belt sphere,
        // including a held-contact deposit waiting for the shared mailbox.
        // An actual open-hand release remains a deposit/drop, never a grab.
        if (!Carries[H].bGuide && Down(H) && Carries[H].bClaimed
            && (!Carries[H].bReleaseQueued || Carries[H].bPouchContactQueued))
        {
            QueuedContact = Carries[H].bReleaseQueued;
            Carries[H].bReleaseQueued = false;
            Target = Inventory.GetHeldForHand(1-H);
            if (Target != None && CompatibleCarry(H, Target.Item)
                && TryBeginInsertGuide(self, H, Target.Item))
            { Carries[H].bPouchContactQueued = false; continue; }
            Carries[H].bReleaseQueued = QueuedContact;
        }
        if (Carries[H].bReleaseQueued)
        {
            if (Carries[H].bPouchContactQueued)
            {
                if (NearestPouch(H) != Carries[H].QueuedSide)
                { Carries[H].bReleaseQueued = false; Carries[H].bPouchContactQueued = false; }
                else { SubmitRelease(H); continue; }
            }
            else if (!Open(H)) { Carries[H].bReleaseQueued = false; continue; }
            if (!Carries[H].bReleaseQueued) continue;
            if (Carries[H].QueuedAction == PouchAction && NearestPouch(H) != Carries[H].QueuedSide)
            { Carries[H].QueuedAction = ReleaseAction; Carries[H].QueuedSide = 255; Carries[H].ReleaseVelocity = vect(0,0,0); }
            SubmitRelease(H); continue;
        }
        Side = NearestPouch(H);
        if (Side < 0) Carries[H].bPouchExitRequired = false;
        if (Carries[H].bClaimed && Side >= 0 && (Down(H) || Open(H)) && !GuideNearWell(H)
            && !Carries[H].bPouchExitRequired)
        {
            // A hand can withdraw an unpaid recovered magazine from its
            // guide into the pouch. Retire the guide before changing owner.
            if (Carries[H].bGuide)
            {
                if (Carries[H].AmmoSlot == 1 && Inventory.Input.Reloads.Secondary != None
                    && Inventory.Input.Reloads.Secondary.bRecoveredMagazine)
                    Inventory.Input.Reloads.Secondary.Abort();
                if (Inventory.Input.Reloads.bRecoveredMagazineSession
                    && Inventory.Input.Reloads.Gun == Carries[H].TargetWeapon
                    && Inventory.Input.Reloads.OffHand() == H)
                    Inventory.Input.Reloads.Finish("recovered-magazine-pouched");
                CancelInsertGuide(H);
            }
            CaptureRelease(H, Side, true);
            SubmitRelease(H);
            continue;
        }
        // The insertion owner handles release/partial-settle while guiding.
        if (Carries[H].bGuide || !Open(H) || !Carries[H].bClaimed) continue;
        Side = NearestPouch(H);
        CaptureRelease(H, Side);
        SubmitRelease(H);
    }
}

// A Bullpup well can sit inside the belt return sphere. While the exact
// insertion owns that contact, pouch proximity must not steal its paid prop.
// Pulling away from the well still permits the existing pouch return gesture.
function bool GuideNearWell(int Hand)
{
    local VRInteractiveReload R;
    if (!Carries[Hand].bGuide || Inventory.Input == None) return false;
    R = Inventory.Input.Reloads;
    if (R == None) return false;
    if (Carries[Hand].AmmoSlot == 1)
        return R.Secondary != None && R.Secondary.bRecoveredMagazine
            && R.Secondary.Gun == Carries[Hand].TargetWeapon && R.Secondary.OffHand() == Hand
            && VSize(Bridge.Hands[Hand].Position - R.Secondary.Contact()) <= R.Secondary.Radius * 2;
    return R.bActive && R.bRecoveredMagazineSession && R.Gun == Carries[Hand].TargetWeapon
        && R.OffHand() == Hand
        && VSize(Carries[Hand].Origin - R.AmmoTarget()) <= 2 * R.SnapRadius * R.MagnetScale();
}

function LatePlace()
{
    local int H;
    local vector Contact, Wrist;
    local quat ContactQ, WristQ;
    local bool bHeld;
    for (H = 0; H < 2; ++H)
    {
        if (!OwnsHand(H)) continue;
        if (Carries[H].bAwaitClaimAdmission) { Carries[H].Pose.Cancel(); continue; }
        if (Carries[H].bGuide) { Carries[H].Pose.Cancel(); continue; }
        if (Carries[H].bRequireFresh || bShutDown || !ContextValid(H) || !RawHandFree(H)
            || Bridge.FreeHandPose == None || !Bridge.FreeHandPose.bReady
            || Carries[H].Calibration != Bridge.NativeCalibrationEpoch || Carries[H].RoomEpoch != Bridge.NativeRoomSpaceEpoch)
        { Carries[H].Pose.Cancel(); continue; }
        if (!Dropped.LeaseValid(Carries[H].Slot, Carries[H].Generation)) continue;
        Wrist = Bridge.Hands[H].Position;
        WristQ = Bridge.FreeHandPose.WristRotation(H, H == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
        if (Carries[H].bGenericCarry)
        { Contact = vect(0,0,0); ContactQ = QuatFromRotator(rot(0,0,0)); Wrist = Bridge.PalmPosition(H); }
        else Carries[H].Pose.GetFrame(0, Contact, ContactQ);
        // A deposit made while still gripping keeps the magazine in the hand
        // until the authority takes it; it never hangs where contact began.
        bHeld = Down(H) && (!Carries[H].bReleaseQueued || Carries[H].bPouchContactQueued)
            && (Carries[H].Request == 0 || Carries[H].Action == ClaimAction
                || (Carries[H].Action == PouchAction && Carries[H].bPouchContactQueued));
        if (!Carries[H].bGuide && bHeld)
        {
            Carries[H].Rotation = QuatProduct(WristQ, QuatInvert(ContactQ));
            Carries[H].Origin = Wrist - QuatRotateVector(Carries[H].Rotation, Contact * Dropped.Props[Carries[H].Slot].Scale);
        }
        if (Carries[H].bGenericCarry) Carries[H].Pose.Cancel();
        else Carries[H].Pose.Place(Bridge.WorldInfo.RealTimeSeconds, bHeld || Carries[H].bGuide, 0,
            Carries[H].bGuide ? 1.0 : 0.0, Wrist, WristQ, Carries[H].Origin, Carries[H].Rotation,
            Dropped.Props[Carries[H].Slot].Scale);
        if (!Carries[H].bGuide && bHeld && Carries[H].Pose.bVisible)
        {
            // Keep geometry on the wrist the player actually sees throughout
            // acquisition/regrip blending, as the existing reload carry does.
            Carries[H].Rotation = QuatProduct(Carries[H].Pose.LastWristQ, QuatInvert(ContactQ));
            Carries[H].Origin = Carries[H].Pose.LastWrist
                - QuatRotateVector(Carries[H].Rotation, Contact * Dropped.Props[Carries[H].Slot].Scale);
        }
        Dropped.MoveLease(Carries[H].Slot, Carries[H].Generation, Carries[H].Origin, Carries[H].Rotation);
        if (bHeld && (Carries[H].Pose.bVisible || Carries[H].bGenericCarry) && Carries[H].bClaimed && !Carries[H].bCarryFramePublished)
        {
            // One accepted cosmetic contact anchors remote carry to its hand;
            // subsequent tracked frames need no additional presentation RPC.
            Bridge.PublishMagazinePresentation(Carries[H].Token, Carries[H].Origin,
                QuatToRotator(Carries[H].Rotation), Carries[H].Velocity,
                Dropped.Props[Carries[H].Slot].Scale, Carries[H].WorldProp);
            Carries[H].bCarryFramePublished = true;
        }
    }
}

function bool Busy()
{
    return OwnsHand(0) || OwnsHand(1);
}

// Keep polling Update until Busy is false: an accepted claim/seat may arrive
// after shutdown, and only its backend may release the authority payload.
function Shutdown()
{
    bShutDown = true;
    if (Hints != None) { Hints.Shutdown(); Hints = None; }
    CancelHand(0); CancelHand(1);
}
