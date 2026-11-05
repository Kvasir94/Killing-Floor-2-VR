// Local intent only. The callbacks own exact inventory/held-state authority.
// Call Update before ordinary grip arbitration. Each hand has its own intent
// and receipt; Busy fences whole-pair publication while either is unresolved.
class VRWorldDropInput extends Object;

// Alyx-style release velocity for this hand throw (VRThrowRelease).
var VRThrowRelease Thrower;

var VRHandsBridge Bridge;
var VRHandInventory Inventory;
var VRWorldDropHints Hints;
var bool bContextReady, bApplying, bResultContextValid, bResultGripHeld, bShutDown;
var int ApplyingHand;
var int Calibration, RoomEpoch, PreviousDownMask, SawOpenMask, EdgeMask, ClaimMask;
var int TickNumber, EdgeTick[2];
var float CatchUntil[2];
// A squeeze made ahead of an inbound toss keeps catching for AirCatchSeconds,
// so a gun arriving at a closed hand latches instead of passing through (#171).
var float AirCatchUntil[2];
var byte bCatchWindowOpen[2], bCatchRequestLogged[2];
var Actor CatchContact[2];
var KFWeapon CatchContactWeapon[2];
var KFPawn_Human CatchContactOwner[2];
var class<Inventory> CatchContactClass[2];
var int CatchContactIndex[2];

struct HandMotion
{
    var bool bReady;
    var float At;
    var vector Position, Linear, Angular;
    var quat Rotation, ToWorld;
    var int Samples;
};
var HandMotion Motion[2];

struct HeldIntent
{
    var VRWeaponRuntime Runtime;
    var int ItemId, ArmedHands, LeftRevision, RightRevision;
};
var HeldIntent Held[2];

struct HandAction
{
    var VRWeaponRuntime QueuedRuntime;
    var bool bQueuedExplicit;
    var KFWeapon QueuedWeapon;
    var int QueuedHand, QueuedItemId, QueuedRevision, QueuedHands, QueuedLeftRevision, QueuedRightRevision;
    var vector QueuedRoot, QueuedPalm, QueuedLinear, QueuedAngular;
    var rotator QueuedFacing;
    var float QueuedUntil;

    var int PendingRequest, PendingHand, PendingCalibration, PendingRoomEpoch;
    var byte PendingAction;
    var KFPawn_Human PendingHuman;
    var KFWeapon PendingWeapon;
    var bool bPendingContextLost;
    var bool bPendingCatchReleased;
    var float PendingCatchReleaseAt;
    var vector PendingCatchReleaseLinear, PendingCatchReleaseAngular;
};
var HandAction Actions[2];
var float ReleaseQueueSeconds, CatchBufferSeconds, AirCatchSeconds;

// Positive token means submitted; zero means temporarily unavailable. Neither
// callback may publish a partially changed held pair before returning a token.
delegate int RequestRelease(KFWeapon W, int Hand, vector RootPos, rotator Facing,
    vector Linear, vector Angular) { return 0; }
delegate int RequestCatch(Actor Prop, int Hand) { return 0; }
// Action: 0 release, 1 catch. Status: 0 pending, 1 terminal, 2 abandoned.
// ReadResult must adopt its authority held snapshot before reporting terminal.
delegate byte ReadResult(int Request, out byte Action, out byte Accepted,
    out KFWeapon W, out byte GripRole, out vector RootPos, out quat RootQ) { return 0; }
delegate ApplyResult(KFWeapon W, int Hand, byte Action, byte Accepted,
    byte GripRole, vector RootPos, quat RootQ) {}

function Initialize(VRHandsBridge B, VRHandInventory OwnerInventory)
{
    Bridge = B;
    Inventory = OwnerInventory;
    bShutDown = false;
    Hints = new(self) class'VRWorldDropHints';
    Hints.bGunsOnly = true;
    Hints.Initialize(B, OwnerInventory);
    ResetIntent();
}

function bool Enabled()
{
    return class'VRWorldWeaponPolicy'.static.Enabled()
        && Bridge != None && Bridge.bWorldWeaponDrops && Bridge.NativeWorldDropVersion == 9;
}

function bool ValidContext(optional bool bAllowSelector)
{
    return !bShutDown && Enabled() && Inventory != None && Inventory.ContextValid() && Inventory.Input != None
        && Inventory.Input.ContextValid() && Bridge.NativeHeadTracked != 0
        && Bridge.NativeRecenterRequested == 0 && Bridge.NativeMenuActive == 0
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3
        && (Bridge.NativeRoomMotionMask & 3) == 3
        && (bAllowSelector || (!Inventory.Input.IsSelectorOpen(0) && !Inventory.Input.IsSelectorOpen(1)));
}

function bool Down(int Hand)
{
    local float Value;
    Value = Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
    return Value == Value && Value >= 0 && Value <= 1.01
        && (Bridge.NativeGripMask & (1 << Hand)) != 0;
}

function bool Open(int Hand)
{
    return Inventory != None && Inventory.Input != None && Inventory.Input.GripReleased(Hand);
}

// Acquisition uses a fresh squeeze in every mode. Retention is role-specific:
// relaxing the pickup squeeze must not undo a latched main or toggle support.
function bool LatchedRole(byte Role)
{
    return Role == 0 ? Bridge.bToggleGrip : !Bridge.bHoldSupportGrip;
}

function ClearQueue(int H)
{
    Actions[H].bQueuedExplicit = false;
    Actions[H].QueuedRuntime = None;
    Actions[H].QueuedWeapon = None;
    Actions[H].QueuedHand = -1;
    Actions[H].QueuedUntil = 0;
}

function ResetHandMotion(int H)
{
    Motion[H].bReady = false; Motion[H].Samples = 0;
    Motion[H].Linear = vect(0,0,0); Motion[H].Angular = vect(0,0,0);
    if (Thrower != None) Thrower.Reset(H);
    if (Actions[H].QueuedRuntime != None)
    {
        Actions[H].QueuedLinear = vect(0,0,0); Actions[H].QueuedAngular = vect(0,0,0);
        Actions[H].QueuedUntil = -1;
    }
    Actions[H].PendingCatchReleaseLinear = vect(0,0,0);
    Actions[H].PendingCatchReleaseAngular = vect(0,0,0);
}

// This never abandons a submitted transaction. Its result must still drain,
// even after settings/tracking change; only authority can settle that action.
function ResetIntent(optional bool bKeepHeld, optional bool bKeepQueue)
{
    local int I;
    bContextReady = false;
    PreviousDownMask = 3;
    SawOpenMask = 0;
    EdgeMask = 0;
    ClaimMask = 0;
    for (I = 0; I < 2; ++I)
    {
        if (!bKeepQueue) ClearQueue(I);
        if (!bKeepHeld) { Held[I].Runtime = None; Held[I].ArmedHands = 0; }
        ResetHandMotion(I);
        CatchUntil[I] = 0; AirCatchUntil[I] = 0; EdgeTick[I] = -100;
        CatchContact[I] = None; CatchContactWeapon[I] = None; CatchContactOwner[I] = None;
    }
}

function bool Busy() { return Actions[0].PendingRequest > 0 || Actions[1].PendingRequest > 0 || bApplying; }

function bool HandPending(int Hand)
{
    return Hand >= 0 && Hand < 2 && Actions[Hand].PendingRequest > 0;
}

function bool WeaponPending(KFWeapon W)
{
    return W != None && ((Actions[0].PendingRequest > 0 && Actions[0].PendingWeapon == W)
        || (Actions[1].PendingRequest > 0 && Actions[1].PendingWeapon == W));
}

function bool OwnsHand(int Hand)
{
    local VRWeaponRuntime R;
    local int H;
    if (Hand < 0 || Hand > 1) return false;
    if (Inventory != None && Inventory.Registry != None)
    {
        R = Inventory.Registry.GetPrimary(Hand);
        if (R == None) R = Inventory.Registry.GetSupport(Hand);
    }
    for (H = 0; H < 2; ++H)
        if (R != None && ((Actions[H].PendingRequest > 0 && Actions[H].PendingAction == 0 && R.Item == Actions[H].PendingWeapon)
            || (Enabled() && R == Actions[H].QueuedRuntime))) return true;
    return HandPending(Hand)
        || (Inventory != None && Inventory.DeferredCatch[Hand].Weapon != None)
        || (Enabled() && (Actions[Hand].QueuedRuntime != None || (ClaimMask & (1 << Hand)) != 0));
}

function int HeldMask(VRWeaponRuntime R)
{
    local int Mask;
    if (R == None) return 0;
    if (R.PrimaryHand >= 0 && R.PrimaryHand < 2
        && Inventory.Registry.GetPrimary(R.PrimaryHand) == R) Mask = 1 << R.PrimaryHand;
    if (R.SupportHand >= 0 && R.SupportHand < 2
        && Inventory.Registry.GetSupport(R.SupportHand) == R) Mask = Mask | (1 << R.SupportHand);
    return Mask;
}

// A role on the other hand may change the item revision without changing
// this hand's physical hold. Keep its release debt through that publication,
// including an open sample; a rebind of this hand revokes the old debt.
function RefreshHeldIntent(int Slot, VRWeaponRuntime R)
{
    local int Mask;
    Mask = HeldMask(R);
    if (Held[Slot].Runtime != R || Held[Slot].ItemId != R.ItemId)
        Held[Slot].ArmedHands = 0;
    else
    {
        if (Held[Slot].LeftRevision != Inventory.Registry.HandRevision[0])
            Held[Slot].ArmedHands = Held[Slot].ArmedHands & ~1;
        if (Held[Slot].RightRevision != Inventory.Registry.HandRevision[1])
            Held[Slot].ArmedHands = Held[Slot].ArmedHands & ~2;
    }
    Held[Slot].Runtime = R; Held[Slot].ItemId = R.ItemId;
    Held[Slot].LeftRevision = Inventory.Registry.HandRevision[0];
    Held[Slot].RightRevision = Inventory.Registry.HandRevision[1];
    Held[Slot].ArmedHands = Held[Slot].ArmedHands & Mask;
}

function PruneHeldIntent()
{
    local int I;
    for (I = 0; I < 2; ++I)
        if (Held[I].Runtime != None && (!Held[I].Runtime.IsCurrent() || HeldMask(Held[I].Runtime) == 0))
        { Held[I].Runtime = None; Held[I].ArmedHands = 0; }
}

function bool ArmedFor(VRWeaponRuntime R, int Hand)
{
    local int I;
    for (I = 0; I < 2; ++I)
        if (Held[I].Runtime == R && (Held[I].ArmedHands & (1 << Hand)) != 0) return true;
    return false;
}

function bool AllOpen(VRWeaponRuntime R)
{
    local int H, Mask;
    if (R != None && ((R.PrimaryHand >= 0 && LatchedRole(0))
        || (R.SupportHand >= 0 && LatchedRole(1)))) return false;
    if (R != None && R.PrimaryHand >= 0 && Inventory.WaitsForFirstGrip(R, R.PrimaryHand)) return false;
    Mask = HeldMask(R);
    if (Mask == 0) return false;
    for (H = 0; H < 2; ++H)
        if ((Mask & (1 << H)) != 0 && !Open(H)) return false;
    return true;
}

function bool EmptyHand(int H)
{
    return Inventory.Registry.GetPrimary(H) == None && Inventory.Registry.GetSupport(H) == None
        && !Inventory.HasWorldGrab(H) && !Inventory.HasGauntletHand(H)
        && !Inventory.IsTransferPending(H) && !Inventory.Input.HandCarrying(H)
        && (Inventory.Input.Reloads == None || !Inventory.Input.Reloads.OwnsHand(H));
}

// Return room-space angular velocity in radians/sec, taking the short arc.
function vector AngularStep(quat Before, quat After, float DT)
{
    local quat D;
    local vector Axis;
    local float Angle;
    D = QuatProduct(After, QuatInvert(Before));
    if (D.W < 0) { D.X = -D.X; D.Y = -D.Y; D.Z = -D.Z; D.W = -D.W; }
    Axis.X = D.X; Axis.Y = D.Y; Axis.Z = D.Z;
    Angle = 2.0 * ACos(FClamp(D.W, -1, 1));
    return VSizeSq(Axis) > 0.000001 ? Normal(Axis) * (Angle / DT) : vect(0,0,0);
}

// Restart position tracking after a rejected sample, keeping prior momentum.
function ReseedHand(int H, float Now)
{
    local vector P;
    local quat Q, MapQ;
    P = H == 0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
    Q = QuatFromRotator(H == 0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation);
    MapQ = QuatProduct(QuatFromRotator(H == 0 ? Bridge.LeftRotation : Bridge.RightRotation), QuatInvert(Q));
    if (!Motion[H].bReady || !class'VRReloadMotionGuard'.static.ValidPosition(P)
        || !class'VRHandRolePose'.static.ValidQuaternion(Q)
        || !class'VRHandRolePose'.static.ValidQuaternion(MapQ))
    { ResetHandMotion(H); SampleHand(H, Now); return; }
    Motion[H].Position = P; Motion[H].Rotation = Q; Motion[H].ToWorld = MapQ; Motion[H].At = Now;
}

// Tracking discontinuity rejects the sample instead of becoming a clamped toss.
// Locomotion/recoil are excluded: room deltas are rotated into world space.
function bool SampleHand(int H, float Now)
{
    local HandMotion S;
    local vector P, V, A;
    local quat Q, WorldQ, MapQ;
    local float DT, Alpha, MapDot;
    S = Motion[H];
    P = H == 0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
    Q = QuatFromRotator(H == 0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation);
    WorldQ = QuatFromRotator(H == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    MapQ = QuatProduct(WorldQ, QuatInvert(Q));
    if (!class'VRReloadMotionGuard'.static.ValidPosition(P)
        || !class'VRHandRolePose'.static.ValidQuaternion(Q)
        || !class'VRHandRolePose'.static.ValidQuaternion(MapQ)) return false;
    if (S.bReady)
    {
        DT = Now - S.At;
        if (DT < 0 || DT > 0.08) return false;
        if (DT == 0) return VSizeSq(P - S.Position) < 0.0001 && Abs(QuatDot(Q, S.Rotation)) > 0.99999;
        MapDot = Abs(QuatDot(MapQ, S.ToWorld));
        if (MapDot < 0.999 || VSize(P - S.Position) > FMin(40, 2 + 1200 * DT)) return false;
        V = (P - S.Position) / DT;
        A = AngularStep(S.Rotation, Q, DT);
        if (!class'VRReloadMotionGuard'.static.ValidPosition(A)) return false;
        // A hard wrist snap is a real throw, not a tracking jump; clamp its
        // spin (as cosmetic local drops do) instead of discarding momentum.
        if (VSize(A) > 40) A = Normal(A) * 40;
        Alpha = FClamp(DT / 0.035, 0.15, 1);
        S.Linear += (V - S.Linear) * Alpha;
        if (Thrower != None) Thrower.Add(H, V, Now);
        S.Angular += (A - S.Angular) * Alpha;
        ++S.Samples;
    }
    else
    {
        S.Linear = vect(0,0,0); S.Angular = vect(0,0,0); S.Samples = 0;
        if (Thrower == None) Thrower = new(self) class'VRThrowRelease'; Thrower.Reset(H);
    }
    S.Position = P; S.Rotation = Q; S.ToWorld = MapQ; S.At = Now; S.bReady = true;
    Motion[H] = S;
    return true;
}

function bool CaptureRoot(VRWeaponRuntime R, int H, out vector Position, out quat Q)
{
    local name Root;
    local VRWorldDropPrediction P;
    if (R == None || !R.IsCurrent() || R.Presenter == None || R.Item.MySkelMesh == None
        || R.Presenter.ActiveProfile < 0 || R.Presenter.ActiveProfile >= R.Presenter.WeaponProfiles.Length) return false;
    if (Inventory.WorldDrops != None) P = Inventory.WorldDrops.PredictionFor(R.Item);
    if (P != None && P.bConfirmedAcquire && P.GetVisualRoot(Position, Q))
        return VSizeSq(Position - Bridge.PalmPosition(H)) <= Square(110.0);
    if (R.PrimaryHand < 0)
    {
        if (!R.Presenter.ForegripCarryRoot(Position, Q)) return false;
    }
    else
    {
        Root = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
        if (Root == '' || R.Item.MySkelMesh.MatchRefBone(Root) < 0) return false;
        Position = R.Item.MySkelMesh.GetBoneLocation(Root);
        Q = R.Item.MySkelMesh.GetBoneQuaternion(Root);
    }
    return class'VRReloadMotionGuard'.static.ValidPosition(Position)
        && class'VRHandRolePose'.static.ValidQuaternion(Q)
        && VSizeSq(Position - Bridge.PalmPosition(H)) <= Square(110.0);
}

function bool QueueRelease(VRWeaponRuntime R, int H, float Now)
{
    local vector Position, Linear, Angular;
    local quat Q;
    if (HandPending(H) || R.WorldDropped != 0 || !CaptureRoot(R, H, Position, Q)) return false;
    if (Motion[H].Samples >= 2 && Now - Motion[H].At <= 0.05)
    {
        // Alyx's release: drop the braking frames, average direction at peak speed.
        Linear = QuatRotateVector(Motion[H].ToWorld,
            Thrower != None ? Thrower.Release(H, Now, Motion[H].Linear) : Motion[H].Linear);
        Angular = QuatRotateVector(Motion[H].ToWorld, Motion[H].Angular);
    }
    // The release body applies the one throw rule (VRWorldDropGun.ShapeRelease).
    Actions[H].QueuedRuntime = R; Actions[H].QueuedWeapon = R.Item; Actions[H].QueuedHand = H;
    Actions[H].QueuedItemId = R.ItemId; Actions[H].QueuedRevision = R.OwnershipRevision;
    Actions[H].QueuedHands = HeldMask(R);
    Actions[H].QueuedLeftRevision = Inventory.Registry.HandRevision[0];
    Actions[H].QueuedRightRevision = Inventory.Registry.HandRevision[1];
    Actions[H].QueuedRoot = Position; Actions[H].QueuedFacing = QuatToRotator(Q);
    Actions[H].QueuedPalm = Bridge.PalmPosition(H); Actions[H].QueuedLinear = Linear; Actions[H].QueuedAngular = Angular;
    Actions[H].QueuedUntil = Now + ReleaseQueueSeconds;
    if (Bridge.NativePromoEvents != 0) Bridge.NativePromoAction(class'VRHandsBridge'.const.PROMO_GUN_RELEASE, R.Item, int(VSize(Linear)));
    return true;
}

function bool QueueRecoveredRelease(VRWeaponRuntime R, int H, VRWorldDropPrediction P)
{
    local vector Position, Linear, Angular;
    local quat Q;
    local float Now;
    if (!ValidContext() || HandPending(H) || R == None || !R.IsCurrent()
        || Inventory.GetHeldForHand(H) != R || R.WorldDropped != 0) return false;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Position = Bridge.PalmPosition(H);
    Q = QuatFromRotator(H == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    if (P != None && !P.bDeleteMe && P.bReleasedAgain && Now - P.RethrowAt <= 0.25
        && VSizeSq(P.RethrowPalm - Position) <= Square(45.0)
        && VSizeSq(P.SavedRethrowRoot - Position) <= Square(110.0) && P.bSavedRethrowRoot)
    {
        Position = P.SavedRethrowRoot; Q = P.SavedRethrowRootQ;
        Linear = P.RethrowLinear; Angular = P.RethrowAngular;
    }
    Actions[H].QueuedRuntime = R; Actions[H].QueuedWeapon = R.Item; Actions[H].QueuedHand = H;
    Actions[H].QueuedItemId = R.ItemId; Actions[H].QueuedRevision = R.OwnershipRevision;
    Actions[H].QueuedHands = HeldMask(R);
    Actions[H].QueuedLeftRevision = Inventory.Registry.HandRevision[0];
    Actions[H].QueuedRightRevision = Inventory.Registry.HandRevision[1];
    Actions[H].QueuedRoot = Position; Actions[H].QueuedFacing = QuatToRotator(Q);
    Actions[H].QueuedPalm = Bridge.PalmPosition(H); Actions[H].QueuedLinear = Linear; Actions[H].QueuedAngular = Angular;
    Actions[H].QueuedUntil = Now + ReleaseQueueSeconds; Actions[H].bQueuedExplicit = true;
    return true;
}

function BeginPending(int Token, int Hand, byte Action, KFWeapon W)
{
    Actions[Hand].PendingRequest = Token; Actions[Hand].PendingHand = Hand; Actions[Hand].PendingAction = Action;
    Actions[Hand].bPendingCatchReleased = false;
    Actions[Hand].PendingWeapon = W;
    Actions[Hand].PendingHuman = Bridge.Human; Actions[Hand].PendingCalibration = Calibration; Actions[Hand].PendingRoomEpoch = RoomEpoch;
    Actions[Hand].bPendingContextLost = false;
    ClaimMask = ClaimMask | (1 << Hand);
    CatchUntil[Hand] = 0; AirCatchUntil[Hand] = 0;
}

function StowRefusedRelease(int Slot, int Hand, KFWeapon W, string Stage)
{
    local VRWeaponRuntime R;
    if (Slot >= 0) ClearQueue(Slot);
    R = Inventory.Registry.FindItem(W);
    if (R == None || Hand < 0 || Hand > 1 || Inventory.GetHeldForHand(Hand) != R || !Open(Hand)) return;
    `log("KF2VR_WORLD_DROP phase=hold-release-stowed stage=" $ Stage @ "weapon=" $ W.Class @ "hand=" $ Hand
        @ "state=" $ W.GetStateName());
    Inventory.ReleaseHand(Hand, true);
}

function bool QueuedReleaseCurrent(int H)
{
    return Actions[H].QueuedRuntime != None && Actions[H].QueuedRuntime.IsCurrent() && Actions[H].QueuedRuntime.Item == Actions[H].QueuedWeapon
        && Actions[H].QueuedRuntime.ItemId == Actions[H].QueuedItemId && Actions[H].QueuedRuntime.OwnershipRevision == Actions[H].QueuedRevision
        && ((Actions[H].QueuedHands & 1) == 0 || Inventory.Registry.HandRevision[0] == Actions[H].QueuedLeftRevision)
        && ((Actions[H].QueuedHands & 2) == 0 || Inventory.Registry.HandRevision[1] == Actions[H].QueuedRightRevision)
        && HeldMask(Actions[H].QueuedRuntime) == Actions[H].QueuedHands && (Actions[H].bQueuedExplicit || AllOpen(Actions[H].QueuedRuntime));
}

function SubmitQueue(int H, float Now)
{
    local int Token;
    local vector Position;
    local quat Q;
    if (HandPending(H) || Actions[H].QueuedRuntime == None) return;
    if (!QueuedReleaseCurrent(H)) { ClearQueue(H); return; }
    // Waiting for another action does not revoke a real release. Its motion
    // sample does expire: drop from the current held frame without old momentum.
    if (Now > Actions[H].QueuedUntil)
    {
        Actions[H].QueuedLinear = vect(0,0,0); Actions[H].QueuedAngular = vect(0,0,0);
        if (!CaptureRoot(Actions[H].QueuedRuntime, Actions[H].QueuedHand, Position, Q)) return;
        Actions[H].QueuedRoot = Position; Actions[H].QueuedFacing = QuatToRotator(Q);
        Actions[H].QueuedPalm = Bridge.PalmPosition(Actions[H].QueuedHand);
    }
    Token = RequestRelease(Actions[H].QueuedWeapon, Actions[H].QueuedHand, Actions[H].QueuedRoot, Actions[H].QueuedFacing, Actions[H].QueuedLinear, Actions[H].QueuedAngular);
    if (Token <= 0)
    {
        // A transient refusal (firing, a busy action) retries. One that
        // outlasts the release window must not leave an open Hold hand
        // still carrying the item: stow it instead.
        if (!Bridge.bToggleGrip && !Actions[H].bQueuedExplicit && Now > Actions[H].QueuedUntil + 0.25
            && !(Inventory.WorldDrops != None && Inventory.WorldDrops.ReleaseSettling(Actions[H].QueuedWeapon)))
            StowRefusedRelease(H, Actions[H].QueuedHand, Actions[H].QueuedWeapon, "request");
        return;
    }
    BeginPending(Token, Actions[H].QueuedHand, 0, Actions[H].QueuedWeapon);
    ClearQueue(H);
}

// A deliberate draw may be published one tick after its initiating squeeze.
// A grip already held on mode entry/settings changes is never a fresh draw.
function ObserveHeld(float Now)
{
    local VRWeaponRuntime R;
    local int I, H, Slot, Mask, Fresh;
    PruneHeldIntent();
    for (H = 0; H < 2; ++H)
    {
        R = Inventory.GetHeldForHand(H);
        if (R == None || !R.IsCurrent() || R.WorldDropped != 0) continue;
        if (WeaponPending(R.Item) || !class'VRWorldDropGun'.static.HasWorldArt(R.Item)) continue;
        Slot = -1;
        for (I = 0; I < 2; ++I) if (Held[I].Runtime == R) Slot = I;
        if (Slot < 0)
        {
            for (I = 0; I < 2; ++I) if (Held[I].Runtime == None && Slot < 0) Slot = I;
            if (Slot < 0) continue;
        }
        RefreshHeldIntent(Slot, R);
        Mask = HeldMask(R);
        Fresh = EdgeMask & Mask;
        // Support acquisition happens after this coordinator. Its squeeze
        // from the preceding tick still arms that same actor's new support
        // role, so releasing the primary can hand retention to the carrier.
        for (I = 0; I < 2; ++I)
            if ((Mask & (1 << I)) != 0 && Down(I) && EdgeTick[I] >= TickNumber - 1)
                Fresh = Fresh | (1 << I);
        Held[Slot].ArmedHands = Held[Slot].ArmedHands | Fresh;
        // Hold is a level, not a squeeze-edge latch. Tracking/context guards
        // above already ensure an open sample is real. Spawn equipment and
        // quick swaps retain an open hand only until its first squeeze.
        if (R.PrimaryHand >= 0 && !Bridge.bToggleGrip
            && !Inventory.WaitsForFirstGrip(R, R.PrimaryHand))
            Held[Slot].ArmedHands = Held[Slot].ArmedHands | (1 << R.PrimaryHand);
        if (R.SupportHand >= 0 && Bridge.bHoldSupportGrip)
            Held[Slot].ArmedHands = Held[Slot].ArmedHands | (1 << R.SupportHand);
        if (Held[Slot].ArmedHands != 0 && AllOpen(R) && Actions[H].QueuedRuntime == None)
        {
            if (QueueRelease(R, H, Now)) Held[Slot].ArmedHands = 0;
        }
    }
}

// The squeeze can still take a catch: just made, or held ahead of a toss.
function bool CatchWindowOpen(int H, bool bAirborne, float Now)
{
    return (CatchUntil[H] > 0 && Now <= CatchUntil[H]) || (bAirborne && AirCatchUntil[H] > 0 && Now <= AirCatchUntil[H]);
}

function Actor ContactGun(int Hand, optional bool bAirborneOnly)
{
    local VRWorldDropGun Prop;
    local KFDroppedPickup Stock;
    local KFPickupFactory_Item Factory;
    local Actor Best;
    local vector Palm, PrimaryAt, SupportAt;
    local float Distance, BestDistance;
    Palm = Bridge.PalmPosition(Hand);
    BestDistance = 100000000;
    foreach Bridge.WorldInfo.AllActors(class'VRWorldDropGun', Prop)
    {
        if (Inventory.WorldDrops != None && Inventory.WorldDrops.PredictionFor(Prop.OwnedWeapon) != None) continue;
        if (bAirborneOnly && !class'VRGravityPullChannel'.static.Airborne(Prop)) continue;
        if (!Prop.CanPickupBy(Bridge.Human) || Prop.GripRoleAt(Palm, Hand, true) < 0) continue;
        Distance = VSizeSq(Palm - Prop.GrabPosition());
        if (Prop.GripContacts(Hand, PrimaryAt, SupportAt))
            Distance = FMin(VSizeSq(Palm - PrimaryAt), VSizeSq(Palm - SupportAt));
        if (Prop.bGrounded) Distance = FMin(Distance, VSizeSq(Palm - Prop.GroundPosition));
        if (Distance < BestDistance) { BestDistance = Distance; Best = Prop; }
    }
    if (bAirborneOnly) return Best;
    foreach Bridge.WorldInfo.AllActors(class'KFDroppedPickup', Stock)
    {
        if (!class'VRStockWorldPickup'.static.IsPickup(Stock)
            || !class'VRStockWorldPickup'.static.NearHand(Stock, Palm, Hand)) continue;
        Distance = VSizeSq(Palm - class'VRStockWorldPickup'.static.GrabPosition(Stock));
        if (Distance < BestDistance) { BestDistance = Distance; Best = Stock; }
    }
    foreach Bridge.WorldInfo.AllActors(class'KFPickupFactory_Item', Factory)
    {
        if (!class'VRStockWorldPickup'.static.IsPickup(Factory)
            || !class'VRStockWorldPickup'.static.NearHand(Factory, Palm, Hand)) continue;
        Distance = VSizeSq(Palm - class'VRStockWorldPickup'.static.GrabPosition(Factory));
        if (Distance < BestDistance) { BestDistance = Distance; Best = Factory; }
    }
    return Best;
}

function bool CatchContactValid(int H)
{
    local VRWorldDropGun Prop;
    local KFDroppedPickup Stock;
    local KFPickupFactory_Item Factory;
    if (CatchContact[H] == None || CatchContact[H].bDeleteMe || !EmptyHand(H) || !Down(H)) return false;
    Prop = VRWorldDropGun(CatchContact[H]);
    if (Prop != None)
        return Prop.OwnedWeapon == CatchContactWeapon[H] && Prop.DropOwner == CatchContactOwner[H]
            && Prop.InventoryClass == CatchContactClass[H] && Prop.CanPickupBy(Bridge.Human)
            && Prop.GripRoleAt(Bridge.PalmPosition(H), H, true) >= 0;
    if (!class'VRStockWorldPickup'.static.NearHand(CatchContact[H], Bridge.PalmPosition(H), H)) return false;
    Stock = KFDroppedPickup(CatchContact[H]);
    if (Stock != None) return Stock.InventoryClass == CatchContactClass[H];
    Factory = KFPickupFactory_Item(CatchContact[H]);
    return Factory != None && Factory.PickupIndex == CatchContactIndex[H]
        && Factory.ItemPickups[Factory.PickupIndex].ItemClass == CatchContactClass[H];
}

// Capture only the prop touched during a fresh squeeze. Waiting for another
// paid action may extend this exact contact, never the original search window.
function ObserveCatchContact(float Now)
{
    local VRWorldDropGun Prop;
    local KFDroppedPickup Stock;
    local KFPickupFactory_Item Factory;
    local int H;
    for (H = 0; H < 2; ++H)
    {
        if (Inventory.DeferredCatch[H].Weapon != None || HandPending(H) || !EmptyHand(H) || !Down(H)
            || (Inventory.WorldDrops != None && Inventory.WorldDrops.PredictionOwnsHand(H)))
        { CatchContact[H] = None; CatchUntil[H] = 0; AirCatchUntil[H] = 0; continue; }
        if (CatchContact[H] != None)
        {
            if (!CatchContactValid(H)) CatchContact[H] = None;
        }
        else if (CatchWindowOpen(H, false, Now) || CatchWindowOpen(H, true, Now))
        {
            CatchContact[H] = ContactGun(H, !CatchWindowOpen(H, false, Now));
            if (CatchContact[H] != None)
            {
                CatchUntil[H] = 0; AirCatchUntil[H] = 0; bCatchWindowOpen[H] = 0;
                Prop = VRWorldDropGun(CatchContact[H]);
                Stock = KFDroppedPickup(CatchContact[H]);
                Factory = KFPickupFactory_Item(CatchContact[H]);
                CatchContactWeapon[H] = Prop != None ? Prop.OwnedWeapon : None;
                CatchContactOwner[H] = Prop != None ? Prop.DropOwner : None;
                if (Prop != None) CatchContactClass[H] = Prop.InventoryClass;
                else if (Stock != None) CatchContactClass[H] = Stock.InventoryClass;
                else if (Factory != None)
                {
                    CatchContactIndex[H] = Factory.PickupIndex;
                    CatchContactClass[H] = Factory.ItemPickups[Factory.PickupIndex].ItemClass;
                }
            }
        }
        if (CatchContact[H] == None && bCatchWindowOpen[H] != 0 && Now > CatchUntil[H])
        {
            bCatchWindowOpen[H] = 0;
            LogCatchMiss(H);
        }
        if (CatchContact[H] != None) ClaimMask = ClaimMask | (1 << H);
    }
}

// A squeeze whose buffer expired without a catch contact, while one of our
// airborne guns was within reach: names the gun and why it did not qualify
// (no grip zone at the palm, or a prediction already owns it).
function LogCatchMiss(int H)
{
    local VRWorldDropGun Prop, Best;
    local vector Palm, PrimaryAt, SupportAt;
    local float Distance, BestDistance;
    Palm = Bridge.PalmPosition(H);
    BestDistance = Square(60.0);
    foreach Bridge.WorldInfo.AllActors(class'VRWorldDropGun', Prop)
    {
        if (Prop.bGrounded || !Prop.CanPickupBy(Bridge.Human)) continue;
        Distance = VSizeSq(Palm - Prop.GrabPosition());
        if (Prop.GripContacts(H, PrimaryAt, SupportAt))
            Distance = FMin(Distance, FMin(VSizeSq(Palm - PrimaryAt), VSizeSq(Palm - SupportAt)));
        if (Distance < BestDistance) { BestDistance = Distance; Best = Prop; }
    }
    if (Best == None) return;
    `log("KF2VR_WORLD_DROP phase=catch-miss hand=" $ H @ "weapon=" $ Best.InventoryClass
        @ "distance=" $ Sqrt(BestDistance) @ "zone=" $ Best.GripRoleAt(Palm, H, true)
        @ "predicted=" $ (Inventory.WorldDrops != None && Inventory.WorldDrops.PredictionFor(Best.OwnedWeapon) != None)
        @ "empty_hand=" $ EmptyHand(H));
}

function LogCatchRequest(int H, Actor Target, string Phase, optional byte GripRole)
{
    local VRWorldDropGun Prop;
    Prop = VRWorldDropGun(Target);
    `log("KF2VR_WORLD_DROP phase=" $ Phase @ "hand=" $ H
        @ "weapon=" $ (Prop != None ? string(Prop.InventoryClass) : (Target != None ? string(Target.Class) : "None"))
        @ "zone=" $ (Prop != None ? Prop.GripRoleAt(Bridge.PalmPosition(H), H, true) : -1)
        @ "role=" $ GripRole @ "airborne=" $ (Prop != None && !Prop.bGrounded));
}

function TryCatch(float Now)
{
    local KFWeapon W;
    local int H, Token;
    for (H = 0; H < 2; ++H)
    {
        if (HandPending(H) || Actions[H].QueuedRuntime != None || Inventory.DeferredCatch[H].Weapon != None) continue;
        if (!CatchContactValid(H)) { CatchContact[H] = None; continue; }
        W = CatchContactWeapon[H];
        Token = RequestCatch(CatchContact[H], H);
        // Transient refusals retry every tick; name the first one only.
        if (Token <= 0 && bCatchRequestLogged[H] == 0)
        { bCatchRequestLogged[H] = 1; LogCatchRequest(H, CatchContact[H], "catch-request-refused"); }
        if (Token > 0)
        {
            LogCatchRequest(H, CatchContact[H], "catch-request");
            CatchContact[H] = None;
            BeginPending(Token, H, 1, W);
        }
    }
}

function ArmCaughtWeapon(KFWeapon W, int Hand, optional bool bDraw)
{
    local VRWeaponRuntime R;
    local int I, Slot;
    if (Hand < 0 || Hand > 1 || !ValidContext(bDraw) || !Down(Hand)) return;
    // A deliberate draw may close only one of two wheels. Keep its exact
    // held identity until both close, while tracking/calibration loss still
    // cancels all release intent. A later open grip remains a real release.
    if (bDraw && (Calibration != Bridge.NativeCalibrationEpoch || RoomEpoch != Bridge.NativeRoomSpaceEpoch))
    {
        for (I = 0; I < 2; ++I) { Held[I].Runtime = None; Held[I].ArmedHands = 0; }
        Calibration = Bridge.NativeCalibrationEpoch; RoomEpoch = Bridge.NativeRoomSpaceEpoch;
    }
    R = Inventory.Registry.FindItem(W);
    if (R == None || (HeldMask(R) & (1 << Hand)) == 0) return;
    if (!bDraw) Inventory.InitialGripHoldWeapon[Hand] = None;
    // Draw commits before the coordinator observes the new held pair. Retire
    // replaced actors now, then prefer the exact actor over an earlier empty
    // slot so one physical item never acquires two competing release records.
    PruneHeldIntent();
    Slot = -1;
    for (I = 0; I < 2; ++I) if (Held[I].Runtime == R) Slot = I;
    if (Slot < 0)
        for (I = 0; I < 2; ++I) if (Held[I].Runtime == None && Slot < 0) Slot = I;
    if (Slot < 0) return;
    RefreshHeldIntent(Slot, R);
    Held[Slot].ArmedHands = Held[Slot].ArmedHands | (1 << Hand);
}

function DrainResult(int H)
{
    local byte Status, Action, Accepted, GripRole;
    local KFWeapon W;
    local vector Position;
    local quat Q;
    local VRWeaponRuntime R;
    if (Actions[H].PendingRequest <= 0) return;
    Status = ReadResult(Actions[H].PendingRequest, Action, Accepted, W, GripRole, Position, Q);
    if (Status == 0) return;
    bResultContextValid = !Actions[H].bPendingContextLost && ValidContext() && Bridge.Human == Actions[H].PendingHuman
        && Bridge.NativeCalibrationEpoch == Actions[H].PendingCalibration && Bridge.NativeRoomSpaceEpoch == Actions[H].PendingRoomEpoch;
    bResultGripHeld = bResultContextValid && H >= 0 && H < 2 && Down(H);
    bApplying = true;
    ApplyingHand = H;
    if (Status == 1 && Action == 1)
        `log("KF2VR_WORLD_DROP phase=catch-result hand=" $ H @ "weapon=" $ (W != None ? string(W.Class) : "None")
            @ "accepted=" $ (Accepted != 0) @ "role=" $ GripRole @ "context=" $ bResultContextValid
            @ "grip_held=" $ bResultGripHeld);
    else if (Status != 1 && Actions[H].PendingAction == 1)
        `log("KF2VR_WORLD_DROP phase=catch-result hand=" $ H @ "weapon=" $ Actions[H].PendingWeapon
            @ "accepted=False reason=no-reply status=" $ Status);
    if (Bridge.NativePromoEvents != 0 && Status == 1 && Action == 1 && Accepted != 0)
        Bridge.NativePromoAction(class'VRHandsBridge'.const.PROMO_GUN_CATCH, W, H);
    if (Status == 1) ApplyResult(W, H, Action, Accepted, GripRole, Position, Q);
    else if (Inventory.WorldDrops != None)
        Inventory.WorldDrops.AbandonPrediction(Actions[H].PendingWeapon, Actions[H].PendingRequest);
    // Keep Busy true through the callback; its own held-pair write is explicit.
    Actions[H].PendingRequest = 0; Actions[H].PendingHand = -1; Actions[H].PendingHuman = None; Actions[H].PendingWeapon = None; bApplying = false;
    ApplyingHand = -1;
    // A refused drop leaves the item in an open Hold hand; stow it.
    if (Status == 1 && Action == 0 && Accepted == 0 && bResultContextValid && !Bridge.bToggleGrip && Open(H))
        StowRefusedRelease(-1, H, W, "result");
    if (Status == 1 && Action == 1 && Accepted != 0 && !LatchedRole(GripRole) && Actions[H].bPendingCatchReleased
        && bResultContextValid && Open(H) && W != None
        && (Inventory.WorldDrops == None || Inventory.WorldDrops.PredictionFor(W) == None
            || Inventory.WorldDrops.PredictionFor(W).bConfirmedAcquire))
    {
        // This is an observed deliberate release from the same valid tracking
        // epoch, not an inferred grip-off sample after context loss. The catch
        // must settle first; then its exact newly owned frame can be released.
        R = Inventory.Registry.FindItem(W);
        if (R != None && HeldMask(R) != 0)
        {
            Inventory.PlaceAll();
            if (QueueRelease(R, H, Bridge.WorldInfo.RealTimeSeconds))
            {
                if (Bridge.WorldInfo.RealTimeSeconds - Actions[H].PendingCatchReleaseAt <= 0.25)
                { Actions[H].QueuedLinear = Actions[H].PendingCatchReleaseLinear; Actions[H].QueuedAngular = Actions[H].PendingCatchReleaseAngular; }
                else { Actions[H].QueuedLinear = vect(0,0,0); Actions[H].QueuedAngular = vect(0,0,0); }
            }
        }
        else if (Inventory.DeferredCatch[H].Weapon == W)
            Inventory.DeferredCatch[H].bRelease = true;
    }
    Actions[H].bPendingCatchReleased = false;
    if (Status == 1 && Action == 1 && Accepted != 0 && bResultGripHeld && W != None)
        ArmCaughtWeapon(W, H);
}

// Rejecting velocity history does not invalidate an already admitted catch.
// Current native poses, epochs and physical reach still have to be valid.
function bool CurrentCatchPoseValid()
{
    local int H;
    local float Grip;
    local vector Palm, Room;
    if (!ValidContext() || Bridge.NativeCalibrationEpoch != Calibration
        || Bridge.NativeRoomSpaceEpoch != RoomEpoch
        || !class'VRReloadMotionGuard'.static.ValidPosition(Bridge.HeadPosition)) return false;
    for (H = 0; H < 2; ++H)
    {
        Palm = Bridge.PalmPosition(H);
        Room = H == 0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
        Grip = H == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
        if (!class'VRReloadMotionGuard'.static.ValidPosition(Palm)
            || !class'VRReloadMotionGuard'.static.ValidPosition(Room)
            || VSizeSq(Palm - Bridge.HeadPosition) > Square(180.0)
            || !(Grip >= 0 && Grip <= 1.01)
            || !class'VRHandRolePose'.static.ValidQuaternion(QuatFromRotator(
                H == 0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation))) return false;
    }
    return true;
}

function Update(float Delta)
{
    local int H, I, DownMask;
    local float Now;
    local bool Valid, KeepHeld;
    ++TickNumber;
    ClaimMask = 0;
    Valid = ValidContext();
    if (bContextReady && (Bridge.NativeCalibrationEpoch != Calibration || Bridge.NativeRoomSpaceEpoch != RoomEpoch)) Valid = false;
    if (!Valid)
    {
        if (Inventory != None)
        {
            for (H = 0; H < 2; ++H)
            { Inventory.DeferredCatch[H].bGripSeen = false; Inventory.DeferredCatch[H].bRelease = false; }
        }
        for (H = 0; H < 2; ++H) if (HandPending(H)) Actions[H].bPendingContextLost = true;
        KeepHeld = ValidContext(true) && Calibration == Bridge.NativeCalibrationEpoch
            && RoomEpoch == Bridge.NativeRoomSpaceEpoch;
        ResetIntent(KeepHeld, KeepHeld);
        if (Hints != None) Hints.Update(false);
        for (H = 0; H < 2; ++H) DrainResult(H);
        return;
    }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (!bContextReady)
    {
        Calibration = Bridge.NativeCalibrationEpoch; RoomEpoch = Bridge.NativeRoomSpaceEpoch;
        bContextReady = true;
    }
    for (H = 0; H < 2; ++H)
        if (!SampleHand(H, Now))
        {
            KeepHeld = CurrentCatchPoseValid();
            if (!KeepHeld)
            {
                for (I = 0; I < 2; ++I)
                {
                    Inventory.DeferredCatch[I].bGripSeen = false;
                    Inventory.DeferredCatch[I].bRelease = false;
                    if (HandPending(I)) Actions[I].bPendingContextLost = true;
                }
                ResetIntent();
                if (Hints != None) Hints.Update(false);
                for (I = 0; I < 2; ++I) DrainResult(I);
                return;
            }
            // Current poses still admit contact and release. The discontinuity
            // never becomes a velocity sample, but the momentum and throw
            // history measured before it (and any queued release) are kept.
            ReseedHand(H, Now);
        }
    for (H = 0; H < 2; ++H)
        if (Inventory.DeferredCatch[H].Weapon != None
            && Inventory.DeferredCatch[H].Calibration == Bridge.NativeCalibrationEpoch
            && Inventory.DeferredCatch[H].RoomEpoch == Bridge.NativeRoomSpaceEpoch)
        {
            if (Down(H)) { Inventory.DeferredCatch[H].bGripSeen = true; Inventory.DeferredCatch[H].bRelease = false; }
            if (!LatchedRole(Inventory.DeferredCatch[H].Role) && Inventory.DeferredCatch[H].bGripSeen && Open(H))
                Inventory.DeferredCatch[H].bRelease = true;
        }
    EdgeMask = 0;
    for (H = 0; H < 2; ++H)
    {
        if (Open(H)) SawOpenMask = SawOpenMask | (1 << H);
        if (!Down(H)) continue;
        DownMask = DownMask | (1 << H);
        if ((PreviousDownMask & (1 << H)) == 0 && (SawOpenMask & (1 << H)) != 0)
        {
            EdgeMask = EdgeMask | (1 << H); EdgeTick[H] = TickNumber;
            CatchUntil[H] = Now + CatchBufferSeconds;
            AirCatchUntil[H] = Now + AirCatchSeconds;
            bCatchWindowOpen[H] = 1; bCatchRequestLogged[H] = 0;
            SawOpenMask = SawOpenMask & ~(1 << H);
        }
    }
    PreviousDownMask = DownMask;
    for (H = 0; H < 2; ++H)
    if (Actions[H].PendingRequest > 0 && Actions[H].PendingAction == 1 && !Actions[H].bPendingContextLost
        && !Actions[H].bPendingCatchReleased && Open(Actions[H].PendingHand))
    {
        Actions[H].bPendingCatchReleased = true;
        Actions[H].PendingCatchReleaseAt = Now;
        Actions[H].PendingCatchReleaseLinear = QuatRotateVector(Motion[Actions[H].PendingHand].ToWorld, Motion[Actions[H].PendingHand].Linear);
        Actions[H].PendingCatchReleaseAngular = QuatRotateVector(Motion[Actions[H].PendingHand].ToWorld, Motion[Actions[H].PendingHand].Angular);
    }
    if (Inventory.WorldDrops != None) Inventory.WorldDrops.ObservePredictions(Now);
    if (Hints != None) Hints.Update(true);
    for (H = 0; H < 2; ++H) DrainResult(H);
    ObserveHeld(Now);
    ObserveCatchContact(Now);
    // Each hand submits independently; authority serializes shared reserve commits.
    for (H = 0; H < 2; ++H) SubmitQueue(H, Now);
    TryCatch(Now);
}

// Root must keep polling submitted results during teardown, or explicitly
// abandon them through its transport before dropping this object.
function Shutdown()
{
    local int H;
    bShutDown = true;
    for (H = 0; H < 2; ++H) if (Actions[H].PendingRequest > 0) Actions[H].bPendingContextLost = true;
    ResetIntent();
    if (Hints != None) Hints.Shutdown();
}

defaultproperties
{
    ApplyingHand=-1
    ReleaseQueueSeconds=0.35
    CatchBufferSeconds=0.10
    AirCatchSeconds=0.75
}
